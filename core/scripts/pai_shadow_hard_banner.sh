#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
STATUS_OUT="$("$ROOT_DIR/scripts/pai_runtime_guard.sh" status)"

allowed="$(printf '%s\n' "$STATUS_OUT" | awk -F= '/^NATIVE_ARTIFACTS_ALLOWED=/{print $2}' | tail -n1)"
reason="$(printf '%s\n' "$STATUS_OUT" | awk -F= '/^NATIVE_ARTIFACTS_FORBIDDEN_REASON=/{print $2}' | tail -n1)"
allowed_paths="$(printf '%s\n' "$STATUS_OUT" | awk -F= '/^PAI_SHADOW_ALLOWED_ARTIFACT_PATHS=/{print $2}' | tail -n1)"
if [[ -z "$allowed_paths" ]]; then
  allowed_paths=".pai/tasks/todo.md,.pai/plans/active_plan.md,.pai/walkthrough-final.md"
fi

if [[ "${allowed:-1}" == "0" ]]; then
  cat <<'EOF'
SHADOW_HARD_BANNER=ACTIVE
RULE: If NATIVE_ARTIFACTS_ALLOWED=0, ban task_boundary + native task.md/implementation_plan.md/walkthrough.md edits, use .pai/* only.
BANNED_TOOLS=task_boundary,task.md,implementation_plan.md,walkthrough.md
EOF
  echo "ALLOWED_PAI_PATHS=$allowed_paths"
  [[ -n "$reason" ]] && echo "REASON=$reason"
else
  echo "SHADOW_HARD_BANNER=INACTIVE"
fi
