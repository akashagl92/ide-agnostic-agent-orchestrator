#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"

RUNTIME_DIR="$ROOT_DIR/.pai/runtime"
CIRCUIT_FILE="$RUNTIME_DIR/native_circuit.env"
EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
mkdir -p "$RUNTIME_DIR"

: "${PAI_NATIVE_BREAKER_COOLDOWN_SEC:=300}"
: "${PAI_NATIVE_BREAKER_THRESHOLD:=2}"

now_iso() { pai_now_iso; }
now_epoch() { date +%s; }

emit_event() {
  local event="$1"; shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

load_state() {
  if [[ -f "$CIRCUIT_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CIRCUIT_FILE"
  fi
  : "${STATE:=closed}"
  : "${FAIL_COUNT:=0}"
  : "${OPENED_AT:=}"
  : "${COOLDOWN_UNTIL_EPOCH:=0}"
  : "${LAST_REASON:=}"
}

save_state() {
  cat > "$CIRCUIT_FILE" <<EOS
STATE=$STATE
FAIL_COUNT=$FAIL_COUNT
OPENED_AT=$OPENED_AT
COOLDOWN_UNTIL_EPOCH=$COOLDOWN_UNTIL_EPOCH
LAST_REASON=$LAST_REASON
UPDATED_AT=$(now_iso)
EOS
}

cmd="${1:-status}"
reason="${2:-manual}"
load_state

case "$cmd" in
  status)
    if [[ "$STATE" == "open" ]]; then
      now="$(now_epoch)"
      if [[ "$COOLDOWN_UNTIL_EPOCH" =~ ^[0-9]+$ ]] && (( now >= COOLDOWN_UNTIL_EPOCH )); then
        STATE="half_open"
        LAST_REASON="cooldown_elapsed"
        save_state
        emit_event "native_circuit_half_open" "reason=$LAST_REASON"
      fi
    fi
    echo "STATE=$STATE"
    echo "FAIL_COUNT=$FAIL_COUNT"
    echo "OPENED_AT=$OPENED_AT"
    echo "COOLDOWN_UNTIL_EPOCH=$COOLDOWN_UNTIL_EPOCH"
    echo "LAST_REASON=$LAST_REASON"
    ;;
  record-failure)
    FAIL_COUNT=$((FAIL_COUNT + 1))
    LAST_REASON="$reason"
    if (( FAIL_COUNT >= PAI_NATIVE_BREAKER_THRESHOLD )); then
      STATE="open"
      OPENED_AT="$(now_iso)"
      COOLDOWN_UNTIL_EPOCH=$(( $(now_epoch) + PAI_NATIVE_BREAKER_COOLDOWN_SEC ))
      emit_event "native_circuit_opened" "reason=$reason" "fail_count=$FAIL_COUNT" "cooldown_sec=$PAI_NATIVE_BREAKER_COOLDOWN_SEC"
    fi
    save_state
    ;;
  record-success)
    FAIL_COUNT=0
    STATE="closed"
    LAST_REASON="$reason"
    COOLDOWN_UNTIL_EPOCH=0
    save_state
    emit_event "native_circuit_closed" "reason=$reason"
    ;;
  open)
    STATE="open"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    LAST_REASON="$reason"
    OPENED_AT="$(now_iso)"
    COOLDOWN_UNTIL_EPOCH=$(( $(now_epoch) + PAI_NATIVE_BREAKER_COOLDOWN_SEC ))
    save_state
    emit_event "native_circuit_opened" "reason=$reason" "fail_count=$FAIL_COUNT" "cooldown_sec=$PAI_NATIVE_BREAKER_COOLDOWN_SEC"
    ;;
  close|reset)
    STATE="closed"
    FAIL_COUNT=0
    LAST_REASON="$reason"
    OPENED_AT=""
    COOLDOWN_UNTIL_EPOCH=0
    save_state
    emit_event "native_circuit_closed" "reason=$reason"
    ;;
  *)
    echo "Usage: scripts/pai_native_circuit.sh <status|record-failure|record-success|open|close|reset> [reason]"
    exit 1
    ;;
esac
