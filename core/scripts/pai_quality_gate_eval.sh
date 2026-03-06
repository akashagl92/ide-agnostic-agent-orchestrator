#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

resolve_root() {
  if [[ -n "${PAI_PROJECT_ROOT:-}" && -d "${PAI_PROJECT_ROOT}" ]]; then
    echo "${PAI_PROJECT_ROOT}"
    return
  fi
  if [[ -d "$(pwd)/.pai" ]]; then
    echo "$(pwd)"
    return
  fi
  if git_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -d "${git_root}/.pai" ]]; then
    echo "${git_root}"
    return
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  echo "$(cd "${script_dir}/.." && pwd -P)"
}

ROOT_DIR="$(resolve_root)"
pai_load_runtime "$ROOT_DIR"
REPORT_JSON="$ROOT_DIR/.pai/state/telemetry_report.json"
EXEC_LOG="$ROOT_DIR/.pai/state/execution_log.jsonl"
EVENT_BUS="$ROOT_DIR/scripts/pai_event_bus.sh"
mkdir -p "$ROOT_DIR/.pai/state"
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
detect_stage() {
  local stage="dev"
  if [[ -x "$ROOT_DIR/scripts/pai_stage_detect.sh" ]]; then
    stage="$("$ROOT_DIR/scripts/pai_stage_detect.sh" | awk -F= '/^STAGE=/{print $2}' | head -n1)"
  fi
  [[ -n "$stage" ]] || stage="dev"
  echo "$stage"
}

stage="$(detect_stage)"
run_start_ms="$(now_ms)"

append_execution_log() {
  local rc="$1"
  local status="FAIL"
  [[ "$rc" -eq 0 ]] && status="PASS"
  local run_end_ms
  run_end_ms="$(now_ms)"
  local duration_ms=$((run_end_ms - run_start_ms))
  printf '{"ran_at":"%s","stage":"%s","name":"quality_gate_eval","command":"scripts/pai_quality_gate_eval.sh","exit_code":%s,"status":"%s","duration_ms":%s}\n' \
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

fail_gate() {
  local reason="$1"
  local error_count="${2:-1}"
  echo "QUALITY_GATE_STATUS=FAIL"
  emit_event "quality_gate_failed" "stage=$stage" "errors=$error_count" "reason=$reason"
  exit 1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for quality gate evaluation" >&2
  exit 2
fi

refresh_telemetry="${PAI_QUALITY_REFRESH_TELEMETRY:-1}"
if [[ "$refresh_telemetry" == "1" ]]; then
  "$ROOT_DIR/scripts/pai_telemetry_report.sh" >/dev/null
else
  [[ -f "$REPORT_JSON" ]] || "$ROOT_DIR/scripts/pai_telemetry_report.sh" >/dev/null
fi

docs_quality_enabled="${PAI_DOCS_QUALITY_ENABLED:-1}"
if [[ "$docs_quality_enabled" == "1" ]]; then
  docs_scope="${PAI_DOCS_QUALITY_SCOPE:-all}"
  if ! "$ROOT_DIR/scripts/pai_docs_quality_gate.sh" "$docs_scope"; then
    echo "QUALITY_FAIL docs_quality_check scope=$docs_scope"
    fail_gate "docs_quality_check_failed"
  fi
fi

spawn_success="$(jq -r '.kpi.spawn_success_rate_pct' "$REPORT_JSON")"
deadlock_rate="$(jq -r '.kpi.deadlock_rate' "$REPORT_JSON")"
fallback_logged="$(jq -r '.kpi.fallback_logged_all_failures' "$REPORT_JSON")"
sigma_level="$(jq -r '.kpi.sigma_level_current_stage' "$REPORT_JSON")"

spawn_target="$(jq -r '.targets.spawn_success_rate_pct_min' "$REPORT_JSON")"
deadlock_target="$(jq -r '.targets.deadlock_rate_target' "$REPORT_JSON")"
fallback_target="$(jq -r '.targets.fallback_logged_all_failures_target' "$REPORT_JSON")"
sigma_target="$(jq -r '.targets.sigma_level_floor' "$REPORT_JSON")"

errors=0
if ! awk -v a="$spawn_success" -v b="$spawn_target" 'BEGIN{exit !(a+0 >= b+0)}'; then
  echo "QUALITY_FAIL spawn_success_rate_pct=$spawn_success target_min=$spawn_target"
  errors=$((errors + 1))
fi
if ! awk -v a="$deadlock_rate" -v b="$deadlock_target" 'BEGIN{exit !(a+0 <= b+0)}'; then
  echo "QUALITY_FAIL deadlock_rate=$deadlock_rate target_max=$deadlock_target"
  errors=$((errors + 1))
fi
if ! awk -v a="$fallback_logged" -v b="$fallback_target" 'BEGIN{exit !(a+0 >= b+0)}'; then
  echo "QUALITY_FAIL fallback_logged_all_failures=$fallback_logged target=$fallback_target"
  errors=$((errors + 1))
fi
if ! awk -v a="$sigma_level" -v b="$sigma_target" 'BEGIN{exit !(a+0 >= b+0)}'; then
  echo "QUALITY_FAIL sigma_level_current_stage=$sigma_level target_min=$sigma_target"
  errors=$((errors + 1))
fi

if [[ "$errors" -gt 0 ]]; then
  fail_gate "kpi_threshold_failure" "$errors"
fi

echo "QUALITY_GATE_STATUS=PASS"
echo "report=$REPORT_JSON"
emit_event "quality_gate_passed" "stage=$stage"
