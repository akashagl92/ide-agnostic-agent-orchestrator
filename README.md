# portable-pai-core

Modular, IDE-agnostic orchestration framework for AI-assisted software delivery.

`portable-pai-core` gives you a portable control plane for:
- runtime safety profiles (`SHADOW` / `NATIVE`)
- structured policy enforcement for parent/sub-agent execution
- event telemetry and quality gates
- adapter contracts for IDE-specific integrations without core lock-in

## Why this exists
Most AI workflows break when moving between IDEs, CLIs, or projects. This framework separates:
- **Core guarantees** (policy, telemetry, quality, orchestration safety)
- **Adapter enhancements** (native hooks, notifications, panels, approvals)

So teams can keep one reliable system across different tooling stacks.

## Architecture

```mermaid
flowchart LR
    A["Project Workspace"] --> B["Wrapper Commands (scripts/pai_*)"]
    B --> C["Core Runtime (core/scripts)"]
    C --> D["Policy Engine (policy.json + pai_policy_eval.py)"]
    C --> E["Event Bus (.pai/events/events.jsonl)"]
    C --> F["Telemetry + Quality Gate"]
    G["IDE/CLI Adapters"] --> E
    G --> C
    H["Personas + Project Context (.pai/)"] --> C
```

## Native Artifact Safety Flow

```mermaid
flowchart TD
    R["Native Mutation Request"] --> L["Single Write Lane Lock"]
    L --> W["Watchdog + Heartbeat"]
    W --> X{"Operation Timed Out/Failed?"}
    X -- "No" --> S["Record Success"]
    S --> C1["Circuit Closed/Reset"]
    X -- "Yes" --> F1["Record Failure"]
    F1 --> C2["Circuit Breaker"]
    C2 --> O{"Breaker Open?"}
    O -- "Yes" --> SH["Auto Switch to SHADOW (Optional)"]
    F1 --> Q["Queue Idempotent Replay Item"]
    Q --> RP["Replay Worker (bounded retries)"]
    RP --> DQ["Processed or Dead-Letter"]
```

## Repository Layout

```text
portable-pai-core/
  adapters/
    CONTRACT.md
    claude/
    codex/
    cursor/
    cli/
    opencode/
  core/
    scripts/
    config/
    schemas/
  docs/
  scripts/
    init-project.sh
  tests/
```

## Core Concepts
- **Profile**: `SHADOW` (safe default) or `NATIVE` (explicitly enabled)
- **Sub-agent modes**: `single_parent`, `proposal_only`, `scoped_write`
- **Policy-first execution**: child commands are evaluated before spawn
- **Event bus**: normalized events emitted to JSONL for audit/automation
- **Quality gate**: KPI-driven pass/fail with stage awareness
- **Native artifact safety stack**:
  - single-lane mutation lock (`pai_native_mutation.sh`)
  - timeout watchdog + circuit breaker (`pai_native_circuit.sh`)
  - idempotent retry/replay queue (`pai_native_replay.sh`)

## Quick Start (Any Project)

From this repo root:

```bash
bash scripts/init-project.sh --project /path/to/your-project
```

This will:
1. create `.pai/config` in the target project
2. install `runtime.env` + `policy.json`
3. create compatibility wrappers in target `scripts/`

Then in target project:

```bash
scripts/pai_runtime_guard.sh status
scripts/pai_telemetry_report.sh
scripts/pai_quality_gate_eval.sh
```

## Configuration
Primary config lives in target project:
- `.pai/config/runtime.env`
- `.pai/config/policy.json`

Important runtime knobs:
- `PAI_KPI_WINDOW_MODE=rolling|lifetime`
- `PAI_KPI_WINDOW_SIZE=<N>`
- `PAI_KPI_INCLUDE_RECONCILED=0|1`
- `PAI_QUALITY_REFRESH_TELEMETRY=0|1`

## Adapter Model
Adapters must comply with [adapters/CONTRACT.md](adapters/CONTRACT.md).

Core policy decisions must remain authoritative; adapters may only add native productivity features.

## Validation

In integrated project repos (where wrappers are installed), run:

```bash
npm run test:portable
bash scripts/pai_pilot_preflight.sh
```

## Deploy as Public Repo

```bash
cd portable-pai-core
git init
git add .
git commit -m "Initial portable-pai-core release"
git branch -M main
git remote add origin git@github.com:<your-org>/portable-pai-core.git
git push -u origin main
```

If using GitHub CLI:

```bash
cd portable-pai-core
gh repo create <your-org>/portable-pai-core --public --source=. --remote=origin --push
```

## Rollout Strategy
1. Pilot in one project (done: Portfolio-Fetch)
2. Extend to `moltbot`
3. Extend to `agentic-memory-scaling`
4. Global rollout

## License
MIT
