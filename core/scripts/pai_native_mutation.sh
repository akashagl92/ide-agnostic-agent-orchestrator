#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"

EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
RUNTIME_DIR="$ROOT_DIR/.pai/runtime"
LOCK_DIR="$RUNTIME_DIR/native_mutation.lock"
QUEUE_DIR="$RUNTIME_DIR/native_queue"
PENDING_DIR="$QUEUE_DIR/pending"
PROCESSED_DIR="$QUEUE_DIR/processed"
DEAD_DIR="$QUEUE_DIR/dead"
mkdir -p "$RUNTIME_DIR" "$PENDING_DIR" "$PROCESSED_DIR" "$DEAD_DIR"

: "${PAI_NATIVE_TIMEOUT_SEC:=20}"
: "${PAI_NATIVE_LOCK_TTL_SEC:=120}"
: "${PAI_NATIVE_LOCK_WAIT_SEC:=30}"
: "${PAI_NATIVE_BREAKER_THRESHOLD:=2}"
: "${PAI_NATIVE_BREAKER_COOLDOWN_SEC:=300}"
: "${PAI_NATIVE_RETRY_MAX:=2}"
: "${PAI_NATIVE_REPLAY_ENABLED:=1}"
: "${PAI_NATIVE_AUTO_SHADOW_ON_OPEN:=1}"
: "${PAI_NATIVE_QUEUE_ON_FAILURE:=1}"

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
  scripts/pai_native_mutation.sh run <operation_key> -- <command>
U
}

cmd="${1:-}"
if [[ "$cmd" != "run" ]]; then
  usage
  exit 1
fi
shift

op_key="${1:-}"
[[ -n "$op_key" ]] || { echo "Missing operation_key"; exit 1; }
shift
[[ "${1:-}" == "--" ]] || { echo "Usage: ... run <operation_key> -- <command>"; exit 1; }
shift
[[ "$#" -gt 0 ]] || { echo "Missing command"; exit 1; }
cmd_text="$*"

if [[ "$PROFILE" != "NATIVE" ]]; then
  emit_event "native_mutation_denied" "op=$op_key" "reason=profile_not_native" "profile=$PROFILE"
  echo "NATIVE_MUTATION_DENY profile=$PROFILE"
  exit 3
fi

# Circuit breaker gate.
cstate="$("$ROOT_DIR/scripts/pai_native_circuit.sh" status | awk -F= '/^STATE=/{print $2}' | tail -n1)"
if [[ "$cstate" == "open" ]]; then
  emit_event "native_mutation_denied" "op=$op_key" "reason=circuit_open"
  echo "NATIVE_MUTATION_DENY circuit_open"
  exit 4
fi

queue_file="$PENDING_DIR/$op_key.env"
if [[ -f "$PROCESSED_DIR/$op_key.ok" ]]; then
  emit_event "native_mutation_deduped" "op=$op_key" "reason=already_processed"
  echo "NATIVE_MUTATION_SKIP already_processed"
  exit 0
fi

acquire_lock() {
  local start wait age lock_ts
  start="$(now_epoch)"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ -f "$LOCK_DIR/created_at_epoch" ]]; then
      lock_ts="$(cat "$LOCK_DIR/created_at_epoch" 2>/dev/null || true)"
      if [[ "$lock_ts" =~ ^[0-9]+$ ]]; then
        age=$(( $(now_epoch) - lock_ts ))
        if (( age > PAI_NATIVE_LOCK_TTL_SEC )); then
          rm -rf "$LOCK_DIR"
          emit_event "native_lock_reaped" "op=$op_key" "age_sec=$age"
          continue
        fi
      fi
    fi
    wait=$(( $(now_epoch) - start ))
    if (( wait >= PAI_NATIVE_LOCK_WAIT_SEC )); then
      return 1
    fi
    sleep 0.2
  done
  echo "$$" > "$LOCK_DIR/owner_pid"
  echo "$(now_epoch)" > "$LOCK_DIR/created_at_epoch"
  echo "$op_key" > "$LOCK_DIR/op_key"
  return 0
}

release_lock() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

queue_failure() {
  local reason="$1"
  [[ "$PAI_NATIVE_REPLAY_ENABLED" == "1" && "$PAI_NATIVE_QUEUE_ON_FAILURE" == "1" ]] || return 0
  if [[ ! -f "$queue_file" ]]; then
    cat > "$queue_file" <<Q
OP_KEY=$op_key
ATTEMPTS=0
CREATED_AT=$(now_iso)
LAST_REASON=$reason
COMMAND=$cmd_text
Q
  else
    awk -F= 'BEGIN{OFS="="} $1=="LAST_REASON"{$0="LAST_REASON='"$reason"'"}1' "$queue_file" > "$queue_file.tmp"
    mv "$queue_file.tmp" "$queue_file"
  fi
  emit_event "native_mutation_enqueued" "op=$op_key" "reason=$reason"
}

if ! acquire_lock; then
  queue_failure "lock_timeout"
  "$ROOT_DIR/scripts/pai_native_circuit.sh" record-failure "lock_timeout" >/dev/null || true
  emit_event "native_mutation_failed" "op=$op_key" "reason=lock_timeout"
  echo "NATIVE_MUTATION_FAIL lock_timeout"
  exit 5
fi

emit_event "native_mutation_started" "op=$op_key"

op_dir="$RUNTIME_DIR/native_ops/$op_key"
mkdir -p "$op_dir"
heartbeat_file="$op_dir/heartbeat.at"
cmd_file="$op_dir/command.sh"
stdout_file="$op_dir/stdout.log"
stderr_file="$op_dir/stderr.log"
term_reason_file="$op_dir/term.reason"
rm -f "$term_reason_file"

echo "$(now_iso)" > "$heartbeat_file"
cat > "$cmd_file" <<C
#!/usr/bin/env bash
set -euo pipefail
cd "$ROOT_DIR"
$cmd_text
C
chmod +x "$cmd_file"

"$cmd_file" >"$stdout_file" 2>"$stderr_file" &
cpid=$!

echo "CMD_PID=$cpid" > "$op_dir/pids.env"
(
  start="$(now_epoch)"
  while kill -0 "$cpid" 2>/dev/null; do
    echo "$(now_iso)" > "$heartbeat_file"
    elapsed=$(( $(now_epoch) - start ))
    if (( elapsed >= PAI_NATIVE_TIMEOUT_SEC )); then
      echo "timeout" > "$term_reason_file"
      kill -TERM "$cpid" 2>/dev/null || true
      sleep 1
      kill -KILL "$cpid" 2>/dev/null || true
      exit 0
    fi
    sleep 1
  done
) &
watchdog_pid=$!

echo "WATCHDOG_PID=$watchdog_pid" >> "$op_dir/pids.env"

set +e
wait "$cpid"
rc=$?
set -e

kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

term_reason="$(cat "$term_reason_file" 2>/dev/null || true)"
reason="ok"
if [[ "$term_reason" == "timeout" ]]; then
  rc=124
  reason="timeout"
fi

if [[ "$rc" -eq 0 ]]; then
  "$ROOT_DIR/scripts/pai_native_circuit.sh" record-success "native_write_ok" >/dev/null || true
  touch "$PROCESSED_DIR/$op_key.ok"
  rm -f "$queue_file"
  emit_event "native_mutation_completed" "op=$op_key" "exit_code=$rc"
  echo "NATIVE_MUTATION_OK op=$op_key"
  release_lock
  exit 0
fi

queue_failure "$reason"
"$ROOT_DIR/scripts/pai_native_circuit.sh" record-failure "$reason" >/dev/null || true
cstate_after="$("$ROOT_DIR/scripts/pai_native_circuit.sh" status | awk -F= '/^STATE=/{print $2}' | tail -n1)"
if [[ "$cstate_after" == "open" && "$PAI_NATIVE_AUTO_SHADOW_ON_OPEN" == "1" ]]; then
  "$ROOT_DIR/scripts/pai_runtime_guard.sh" shadow-on native_circuit_open >/dev/null 2>&1 || true
fi
emit_event "native_mutation_failed" "op=$op_key" "exit_code=$rc" "reason=$reason"
echo "NATIVE_MUTATION_FAIL op=$op_key rc=$rc reason=$reason"
release_lock
exit "$rc"
