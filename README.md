# Keynote Sidekick

Keynote Sidekick is a macOS app that adds a persistent chat panel next to Apple Keynote and applies presentation edits from natural-language prompts.

It uses a deterministic operation pipeline:

1. Collect live deck context from Keynote.
2. Ask Codex for an intent plan (JSON operations).
3. Normalize and validate operations locally.
4. Execute through deterministic Keynote automation (AppleScript first, AX fallback).


---

## Features

- Persistent right-side chat panel while working in Keynote.
- Deterministic operation execution with validation and safety gates.
- Codex planning through `codex proto` with `codex exec` fallback.
- Optional pipeline mode for scripted testing through STDIN.
- Debug and failure logging.

---

## Requirements

- macOS 13+
- Apple Keynote installed
- Codex CLI installed and authenticated (`codex login`)

---

### Configure settings in app

- Codex CLI path (default `codex`)
- ChatGPT/Codex login status
- Model
- Reasoning settings
- Debug logging toggle
- Reflection-based edits toggle

---

## Reflection-Based Edits

When enabled in Settings, each prompt run can:

1. Capture full deck state before edits.
2. Run normal planning/execution.
3. Capture post-edit state.
4. Ask Codex to verify whether outcome matches objective.
5. If not, apply minimal repair operations and repeat verification.

---

## Safety and Execution Principles

- Deterministic first: AppleScript over coordinate UI actions.
- Idempotent ensure operations where possible.
- Protocol gate + sanitizer normalize planner output before execution.
- Destructive actions require explicit confirmation intent.
- Scope guards prevent plan drift and runaway slide creation.

---

## Logging

Default log directory:

`~/Library/Logs/KeynoteSidekick`

Important files:

- `sidekick.log` (run transcript log)
- `failures.ndjson` (structured failure events)
- `reflection-runs/` (per-run reflection logs when retained)

