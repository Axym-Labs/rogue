#!/usr/bin/env bash
# Run Rogue against local Qwen inside a Docker-enforced workspace boundary.
set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPOSITORY="$(dirname "$SCRIPT_DIR")"
LOCAL_LLM_ROOT="${LOCAL_LLM_ROOT:-/home/davwis/main/harness/local-llm}"
LOCAL_LLM_START="${LOCAL_LLM_START:-$LOCAL_LLM_ROOT/scripts/start-local-llm-ninfer.sh}"
MODEL="${ROGUE_LOCAL_MODEL:-claude-opus-4-6[1m]}"
CONTEXT_WINDOW="${ROGUE_LOCAL_CONTEXT:-229376}"
IMAGE="${ROGUE_LOCAL_IMAGE:-axym/rogue-local-qwen:latest}"
WORKSPACE_ROOT="${LOCAL_ROGUE_WORKSPACE_ROOT:-/home/davwis/main/workspace}"
WRITABLE_DIR="${LOCAL_ROGUE_WORKDIR:-$WORKSPACE_ROOT/rogue-workdir}"
DRY_RUN=0
ROGUE_ARGS=()

usage() {
  printf '%s\n' \
    'Usage: local-qwen-sandbox.sh [--dry-run] [-- ROGUE_ARGS...]' \
    '' \
    'The complete ~/main/workspace tree is visible read-only. Only' \
    '~/main/workspace/rogue-workdir is writable.' \
    '' \
    'The default Rogue mode is continuous autonomy. The local Qwen server and' \
    'sandbox live only while this wrapper is running; Ctrl-C closes both.'
}

while (($#)); do
  case "$1" in
    --project)
      printf '%s\n' 'ERROR: --project is obsolete; local-rogue exposes the full workspace read-only' >&2
      exit 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      ROGUE_ARGS+=("$@")
      break
      ;;
    *)
      ROGUE_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ -d "$WORKSPACE_ROOT" ]] || { printf 'ERROR: workspace directory does not exist: %s\n' "$WORKSPACE_ROOT" >&2; exit 2; }
WORKSPACE_ROOT="$(realpath "$WORKSPACE_ROOT")"
[[ "$WORKSPACE_ROOT" != / ]] || { printf '%s\n' 'ERROR: refusing to expose the filesystem root as a workspace' >&2; exit 2; }

WRITABLE_DIR="$(realpath -m "$WRITABLE_DIR")"
case "$WRITABLE_DIR" in
  "$WORKSPACE_ROOT"/*) ;;
  *) printf 'ERROR: writable directory must be inside the workspace: %s\n' "$WRITABLE_DIR" >&2; exit 2 ;;
esac
mkdir -p "$WRITABLE_DIR"
WRITABLE_DIR="$(realpath "$WRITABLE_DIR")"
[[ "$WRITABLE_DIR" != "$WORKSPACE_ROOT" ]] || { printf '%s\n' 'ERROR: the complete workspace cannot be writable' >&2; exit 2; }
WRITABLE_RELATIVE="${WRITABLE_DIR#"$WORKSPACE_ROOT"/}"
CONTAINER_WRITABLE_DIR="/workspace/$WRITABLE_RELATIVE"

# File names only: values are deliberately never opened. The workspace bind is
# the complete read-only host view; these nested empty-file mounts hide common
# secrets in both the read-only tree and the nested writable directory.
mapfile -d '' MASKED_CREDENTIALS < <(
  find "$WORKSPACE_ROOT" -xdev -type f \
    \( \
      -name '.env' -o -name '.env.*' -o \
      -name '*.pem' -o -name '*.key' -o \
      -name 'id_rsa' -o -name 'id_ed25519' -o \
      -name '.netrc' -o -name '.npmrc' -o -name '.pypirc' -o \
      -name '.git-credentials' -o -name 'credentials.json' -o \
      -name 'secrets.json' -o -name 'auth.json' -o \
      -path '*/.rogue/config.json' \
    \) \
    ! -name '.env.example' ! -name '.env.sample' \
    -printf '%P\0' | sort -z
)

masked_json="$({ for item in "${MASKED_CREDENTIALS[@]}"; do printf '%s\0' "$item"; done; } | jq -Rs 'split("\u0000")[:-1]')"
if [[ "$DRY_RUN" == 1 ]]; then
  jq -n \
    --arg workspace "$WORKSPACE_ROOT" \
    --arg workdir "$WRITABLE_DIR" \
    --arg containerWorkdir "$CONTAINER_WRITABLE_DIR" \
    --arg repository "$REPOSITORY" \
    --arg model "$MODEL" \
    --argjson context "$CONTEXT_WINDOW" \
    --argjson masked "$masked_json" \
    '{
      workspace: $workspace,
      workdir: $workdir,
      repository: $repository,
      model: $model,
      contextWindow: $context,
      reasoning: "xhigh",
      network: "internal",
      mounts: [
        {source: $workspace, target: "/workspace", mode: "ro"},
        {source: $workdir, target: $containerWorkdir, mode: "rw"}
      ],
      maskedCredentials: $masked,
      security: {
        readOnlyRoot: true,
        capabilities: [],
        noNewPrivileges: true,
        dockerSocket: false,
        hostNamespaces: false,
        internet: false
      }
    }'
  exit 0
fi

command -v docker >/dev/null || { printf '%s\n' 'ERROR: Docker is required' >&2; exit 1; }
command -v curl >/dev/null || { printf '%s\n' 'ERROR: curl is required' >&2; exit 1; }
[[ -x "$LOCAL_LLM_START" ]] || { printf 'ERROR: local Qwen launcher not found: %s\n' "$LOCAL_LLM_START" >&2; exit 1; }

REVISION="$(git -C "$REPOSITORY" rev-parse HEAD)"
BUILT_REVISION="$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$IMAGE" 2>/dev/null || true)"
if [[ "$BUILT_REVISION" != "$REVISION" ]]; then
  npm --prefix "$REPOSITORY" run build
  docker build \
    --build-arg "ROGUE_UID=$(id -u)" \
    --build-arg "ROGUE_GID=$(id -g)" \
    --build-arg "ROGUE_REVISION=$REVISION" \
    --tag "$IMAGE" \
    "$REPOSITORY"
fi

TOKEN="$(printf '%s' "$WORKSPACE_ROOT" | sha256sum | cut -c1-12)"
NETWORK="axym-rogue-$TOKEN-$$"
CONTAINER="axym-rogue-$TOKEN-$$"
STATE_VOLUME="axym-rogue-state-$TOKEN"
MODEL_CONTAINER="${LOCAL_LLM_CONTAINER_NAME:-${NINFER_CONTAINER_NAME:-local-llm}}"
MODEL_STARTED=0
MODEL_CONNECTED=0
BOOTSTRAP="$(mktemp)"

cleanup() {
  trap - EXIT INT TERM HUP
  docker stop --time 5 "$CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [[ "$MODEL_CONNECTED" == 1 ]]; then
    docker network disconnect "$NETWORK" "$MODEL_CONTAINER" >/dev/null 2>&1 || true
  fi
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  if [[ "$MODEL_STARTED" == 1 ]]; then
    docker stop --time 10 "$MODEL_CONTAINER" >/dev/null 2>&1 || true
  fi
  rm -f "$BOOTSTRAP"
}
trap cleanup EXIT INT TERM HUP

if [[ "$(docker inspect -f '{{.State.Running}}' "$MODEL_CONTAINER" 2>/dev/null || true)" != true ]]; then
  LOCAL_LLM_DETACH=1 "$LOCAL_LLM_START" >/tmp/axym-local-qwen.log 2>&1
  MODEL_STARTED=1
fi

printf '%s\n' 'Waiting for local Qwen…' >&2
for _ in $(seq 1 180); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then break; fi
  sleep 1
done
curl --fail --silent --max-time 5 http://127.0.0.1:8000/v1/models >/dev/null || {
  printf '%s\n' 'ERROR: local Qwen did not become ready; see /tmp/axym-local-qwen.log' >&2
  exit 1
}

docker network create --internal "$NETWORK" >/dev/null
docker network connect --alias local-llm "$NETWORK" "$MODEL_CONTAINER"
MODEL_CONNECTED=1

jq -n \
  --arg model "$MODEL" \
  --argjson context "$CONTEXT_WINDOW" \
  '{
    customProviders: [{
      id: "local-qwen",
      name: "Local Qwen 27B",
      baseUrl: "http://local-llm:8000",
      api: "anthropic-messages",
      contextWindow: $context,
      maxTokens: 32768,
      reasoning: true,
      models: [{id: $model, name: "Qwen3.8 27B NVFP4", reasoning: true, contextWindow: $context, maxTokens: 32768}]
    }],
    providers: [{provider: "local-qwen", model: $model, priority: 0}],
    relays: []
  }' >"$BOOTSTRAP"
chmod 0600 "$BOOTSTRAP"

DOCKER_ARGS=(
  run --detach
  --name "$CONTAINER"
  --restart unless-stopped
  --network "$NETWORK"
  --user "$(id -u):$(id -g)"
  --read-only
  --cap-drop ALL
  --security-opt no-new-privileges:true
  --pids-limit 256
  --memory 8g
  --cpus 8
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=512m
  --env HOME=/tmp
  --env "ROGUE_WORKSPACE=$CONTAINER_WRITABLE_DIR"
  --env ROGUE_STATE_DIR=/state
  --env ROGUE_BOOTSTRAP=/state/initial_auth.json
  --env ROGUE_INITIAL_AUTH_FILE=/run/rogue/initial_auth.json
  --env ROGUE_THINKING=xhigh
  --env ROGUE_CACHE_RETENTION=none
  --env 'ROGUE_EXTRA_ARGS=--no-failover'
  --mount "type=bind,src=$WORKSPACE_ROOT,dst=/workspace,readonly"
  --mount "type=bind,src=$WRITABLE_DIR,dst=$CONTAINER_WRITABLE_DIR"
  --mount "type=volume,src=$STATE_VOLUME,dst=/state"
  --mount "type=bind,src=$BOOTSTRAP,dst=/run/rogue/initial_auth.json,readonly"
)
for relative in "${MASKED_CREDENTIALS[@]}"; do
  [[ "$relative" != *$'\n'* && "$relative" != *,* ]] || {
    printf 'ERROR: unsupported credential path: %q\n' "$relative" >&2
    exit 1
  }
  DOCKER_ARGS+=(--mount "type=bind,src=/dev/null,dst=/workspace/$relative,readonly")
done
DOCKER_ARGS+=("$IMAGE" "${ROGUE_ARGS[@]}")

docker "${DOCKER_ARGS[@]}" >/dev/null
printf 'Rogue can read %s and write only %s; %d credential file(s) are hidden. Ctrl-C stops Rogue and Qwen.\n' \
  "$WORKSPACE_ROOT" "$WRITABLE_DIR" "${#MASKED_CREDENTIALS[@]}" >&2
FIRST_LOG=1
while docker inspect "$CONTAINER" >/dev/null 2>&1; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]]; then
    # A model-issued exit cannot end the supervised service. An explicit user
    # Ctrl-C/HUP reaches the wrapper trap instead and removes the container.
    docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ "$FIRST_LOG" == 1 ]]; then
    docker logs --follow "$CONTAINER" || true
    FIRST_LOG=0
  else
    docker logs --tail 20 --follow "$CONTAINER" || true
  fi
  sleep 1
done
