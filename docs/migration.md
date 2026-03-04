# Migration

- Preserve existing script entry points (`scripts/pai_*`).
- Move canonical implementations to `core/scripts`.
- Keep wrappers in `scripts/` for compatibility.
- Run stale reconcile + telemetry + quality gate after migration.
