#!/usr/bin/env bash
set -euo pipefail

pai_resolve_root() {
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

pai_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Load canonical runtime config first, then runtime profile overrides.
pai_load_runtime() {
  local root="$1"
  local canonical="$root/.pai/config/runtime.env"
  local profile="$root/.pai/runtime/profile.env"

  if [[ -f "$canonical" ]]; then
    # shellcheck disable=SC1090
    source "$canonical"
  fi
  if [[ -f "$profile" ]]; then
    # shellcheck disable=SC1090
    source "$profile"
  fi

  : "${PROFILE:=SHADOW}"
  : "${LOCKED:=1}"
  : "${REASON:=bootstrap_default_shadow}"
  : "${SUBAGENT_ENABLED:=1}"
  : "${SUBAGENT_MODE:=proposal_only}"
  : "${SUBAGENT_MAX_CONCURRENCY:=2}"
  : "${SUBAGENT_TIMEOUT_SEC:=180}"
  : "${SUBAGENT_PARENT_ONLY_WRITES:=1}"
  : "${SUBAGENT_NATIVE_WRITES:=0}"
  : "${CAPABILITY_SPAWN_SUBAGENT:=1}"
  : "${PAI_EVENT_BUS_ENABLED:=1}"
  : "${PAI_EVENT_LOG:=.pai/events/events.jsonl}"
  : "${PAI_POLICY_ENABLED:=1}"
  : "${PAI_POLICY_FILE:=.pai/config/policy.json}"
  : "${PAI_KPI_WINDOW_MODE:=rolling}"
  : "${PAI_KPI_WINDOW_SIZE:=20}"
  : "${PAI_KPI_INCLUDE_RECONCILED:=0}"
  : "${PAI_QUALITY_REFRESH_TELEMETRY:=1}"

  # Backward-compat mapping: legacy research_only behaves like proposal_only.
  if [[ "$SUBAGENT_MODE" == "research_only" ]]; then
    SUBAGENT_MODE="proposal_only"
  fi
}

pai_validate_mode() {
  case "${1:-}" in
    single_parent|proposal_only|scoped_write) return 0 ;;
    *) return 1 ;;
  esac
}
