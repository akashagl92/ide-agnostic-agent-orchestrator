# Quickstart

## Bootstrap in a project
1. Create `.pai/config/`.
2. Add `runtime.env` and `policy.json` from `core/config/`.
3. Add command wrappers in `scripts/` that execute `core/scripts/*`.
4. Verify with pilot preflight and quality gate.

## Default safe mode
- `PROFILE=SHADOW`
- `SUBAGENT_MODE=proposal_only`
- Parent-only writes for orchestration artifacts.
