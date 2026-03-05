#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"

EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
GUARD="$ROOT_DIR/scripts/pai_native_artifact_guard.sh"
BRIDGE_DIR="$ROOT_DIR/.pai/runtime/native_artifact_bridge"
TARGET_STATE_DIR="$BRIDGE_DIR/targets"
PID_FILE="$BRIDGE_DIR/bridge.pid"
LOG_FILE="$BRIDGE_DIR/bridge.log"
SESSION_FILE="$BRIDGE_DIR/session.env"
LOOP_LOCK_DIR="$BRIDGE_DIR/loop.lock"
LOOP_HEARTBEAT_FILE="$BRIDGE_DIR/loop.heartbeat"

mkdir -p "$BRIDGE_DIR" "$TARGET_STATE_DIR"

SOURCE_ROOT="${PAI_NATIVE_ARTIFACT_SOURCE_ROOT:-$HOME/.gemini/antigravity/brain}"
POLL_SEC="${PAI_NATIVE_ARTIFACT_BRIDGE_POLL_SEC:-5}"
IDLE_END_SEC="${PAI_NATIVE_ARTIFACT_BRIDGE_IDLE_END_SEC:-30}"

emit_event() {
  local event="$1"; shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

usage() {
  cat <<'U'
Usage:
  scripts/pai_native_artifact_bridge.sh <status|start|stop|ensure|run-loop|run-once>
U
}

is_pid_running() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

read_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  echo "$pid"
}

stat_mtime() {
  local path="$1"
  if stat -f "%m" "$path" >/dev/null 2>&1; then
    stat -f "%m" "$path"
  else
    stat -c "%Y" "$path"
  fi
}

latest_session_dir() {
  [[ -d "$SOURCE_ROOT" ]] || return 1
  local latest=""
  local latest_mtime=0
  local dir mtime
  shopt -s nullglob
  for dir in "$SOURCE_ROOT"/*; do
    [[ -d "$dir" ]] || continue
    mtime="$(stat_mtime "$dir" 2>/dev/null || echo 0)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    if (( mtime > latest_mtime )); then
      latest_mtime="$mtime"
      latest="$dir"
    fi
  done
  shopt -u nullglob
  [[ -n "$latest" ]] || return 1
  echo "$latest"
}

target_basename() {
  case "${1:-}" in
    task) echo "task.md" ;;
    implementation_plan) echo "implementation_plan.md" ;;
    walkthrough) echo "walkthrough.md" ;;
    *) return 1 ;;
  esac
}

artifact_sig() {
  local session_dir="$1"
  local target="$2"
  local base
  base="$(target_basename "$target")"
  local f
  local max_mtime=0
  local total_size=0
  local found=0

  shopt -s nullglob
  for f in \
    "$session_dir/$base" \
    "$session_dir/$base.metadata.json" \
    "$session_dir/$base.resolved" \
    "$session_dir/$base.resolved."*; do
    [[ -f "$f" ]] || continue
    found=1
    local mtime size
    mtime="$(stat_mtime "$f" 2>/dev/null || echo 0)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    if stat -f "%z" "$f" >/dev/null 2>&1; then
      size="$(stat -f "%z" "$f")"
    else
      size="$(stat -c "%s" "$f")"
    fi
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    if (( mtime > max_mtime )); then
      max_mtime="$mtime"
    fi
    total_size=$(( total_size + size ))
  done
  shopt -u nullglob

  if [[ "$found" == "0" ]]; then
    echo ""
    return 0
  fi

  echo "${max_mtime}:${total_size}"
}

state_file_for() {
  local target="$1"
  echo "$TARGET_STATE_DIR/${target}.env"
}

load_target_state() {
  local target="$1"
  local state_file
  state_file="$(state_file_for "$target")"

  ACTIVE=0
  OP_KEY=""
  LAST_SIG=""
  LAST_CHANGE_EPOCH=0
  SESSION_ID=""
  BOOTSTRAPPED=0

  [[ -f "$state_file" ]] || return 0
  # shellcheck disable=SC1090
  source "$state_file"
}

save_target_state() {
  local target="$1"
  local state_file
  state_file="$(state_file_for "$target")"
  cat > "$state_file" <<EOF
ACTIVE=$ACTIVE
OP_KEY=$OP_KEY
LAST_SIG=$LAST_SIG
LAST_CHANGE_EPOCH=$LAST_CHANGE_EPOCH
SESSION_ID=$SESSION_ID
BOOTSTRAPPED=$BOOTSTRAPPED
EOF
}

guard_start() {
  local target="$1"
  local op_key="$2"
  "$GUARD" guard --target "$target" --phase start --op-key "$op_key" >/dev/null 2>&1
}

guard_heartbeat() {
  local target="$1"
  local op_key="$2"
  "$GUARD" guard --target "$target" --phase heartbeat --op-key "$op_key" >/dev/null 2>&1 || true
}

guard_end() {
  local target="$1"
  local op_key="$2"
  local result="${3:-success}"
  "$GUARD" guard --target "$target" --phase end --op-key "$op_key" --result "$result" >/dev/null 2>&1 || true
}

close_target_if_active() {
  local target="$1"
  local result="${2:-success}"
  load_target_state "$target"
  if [[ "$ACTIVE" == "1" && -n "$OP_KEY" ]]; then
    guard_end "$target" "$OP_KEY" "$result"
    emit_event "native_artifact_bridge_closed" "target=$target" "op=$OP_KEY" "result=$result"
  fi
  ACTIVE=0
  OP_KEY=""
  LAST_CHANGE_EPOCH=0
  BOOTSTRAPPED=0
  save_target_state "$target"
}

tick_once() {
  local now
  now="$(date +%s)"

  local session_dir=""
  session_dir="$(latest_session_dir 2>/dev/null || true)"

  local current_session=""
  if [[ -f "$SESSION_FILE" ]]; then
    current_session="$(awk -F= '/^SESSION_DIR=/{print $2}' "$SESSION_FILE" | tail -n1)"
  fi

  if [[ "$session_dir" != "$current_session" ]]; then
    local t
    for t in task implementation_plan walkthrough; do
      close_target_if_active "$t" "success"
    done
    printf 'SESSION_DIR=%s\nUPDATED_AT=%s\n' "$session_dir" "$(pai_now_iso)" > "$SESSION_FILE"
    emit_event "native_artifact_bridge_session_changed" "session_dir=$session_dir"
  fi

  [[ -n "$session_dir" ]] || return 0

  local target sig op_epoch
  for target in task implementation_plan walkthrough; do
    load_target_state "$target"
    sig="$(artifact_sig "$session_dir" "$target")"

    if [[ -z "$sig" ]]; then
      if [[ "$ACTIVE" == "1" && -n "$OP_KEY" ]]; then
        guard_heartbeat "$target" "$OP_KEY"
        op_epoch=$(( now - LAST_CHANGE_EPOCH ))
        if (( op_epoch >= IDLE_END_SEC )); then
          guard_end "$target" "$OP_KEY" "success"
          emit_event "native_artifact_bridge_idle_end" "target=$target" "op=$OP_KEY" "idle_sec=$op_epoch"
          ACTIVE=0
          OP_KEY=""
          LAST_CHANGE_EPOCH=0
        fi
      fi
      save_target_state "$target"
      continue
    fi

    if [[ "$SESSION_ID" != "$session_dir" ]]; then
      ACTIVE=0
      OP_KEY=""
      LAST_SIG=""
      LAST_CHANGE_EPOCH=0
      BOOTSTRAPPED=0
      SESSION_ID="$session_dir"
    fi

    if [[ "$BOOTSTRAPPED" == "0" ]]; then
      # Snapshot existing artifacts at startup/session switch; do not treat as active mutation.
      LAST_SIG="$sig"
      LAST_CHANGE_EPOCH="$now"
      BOOTSTRAPPED=1
      save_target_state "$target"
      continue
    fi

    if [[ "$sig" != "$LAST_SIG" ]]; then
      if [[ "$ACTIVE" != "1" || -z "$OP_KEY" ]]; then
        OP_KEY="$(basename "$session_dir")-${target}-${now}"
        if guard_start "$target" "$OP_KEY"; then
          ACTIVE=1
          emit_event "native_artifact_bridge_started" "target=$target" "op=$OP_KEY" "session=$(basename "$session_dir")"
        else
          ACTIVE=0
          OP_KEY=""
          emit_event "native_artifact_bridge_start_blocked" "target=$target" "session=$(basename "$session_dir")"
        fi
      fi
      if [[ "$ACTIVE" == "1" && -n "$OP_KEY" ]]; then
        guard_heartbeat "$target" "$OP_KEY"
      fi
      LAST_SIG="$sig"
      LAST_CHANGE_EPOCH="$now"
      save_target_state "$target"
      continue
    fi

    if [[ "$ACTIVE" == "1" && -n "$OP_KEY" ]]; then
      guard_heartbeat "$target" "$OP_KEY"
      op_epoch=$(( now - LAST_CHANGE_EPOCH ))
      if (( op_epoch >= IDLE_END_SEC )); then
        guard_end "$target" "$OP_KEY" "success"
        emit_event "native_artifact_bridge_idle_end" "target=$target" "op=$OP_KEY" "idle_sec=$op_epoch"
        ACTIVE=0
        OP_KEY=""
        LAST_CHANGE_EPOCH=0
      fi
    fi

    save_target_state "$target"
  done
}

run_loop() {
  [[ "$POLL_SEC" =~ ^[0-9]+$ ]] || POLL_SEC=5
  (( POLL_SEC < 1 )) && POLL_SEC=1
  [[ "$IDLE_END_SEC" =~ ^[0-9]+$ ]] || IDLE_END_SEC=30
  (( IDLE_END_SEC < 5 )) && IDLE_END_SEC=5

  if ! acquire_loop_lock; then
    emit_event "native_artifact_bridge_loop_already_active"
    exit 0
  fi

  trap 'rc=$?; release_loop_lock; echo "$(pai_now_iso) bridge_loop_exit rc=$rc" >> "$LOG_FILE"; emit_event "native_artifact_bridge_loop_exited" "exit_code=$rc"' EXIT
  emit_event "native_artifact_bridge_loop_started" "source_root=$SOURCE_ROOT" "poll_sec=$POLL_SEC"
  while true; do
    echo "$(pai_now_iso)" > "$LOOP_HEARTBEAT_FILE"
    tick_once || true
    sleep "$POLL_SEC"
  done
}

launch_detached() {
  local pid=""
  nohup "$0" run-loop </dev/null >> "$LOG_FILE" 2>&1 &
  pid=$!
  echo "$pid"
}

acquire_loop_lock() {
  if mkdir "$LOOP_LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOOP_LOCK_DIR/owner.pid"
    return 0
  fi

  local owner=""
  owner="$(cat "$LOOP_LOCK_DIR/owner.pid" 2>/dev/null || true)"
  if is_pid_running "$owner"; then
    return 1
  fi

  rm -rf "$LOOP_LOCK_DIR" 2>/dev/null || true
  if mkdir "$LOOP_LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOOP_LOCK_DIR/owner.pid"
    return 0
  fi
  return 1
}

release_loop_lock() {
  local owner=""
  owner="$(cat "$LOOP_LOCK_DIR/owner.pid" 2>/dev/null || true)"
  if [[ "$owner" == "$$" ]]; then
    rm -rf "$LOOP_LOCK_DIR" 2>/dev/null || true
  fi
}

cmd="${1:-status}"
case "$cmd" in
  status)
    echo "ROOT_DIR=$ROOT_DIR"
    echo "BRIDGE_ENABLED=${PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED:-0}"
    echo "SOURCE_ROOT=$SOURCE_ROOT"
    echo "POLL_SEC=$POLL_SEC"
    echo "IDLE_END_SEC=$IDLE_END_SEC"
    running=0
    active_pid=""
    stale_pid=""
    if pid="$(read_pid 2>/dev/null)"; then
      if is_pid_running "$pid"; then
        running=1
        active_pid="$pid"
      else
        stale_pid="$pid"
      fi
    fi
    if [[ "$running" == "0" && -f "$LOOP_LOCK_DIR/owner.pid" ]]; then
      owner_pid="$(cat "$LOOP_LOCK_DIR/owner.pid" 2>/dev/null || true)"
      if is_pid_running "$owner_pid"; then
        running=1
        active_pid="$owner_pid"
        echo "$owner_pid" > "$PID_FILE"
      fi
    fi
    echo "RUNNING=$running"
    [[ -n "$active_pid" ]] && echo "PID=$active_pid"
    [[ "$running" == "0" && -n "$stale_pid" ]] && echo "PID_STALE=$stale_pid"
    if [[ -f "$LOOP_HEARTBEAT_FILE" ]]; then
      hb="$(cat "$LOOP_HEARTBEAT_FILE" 2>/dev/null || true)"
      [[ -n "$hb" ]] && echo "LOOP_HEARTBEAT=$hb"
    fi
    ;;
  ensure)
    if [[ "${PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED:-0}" != "1" ]]; then
      echo "BRIDGE_DISABLED runtime_flag"
      exit 0
    fi
    "$0" start
    ;;
  start)
    if [[ "${PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED:-0}" != "1" ]]; then
      echo "BRIDGE_DISABLED runtime_flag"
      exit 0
    fi
    if pid="$(read_pid 2>/dev/null)" && is_pid_running "$pid"; then
      echo "BRIDGE_ALREADY_RUNNING pid=$pid"
      exit 0
    fi
    new_pid="$(launch_detached)"
    echo "$new_pid" > "$PID_FILE"
    sleep 1
    if ! is_pid_running "$new_pid"; then
      # Retry once with nohup fallback in case setsid launch failed.
      nohup "$0" run-loop </dev/null >> "$LOG_FILE" 2>&1 &
      new_pid=$!
      echo "$new_pid" > "$PID_FILE"
      sleep 1
    fi
    if is_pid_running "$new_pid"; then
      emit_event "native_artifact_bridge_daemon_started" "pid=$new_pid"
      echo "BRIDGE_STARTED pid=$new_pid"
    else
      emit_event "native_artifact_bridge_daemon_start_failed" "reason=post_start_liveness_failed"
      echo "BRIDGE_START_FAILED"
      exit 4
    fi
    ;;
  stop)
    if pid="$(read_pid 2>/dev/null)"; then
      if is_pid_running "$pid"; then
        kill "$pid" 2>/dev/null || true
      fi
      rm -f "$PID_FILE"
      emit_event "native_artifact_bridge_daemon_stopped" "pid=$pid"
      echo "BRIDGE_STOPPED pid=$pid"
    else
      echo "BRIDGE_NOT_RUNNING"
    fi
    ;;
  run-loop)
    run_loop
    ;;
  run-once)
    tick_once
    echo "BRIDGE_TICK_OK"
    ;;
  *)
    usage
    exit 1
    ;;
esac
