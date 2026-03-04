#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

echo "== Validate portable-pai-core =="

required=(
  "$ROOT_DIR/core/scripts/pai_core_lib.sh"
  "$ROOT_DIR/core/scripts/pai_policy_eval.py"
  "$ROOT_DIR/core/scripts/pai_runtime_guard.sh"
  "$ROOT_DIR/core/scripts/pai_subagent_ctl.sh"
  "$ROOT_DIR/core/scripts/pai_native_mutation.sh"
  "$ROOT_DIR/core/scripts/pai_native_circuit.sh"
  "$ROOT_DIR/core/scripts/pai_native_replay.sh"
  "$ROOT_DIR/core/schemas/event.schema.json"
  "$ROOT_DIR/core/schemas/policy.schema.json"
  "$ROOT_DIR/scripts/init-project.sh"
)

for f in "${required[@]}"; do
  [[ -f "$f" ]] || { echo "Missing required file: $f"; exit 2; }
done

echo "Required files: PASS"

TMP_DIR="$(mktemp -d /tmp/pai-validate.XXXXXX)"
TARGET="$TMP_DIR/proj"
mkdir -p "$TARGET"

bash "$ROOT_DIR/scripts/init-project.sh" --project "$TARGET" >/dev/null

"$TARGET/scripts/pai_runtime_guard.sh" status >/dev/null
"$TARGET/scripts/pai_policy_eval.py" --policy "$TARGET/.pai/config/policy.json" --mode proposal_only --actor child --command "echo ok" --root "$TARGET" >/dev/null

if "$TARGET/scripts/pai_policy_eval.py" --policy "$TARGET/.pai/config/policy.json" --mode proposal_only --actor child --command "touch /tmp/pai_validate_block" --root "$TARGET" >/dev/null 2>&1; then
  echo "Policy deny check failed"
  rm -rf "$TMP_DIR"
  exit 3
fi

echo "Bootstrap + policy checks: PASS"
rm -rf "$TMP_DIR"

echo "VALIDATION_STATUS=PASS"
