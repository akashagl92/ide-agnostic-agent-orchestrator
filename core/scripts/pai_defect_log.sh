#!/usr/bin/env bash
set -euo pipefail

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
OUT_DIR="$ROOT_DIR/.pai/state"
LOG_FILE="$OUT_DIR/defect_log.jsonl"
mkdir -p "$OUT_DIR"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

usage() {
  cat <<'EOF'
Usage:
  scripts/pai_defect_log.sh add --class <name> --severity <S0|S1|S2|S3> --stage <dev|pre_merge|pre_deploy|post_deploy> --summary <text> [--source <name>] [--owner <name>]
  scripts/pai_defect_log.sh stats
EOF
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage
  exit 1
fi
shift || true

case "$cmd" in
  add)
    defect_class=""
    severity=""
    stage=""
    summary=""
    source="manual"
    owner="unassigned"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --class) defect_class="${2:-}"; shift 2 ;;
        --severity) severity="${2:-}"; shift 2 ;;
        --stage) stage="${2:-}"; shift 2 ;;
        --summary) summary="${2:-}"; shift 2 ;;
        --source) source="${2:-}"; shift 2 ;;
        --owner) owner="${2:-}"; shift 2 ;;
        *) echo "Unknown arg: $1"; usage; exit 1 ;;
      esac
    done

    [[ -n "$defect_class" && -n "$severity" && -n "$stage" && -n "$summary" ]] || {
      echo "Missing required args for add"; usage; exit 1;
    }

    ts="$(now_iso)"
    id="defect-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    printf '{"id":"%s","timestamp":"%s","class":"%s","severity":"%s","stage":"%s","summary":"%s","source":"%s","owner":"%s"}\n' \
      "$id" "$ts" "$defect_class" "$severity" "$stage" "$(echo "$summary" | sed 's/"/\\"/g')" "$source" "$owner" >> "$LOG_FILE"
    echo "DEFECT_LOGGED id=$id file=$LOG_FILE"
    ;;
  stats)
    total=0
    s0=0
    s1=0
    s2=0
    s3=0
    dev=0
    pre_merge=0
    pre_deploy=0
    post_deploy=0
    if [[ -f "$LOG_FILE" ]]; then
      total="$(wc -l < "$LOG_FILE" | tr -d ' ')"
      s0="$(grep -Eic '"severity"[[:space:]]*:[[:space:]]*"S0"' "$LOG_FILE" 2>/dev/null || true)"
      s1="$(grep -Eic '"severity"[[:space:]]*:[[:space:]]*"S1"' "$LOG_FILE" 2>/dev/null || true)"
      s2="$(grep -Eic '"severity"[[:space:]]*:[[:space:]]*"S2"' "$LOG_FILE" 2>/dev/null || true)"
      s3="$(grep -Eic '"severity"[[:space:]]*:[[:space:]]*"S3"' "$LOG_FILE" 2>/dev/null || true)"
      dev="$(grep -Eic '"stage"[[:space:]]*:[[:space:]]*"dev"' "$LOG_FILE" 2>/dev/null || true)"
      pre_merge="$(grep -Eic '"stage"[[:space:]]*:[[:space:]]*"pre_merge"' "$LOG_FILE" 2>/dev/null || true)"
      pre_deploy="$(grep -Eic '"stage"[[:space:]]*:[[:space:]]*"pre_deploy"' "$LOG_FILE" 2>/dev/null || true)"
      post_deploy="$(grep -Eic '"stage"[[:space:]]*:[[:space:]]*"post_deploy"' "$LOG_FILE" 2>/dev/null || true)"
    fi
    cat <<EOF
DEFECT_LOG=$LOG_FILE
TOTAL=$total
S0=$s0
S1=$s1
S2=$s2
S3=$s3
DEV=$dev
PRE_MERGE=$pre_merge
PRE_DEPLOY=$pre_deploy
POST_DEPLOY=$post_deploy
EOF
    ;;
  *)
    usage
    exit 1
    ;;
esac
