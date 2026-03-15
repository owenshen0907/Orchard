# Orchard Runtime Drivers

## Why this layer exists

Orchard is moving toward a simpler model:

- Orchard owns the task/session lifecycle.
- Codex CLI / Claude Code CLI become pluggable execution drivers.
- The local web page and the control plane only talk to Orchard sessions.

This avoids coupling the product UI to any specific desktop client's internal state.

## Iteration 1

This first iteration does **not** replace the existing managed Codex flow.
Instead, it introduces a thin runtime driver layer in front of it:

- `ConversationDriverKind` in `OrchardCore`
- `OrchardRuntimeConversationDriverFactory`
- `OrchardRuntimeConversationController`

Current implementation status:

- `Codex CLI`: implemented
- `Claude Code`: reserved, not implemented yet

## Current behavior

For `TaskKind.codex` tasks:

1. OrchardAgent reads the driver hint from `TaskPayload.codex.driver`.
2. If the payload does not specify a driver yet, Orchard defaults to `codexCLI`.
3. OrchardAgent asks the driver factory for a conversation driver.
4. The driver creates or restores a runtime controller.
5. OrchardAgent manages the process/session through the controller abstraction.
6. The web UI and control plane still consume Orchard's own task/session state.

Current local status page behavior:

- Host-local task creation now carries `driver` inside `CodexTaskPayload`.
- The local web UI still exposes only `Codex CLI` as the selectable engine for creation.
- If a task payload already carries another driver hint, the UI will show it and the factory will fail fast if that driver is not wired yet.

For `TaskKind.shell` tasks:

- Existing process-backed execution remains unchanged.

## Next iterations

1. Wire `claudeCode` into a real runtime driver implementation.
2. Generalize the progress snapshot type so it is no longer Codex-specific.
3. Move local web actions to target Orchard runtime sessions first, instead of special-casing Codex terminology.
4. Let the control plane schedule driver-specific runs without caring about the underlying CLI details.
