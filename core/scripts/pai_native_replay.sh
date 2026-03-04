#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"

QUEUE_DIR="$ROOT_DIR/.pai/runtime/native_queue"
PENDING_DIR="$QUEUE_DIR/pending"
PROCESSED_DIR="$QUEUE_DIR/processed"
DEAD_DIR="$QUEUE_DIR/dead"
EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
mkdir -p "$PENDING_DIR" "$PROCESSED_DIR" "$DEAD_DIR"

: "${PAI_NATIVE_RETRY_MAX:=2}"

emit_event() {
  local event="$1"; shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

usage() {
  cat <<'U'
Usage:
  scripts/pai_native_replay.sh process [--max <count>]
U
}

cmd="${1:-process}"
if [[ "$cmd" != "process" ]]; then
  usage
  exit 1
fi
shift || true

max_count=50
if [[ "${1:-}" == "--max" ]]; then
  max_count="${2:-50}"
  shift 2 || true
fi
[[ "$max_count" =~ ^[0-9]+$ ]] || { echo "--max must be integer"; exit 1; }

cstate="$("$ROOT_DIR/scripts/pai_native_circuit.sh" status | awk -F= '/^STATE=/{print $2}' | tail -n1)"
if [[ "$cstate" == "open" ]]; then
  echo "REPLAY_BLOCKED circuit_open"
  exit 3
fi

processed=0
failed=0
moved_dead=0

shopt -s nullglob
for item in "$PENDING_DIR"/*.env; do
  (( processed < max_count )) || break

  # shellcheck disable=SC1090
  source "$item"
  : "${OP_KEY:=}"
  : "${ATTEMPTS:=0}"
  : "${COMMAND:=}"

  if [[ -z "$OP_KEY" || -z "$COMMAND" ]]; then
    mv "$item" "$DEAD_DIR/$(basename "$item")"
    moved_dead=$((moved_dead + 1))
    continue
  fi

  if [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] && (( ATTEMPTS >= PAI_NATIVE_RETRY_MAX )); then
    mv "$item" "$DEAD_DIR/$(basename "$item")"
    moved_dead=$((moved_dead + 1))
    emit_event "native_replay_dead_letter" "op=$OP_KEY" "attempts=$ATTEMPTS"
    continue
  fi

  if PAI_NATIVE_QUEUE_ON_FAILURE=0 "$ROOT_DIR/scripts/pai_native_mutation.sh" run "$OP_KEY" -- "$COMMAND"; then
    rm -f "$item"
    processed=$((processed + 1))
    emit_event "native_replay_processed" "op=$OP_KEY"
  else
    failed=$((failed + 1))
    next_attempts=$((ATTEMPTS + 1))
    awk -F= 'BEGIN{OFS="="} $1=="ATTEMPTS"{$0="ATTEMPTS='"$next_attempts"'"}1' "$item" > "$item.tmp"
    mv "$item.tmp" "$item"
    emit_event "native_replay_failed" "op=$OP_KEY" "attempts=$next_attempts"
  fi
done
shopt -u nullglob

echo "REPLAY_SUMMARY processed=$processed failed=$failed dead=$moved_dead"
