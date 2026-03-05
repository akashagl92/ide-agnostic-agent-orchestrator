#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"

echo "== Pilot Preflight =="
echo "root=$ROOT_DIR"

"$ROOT_DIR/scripts/pai_runtime_guard.sh" status | sed -n '1,14p'

echo "\n-- native artifact bridge --"
"$ROOT_DIR/scripts/pai_native_artifact_bridge.sh" ensure
"$ROOT_DIR/scripts/pai_native_artifact_bridge.sh" status

echo "\n-- shadow hard banner --"
"$ROOT_DIR/scripts/pai_shadow_hard_banner.sh"

echo "\n-- config doctor --"
"$ROOT_DIR/scripts/pai_config_doctor.sh" || true

echo "\n-- stale reconcile (dry-run) --"
bash "$ROOT_DIR/scripts/pai_reconcile_jobs.sh"

echo "\n-- subagent list --"
"$ROOT_DIR/scripts/pai_subagent_ctl.sh" list || true

echo "\n-- policy allow/deny smoke --"
if "$ROOT_DIR/scripts/pai_policy_eval.py" --policy "$ROOT_DIR/.pai/config/policy.json" --mode proposal_only --actor child --command "echo ok" --root "$ROOT_DIR"; then
  echo "policy_allow=PASS"
else
  echo "policy_allow=FAIL"
fi
if "$ROOT_DIR/scripts/pai_policy_eval.py" --policy "$ROOT_DIR/.pai/config/policy.json" --mode proposal_only --actor child --command "touch /tmp/pilot_block" --root "$ROOT_DIR"; then
  echo "policy_deny=FAIL"
else
  echo "policy_deny=PASS"
fi

echo "\n-- telemetry + quality gate --"
"$ROOT_DIR/scripts/pai_telemetry_report.sh" >/dev/null
if "$ROOT_DIR/scripts/pai_quality_gate_eval.sh"; then
  echo "quality_gate=PASS"
else
  echo "quality_gate=FAIL"
fi

echo "\n-- latest events --"
tail -n 12 "$ROOT_DIR/.pai/events/events.jsonl" 2>/dev/null || true
