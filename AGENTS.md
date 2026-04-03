# Agents

Guidance for coding agents working in this repo.

## Core principles

- Treat the code in `lua/` as the source of truth; use `README.md` as user-facing documentation, not as authority over behavior.
- Prefer changes that are small, targeted, and easy to review.
- Match existing Lua style and naming.
- Avoid unrelated changes.
- If a request is ambiguous or would require broad changes, ask first.

## Project map

- `README.md` — plugin documentation: install, quick start, config, commands, API, highlights.
- `lua/` — plugin implementation.
- `tests/` — automated tests.
- `Makefile` — test entry points.

## Implementation

- Preserve public names and documented behavior unless the task explicitly changes them.
- If public API, commands, keymaps, defaults, or other user-visible behavior changes in code, update `README.md` in the same change.
- Handle errors explicitly. If an error is unrecoverable, fail fast.
- If an error is recoverable, communicate it clearly to the user and handle it deliberately in code.
- Don’t hide errors with odd defaults or by swallowing them silently.

## Testing

- Run `make test-file FILE=...` when a targeted test file is enough.
- Run `make test` when changes affect shared behavior or multiple areas.
- Don’t “fix the test” by weakening or bending the implementation.
- Fix the bug, or fix the test if the test is wrong or stale.
- Behavior changes must be intentional, not driven by test convenience.
- If there are no relevant tests, say so clearly.
- If you couldn’t run tests, say so clearly.

## Verification

- For Lua changes, verify by executing the changed code path in headless Neovim and/or by running tests.
- Use `bash` to run headless Neovim commands and tests.
- Reading files or reviewing diffs is not verification.
- If the behavior can be exercised in headless Neovim, verify it there. If it requires interactive UI checks, say clearly that you could not verify it in this environment.
- In your final report, state exactly what you verified and what you could not verify.
