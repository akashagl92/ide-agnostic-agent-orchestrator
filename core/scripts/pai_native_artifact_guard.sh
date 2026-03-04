#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"

EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
WATCH_DIR="$ROOT_DIR/.pai/runtime/native_artifact_watch"
mkdir -p "$WATCH_DIR"

now_iso() { pai_now_iso; }
now_epoch() { date +%s; }

emit_event() {
  local event="$1"; shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

usage() {
  cat <<'U'
Usage:
  scripts/pai_native_artifact_guard.sh guard --target <task|implementation_plan|walkthrough> --phase <start|heartbeat|end> --op-key <id> [--result <success|failed|timeout|stalled>]
U
}

cmd="${1:-}"
[[ "$cmd" == "guard" ]] || { usage; exit 1; }
shift || true

target=""
phase=""
op_key=""
result=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --op-key) op_key="${2:-}"; shift 2 ;;
    --result) result="${2:-}"; shift 2 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

case "$target" in
  task|implementation_plan|walkthrough) ;;
  *) echo "Invalid target: $target"; exit 1 ;;
esac
case "$phase" in
  start|heartbeat|end) ;;
  *) echo "Invalid phase: $phase"; exit 1 ;;
esac
[[ -n "$op_key" ]] || { echo "Missing --op-key"; exit 1; }

watch_file="$WATCH_DIR/${op_key}.env"

# Hard block native artifact updates when SHADOW is active.
if [[ "$PROFILE" == "SHADOW" && "${PAI_NATIVE_SHADOW_ENFORCE_BLOCK:-1}" == "1" && "$phase" == "start" ]]; then
  emit_event "native_artifact_blocked_in_shadow" "target=$target" "op=$op_key"
  echo "NATIVE_ARTIFACT_DENY shadow_profile target=$target"
  exit 11
fi

if [[ "$phase" == "start" ]]; then
  cat > "$watch_file" <<W
TARGET=$target
OP_KEY=$op_key
STARTED_AT_EPOCH=$(now_epoch)
LAST_HEARTBEAT_EPOCH=$(now_epoch)
STARTED_AT=$(now_iso)
W
  emit_event "native_artifact_started" "target=$target" "op=$op_key"
fi

if [[ "$phase" == "heartbeat" ]]; then
  if [[ -f "$watch_file" ]]; then
    awk -F= 'BEGIN{OFS="="} $1=="LAST_HEARTBEAT_EPOCH"{$0="LAST_HEARTBEAT_EPOCH='"$(now_epoch)"'"}1' "$watch_file" > "$watch_file.tmp"
    mv "$watch_file.tmp" "$watch_file"
  fi
fi

should_fallback=0
fallback_reason=""
if [[ "${PAI_NATIVE_ARTIFACT_AUTO_FALLBACK_ENABLED:-1}" == "1" ]]; then
  if [[ "$phase" == "heartbeat" && -f "$watch_file" ]]; then
    start_epoch="$(grep -E '^STARTED_AT_EPOCH=' "$watch_file" | tail -n1 | cut -d= -f2- || true)"
    if [[ "$start_epoch" =~ ^[0-9]+$ ]]; then
      elapsed=$(( $(now_epoch) - start_epoch ))
      if (( elapsed >= PAI_NATIVE_ARTIFACT_STALL_TIMEOUT_SEC )); then
        should_fallback=1
        fallback_reason="native_artifact_stall_timeout"
      fi
    fi
  fi

  if [[ "$phase" == "end" ]]; then
    case "$result" in
      timeout|stalled|failed)
        should_fallback=1
        fallback_reason="native_artifact_${result}"
        ;;
      *) ;;
    esac
  fi
fi

if [[ "$should_fallback" == "1" ]]; then
  if [[ "${PAI_NATIVE_ARTIFACT_OBSERVE_ONLY:-0}" == "1" ]]; then
    emit_event "native_artifact_fallback_observed" "target=$target" "op=$op_key" "reason=$fallback_reason"
  else
    "$ROOT_DIR/scripts/pai_native_circuit.sh" open "$fallback_reason" >/dev/null 2>&1 || true
    # One-way policy: only auto-switch NATIVE -> SHADOW; never auto-enable NATIVE.
    if [[ "$PROFILE" == "NATIVE" && "${PAI_NATIVE_ARTIFACT_ONE_WAY_SHADOW:-1}" == "1" ]]; then
      "$ROOT_DIR/scripts/pai_runtime_guard.sh" shadow-on "$fallback_reason" >/dev/null 2>&1 || true
      emit_event "native_artifact_auto_shadow" "target=$target" "op=$op_key" "reason=$fallback_reason"
    fi
  fi
fi

if [[ "$phase" == "end" ]]; then
  rm -f "$watch_file"
  emit_event "native_artifact_ended" "target=$target" "op=$op_key" "result=${result:-unknown}"
fi

echo "NATIVE_ARTIFACT_GUARD_OK"
