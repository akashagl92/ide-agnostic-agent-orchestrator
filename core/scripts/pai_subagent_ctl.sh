#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
PROFILE_FILE="$ROOT_DIR/.pai/runtime/profile.env"
SUB_DIR="$ROOT_DIR/.pai/runtime/subagents"
EVENT_LOG="$SUB_DIR/events.log"
WORKER="$ROOT_DIR/scripts/pai_subagent_worker.sh"
POLICY_EVAL="$ROOT_DIR/scripts/pai_policy_eval.py"
EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
mkdir -p "$SUB_DIR"

now_iso() { pai_now_iso; }

load_profile() {
  pai_load_runtime "$ROOT_DIR"
  pai_validate_mode "$SUBAGENT_MODE" || { echo "Invalid subagent mode: $SUBAGENT_MODE"; exit 2; }
}

emit_event() {
  local event="$1"
  shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

count_active() {
  local c=0
  shopt -s nullglob
  for s in "$SUB_DIR"/*/state.env; do
    status="$(grep -E '^STATUS=' "$s" | tail -n1 | cut -d= -f2- || true)"
    [[ "$status" == "spawning" || "$status" == "running" ]] && c=$((c+1))
  done
  shopt -u nullglob
  echo "$c"
}

reject_by_legacy_rules() {
  local cmd_text="$1"
  local forbidden=("task.md" "implementation_plan.md" "walkthrough.md" ".pai/tasks/todo.md" ".pai/plans/active_plan.md" ".pai/walkthrough-final.md")
  for t in "${forbidden[@]}"; do
    [[ "$cmd_text" == *"$t"* ]] && { echo "Rejected command: forbidden target '$t'"; exit 4; }
  done
  if [[ "$SUBAGENT_MODE" != "proposal_only" ]]; then
    return 0
  fi
  local pattern='(>|>>|\bsed\s+-i\b|\brm\b|\bmv\b|\bcp\b|\btouch\b|\bmkdir\b|\btee\b|\bperl\s+-i\b|\bapply_patch\b|\bgit\s+add\b|\bgit\s+commit\b)'
  if echo "$cmd_text" | grep -Eq "$pattern"; then
    echo "Rejected command: SUBAGENT_MODE=proposal_only allows read/analyze/propose only"
    exit 6
  fi
  return 0
}

cmd="${1:-help}"
case "$cmd" in
  spawn)
    shift
    load_profile
    [[ "$SUBAGENT_ENABLED" == "1" ]] || { echo "Spawn disabled"; exit 3; }
    [[ "$CAPABILITY_SPAWN_SUBAGENT" == "1" ]] || { echo "Spawn capability unavailable"; exit 3; }
    [[ -x "$WORKER" ]] || { echo "Missing worker script: $WORKER"; exit 2; }

    label="${1:-}"
    [[ -n "$label" ]] || { echo "Usage: ... spawn <label> -- <command>"; exit 1; }
    shift
    [[ "${1:-}" == "--" ]] || { echo "Usage: ... spawn <label> -- <command>"; exit 1; }
    shift
    [[ "$#" -ge 1 ]] || { echo "Missing command"; exit 1; }
    cmd_text="$*"

    if [[ "${PAI_POLICY_ENABLED:-1}" == "1" && -x "$POLICY_EVAL" && -f "${ROOT_DIR}/${PAI_POLICY_FILE}" ]]; then
      if ! "$POLICY_EVAL" --policy "${ROOT_DIR}/${PAI_POLICY_FILE}" --mode "$SUBAGENT_MODE" --actor child --command "$cmd_text" --root "$ROOT_DIR"; then
        emit_event "subagent_spawn_denied" "reason=policy_eval_denied" "mode=$SUBAGENT_MODE" "label=$label"
        exit 6
      fi
    else
      reject_by_legacy_rules "$cmd_text"
    fi

    active="$(count_active)"
    (( active < SUBAGENT_MAX_CONCURRENCY )) || { echo "Spawn denied: active=$active max=$SUBAGENT_MAX_CONCURRENCY"; exit 5; }

    id="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    job="$SUB_DIR/$id"
    mkdir -p "$job"

    cat > "$job/command.sh" <<EOC
#!/usr/bin/env bash
set -euo pipefail
cd "$ROOT_DIR"
$cmd_text
EOC
    chmod +x "$job/command.sh"

    cat > "$job/state.env" <<EOS
ID=$id
LABEL=$label
STATUS=spawning
CREATED_AT=$(now_iso)
MODE=$SUBAGENT_MODE
COMMAND=$cmd_text
EOS

    nohup "$WORKER" "$job" "$SUBAGENT_TIMEOUT_SEC" > "$job/worker.log" 2>&1 &
    wp=$!
    echo "$(now_iso) spawn id=$id label=$label mode=$SUBAGENT_MODE worker_pid=$wp" >> "$EVENT_LOG"
    emit_event "subagent_spawned" "id=$id" "label=$label" "mode=$SUBAGENT_MODE" "worker_pid=$wp"
    echo "SPAWNED id=$id label=$label mode=$SUBAGENT_MODE"
    echo "JOB_DIR=$job"
    ;;
  status)
    id="${2:-}"; [[ -n "$id" ]] || { echo "Usage: ... status <id>"; exit 1; }
    cat "$SUB_DIR/$id/state.env"
    ;;
  list)
    shopt -s nullglob
    for s in "$SUB_DIR"/*/state.env; do
      id="$(grep -E '^ID=' "$s"|tail -n1|cut -d= -f2-)"
      st="$(grep -E '^STATUS=' "$s"|tail -n1|cut -d= -f2-)"
      lb="$(grep -E '^LABEL=' "$s"|tail -n1|cut -d= -f2-)"
      echo "$id $st $lb"
    done
    shopt -u nullglob
    ;;
  collect)
    id="${2:-}"; [[ -n "$id" ]] || { echo "Usage: ... collect <id>"; exit 1; }
    job="$SUB_DIR/$id"
    cat "$job/state.env"
    echo "--- STDOUT ---"
    sed -n '1,200p' "$job/stdout.log" 2>/dev/null || true
    echo "--- STDERR ---"
    sed -n '1,120p' "$job/stderr.log" 2>/dev/null || true
    ;;
  cancel)
    id="${2:-}"; [[ -n "$id" ]] || { echo "Usage: ... cancel <id>"; exit 1; }
    touch "$SUB_DIR/$id/cancel.requested"
    echo "$(now_iso) cancel id=$id" >> "$EVENT_LOG"
    emit_event "subagent_cancel_requested" "id=$id"
    echo "CANCEL_REQUESTED id=$id"
    ;;
  *)
    cat <<U
Usage:
  scripts/pai_subagent_ctl.sh spawn <label> -- <command>
  scripts/pai_subagent_ctl.sh status <id>
  scripts/pai_subagent_ctl.sh list
  scripts/pai_subagent_ctl.sh collect <id>
  scripts/pai_subagent_ctl.sh cancel <id>
U
    ;;
esac
