#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
RUNTIME_DIR="$ROOT_DIR/.pai/runtime"
PROFILE_FILE="$RUNTIME_DIR/profile.env"
RUNTIME_CONFIG_FILE="$ROOT_DIR/.pai/config/runtime.env"
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
}

bridge_auto_ensure() {
  pai_load_runtime "$ROOT_DIR"
  [[ "${PAI_RUNTIME_AUTO_ENSURE_BRIDGE:-1}" == "1" ]] || return 0
  [[ "${PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED:-0}" == "1" ]] || return 0
  local bridge="$ROOT_DIR/scripts/pai_native_artifact_bridge.sh"
  [[ -x "$bridge" ]] || return 0
  "$bridge" ensure >/dev/null 2>&1 || true
}

write_state() {
  local reason_override="${1:-$REASON}"
  UPDATED_AT="$(now_iso)"
  cat > "$PROFILE_FILE" <<__PROFILE_EOF__
PROFILE=$PROFILE
LOCKED=$LOCKED
REASON=$reason_override
UPDATED_AT=$UPDATED_AT
__PROFILE_EOF__
  REASON="$reason_override"
  echo "$UPDATED_AT profile=$PROFILE locked=$LOCKED reason=$REASON" >> "$EVENT_LOG"
}

read_state() {
  set_defaults
}

set_runtime_kv() {
  local key="$1"
  local value="$2"
  mkdir -p "$(dirname "$RUNTIME_CONFIG_FILE")"
  touch "$RUNTIME_CONFIG_FILE"
  if grep -q "^${key}=" "$RUNTIME_CONFIG_FILE" 2>/dev/null; then
    awk -v k="$key" -v v="$value" -F= 'BEGIN{OFS="="} $1==k{$0=k"="v}1' "$RUNTIME_CONFIG_FILE" > "$RUNTIME_CONFIG_FILE.tmp"
    mv "$RUNTIME_CONFIG_FILE.tmp" "$RUNTIME_CONFIG_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$RUNTIME_CONFIG_FILE"
  fi
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
    bridge_auto_ensure
    read_state
    bridge_status="$("$ROOT_DIR/scripts/pai_native_artifact_bridge.sh" status 2>/dev/null || true)"
    bridge_running="$(printf '%s\n' "$bridge_status" | awk -F= '/^RUNNING=/{print $2}' | tail -n1)"
    bridge_pid="$(printf '%s\n' "$bridge_status" | awk -F= '/^PID=/{print $2}' | tail -n1)"
    bridge_pid_stale="$(printf '%s\n' "$bridge_status" | awk -F= '/^PID_STALE=/{print $2}' | tail -n1)"
    native_artifacts_allowed="1"
    if [[ "$PROFILE" == "SHADOW" || "$LOCKED" == "1" ]]; then
      native_artifacts_allowed="0"
    fi
    echo "ROOT_DIR=$ROOT_DIR"
    echo "PROFILE_FILE=$PROFILE_FILE"
    echo "RUNTIME_CONFIG_FILE=$RUNTIME_CONFIG_FILE"
    echo "STATE_MODEL=runtime.env policy baseline + profile.env transient state"
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
    echo "PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED=$PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED"
    echo "PAI_NATIVE_ARTIFACT_SOURCE_ROOT=${PAI_NATIVE_ARTIFACT_SOURCE_ROOT:-$HOME/.gemini/antigravity/brain}"
    echo "PAI_NATIVE_ARTIFACT_BRIDGE_POLL_SEC=$PAI_NATIVE_ARTIFACT_BRIDGE_POLL_SEC"
    echo "PAI_NATIVE_ARTIFACT_BRIDGE_IDLE_END_SEC=$PAI_NATIVE_ARTIFACT_BRIDGE_IDLE_END_SEC"
    echo "PAI_RUNTIME_AUTO_ENSURE_BRIDGE=$PAI_RUNTIME_AUTO_ENSURE_BRIDGE"
    echo "PAI_SHADOW_ALLOWED_ARTIFACT_PATHS=$PAI_SHADOW_ALLOWED_ARTIFACT_PATHS"
    echo "NATIVE_ARTIFACTS_ALLOWED=$native_artifacts_allowed"
    if [[ "$native_artifacts_allowed" == "0" ]]; then
      echo "NATIVE_ARTIFACTS_FORBIDDEN_REASON=shadow_or_locked_profile"
      echo "NATIVE_ARTIFACTS_BANNED_TOOLS=task_boundary,task.md,implementation_plan.md,walkthrough.md"
    fi
    if [[ -n "$bridge_running" ]]; then
      echo "BRIDGE_DAEMON_RUNNING=$bridge_running"
    fi
    if [[ -n "$bridge_pid" ]]; then
      echo "BRIDGE_DAEMON_PID=$bridge_pid"
    fi
    if [[ -n "$bridge_pid_stale" ]]; then
      echo "BRIDGE_DAEMON_PID_STALE=$bridge_pid_stale"
    fi
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
    write_state "$reason"
    echo "Reset profile to SHADOW and locked"
    ;;
  subagent-on)
    set_runtime_kv "SUBAGENT_ENABLED" "1"
    echo "Updated runtime baseline: SUBAGENT_ENABLED=1"
    ;;
  subagent-off)
    set_runtime_kv "SUBAGENT_ENABLED" "0"
    echo "Updated runtime baseline: SUBAGENT_ENABLED=0"
    ;;
  subagent-mode)
    mode="${2:-proposal_only}"
    [[ "$mode" == "research_only" ]] && mode="proposal_only"
    validate_mode "$mode"
    set_runtime_kv "SUBAGENT_MODE" "$mode"
    echo "Updated runtime baseline: SUBAGENT_MODE=$mode"
    ;;
  subagent-concurrency)
    value="${2:-2}"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "Concurrency must be an integer"
      exit 1
    fi
    set_runtime_kv "SUBAGENT_MAX_CONCURRENCY" "$value"
    echo "Updated runtime baseline: SUBAGENT_MAX_CONCURRENCY=$value"
    ;;
  subagent-timeout)
    value="${2:-180}"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "Timeout must be an integer"
      exit 1
    fi
    set_runtime_kv "SUBAGENT_TIMEOUT_SEC" "$value"
    echo "Updated runtime baseline: SUBAGENT_TIMEOUT_SEC=$value"
    ;;
  subagent-capability)
    value="${2:-0}"
    if [[ "$value" != "0" && "$value" != "1" ]]; then
      echo "Capability must be 0 or 1"
      exit 1
    fi
    set_runtime_kv "CAPABILITY_SPAWN_SUBAGENT" "$value"
    echo "Updated runtime baseline: CAPABILITY_SPAWN_SUBAGENT=$value"
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
