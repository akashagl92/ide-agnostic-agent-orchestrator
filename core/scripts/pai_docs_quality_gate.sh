#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
pai_load_runtime "$ROOT_DIR"

scope="${1:-${PAI_DOCS_QUALITY_SCOPE:-all}}"
if [[ "$scope" != "all" && "$scope" != "staged" ]]; then
  echo "Usage: scripts/pai_docs_quality_gate.sh [all|staged]" >&2
  exit 2
fi

cd "$ROOT_DIR"

collect_candidates() {
  if [[ "$scope" == "staged" ]]; then
    git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
  else
    git ls-files 2>/dev/null || find . -type f | sed 's|^\./||'
  fi
}

is_report_file() {
  local p
  p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$p" in
    *.md|*.markdown|*.mdx|*.rst|*.txt|*.adoc|*.html) return 0 ;;
    *) return 1 ;;
  esac
}

has_git() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

failures=0
checked=0

while IFS= read -r path || [[ -n "$path" ]]; do
  [[ -n "$path" ]] || continue
  is_report_file "$path" || continue
  [[ -f "$path" ]] || continue
  checked=$((checked + 1))

  # 1) Direct file URI links never render on remote hosts.
  if rg -n 'file:///' "$path" >/tmp/pai_docs_quality.tmp 2>/dev/null; then
    echo "DOCS_QUALITY_FAIL file_uri path=$path"
    sed -n '1,5p' /tmp/pai_docs_quality.tmp
    failures=$((failures + 1))
  fi

  # 2) Absolute local filesystem paths in markdown links/images.
  if rg -n '\]\((/Users/|/home/|~\/|[A-Za-z]:[/\\])' "$path" >/tmp/pai_docs_quality.tmp 2>/dev/null; then
    echo "DOCS_QUALITY_FAIL absolute_local_markdown_link path=$path"
    sed -n '1,5p' /tmp/pai_docs_quality.tmp
    failures=$((failures + 1))
  fi

  # 3) HTML img/src absolute local filesystem paths.
  if rg -n 'src=["'\''](file:///|/Users/|/home/|~\/|[A-Za-z]:[/\\])' "$path" >/tmp/pai_docs_quality.tmp 2>/dev/null; then
    echo "DOCS_QUALITY_FAIL absolute_local_html_src path=$path"
    sed -n '1,5p' /tmp/pai_docs_quality.tmp
    failures=$((failures + 1))
  fi
done < <(collect_candidates)

rm -f /tmp/pai_docs_quality.tmp

echo "DOCS_QUALITY_SCOPE=$scope"
echo "DOCS_QUALITY_FILES_CHECKED=$checked"

if [[ "$failures" -gt 0 ]]; then
  echo "DOCS_QUALITY_STATUS=FAIL"
  exit 1
fi

echo "DOCS_QUALITY_STATUS=PASS"
