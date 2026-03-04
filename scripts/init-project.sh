#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/init-project.sh --project <absolute_path_to_project>

Installs portable-pai-core config + wrappers into target project.
USAGE
}

PROJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[[ -n "$PROJECT" ]] || { usage; exit 1; }
[[ -d "$PROJECT" ]] || { echo "Project not found: $PROJECT"; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="$(cd "$PROJECT" && pwd -P)"

mkdir -p "$TARGET/.pai/config" "$TARGET/scripts"
cp "$ROOT_DIR/core/config/runtime.env.example" "$TARGET/.pai/config/runtime.env"
cp "$ROOT_DIR/core/config/policy.json" "$TARGET/.pai/config/policy.json"

shell_wrappers=(
  pai_defect_log.sh
  pai_event_bus.sh
  pai_native_circuit.sh
  pai_native_mutation.sh
  pai_native_replay.sh
  pai_quality_gate_eval.sh
  pai_reconcile_jobs.sh
  pai_runtime_guard.sh
  pai_skill_ctl.sh
  pai_stage_detect.sh
  pai_subagent_ctl.sh
  pai_subagent_worker.sh
  pai_telemetry_report.sh
)

for f in "${shell_wrappers[@]}"; do
  cat > "$TARGET/scripts/$f" <<WRAP
#!/usr/bin/env bash
set -euo pipefail

canonical="$ROOT_DIR/core/scripts/$f"
if [[ ! -x "\$canonical" ]]; then
  echo "Missing canonical script: \$canonical" >&2
  exit 2
fi

: "\${PAI_PROJECT_ROOT:=$TARGET}"
export PAI_PROJECT_ROOT
exec "\$canonical" "\$@"
WRAP
  chmod +x "$TARGET/scripts/$f"
done

cat > "$TARGET/scripts/pai_policy_eval.py" <<WRAP
#!/usr/bin/env python3
import os
import pathlib
import runpy
import sys

canonical = pathlib.Path("$ROOT_DIR/core/scripts/pai_policy_eval.py")
if not canonical.exists():
    print(f"Missing canonical script: {canonical}", file=sys.stderr)
    raise SystemExit(2)

os.environ.setdefault("PAI_PROJECT_ROOT", "$TARGET")
runpy.run_path(str(canonical), run_name="__main__")
WRAP
chmod +x "$TARGET/scripts/pai_policy_eval.py"

echo "Portable PAI bootstrap complete for: $TARGET"
echo "Next commands:"
echo "  cd $TARGET"
echo "  scripts/pai_runtime_guard.sh status"
echo "  scripts/pai_telemetry_report.sh"
echo "  scripts/pai_quality_gate_eval.sh"
