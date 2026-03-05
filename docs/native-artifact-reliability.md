# Native Artifact Reliability Guide

This document is the canonical reference for the native artifact mitigation stack:
- `scripts/pai_native_mutation.sh` (serialization + watchdog lane)
- `scripts/pai_native_circuit.sh` (circuit-breaker state)
- `scripts/pai_native_replay.sh` (idempotent replay queue)
- `scripts/pai_native_artifact_guard.sh` (artifact-channel timeout/fallback policy)
- `scripts/pai_native_artifact_bridge.sh` (IDE file-event bridge for artifact updates)
- `scripts/pai_runtime_guard.sh` (runtime profile + bridge auto-heal bootstrap)

Note:
- In project repos, these are wrappers under `scripts/`.
- Canonical implementations live in `portable-pai-core/core/scripts/`.

## 1. Goal

Prevent artifact-related deadlocks and races without sacrificing safety:
- block native artifact writes under SHADOW
- force one-way fallback `NATIVE -> SHADOW` on native artifact stall/failure
- preserve auditability with structured events
- keep behavior portable across IDE/CLI implementations

## 2. Control Layers

1. **Profile Gate (hard block in SHADOW)**
- `PAI_NATIVE_SHADOW_ENFORCE_BLOCK=1`
- `pai_native_artifact_guard.sh` denies `--phase start` in `PROFILE=SHADOW`.

2. **Native Mutation Lane**
- `pai_native_mutation.sh` uses a single lock lane to serialize native writes.
- Watchdog timeout enforces max operation duration (`PAI_NATIVE_TIMEOUT_SEC`).

3. **Circuit Breaker**
- `pai_native_circuit.sh` tracks failures and opens after threshold.
- Optional auto-shadow on open (`PAI_NATIVE_AUTO_SHADOW_ON_OPEN=1`).

4. **Replay Queue**
- Failed/idempotent operations can be queued and replayed via `pai_native_replay.sh`.
- Dead-letter behavior prevents infinite retry loops.

5. **Artifact Guard**
- Handles target channels: `task`, `implementation_plan`, `walkthrough`.
- On timeout/failure events, can open breaker and trigger one-way fallback.

6. **Bridge**
- Watches IDE-native artifact files (default Antigravity root).
- Converts file-change activity into guard phases `start/heartbeat/end`.
- Enables timeout policy even when IDE does not expose first-class hook APIs.

## 3. Runtime Flags (Authoritative)

Set in `.pai/config/runtime.env`.

Core artifact controls:
- `PAI_NATIVE_ARTIFACT_AUTO_FALLBACK_ENABLED=1`
- `PAI_NATIVE_ARTIFACT_STALL_TIMEOUT_SEC=180`
- `PAI_NATIVE_ARTIFACT_OBSERVE_ONLY=1|0`
- `PAI_NATIVE_ARTIFACT_ONE_WAY_SHADOW=1`
- `PAI_NATIVE_SHADOW_ENFORCE_BLOCK=1`

Bridge controls:
- `PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED=1|0`
- `PAI_NATIVE_ARTIFACT_SOURCE_ROOT=$HOME/.gemini/antigravity/brain`
- `PAI_NATIVE_ARTIFACT_BRIDGE_POLL_SEC=5`
- `PAI_NATIVE_ARTIFACT_BRIDGE_IDLE_END_SEC=30`
- `PAI_RUNTIME_AUTO_ENSURE_BRIDGE=1`
- `PAI_SHADOW_ALLOWED_ARTIFACT_PATHS=.pai/tasks/todo.md,.pai/plans/active_plan.md,.pai/walkthrough-final.md`

Mutation/circuit/replay controls:
- `PAI_NATIVE_TIMEOUT_SEC`
- `PAI_NATIVE_LOCK_TTL_SEC`
- `PAI_NATIVE_LOCK_WAIT_SEC`
- `PAI_NATIVE_BREAKER_THRESHOLD`
- `PAI_NATIVE_BREAKER_COOLDOWN_SEC`
- `PAI_NATIVE_RETRY_MAX`
- `PAI_NATIVE_REPLAY_ENABLED`
- `PAI_NATIVE_QUEUE_ON_FAILURE`

## 4. Expected Behavior by Profile

### SHADOW profile
- Native artifact `start` is blocked by guard (exit code `11`).
- Bridge may still observe file changes and emit bridge events, but guard blocks native starts.
- No auto-switch needed because profile is already SHADOW.

### NATIVE profile
- Native artifact activity is allowed.
- Stall/failure at guard layer can:
  - open circuit
  - auto-switch to SHADOW (one-way only) when enabled

## 5. Bridge Daemon Lifecycle

Commands:
```bash
scripts/pai_native_artifact_bridge.sh status
scripts/pai_native_artifact_bridge.sh start
scripts/pai_native_artifact_bridge.sh stop
scripts/pai_native_artifact_bridge.sh ensure
scripts/pai_native_artifact_bridge.sh run-once
```

Auto-heal:
- `scripts/pai_runtime_guard.sh status` calls bridge `ensure` when:
  - `PAI_RUNTIME_AUTO_ENSURE_BRIDGE=1`
  - `PAI_NATIVE_ARTIFACT_BRIDGE_ENABLED=1`

This prevents stale PID drift across sessions/reloads.

## 6. Event Model (Audit)

Primary events in `.pai/events/events.jsonl`:
- `native_artifact_started`
- `native_artifact_ended`
- `native_artifact_blocked_in_shadow`
- `native_artifact_fallback_observed` (observe-only mode)
- `native_artifact_auto_shadow`
- `native_circuit_opened`
- `native_circuit_closed`
- `native_artifact_bridge_daemon_started`
- `native_artifact_bridge_loop_started`
- `native_artifact_bridge_session_changed`
- `native_artifact_bridge_started`
- `native_artifact_bridge_idle_end`

Quick filter:
```bash
tail -n 80 .pai/events/events.jsonl | rg "native_artifact|native_circuit|bridge"
```

## 7. Session Bootstrap (Recommended)

Minimal:
```bash
scripts/pai_runtime_guard.sh status
scripts/pai_shadow_hard_banner.sh
```

Rationale:
- prints effective profile + bridge daemon state
- auto-heals bridge if enabled and stale

Full:
```bash
bash scripts/pai_pilot_preflight.sh
```

## 8. Limitations (Important)

This stack fully handles:
- native artifact updates that begin and then stall
- native artifact attempts under SHADOW (blocked start)

It cannot retroactively rescue:
- a currently stuck call that already deadlocked in IDE UI
- pre-write deadlocks where no artifact file/metadata signal is emitted

Operational rule:
- cancel stuck UI step, then retry after confirming bridge is running and profile is correct.

## 9. Troubleshooting Playbook

1. Verify profile + daemon:
```bash
scripts/pai_runtime_guard.sh status
scripts/pai_native_artifact_bridge.sh status
```

2. Confirm event stream:
```bash
tail -n 80 .pai/events/events.jsonl | rg "native_artifact|bridge|circuit"
```

3. If daemon stale:
```bash
scripts/pai_native_artifact_bridge.sh start
scripts/pai_native_artifact_bridge.sh status
```

4. If repeated native failures:
- keep `PROFILE=SHADOW`
- keep `PAI_NATIVE_SHADOW_ENFORCE_BLOCK=1`
- inspect circuit state with `scripts/pai_native_circuit.sh status`

## 10. Validation Matrix

Automated coverage (`npm run test:portable`):
- lock-lane serialization
- mutation watchdog timeout -> circuit -> shadow fallback
- replay idempotency and dedupe
- SHADOW native start block
- one-way artifact fallback (`NATIVE -> SHADOW`)
- bridge-induced artifact stall fallback
- runtime guard auto-ensure for stale bridge daemon

Portable bootstrap validation:
```bash
bash portable-pai-core/scripts/validate.sh
```
