#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: scripts/pai_subagent_worker.sh <job_dir> <timeout_sec>"
  exit 1
fi

JOB_DIR="$1"
TIMEOUT_SEC="$2"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"
ROOT_DIR="$(pai_resolve_root)"
EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
STATE_FILE="$JOB_DIR/state.env"
COMMAND_FILE="$JOB_DIR/command.sh"
STDOUT_FILE="$JOB_DIR/stdout.log"
STDERR_FILE="$JOB_DIR/stderr.log"
CANCEL_FLAG="$JOB_DIR/cancel.requested"

now_iso() { pai_now_iso; }

emit_event() {
  local event="$1"
  shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

set_state() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    awk -v k="$key" -v v="$val" -F= 'BEGIN{OFS="="} $1==k{$0=k"="v}1' "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    echo "$key=$val" >> "$STATE_FILE"
  fi
}

[[ -x "$COMMAND_FILE" ]] || { set_state STATUS failed; set_state ERROR missing_command; exit 2; }

set_state STATUS running
set_state STARTED_AT "$(now_iso)"
job_id="$(grep -E '^ID=' "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
[[ -n "$job_id" ]] && emit_event "subagent_running" "id=$job_id"
"$COMMAND_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE" &
CMD_PID=$!
echo "CMD_PID=$CMD_PID" > "$JOB_DIR/pids.env"

TERM_REASON_FILE="$JOB_DIR/termination.reason"
rm -f "$TERM_REASON_FILE"
(
  start="$(date +%s)"
  while kill -0 "$CMD_PID" 2>/dev/null; do
    if [[ -f "$CANCEL_FLAG" ]]; then
      echo "cancelled" > "$TERM_REASON_FILE"
      kill -TERM "$CMD_PID" 2>/dev/null || true
      sleep 1
      kill -KILL "$CMD_PID" 2>/dev/null || true
      exit 0
    fi
    now="$(date +%s)"
    if (( now - start >= TIMEOUT_SEC )); then
      echo "timed_out" > "$TERM_REASON_FILE"
      kill -TERM "$CMD_PID" 2>/dev/null || true
      sleep 1
      kill -KILL "$CMD_PID" 2>/dev/null || true
      exit 0
    fi
    sleep 1
  done
) &
WATCHDOG_PID=$!
echo "WATCHDOG_PID=$WATCHDOG_PID" >> "$JOB_DIR/pids.env"

set +e
wait "$CMD_PID"
RC=$?
set -e

kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

term_reason="$(cat "$TERM_REASON_FILE" 2>/dev/null || true)"
if [[ "$term_reason" == "cancelled" ]]; then
  set_state STATUS cancelled
  set_state EXIT_CODE 130
  set_state ENDED_AT "$(now_iso)"
  [[ -n "$job_id" ]] && emit_event "subagent_cancelled" "id=$job_id" "exit_code=130"
  exit 0
fi
if [[ "$term_reason" == "timed_out" ]]; then
  set_state STATUS timed_out
  set_state EXIT_CODE 124
  set_state ENDED_AT "$(now_iso)"
  [[ -n "$job_id" ]] && emit_event "subagent_timed_out" "id=$job_id" "exit_code=124"
  exit 0
fi

if [[ "$RC" -eq 0 ]]; then
  set_state STATUS completed
  [[ -n "$job_id" ]] && emit_event "subagent_completed" "id=$job_id" "exit_code=$RC"
else
  set_state STATUS failed
  [[ -n "$job_id" ]] && emit_event "subagent_failed" "id=$job_id" "exit_code=$RC"
fi
set_state EXIT_CODE "$RC"
set_state ENDED_AT "$(now_iso)"
