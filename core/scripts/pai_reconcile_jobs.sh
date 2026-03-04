#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
SUB_DIR="$ROOT_DIR/.pai/runtime/subagents"
SUB_EVENT_LOG="$SUB_DIR/events.log"
EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"

mkdir -p "$SUB_DIR"
touch "$SUB_EVENT_LOG"

DRY_RUN=1
FORCE=0
MAX_AGE_SEC=""

usage() {
  cat <<'EOF'
Usage:
  scripts/pai_reconcile_jobs.sh [--apply] [--max-age-sec <seconds>] [--force]

Behavior:
  - Scans sub-agent jobs in STATUS=spawning|running.
  - Uses timestamp/heartbeat signal to detect stale jobs.
  - Marks stale jobs as timed_out with EXIT_CODE=124.

Options:
  --apply            Apply changes (default is dry-run).
  --max-age-sec N    Override stale threshold in seconds.
  --force            Reconcile even if CMD_PID appears alive.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) DRY_RUN=0; shift ;;
    --max-age-sec)
      MAX_AGE_SEC="${2:-}"
      [[ -n "$MAX_AGE_SEC" ]] || { echo "Missing value for --max-age-sec"; exit 1; }
      shift 2
      ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

pai_load_runtime "$ROOT_DIR"

if [[ -z "$MAX_AGE_SEC" ]]; then
  # Default stale window: 2x timeout or 300s (whichever is larger).
  timeout="${SUBAGENT_TIMEOUT_SEC:-180}"
  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    calc=$((timeout * 2))
  else
    calc=300
  fi
  if ((calc < 300)); then
    calc=300
  fi
  MAX_AGE_SEC="$calc"
fi

[[ "$MAX_AGE_SEC" =~ ^[0-9]+$ ]] || { echo "--max-age-sec must be an integer"; exit 1; }

now_epoch="$(date +%s)"
now_iso="$(pai_now_iso)"

emit_event() {
  local event="$1"
  shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

state_get() {
  local key="$1" file="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

state_set() {
  local key="$1" val="$2" file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    awk -v k="$key" -v v="$val" -F= 'BEGIN{OFS="="} $1==k{$0=k"="v}1' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  else
    echo "$key=$val" >> "$file"
  fi
}

iso_to_epoch() {
  local iso="$1"
  if [[ -z "$iso" ]]; then
    echo ""
    return 0
  fi
  python3 - "$iso" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime, timezone

iso = sys.argv[1].strip()
try:
    if iso.endswith("Z"):
        dt = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    else:
        dt = datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    pass
PY
}

heartbeat_epoch_from_file() {
  local job_dir="$1"
  local heartbeat_file="$job_dir/heartbeat.at"
  if [[ -f "$heartbeat_file" ]]; then
    iso_to_epoch "$(cat "$heartbeat_file" 2>/dev/null || true)"
    return 0
  fi
  echo ""
}

cmd_pid_alive() {
  local pids_file="$1"
  local pid
  pid="$(grep -E '^CMD_PID=' "$pids_file" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

processed=0
stale=0
reconciled=0
skipped_live=0

shopt -s nullglob
for state_file in "$SUB_DIR"/*/state.env; do
  processed=$((processed + 1))
  job_dir="$(dirname "$state_file")"
  job_id="$(state_get ID "$state_file")"
  status="$(state_get STATUS "$state_file")"
  [[ "$status" == "running" || "$status" == "spawning" ]] || continue

  heartbeat_at="$(state_get HEARTBEAT_AT "$state_file")"
  started_at="$(state_get STARTED_AT "$state_file")"
  created_at="$(state_get CREATED_AT "$state_file")"

  heartbeat_epoch="$(iso_to_epoch "$heartbeat_at")"
  [[ -n "$heartbeat_epoch" ]] || heartbeat_epoch="$(heartbeat_epoch_from_file "$job_dir")"
  started_epoch="$(iso_to_epoch "$started_at")"
  created_epoch="$(iso_to_epoch "$created_at")"

  ref_epoch="$heartbeat_epoch"
  [[ -n "$ref_epoch" ]] || ref_epoch="$started_epoch"
  [[ -n "$ref_epoch" ]] || ref_epoch="$created_epoch"
  [[ -n "$ref_epoch" ]] || continue

  age_sec=$((now_epoch - ref_epoch))
  if ((age_sec < MAX_AGE_SEC)); then
    continue
  fi
  stale=$((stale + 1))

  pids_file="$job_dir/pids.env"
  if [[ "$FORCE" != "1" && -f "$pids_file" ]] && cmd_pid_alive "$pids_file"; then
    skipped_live=$((skipped_live + 1))
    echo "SKIP_LIVE id=${job_id:-unknown} status=$status age_sec=$age_sec"
    continue
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN_RECONCILE id=${job_id:-unknown} status=$status age_sec=$age_sec -> timed_out"
    continue
  fi

  state_set STATUS timed_out "$state_file"
  state_set EXIT_CODE 124 "$state_file"
  state_set ENDED_AT "$now_iso" "$state_file"
  state_set RECONCILED_AT "$now_iso" "$state_file"
  state_set RECONCILE_REASON stale_job_timeout_reconcile "$state_file"
  echo "$now_iso reconcile id=${job_id:-unknown} from_status=$status to_status=timed_out age_sec=$age_sec" >> "$SUB_EVENT_LOG"
  emit_event "subagent_reconciled_timed_out" "id=${job_id:-unknown}" "from_status=$status" "age_sec=$age_sec"
  echo "RECONCILED id=${job_id:-unknown} from_status=$status age_sec=$age_sec"
  reconciled=$((reconciled + 1))
done
shopt -u nullglob

echo "SUMMARY processed=$processed stale=$stale reconciled=$reconciled skipped_live=$skipped_live dry_run=$DRY_RUN threshold_sec=$MAX_AGE_SEC"
