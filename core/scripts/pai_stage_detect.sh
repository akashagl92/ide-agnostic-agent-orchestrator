#!/usr/bin/env bash
set -euo pipefail

# Detect operational stage for QA gating.
# Priority:
# 1) Explicit override via PAI_STAGE_OVERRIDE
# 2) CLI override via --stage
# 3) Git/branch/staging/deploy signal heuristics

ROOT_DIR="$(pwd)"
if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  ROOT_DIR="$git_root"
fi

cd "$ROOT_DIR"

allowed_stage() {
  case "$1" in
    dev|pre_merge|pre_deploy|post_deploy) return 0 ;;
    *) return 1 ;;
  esac
}

emit() {
  local stage="$1"
  local confidence="$2"
  local reason="$3"
  echo "STAGE=$stage"
  echo "CONFIDENCE=$confidence"
  echo "REASON=$reason"
}

cli_stage=""
if [[ "${1:-}" == "--stage" ]]; then
  cli_stage="${2:-}"
fi

if [[ -n "${PAI_STAGE_OVERRIDE:-}" ]]; then
  if ! allowed_stage "$PAI_STAGE_OVERRIDE"; then
    echo "Invalid PAI_STAGE_OVERRIDE: $PAI_STAGE_OVERRIDE" >&2
    exit 1
  fi
  emit "$PAI_STAGE_OVERRIDE" "high" "manual_override_env"
  exit 0
fi

if [[ -n "$cli_stage" ]]; then
  if ! allowed_stage "$cli_stage"; then
    echo "Invalid --stage value: $cli_stage" >&2
    exit 1
  fi
  emit "$cli_stage" "high" "manual_override_cli"
  exit 0
fi

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no_git")"
staged_count="$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
modified_count="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
last_msg="$(git log -1 --pretty=%s 2>/dev/null || echo "")"

# Deployment-related signals in branch or latest commit message.
if echo "$branch $last_msg" | grep -Eiq "(release|deploy|prod|production|hotfix)"; then
  emit "pre_deploy" "medium" "deploy_signal_in_branch_or_commit"
  exit 0
fi

# Main branch with no local diffs is frequently used as post-deploy monitoring mode.
if [[ "$branch" == "main" && "$modified_count" == "0" ]]; then
  emit "post_deploy" "low" "main_clean_tree_monitoring_assumption"
  exit 0
fi

# Any staged changes usually imply pre-merge QA gate.
if [[ "$staged_count" != "0" ]]; then
  emit "pre_merge" "high" "staged_changes_detected"
  exit 0
fi

# Default working mode.
emit "dev" "medium" "default_dev_fallback"
