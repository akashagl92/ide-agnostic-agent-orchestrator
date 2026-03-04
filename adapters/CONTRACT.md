# Adapter Contract

Every adapter must provide:
- `adapter.json` manifest
- Event handlers:
  - `on_session_start`
  - `on_pre_tool_use`
  - `on_post_tool_use`
  - `on_subagent_stop`
  - `on_session_end`
- Capability declaration (hooks, notifications, approvals, panels)
- `scripts/emit_event.sh` (or equivalent) that emits schema-compatible events

Adapters may add IDE-native enhancements but must not bypass core policy decisions.
