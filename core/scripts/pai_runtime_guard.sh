#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
RUNTIME_DIR="$ROOT_DIR/.pai/runtime"
PROFILE_FILE="$RUNTIME_DIR/profile.env"
EVENT_LOG="$RUNTIME_DIR/events.log"

mkdir -p "$RUNTIME_DIR"

now_iso() {
  pai_now_iso
}

set_defaults() {
  pai_load_runtime "$ROOT_DIR"
  : "${PROFILE:=SHADOW}"
  : "${LOCKED:=1}"
  : "${REASON:=bootstrap_default_shadow}"
  : "${UPDATED_AT:=$(now_iso)}"

  : "${SUBAGENT_ENABLED:=1}"
  : "${SUBAGENT_MODE:=proposal_only}"
  : "${SUBAGENT_MAX_CONCURRENCY:=2}"
  : "${SUBAGENT_TIMEOUT_SEC:=180}"
  : "${SUBAGENT_PARENT_ONLY_WRITES:=1}"
  : "${SUBAGENT_NATIVE_WRITES:=0}"
  : "${CAPABILITY_SPAWN_SUBAGENT:=1}"
}

write_state() {
  local reason_override="${1:-$REASON}"
  UPDATED_AT="$(now_iso)"
  cat > "$PROFILE_FILE" <<__PROFILE_EOF__
PROFILE=$PROFILE
LOCKED=$LOCKED
REASON=$reason_override
UPDATED_AT=$UPDATED_AT
SUBAGENT_ENABLED=$SUBAGENT_ENABLED
SUBAGENT_MODE=$SUBAGENT_MODE
SUBAGENT_MAX_CONCURRENCY=$SUBAGENT_MAX_CONCURRENCY
SUBAGENT_TIMEOUT_SEC=$SUBAGENT_TIMEOUT_SEC
SUBAGENT_PARENT_ONLY_WRITES=$SUBAGENT_PARENT_ONLY_WRITES
SUBAGENT_NATIVE_WRITES=$SUBAGENT_NATIVE_WRITES
CAPABILITY_SPAWN_SUBAGENT=$CAPABILITY_SPAWN_SUBAGENT
__PROFILE_EOF__
  REASON="$reason_override"
  echo "$UPDATED_AT profile=$PROFILE locked=$LOCKED reason=$REASON subagent_enabled=$SUBAGENT_ENABLED subagent_mode=$SUBAGENT_MODE spawn_cap=$CAPABILITY_SPAWN_SUBAGENT" >> "$EVENT_LOG"
}

read_state() {
  if [[ -f "$PROFILE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PROFILE_FILE"
  fi
  set_defaults
}

validate_mode() {
  local mode="$1"
  [[ "$mode" == "research_only" ]] && mode="proposal_only"
  case "$mode" in
    single_parent|proposal_only|scoped_write) return 0 ;;
    *)
      echo "Invalid SUBAGENT_MODE: $mode"
      echo "Allowed: single_parent | proposal_only | scoped_write (legacy: research_only)"
      exit 1
      ;;
  esac
}

cmd="${1:-status}"
reason="${2:-manual}"

case "$cmd" in
  status)
    read_state
    echo "ROOT_DIR=$ROOT_DIR"
    echo "PROFILE_FILE=$PROFILE_FILE"
    echo "PROFILE=$PROFILE"
    echo "LOCKED=$LOCKED"
    echo "REASON=$REASON"
    echo "UPDATED_AT=$UPDATED_AT"
    echo "SUBAGENT_ENABLED=$SUBAGENT_ENABLED"
    echo "SUBAGENT_MODE=$SUBAGENT_MODE"
    echo "SUBAGENT_MAX_CONCURRENCY=$SUBAGENT_MAX_CONCURRENCY"
    echo "SUBAGENT_TIMEOUT_SEC=$SUBAGENT_TIMEOUT_SEC"
    echo "SUBAGENT_PARENT_ONLY_WRITES=$SUBAGENT_PARENT_ONLY_WRITES"
    echo "SUBAGENT_NATIVE_WRITES=$SUBAGENT_NATIVE_WRITES"
    echo "CAPABILITY_SPAWN_SUBAGENT=$CAPABILITY_SPAWN_SUBAGENT"
    ;;
  native-on)
    read_state
    if [[ "${LOCKED:-0}" == "1" && "${3:-}" != "--force" ]]; then
      echo "Refusing native-on because profile is locked. Use --force after verification pass."
      exit 2
    fi
    PROFILE="NATIVE"
    LOCKED="0"
    write_state "$reason"
    echo "Switched to NATIVE"
    ;;
  shadow-on)
    read_state
    PROFILE="SHADOW"
    LOCKED="1"
    write_state "$reason"
    echo "Switched to SHADOW and locked"
    ;;
  unlock)
    read_state
    LOCKED="0"
    write_state "$reason"
    echo "Unlocked profile"
    ;;
  reset)
    read_state
    PROFILE="SHADOW"
    LOCKED="1"
    SUBAGENT_ENABLED="1"
    SUBAGENT_MODE="proposal_only"
    SUBAGENT_MAX_CONCURRENCY="2"
    SUBAGENT_TIMEOUT_SEC="180"
    SUBAGENT_PARENT_ONLY_WRITES="1"
    SUBAGENT_NATIVE_WRITES="0"
    CAPABILITY_SPAWN_SUBAGENT="0"
    write_state "$reason"
    echo "Reset profile to SHADOW and locked"
    ;;
  subagent-on)
    read_state
    SUBAGENT_ENABLED="1"
    write_state "$reason"
    echo "Subagent PoC enabled"
    ;;
  subagent-off)
    read_state
    SUBAGENT_ENABLED="0"
    write_state "$reason"
    echo "Subagent PoC disabled"
    ;;
  subagent-mode)
    read_state
    mode="${2:-proposal_only}"
    [[ "$mode" == "research_only" ]] && mode="proposal_only"
    validate_mode "$mode"
    SUBAGENT_MODE="$mode"
    write_state "${3:-manual_mode_change}"
    echo "Subagent mode set to $SUBAGENT_MODE"
    ;;
  subagent-concurrency)
    read_state
    value="${2:-2}"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "Concurrency must be an integer"
      exit 1
    fi
    SUBAGENT_MAX_CONCURRENCY="$value"
    write_state "${3:-manual_concurrency_change}"
    echo "Subagent concurrency set to $SUBAGENT_MAX_CONCURRENCY"
    ;;
  subagent-timeout)
    read_state
    value="${2:-180}"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "Timeout must be an integer"
      exit 1
    fi
    SUBAGENT_TIMEOUT_SEC="$value"
    write_state "${3:-manual_timeout_change}"
    echo "Subagent timeout set to $SUBAGENT_TIMEOUT_SEC"
    ;;
  subagent-capability)
    read_state
    value="${2:-0}"
    if [[ "$value" != "0" && "$value" != "1" ]]; then
      echo "Capability must be 0 or 1"
      exit 1
    fi
    CAPABILITY_SPAWN_SUBAGENT="$value"
    write_state "${3:-manual_capability_change}"
    echo "Subagent spawn capability set to $CAPABILITY_SPAWN_SUBAGENT"
    ;;
  *)
    echo "Usage:"
    echo "  scripts/pai_runtime_guard.sh status"
    echo "  scripts/pai_runtime_guard.sh shadow-on <reason>"
    echo "  scripts/pai_runtime_guard.sh native-on <reason> [--force]"
    echo "  scripts/pai_runtime_guard.sh unlock <reason>"
    echo "  scripts/pai_runtime_guard.sh reset <reason>"
    echo "  scripts/pai_runtime_guard.sh subagent-on <reason>"
    echo "  scripts/pai_runtime_guard.sh subagent-off <reason>"
    echo "  scripts/pai_runtime_guard.sh subagent-mode <single_parent|proposal_only|scoped_write> [reason]"
    echo "  scripts/pai_runtime_guard.sh subagent-concurrency <int> [reason]"
    echo "  scripts/pai_runtime_guard.sh subagent-timeout <seconds> [reason]"
    echo "  scripts/pai_runtime_guard.sh subagent-capability <0|1> [reason]"
    exit 1
    ;;
esac
