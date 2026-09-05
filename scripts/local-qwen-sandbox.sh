#!/usr/bin/env bash
# Run Rogue against local Qwen inside a Docker-enforced workspace boundary.
set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPOSITORY="$(dirname "$SCRIPT_DIR")"
ACTIVITY_LOGGER="$SCRIPT_DIR/append-daily-log.sh"
GITLEAKS_CONFIG="$REPOSITORY/config/gitleaks-sandbox.toml"
PERMISSIONS_NOTE="$REPOSITORY/config/00-READ-ME-FIRST.md"
LOCAL_LLM_ROOT="${LOCAL_LLM_ROOT:-/home/davwis/main/harness/local-llm}"
LOCAL_LLM_START="${LOCAL_LLM_START:-$LOCAL_LLM_ROOT/scripts/start-local-llm-ninfer.sh}"
MODEL="${ROGUE_LOCAL_MODEL:-claude-opus-4-6[1m]}"
CONTEXT_WINDOW="${ROGUE_LOCAL_CONTEXT:-229376}"
IMAGE="${ROGUE_LOCAL_IMAGE:-axym/rogue-local-qwen:latest}"
VPN_IMAGE="${LOCAL_ROGUE_VPN_IMAGE:-qmcgaw/gluetun@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027}"
VPN_CONFIG="${LOCAL_ROGUE_VPN_CONFIG:-/home/davwis/.config/local-rogue/wg0.conf}"
WORKSPACE_ROOT="${LOCAL_ROGUE_WORKSPACE_ROOT:-/home/davwis/main/workspace}"
WRITABLE_DIR="${LOCAL_ROGUE_WORKDIR:-$WORKSPACE_ROOT/rogue-workdir}"
ACTIVITY_LOG_DIR="${LOCAL_ROGUE_LOG_DIR:-/home/davwis/.local/state/local-rogue/logs}"
LOG_RETENTION_DAYS="${LOCAL_ROGUE_LOG_RETENTION_DAYS:-90}"
SESSION_RETENTION_DAYS="${LOCAL_ROGUE_SESSION_RETENTION_DAYS:-90}"
CYCLE_DELAY_SECONDS="${LOCAL_ROGUE_CYCLE_DELAY_SECONDS:-300}"
DRY_RUN=0
ROGUE_ARGS=()

usage() {
  printf '%s\n' \
    'Usage: local-qwen-sandbox.sh [--dry-run] [-- ROGUE_ARGS...]' \
    '' \
    'The complete ~/main/workspace tree is visible read-only. Only' \
    '~/main/workspace/rogue-workdir is writable.' \
    'Internet access is available only through the isolated VPN gateway.' \
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

ACTIVITY_LOG_DIR="$(realpath -m "$ACTIVITY_LOG_DIR")"
case "$ACTIVITY_LOG_DIR" in
  "$WORKSPACE_ROOT"|"$WORKSPACE_ROOT"/*)
    printf 'ERROR: activity logs must be outside the exposed workspace: %s\n' "$ACTIVITY_LOG_DIR" >&2
    exit 2
    ;;
esac
[[ -x "$ACTIVITY_LOGGER" ]] || { printf 'ERROR: activity logger not found: %s\n' "$ACTIVITY_LOGGER" >&2; exit 1; }
command -v bwrap >/dev/null || { printf '%s\n' 'ERROR: bubblewrap is required for isolated secret scanning' >&2; exit 1; }
command -v gitleaks >/dev/null || { printf '%s\n' 'ERROR: Gitleaks is required for preflight secret scanning' >&2; exit 1; }
[[ -f "$GITLEAKS_CONFIG" ]] || { printf 'ERROR: Gitleaks config not found: %s\n' "$GITLEAKS_CONFIG" >&2; exit 1; }
[[ -f "$PERMISSIONS_NOTE" ]] || { printf 'ERROR: permissions note not found: %s\n' "$PERMISSIONS_NOTE" >&2; exit 1; }
for retention in "$LOG_RETENTION_DAYS" "$SESSION_RETENTION_DAYS"; do
  [[ "$retention" =~ ^[0-9]+$ ]] && ((retention >= 1 && retention <= 3650)) || {
    printf 'ERROR: invalid retention period: %s\n' "$retention" >&2
    exit 2
  }
done
[[ "$CYCLE_DELAY_SECONDS" =~ ^[0-9]+$ ]] && ((CYCLE_DELAY_SECONDS <= 86400)) || {
  printf 'ERROR: invalid cycle delay in seconds: %s\n' "$CYCLE_DELAY_SECONDS" >&2
  exit 2
}

RUNTIME_DIR="$(mktemp -d)"
chmod 0700 "$RUNTIME_DIR"
MASK_DIRECTORY="$RUNTIME_DIR/hidden"
mkdir "$MASK_DIRECTORY"
chmod 000 "$MASK_DIRECTORY"
MASK_FILE="$RUNTIME_DIR/hidden-file"
touch "$MASK_FILE"
chmod 000 "$MASK_FILE"
cleanup_runtime() {
  trap - EXIT INT TERM HUP
  chmod 0700 "$MASK_DIRECTORY" 2>/dev/null || true
  find "$RUNTIME_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup_runtime EXIT INT TERM HUP

mapfile -d '' MASKED_DIRECTORIES < <(
  find "$WORKSPACE_ROOT" -xdev \
    -path "$WRITABLE_DIR" -prune -o \
    -type d \( \
      -name '.git' -o -name '.hg' -o -name '.svn' -o \
      -name '.rogue' -o -name '.codex' -o -name '.claude' -o \
      -name '.ssh' -o -name '.aws' -o -name '.azure' -o \
      -name '.gnupg' -o -name '.kube' -o -name '.docker' -o \
      -name '.password-store' -o -name '.config' -o -name '.local' -o \
      -name '.cache' \
    \) -printf '%P\0' -prune | sort -z
)

mapfile -d '' SPECIAL_NODES < <(
  find "$WORKSPACE_ROOT" -xdev \
    -type d \( \
      -name '.git' -o -name '.hg' -o -name '.svn' -o \
      -name '.rogue' -o -name '.codex' -o -name '.claude' -o \
      -name '.ssh' -o -name '.aws' -o -name '.azure' -o \
      -name '.gnupg' -o -name '.kube' -o -name '.docker' -o \
      -name '.password-store' -o -name '.config' -o -name '.local' -o \
      -name '.cache' \
    \) -prune -o \
    \( -type s -o -type p -o -type b -o -type c \) -printf '%P\0'
)
if ((${#SPECIAL_NODES[@]})); then
  printf '%s\n' 'ERROR: refusing workspace with an exposed IPC or device node:' >&2
  printf '  %q\n' "${SPECIAL_NODES[@]}" >&2
  exit 2
fi

# File names only: values are deliberately never opened. The workspace bind is
# the complete read-only host view; nested unreadable mounts hide common secrets
# outside the agent-owned writable directory.
mapfile -d '' MASKED_CREDENTIALS < <(
  find "$WORKSPACE_ROOT" -xdev \
    -path "$WRITABLE_DIR" -prune -o \
    -type d \( \
      -name '.git' -o -name '.hg' -o -name '.svn' -o \
      -name '.rogue' -o -name '.codex' -o -name '.claude' -o \
      -name '.ssh' -o -name '.aws' -o -name '.azure' -o \
      -name '.gnupg' -o -name '.kube' -o -name '.docker' -o \
      -name '.password-store' -o -name '.config' -o -name '.local' -o \
      -name '.cache' \
    \) -prune -o \
    -type f \
    \( \
      -name '.env' -o -name '.env.*' -o -name '.envrc' -o \
      -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' -o \
      -iname '*.pfx' -o -iname '*.jks' -o -iname '*.keystore' -o \
      -name 'id_rsa' -o -name 'id_ed25519' -o \
      -name '.netrc' -o -name '.npmrc' -o -name '.pypirc' -o \
      -name '.git-credentials' -o -name '.gitmodules' -o -name 'pip.conf' -o \
      -iname '*credentials*.json' -o -iname '*secrets*.json' -o \
      -iname 'client_secret*.json' -o -iname 'service-account*.json' -o \
      -iname 'token.json' -o -iname '*_token.json' -o -iname 'auth.json' -o \
      -iname 'terraform.tfstate*' -o -iname '*.tfvars' -o -iname '*.kdbx' \
    \) \
    ! -name '.env.example' ! -name '.env.sample' \
    -printf '%P\0' | sort -z
)

SECRET_REPORT="$RUNTIME_DIR/gitleaks.json"
set +e
bwrap \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind "$(command -v gitleaks)" /gitleaks \
  --ro-bind "$GITLEAKS_CONFIG" /gitleaks.toml \
  --ro-bind "$WORKSPACE_ROOT" /workspace \
  --bind "$RUNTIME_DIR" /runtime \
  --tmpfs /tmp \
  --proc /proc \
  --dev /dev \
  --chdir /workspace \
  /gitleaks dir \
    --config /gitleaks.toml \
    --no-banner \
    --no-color \
    --log-level error \
    --redact=100 \
    --max-archive-depth 0 \
    --max-decode-depth 0 \
    --max-target-megabytes 2 \
    --timeout 60 \
    --report-format json \
    --report-path /runtime/gitleaks.json \
    . >/dev/null 2>"$RUNTIME_DIR/gitleaks.stderr"
GITLEAKS_STATUS=$?
set -e
if [[ "$GITLEAKS_STATUS" != 0 && "$GITLEAKS_STATUS" != 1 ]]; then
  printf '%s\n' 'ERROR: isolated Gitleaks preflight failed closed' >&2
  exit 1
fi
[[ -f "$SECRET_REPORT" ]] || printf '%s\n' '[]' >"$SECRET_REPORT"

mapfile -d '' SCANNED_CREDENTIALS < <(
  jq -jr '.[] | .File, "\u0000"' "$SECRET_REPORT" |
    while IFS= read -r -d '' relative; do
      relative="${relative#./}"
      [[ "$relative" == "$WRITABLE_RELATIVE" || "$relative" == "$WRITABLE_RELATIVE"/* ]] && continue
      printf '%s\0' "$relative"
    done
)
MASKED_CREDENTIALS+=("${SCANNED_CREDENTIALS[@]}")
mapfile -d '' MASKED_CREDENTIALS < <(
  { for item in "${MASKED_CREDENTIALS[@]}"; do printf '%s\0' "$item"; done; } | sort -zu
)
# A directory mask already hides every descendant. Emitting nested file mounts
# beneath that empty read-only directory is redundant and Docker cannot create
# their mountpoints without weakening the parent boundary.
FILTERED_CREDENTIALS=()
for credential in "${MASKED_CREDENTIALS[@]}"; do
  hidden_by_directory=0
  for directory in "${MASKED_DIRECTORIES[@]}"; do
    if [[ "$credential" == "$directory"/* ]]; then
      hidden_by_directory=1
      break
    fi
  done
  [[ "$hidden_by_directory" == 1 ]] || FILTERED_CREDENTIALS+=("$credential")
done
MASKED_CREDENTIALS=("${FILTERED_CREDENTIALS[@]}")
GITLEAKS_VERSION="$(gitleaks version)"
SECRET_FINDINGS="${#SCANNED_CREDENTIALS[@]}"

masked_json="$({ for item in "${MASKED_CREDENTIALS[@]}"; do printf '%s\0' "$item"; done; } | jq -Rs 'split("\u0000")[:-1]')"
masked_directories_json="$({ for item in "${MASKED_DIRECTORIES[@]}"; do printf '%s\0' "$item"; done; } | jq -Rs 'split("\u0000")[:-1]')"
if [[ "$DRY_RUN" == 1 ]]; then
  jq -n \
    --arg workspace "$WORKSPACE_ROOT" \
    --arg workdir "$WRITABLE_DIR" \
    --arg containerWorkdir "$CONTAINER_WRITABLE_DIR" \
    --arg activityLogDir "$ACTIVITY_LOG_DIR" \
    --arg vpnImage "$VPN_IMAGE" \
    --arg vpnConfig "$VPN_CONFIG" \
    --arg permissionsNote "$PERMISSIONS_NOTE" \
    --arg repository "$REPOSITORY" \
    --arg model "$MODEL" \
    --argjson context "$CONTEXT_WINDOW" \
    --argjson logRetentionDays "$LOG_RETENTION_DAYS" \
    --argjson sessionRetentionDays "$SESSION_RETENTION_DAYS" \
    --argjson cycleDelaySeconds "$CYCLE_DELAY_SECONDS" \
    --argjson masked "$masked_json" \
    --argjson maskedDirectories "$masked_directories_json" \
    --arg gitleaksVersion "$GITLEAKS_VERSION" \
    --argjson secretFindings "$SECRET_FINDINGS" \
    '{
      workspace: $workspace,
      workdir: $workdir,
      repository: $repository,
      model: $model,
      contextWindow: $context,
      reasoning: "xhigh",
      network: "vpn-only",
      vpnGateway: {
        image: $vpnImage,
        config: $vpnConfig,
        proxy: "http://vpn-gateway:8888",
        killSwitch: true,
        credentialsExposedToAgent: false,
        directInternet: false
      },
      mounts: [
        {source: $workspace, target: "/workspace", mode: "ro"},
        {source: $workdir, target: $containerWorkdir, mode: "rw"}
      ],
      activityLogs: {
        directory: $activityLogDir,
        rolling: "daily",
        retentionDays: $logRetentionDays,
        timestamps: "UTC",
        sessionTagged: true,
        accessibleToAgent: false
      },
      conversationRetentionDays: $sessionRetentionDays,
      cycleDelaySeconds: $cycleDelaySeconds,
      permissionNote: {
        source: $permissionsNote,
        target: ($containerWorkdir + "/00-READ-ME-FIRST.md"),
        mode: "ro"
      },
      maskedCredentials: $masked,
      maskedDirectories: $maskedDirectories,
      secretScan: {
        tool: "gitleaks",
        version: $gitleaksVersion,
        redacted: true,
        findings: $secretFindings
      },
      modelService: {
        dedicated: true,
        hostIpc: false,
        outboundNetwork: false,
        readOnlyRoot: true,
        capabilities: [],
        noNewPrivileges: true
      },
      security: {
        readOnlyRoot: true,
        capabilities: [],
        noNewPrivileges: true,
        dockerSocket: false,
        hostNamespaces: false,
        internet: "vpn-only",
        recursiveSubmounts: false,
        apparmor: "docker-default",
        seccomp: "builtin",
        ipc: "private",
        cgroupns: "private",
        restartPolicy: "no"
      }
    }'
  exit 0
fi

command -v docker >/dev/null || { printf '%s\n' 'ERROR: Docker is required' >&2; exit 1; }
[[ -x "$LOCAL_LLM_START" ]] || { printf 'ERROR: local Qwen launcher not found: %s\n' "$LOCAL_LLM_START" >&2; exit 1; }
[[ -f "$VPN_CONFIG" ]] || {
  printf 'ERROR: VPN WireGuard config not found: %s\n' "$VPN_CONFIG" >&2
  printf '%s\n' 'Download a WireGuard config (a free Proton VPN account works) and save it there with mode 0600.' >&2
  exit 1
}
VPN_CONFIG="$(realpath "$VPN_CONFIG")"
case "$VPN_CONFIG" in
  "$WORKSPACE_ROOT"|"$WORKSPACE_ROOT"/*)
    printf 'ERROR: VPN config must be outside the agent-visible workspace: %s\n' "$VPN_CONFIG" >&2
    exit 2
    ;;
esac
VPN_CONFIG_MODE="$(stat -c '%a' "$VPN_CONFIG")"
VPN_CONFIG_OWNER="$(stat -c '%u' "$VPN_CONFIG")"
if (( (0$VPN_CONFIG_MODE & 077) != 0 )) || [[ "$VPN_CONFIG_OWNER" != "$(id -u)" ]]; then
  printf 'ERROR: VPN config must be owned by UID %s and unreadable by group/others (mode 0600): %s\n' "$(id -u)" "$VPN_CONFIG" >&2
  exit 2
fi
grep -Eq '^\[Interface\][[:space:]]*$' "$VPN_CONFIG" \
  && grep -Eq '^[[:space:]]*PrivateKey[[:space:]]*=' "$VPN_CONFIG" \
  && grep -Eq '^\[Peer\][[:space:]]*$' "$VPN_CONFIG" \
  && grep -Eq '^[[:space:]]*PublicKey[[:space:]]*=' "$VPN_CONFIG" \
  && grep -Eq '^[[:space:]]*Endpoint[[:space:]]*=' "$VPN_CONFIG" \
  && grep -Eq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0\.0\.0\.0/0' "$VPN_CONFIG" || {
  printf 'ERROR: VPN config is not a complete full-tunnel WireGuard client configuration: %s\n' "$VPN_CONFIG" >&2
  exit 2
}
if grep -Eq '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown)[[:space:]]*=' "$VPN_CONFIG"; then
  printf 'ERROR: refusing executable hooks in VPN config: %s\n' "$VPN_CONFIG" >&2
  exit 2
fi
mkdir -p "$ACTIVITY_LOG_DIR"
chmod 0700 "$ACTIVITY_LOG_DIR"

PERMISSIONS_TARGET="$WRITABLE_DIR/00-READ-ME-FIRST.md"
if [[ -L "$PERMISSIONS_TARGET" ]]; then
  rm "$PERMISSIONS_TARGET"
elif [[ -e "$PERMISSIONS_TARGET" && ! -f "$PERMISSIONS_TARGET" ]]; then
  printf 'ERROR: permissions-note target is not a regular file: %s\n' "$PERMISSIONS_TARGET" >&2
  exit 2
fi
install -m 0444 "$PERMISSIONS_NOTE" "$PERMISSIONS_TARGET"

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
LOG_SESSION="$TOKEN-$$"
NETWORK="axym-rogue-$TOKEN-$$"
EGRESS_NETWORK="axym-rogue-vpn-egress-$TOKEN-$$"
CONTAINER="axym-rogue-$TOKEN-$$"
VPN_CONTAINER="axym-rogue-vpn-$TOKEN-$$"
VPN_STATE_VOLUME="axym-rogue-vpn-state-$TOKEN-$$"
STATE_VOLUME="axym-rogue-state-$TOKEN"
MODEL_CONTAINER="${LOCAL_LLM_CONTAINER_NAME:-${NINFER_CONTAINER_NAME:-local-llm}}"
MODEL_STARTED=0
VPN_STARTED=0
BOOTSTRAP="$RUNTIME_DIR/initial_auth.json"
MODEL_LOG="$RUNTIME_DIR/model.log"
LOG_FIFO="$RUNTIME_DIR/activity.pipe"
DOCKER_LOG_PID=0
LOG_READER_PID=0
SESSION_LOGGED=0
mkfifo "$LOG_FIFO"
VPN_RESOLV="$RUNTIME_DIR/vpn-resolv.conf"
touch "$VPN_RESOLV"
chmod 0666 "$VPN_RESOLV"

log_metadata() {
  printf '%s\n' "$1" | \
    LOCAL_ROGUE_LOG_DIR="$ACTIVITY_LOG_DIR" \
    LOCAL_ROGUE_LOG_RETENTION_DAYS="$LOG_RETENTION_DAYS" \
    LOCAL_ROGUE_LOG_SESSION="$LOG_SESSION" \
    "$ACTIVITY_LOGGER" >/dev/null
}

cleanup() {
  trap - EXIT INT TERM HUP
  if [[ "$DOCKER_LOG_PID" != 0 ]]; then
    kill "$DOCKER_LOG_PID" 2>/dev/null || true
    wait "$DOCKER_LOG_PID" 2>/dev/null || true
  fi
  if [[ "$LOG_READER_PID" != 0 ]]; then
    kill "$LOG_READER_PID" 2>/dev/null || true
    wait "$LOG_READER_PID" 2>/dev/null || true
  fi
  if [[ "$SESSION_LOGGED" == 1 ]]; then
    log_metadata "event=session_stop"
    SESSION_LOGGED=0
  fi
  docker stop --time 5 "$CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [[ "$MODEL_STARTED" == 1 ]]; then
    docker stop --time 10 "$MODEL_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ "$VPN_STARTED" == 1 ]]; then
    docker stop --time 5 "$VPN_CONTAINER" >/dev/null 2>&1 || true
  fi
  docker rm -f "$VPN_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker network rm "$EGRESS_NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$VPN_STATE_VOLUME" >/dev/null 2>&1 || true
  chmod 0700 "$MASK_DIRECTORY" 2>/dev/null || true
  find "$RUNTIME_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

mapfile -t ACTIVE_ROGUES < <(docker ps -q --filter label=com.axym.local-rogue=true)
if ((${#ACTIVE_ROGUES[@]})); then
  printf '%s\n' 'ERROR: another contained Rogue session is already running' >&2
  exit 1
fi
mapfile -t STALE_ROGUES < <(docker ps -aq --filter status=exited --filter label=com.axym.local-rogue=true)
if ((${#STALE_ROGUES[@]})); then
  docker rm "${STALE_ROGUES[@]}" >/dev/null
fi
mapfile -t STALE_VPNS < <(docker ps -aq --filter label=com.axym.local-rogue-vpn=true)
if ((${#STALE_VPNS[@]})); then
  docker rm -f "${STALE_VPNS[@]}" >/dev/null
fi
mapfile -t STALE_VPN_VOLUMES < <(docker volume ls -q --filter label=com.axym.local-rogue-vpn=true)
if ((${#STALE_VPN_VOLUMES[@]})); then
  docker volume rm "${STALE_VPN_VOLUMES[@]}" >/dev/null 2>&1 || true
fi

if docker inspect "$MODEL_CONTAINER" >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: refusing to reuse an existing local model container; stop it before starting local-rogue' >&2
  exit 1
fi
docker network create --internal "$NETWORK" >/dev/null
docker network create "$EGRESS_NETWORK" >/dev/null
docker volume create --label com.axym.local-rogue-vpn=true "$VPN_STATE_VOLUME" >/dev/null
# Copy the user-owned 0600 credential into a root-owned ephemeral volume. This
# short-lived initializer has no network and only read-search privilege; the
# long-running gateway receives neither that privilege nor the host path.
docker run --rm \
  --network none \
  --read-only \
  --cap-drop ALL \
  --cap-add DAC_READ_SEARCH \
  --security-opt no-new-privileges:true \
  --pids-limit 16 \
  --memory 64m \
  --memory-swap 64m \
  --mount "type=volume,src=$VPN_STATE_VOLUME,dst=/gluetun,volume-nocopy" \
  --mount "type=bind,src=$VPN_CONFIG,dst=/run/wg0.conf,readonly" \
  --entrypoint /bin/sh \
  "$VPN_IMAGE" \
  -c 'install -d -m 700 /gluetun/wireguard && install -m 400 /run/wg0.conf /gluetun/wireguard/wg0.conf'
docker create \
  --name "$VPN_CONTAINER" \
  --hostname vpn-gateway \
  --label com.axym.local-rogue-vpn=true \
  --restart no \
  --network "$EGRESS_NETWORK" \
  --read-only \
  --cap-drop ALL \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  --security-opt no-new-privileges:true \
  --security-opt apparmor=docker-default \
  --security-opt seccomp=builtin \
  --cgroupns private \
  --ipc private \
  --pids-limit 128 \
  --memory 512m \
  --memory-swap 512m \
  --cpus 2 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
  --mount "type=volume,src=$VPN_STATE_VOLUME,dst=/gluetun,volume-nocopy" \
  --mount "type=bind,src=$VPN_RESOLV,dst=/etc/resolv.conf" \
  --env PUID=0 \
  --env PGID=0 \
  --env VPN_SERVICE_PROVIDER=custom \
  --env VPN_TYPE=wireguard \
  --env HTTPPROXY=on \
  --env HTTPPROXY_LOG=off \
  --env HTTPPROXY_LISTENING_ADDRESS=:8888 \
  --env FIREWALL_INPUT_PORTS=8888 \
  --env PUBLICIP_ENABLED=off \
  --env VERSION_INFORMATION=off \
  --env TZ=UTC \
  "$VPN_IMAGE" >/dev/null
docker network connect --alias vpn-gateway "$NETWORK" "$VPN_CONTAINER"
docker start "$VPN_CONTAINER" >/dev/null
VPN_STARTED=1

printf '%s\n' 'Waiting for the VPN kill-switch gateway…' >&2
for _ in $(seq 1 90); do
  VPN_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$VPN_CONTAINER" 2>/dev/null || true)"
  [[ "$VPN_HEALTH" == healthy ]] && break
  [[ "$VPN_HEALTH" == unhealthy || "$VPN_HEALTH" == exited || "$VPN_HEALTH" == dead ]] && break
  sleep 1
done
[[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$VPN_CONTAINER" 2>/dev/null || true)" == healthy ]] || {
  printf '%s\n' 'ERROR: VPN gateway did not become healthy; refusing to start Qwen or Rogue.' >&2
  exit 1
}

LOCAL_LLM_DETACH=1 \
  LOCAL_LLM_DOCKER_NETWORK="$NETWORK" \
  LOCAL_LLM_NETWORK_ALIAS=local-llm \
  "$LOCAL_LLM_START" >"$MODEL_LOG" 2>&1
MODEL_STARTED=1

printf '%s\n' 'Waiting for local Qwen…' >&2
for _ in $(seq 1 180); do
  if docker exec "$MODEL_CONTAINER" bash -c \
    'exec 3<>/dev/tcp/127.0.0.1/8000; printf "GET /v1/models HTTP/1.0\r\nHost: local-llm\r\n\r\n" >&3; IFS= read -r line <&3; [[ "$line" == *" 200 "* ]]' \
    >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$MODEL_CONTAINER" bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/8000; printf "GET /v1/models HTTP/1.0\r\nHost: local-llm\r\n\r\n" >&3; IFS= read -r line <&3; [[ "$line" == *" 200 "* ]]' \
  >/dev/null 2>&1 || {
  printf 'ERROR: local Qwen did not become ready; private log: %s\n' "$MODEL_LOG" >&2
  exit 1
}

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
    httpProxy: {url: "http://vpn-gateway:8888", noProxy: "local-llm,localhost,127.0.0.1"},
    relays: []
  }' >"$BOOTSTRAP"
chmod 0600 "$BOOTSTRAP"

DOCKER_ARGS=(
  run --detach
  --name "$CONTAINER"
  --hostname local-rogue
  --label com.axym.local-rogue=true
  --label "com.axym.local-rogue.workspace=$TOKEN"
  --restart no
  --network "$NETWORK"
  --user "$(id -u):$(id -g)"
  --read-only
  --cap-drop ALL
  --security-opt no-new-privileges:true
  --security-opt apparmor=docker-default
  --security-opt seccomp=builtin
  --cgroupns private
  --ipc private
  --pids-limit 256
  --memory 8g
  --memory-swap 8g
  --cpus 8
  --ulimit core=0:0
  --ulimit nofile=2048:2048
  --ulimit fsize=1073741824:1073741824
  --shm-size 64m
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=512m
  --env HOME=/tmp
  --env "ROGUE_WORKSPACE=$CONTAINER_WRITABLE_DIR"
  --env ROGUE_STATE_DIR=/state
  --env ROGUE_BOOTSTRAP=/state/initial_auth.json
  --env ROGUE_INITIAL_AUTH_FILE=/run/rogue/initial_auth.json
  --env ROGUE_THINKING=xhigh
  --env ROGUE_CACHE_RETENTION=none
  --env ROGUE_REPROVISION=1
  --env HTTP_PROXY=http://vpn-gateway:8888
  --env HTTPS_PROXY=http://vpn-gateway:8888
  --env http_proxy=http://vpn-gateway:8888
  --env https_proxy=http://vpn-gateway:8888
  --env NO_PROXY=local-llm,localhost,127.0.0.1
  --env no_proxy=local-llm,localhost,127.0.0.1
  --env "ROGUE_SESSION_RETENTION_DAYS=$SESSION_RETENTION_DAYS"
  --env 'ROGUE_EXTRA_ARGS=--no-failover'
  --mount "type=bind,src=$WORKSPACE_ROOT,dst=/workspace,readonly,bind-recursive=disabled"
  --mount "type=bind,src=$WRITABLE_DIR,dst=$CONTAINER_WRITABLE_DIR,bind-recursive=disabled"
  --mount "type=bind,src=$PERMISSIONS_NOTE,dst=$CONTAINER_WRITABLE_DIR/00-READ-ME-FIRST.md,readonly"
  --mount "type=volume,src=$STATE_VOLUME,dst=/state,volume-nocopy"
  --mount "type=bind,src=$BOOTSTRAP,dst=/run/rogue/initial_auth.json,readonly"
)
for relative in "${MASKED_DIRECTORIES[@]}"; do
  [[ -n "$relative" && "$relative" != *$'\n'* && "$relative" != *,* ]] || {
    printf 'ERROR: unsupported sensitive directory path: %q\n' "$relative" >&2
    exit 1
  }
  DOCKER_ARGS+=(--mount "type=bind,src=$MASK_DIRECTORY,dst=/workspace/$relative,readonly,bind-recursive=disabled")
done
for relative in "${MASKED_CREDENTIALS[@]}"; do
  [[ "$relative" != *$'\n'* && "$relative" != *,* ]] || {
    printf 'ERROR: unsupported credential path: %q\n' "$relative" >&2
    exit 1
  }
  DOCKER_ARGS+=(--mount "type=bind,src=$MASK_FILE,dst=/workspace/$relative,readonly")
done
DOCKER_ARGS+=("$IMAGE" --cycle-delay "$CYCLE_DELAY_SECONDS" "${ROGUE_ARGS[@]}")

docker "${DOCKER_ARGS[@]}" >/dev/null
log_metadata "event=session_start model=$MODEL context=$CONTEXT_WINDOW reasoning=xhigh egress=vpn rogue_revision=$REVISION"
SESSION_LOGGED=1
printf 'Rogue can read %s and write only %s; %d credential file(s) are hidden. Ctrl-C stops Rogue and Qwen.\n' \
  "$WORKSPACE_ROOT" "$WRITABLE_DIR" "${#MASKED_CREDENTIALS[@]}" >&2
FIRST_LOG=1
while docker inspect "$CONTAINER" >/dev/null 2>&1; do
  if [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$VPN_CONTAINER" 2>/dev/null || true)" != healthy ]]; then
    printf '%s\n' 'ERROR: VPN gateway lost health; stopping the contained session.' >&2
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != true ]]; then
    # A model-issued exit cannot end the supervised service. An explicit user
    # Ctrl-C/HUP reaches the wrapper trap instead and removes the container.
    docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
  LOCAL_ROGUE_LOG_DIR="$ACTIVITY_LOG_DIR" \
    LOCAL_ROGUE_LOG_RETENTION_DAYS="$LOG_RETENTION_DAYS" \
    LOCAL_ROGUE_LOG_SESSION="$LOG_SESSION" \
    "$ACTIVITY_LOGGER" <"$LOG_FIFO" &
  LOG_READER_PID=$!
  if [[ "$FIRST_LOG" == 1 ]]; then
    docker logs --follow "$CONTAINER" >"$LOG_FIFO" 2>&1 &
    FIRST_LOG=0
  else
    docker logs --tail 20 --follow "$CONTAINER" >"$LOG_FIFO" 2>&1 &
  fi
  DOCKER_LOG_PID=$!
  wait "$DOCKER_LOG_PID" 2>/dev/null || true
  DOCKER_LOG_PID=0
  wait "$LOG_READER_PID" 2>/dev/null || true
  LOG_READER_PID=0
  sleep 1
done
