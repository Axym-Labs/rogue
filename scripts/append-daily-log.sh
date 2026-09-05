#!/usr/bin/env bash
# Mirror a stream to the terminal and a private log selected per input line.
set -euo pipefail

LOG_DIR="${LOCAL_ROGUE_LOG_DIR:-/home/davwis/.local/state/local-rogue/logs}"
umask 077
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"

while IFS= read -r line || [[ -n "$line" ]]; do
  log_file="$LOG_DIR/$(date +%F).log"
  if [[ ! -e "$log_file" ]]; then
    : >"$log_file"
    chmod 0600 "$log_file"
  fi
  printf '%s\n' "$line" >>"$log_file"
  printf '%s\n' "$line"
done
