#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"
SUB_DIR="$ROOT_DIR/.pai/runtime/subagents"
SUB_EVENT_LOG="$SUB_DIR/events.log"
RUNTIME_EVENT_LOG="$ROOT_DIR/.pai/runtime/events.log"
TODO_FILE="$ROOT_DIR/.pai/tasks/todo.md"
DEFECT_LOG="$ROOT_DIR/.pai/state/defect_log.jsonl"
OUT_DIR="$ROOT_DIR/.pai/state"
OUT_JSON="$OUT_DIR/telemetry_report.json"
OUT_MD="$OUT_DIR/telemetry_report.md"
EXEC_LOG="$OUT_DIR/execution_log.jsonl"
EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
mkdir -p "$OUT_DIR"
touch "$EXEC_LOG"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

now_ms() {
  local ms
  ms="$(date +%s%3N 2>/dev/null || true)"
  if [[ -n "$ms" && "$ms" =~ ^[0-9]+$ ]]; then
    echo "$ms"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
    return
  fi
  echo "$(( $(date +%s) * 1000 ))"
}

compute_spawn_window_stats() {
  local sub_dir="$1"
  local mode="$2"
  local size="$3"
  local include_reconciled="$4"
  python3 - "$sub_dir" "$mode" "$size" "$include_reconciled" <<'PY'
import os
import sys
from datetime import datetime

sub_dir, mode, size_s, include_reconciled_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    size = int(size_s)
except Exception:
    size = 20
include_reconciled = str(include_reconciled_s).strip() == "1"

def parse_state(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k] = v
    except Exception:
        return None
    return data

def ts_key(data):
    for k in ("CREATED_AT", "STARTED_AT", "ENDED_AT"):
        v = data.get(k, "")
        if v:
            return v
    return ""

rows = []
if os.path.isdir(sub_dir):
    for name in os.listdir(sub_dir):
        st = os.path.join(sub_dir, name, "state.env")
        if not os.path.isfile(st):
            continue
        data = parse_state(st)
        if not data:
            continue
        if (not include_reconciled) and data.get("RECONCILE_REASON", ""):
            continue
        rows.append(data)

rows.sort(key=ts_key, reverse=True)
if mode == "rolling":
    rows = rows[:max(size, 1)]

completed = failed = timed_out = cancelled = 0
for r in rows:
    status = r.get("STATUS", "")
    if status == "completed":
        completed += 1
    elif status == "failed":
        failed += 1
    elif status == "timed_out":
        timed_out += 1
    elif status == "cancelled":
        cancelled += 1

total = len(rows)
print(f"TOTAL={total}")
print(f"COMPLETED={completed}")
print(f"FAILED={failed}")
print(f"TIMED_OUT={timed_out}")
print(f"CANCELLED={cancelled}")
PY
}

count_or_zero() {
  local pattern="$1"
  local file="$2"
  [[ -f "$file" ]] || { echo 0; return; }
  local out
  out="$(grep -Eic "$pattern" "$file" 2>/dev/null || true)"
  [[ -n "$out" ]] || out=0
  echo "$out"
}

detect_stage() {
  local stage="dev"
  if [[ -x "$ROOT_DIR/scripts/pai_stage_detect.sh" ]]; then
    stage="$("$ROOT_DIR/scripts/pai_stage_detect.sh" | awk -F= '/^STAGE=/{print $2}' | head -n1)"
  fi
  [[ -n "$stage" ]] || stage="dev"
  echo "$stage"
}

build_execution_sections() {
  local exec_file="$1"
  local json_out="$2"
  local md_out="$3"
  python3 - "$exec_file" "$json_out" "$md_out" <<'PY'
import json
import os
import sys

exec_file, json_out, md_out = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
if os.path.exists(exec_file):
    with open(exec_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue

rows = rows[-200:]

def last_by(name):
    for row in reversed(rows):
        if row.get("name") == name:
            return row
    return None

def slim(row):
    if not row:
        return None
    return {
        "ran_at": row.get("ran_at", ""),
        "stage": row.get("stage", ""),
        "name": row.get("name", ""),
        "command": row.get("command", ""),
        "exit_code": row.get("exit_code", -1),
        "status": row.get("status", "UNKNOWN"),
        "duration_ms": row.get("duration_ms", 0),
    }

recent = [slim(r) for r in reversed(rows[-10:])]
payload = {
    "last_quality_gate": slim(last_by("quality_gate_eval")),
    "last_telemetry_report": slim(last_by("telemetry_report")),
    "recent_checks": recent,
}

with open(json_out, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)

with open(md_out, "w", encoding="utf-8") as f:
    f.write("## Execution Log (Recent)\n\n")
    f.write("| Time (UTC) | Stage | Check | Command | Status | Exit | Duration |\n")
    f.write("|---|---|---|---|---|---:|---:|\n")
    if recent:
        for row in recent:
            time = row.get("ran_at", "")
            stage = row.get("stage", "")
            name = row.get("name", "")
            cmd = row.get("command", "")
            status = row.get("status", "")
            exit_code = row.get("exit_code", "")
            duration = row.get("duration_ms", "")
            f.write(f"| {time} | {stage} | {name} | `{cmd}` | {status} | {exit_code} | {duration} ms |\n")
    else:
        f.write("| - | - | - | - | - | - | - |\n")
PY
}

sigma_from_dpmo() {
  # Approximate sigma mapping for software trend tracking.
  local dpmo="$1"
  awk -v d="$dpmo" '
    BEGIN {
      if (d <= 3.4) print "6.0";
      else if (d <= 233) print "5.0";
      else if (d <= 6210) print "4.0";
      else if (d <= 66807) print "3.0";
      else if (d <= 308537) print "2.0";
      else print "1.0";
    }'
}

kpi_window_mode="${PAI_KPI_WINDOW_MODE:-rolling}"
kpi_window_size="${PAI_KPI_WINDOW_SIZE:-20}"
include_reconciled="${PAI_KPI_INCLUDE_RECONCILED:-0}"
if [[ "$kpi_window_mode" != "rolling" && "$kpi_window_mode" != "lifetime" ]]; then
  kpi_window_mode="rolling"
fi
if ! [[ "$kpi_window_size" =~ ^[0-9]+$ ]]; then
  kpi_window_size=20
fi
if [[ "$include_reconciled" != "0" && "$include_reconciled" != "1" ]]; then
  include_reconciled=0
fi

window_stats="$(compute_spawn_window_stats "$SUB_DIR" "$kpi_window_mode" "$kpi_window_size" "$include_reconciled")"
total_spawns="$(echo "$window_stats" | awk -F= '/^TOTAL=/{print $2}' | tail -n1)"
completed="$(echo "$window_stats" | awk -F= '/^COMPLETED=/{print $2}' | tail -n1)"
failed="$(echo "$window_stats" | awk -F= '/^FAILED=/{print $2}' | tail -n1)"
timed_out="$(echo "$window_stats" | awk -F= '/^TIMED_OUT=/{print $2}' | tail -n1)"
cancelled="$(echo "$window_stats" | awk -F= '/^CANCELLED=/{print $2}' | tail -n1)"
[[ -n "$total_spawns" ]] || total_spawns=0
[[ -n "$completed" ]] || completed=0
[[ -n "$failed" ]] || failed=0
[[ -n "$timed_out" ]] || timed_out=0
[[ -n "$cancelled" ]] || cancelled=0

runtime_deadlocks="$(count_or_zero 'native_stall|deadlock|stuck|spinner' "$RUNTIME_EVENT_LOG")"
todo_deadlocks="$(count_or_zero 'deadlock|stuck|spinner' "$TODO_FILE")"
deadlock_events=$((runtime_deadlocks + todo_deadlocks))
fallback_logs="$(count_or_zero 'fallback_to_single_parent|single-parent fallback|fallback to single-parent|fallback to single-parent' "$TODO_FILE")"
stage="$(detect_stage)"

failures=$((failed + timed_out + cancelled))
spawn_den="$total_spawns"
[[ "$spawn_den" -gt 0 ]] || spawn_den=1
spawn_success_rate="$(awk -v ok="$completed" -v total="$spawn_den" 'BEGIN { printf "%.2f", (ok/total)*100 }')"
deadlock_rate="$(awk -v d="$deadlock_events" -v total="$spawn_den" 'BEGIN { printf "%.4f", d/total }')"

fallback_logged_all_failures=0
if [[ "$failures" -eq 0 || "$fallback_logs" -ge "$failures" ]]; then
  fallback_logged_all_failures=1
fi

timestamp="$(now_iso)"
stage="$(detect_stage)"
run_start_ms="$(now_ms)"

append_execution_log() {
  local rc="$1"
  local status="FAIL"
  [[ "$rc" -eq 0 ]] && status="PASS"
  local run_end_ms
  run_end_ms="$(now_ms)"
  local duration_ms=$((run_end_ms - run_start_ms))
  printf '{"ran_at":"%s","stage":"%s","name":"telemetry_report","command":"scripts/pai_telemetry_report.sh","exit_code":%s,"status":"%s","duration_ms":%s}\n' \
    "$(now_iso)" "$stage" "$rc" "$status" "$duration_ms" >> "$EXEC_LOG"
}
trap 'append_execution_log $?' EXIT

emit_event() {
  local event="$1"
  shift || true
  if [[ -x "$EVENT_BUS" ]]; then
    "$EVENT_BUS" emit "$event" "$@" >/dev/null 2>&1 || true
  fi
}

# Opportunity model: changed scope + stage control checks.
changed_files="$(git -C "$ROOT_DIR" diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')"
[[ -n "$changed_files" && "$changed_files" -gt 0 ]] || changed_files=1
case "$stage" in
  dev) stage_checks=4 ;;
  pre_merge) stage_checks=6 ;;
  pre_deploy) stage_checks=5 ;;
  post_deploy) stage_checks=4 ;;
  *) stage_checks=4 ;;
esac
opportunities=$((changed_files + stage_checks + total_spawns))
[[ "$opportunities" -gt 0 ]] || opportunities=1

defect_log_total=0
defect_log_stage=0
if [[ -f "$DEFECT_LOG" ]]; then
  defect_log_total="$(wc -l < "$DEFECT_LOG" | tr -d ' ')"
  defect_log_stage="$(grep -Eic "\"stage\"[[:space:]]*:[[:space:]]*\"$stage\"" "$DEFECT_LOG" 2>/dev/null || true)"
  [[ -n "$defect_log_stage" ]] || defect_log_stage=0
fi

# Stage defects combine logged defects + runtime orchestration failures.
defects=$((defect_log_stage + failures + deadlock_events))
dpo="$(awk -v d="$defects" -v o="$opportunities" 'BEGIN { printf "%.8f", d/o }')"
dpmo="$(awk -v dpo="$dpo" 'BEGIN { printf "%.2f", dpo*1000000 }')"
sigma_level="$(sigma_from_dpmo "$dpmo")"

tmp_exec_json="$(mktemp)"
tmp_exec_md="$(mktemp)"
build_execution_sections "$EXEC_LOG" "$tmp_exec_json" "$tmp_exec_md"
execution_log_json="$(cat "$tmp_exec_json")"
execution_log_md="$(cat "$tmp_exec_md")"
rm -f "$tmp_exec_json" "$tmp_exec_md"

cat > "$OUT_JSON" <<EOF
{
  "updated_at": "$timestamp",
  "root_dir": "$ROOT_DIR",
  "stage": "$stage",
  "kpi_window": {
    "mode": "$kpi_window_mode",
    "size": $kpi_window_size,
    "evaluated_jobs": $total_spawns,
    "include_reconciled": $include_reconciled
  },
  "kpi": {
    "total_spawns": $total_spawns,
    "completed_spawns": $completed,
    "failed_spawns": $failures,
    "defect_log_total": $defect_log_total,
    "defects_current_stage": $defects,
    "spawn_success_rate_pct": $spawn_success_rate,
    "deadlock_events": $deadlock_events,
    "deadlock_rate": $deadlock_rate,
    "fallback_to_single_parent_logs": $fallback_logs,
    "fallback_logged_all_failures": $fallback_logged_all_failures,
    "opportunities_current_stage": $opportunities,
    "dpo_current_stage": $dpo,
    "dpmo_current_stage": $dpmo,
    "sigma_level_current_stage": $sigma_level
  },
  "targets": {
    "spawn_success_rate_pct_min": 95,
    "deadlock_rate_target": 0,
    "fallback_logged_all_failures_target": 1,
    "sigma_level_floor": 4.0
  },
  "execution_log": $execution_log_json
}
EOF

cat > "$OUT_MD" <<EOF
# PAI Telemetry Report

Updated: $timestamp
Stage: $stage
KPI Window: $kpi_window_mode (size=$kpi_window_size, evaluated_jobs=$total_spawns, include_reconciled=$include_reconciled)

- total_spawns: $total_spawns
- completed_spawns: $completed
- failed_spawns: $failures
- defect_log_total: $defect_log_total
- defects_current_stage: $defects
- spawn_success_rate_pct: $spawn_success_rate
- deadlock_events: $deadlock_events
- deadlock_rate: $deadlock_rate
- fallback_to_single_parent_logs: $fallback_logs
- fallback_logged_all_failures: $fallback_logged_all_failures
- opportunities_current_stage: $opportunities
- dpo_current_stage: $dpo
- dpmo_current_stage: $dpmo
- sigma_level_current_stage: $sigma_level

## Targets
- spawn_success_rate_pct >= 95
- deadlock_rate = 0
- fallback_logged_all_failures = 1
- sigma_level_current_stage >= 4.0

$execution_log_md
EOF

echo "TELEMETRY_UPDATED"
echo "JSON=$OUT_JSON"
echo "MARKDOWN=$OUT_MD"
emit_event "telemetry_updated" "stage=$stage" "spawn_success_rate_pct=$spawn_success_rate" "sigma_level=$sigma_level"
