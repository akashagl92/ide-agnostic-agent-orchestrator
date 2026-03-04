#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"

cmd="${1:-emit}"
if [[ "$cmd" != "emit" ]]; then
  echo "Usage: scripts/pai_event_bus.sh emit <event> [key=value ...]" >&2
  exit 1
fi

shift || true
event="${1:-}"
if [[ -z "$event" ]]; then
  echo "Missing event name" >&2
  exit 1
fi
shift || true

if [[ "${PAI_EVENT_BUS_ENABLED:-1}" != "1" ]]; then
  exit 0
fi

if [[ "$PAI_EVENT_LOG" == /* ]]; then
  event_log="$PAI_EVENT_LOG"
else
  event_log="$ROOT_DIR/$PAI_EVENT_LOG"
fi
mkdir -p "$(dirname "$event_log")"

kv_json=""
for pair in "$@"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  safe_val="$(printf '%s' "$val" | sed 's/"/\\"/g')"
  if [[ -n "$kv_json" ]]; then
    kv_json+=" , "
  fi
  kv_json+="\"$key\":\"$safe_val\""
done

printf '{"ts":"%s","event":"%s","profile":"%s","mode":"%s","data":{%s}}\n' \
  "$(pai_now_iso)" "$event" "${PROFILE:-SHADOW}" "${SUBAGENT_MODE:-proposal_only}" "$kv_json" >> "$event_log"
