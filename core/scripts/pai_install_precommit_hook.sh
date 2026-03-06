#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"

if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repository: $ROOT_DIR" >&2
  exit 2
fi

hook_dir="$ROOT_DIR/.git/hooks"
hook_file="$hook_dir/pre-commit"
mkdir -p "$hook_dir"

cat > "$hook_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

PAI_DOCS_QUALITY_SCOPE=staged bash scripts/pai_quality_gate_eval.sh
EOF

chmod +x "$hook_file"
echo "PRECOMMIT_HOOK_INSTALLED=$hook_file"
