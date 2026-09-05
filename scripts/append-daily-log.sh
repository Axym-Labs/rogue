#!/usr/bin/env bash
# Mirror a stream to the terminal and a private log selected per input line.
set -euo pipefail

LOG_DIR="${LOCAL_ROGUE_LOG_DIR:-/home/davwis/.local/state/local-rogue/logs}"
RETENTION_DAYS="${LOCAL_ROGUE_LOG_RETENTION_DAYS:-90}"
LOG_SESSION="${LOCAL_ROGUE_LOG_SESSION:-unknown}"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((RETENTION_DAYS >= 1 && RETENTION_DAYS <= 3650)) || {
  printf 'ERROR: invalid activity-log retention: %s\n' "$RETENTION_DAYS" >&2
  exit 2
}
[[ "$LOG_SESSION" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'ERROR: invalid activity-log session identifier\n' >&2
  exit 2
}
umask 077
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
# Restrict cleanup to this logger's date-named files; unrelated operator files
# in the private directory are never candidates.
find "$LOG_DIR" -maxdepth 1 -type f -name '????-??-??.log' -mtime "+$RETENTION_DAYS" -delete

while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip every C0 control except horizontal tab. This neutralizes terminal
  # escape/OSC sequences and carriage-return rewriting before either sink.
  line="$(printf '%s' "$line" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log_file="$LOG_DIR/${timestamp%%T*}.log"
  if [[ ! -e "$log_file" ]]; then
    : >"$log_file"
    chmod 0600 "$log_file"
  fi
  printf '[%s] [session=%s] %s\n' "$timestamp" "$LOG_SESSION" "$line" >>"$log_file"
  printf '%s\n' "$line"
done
