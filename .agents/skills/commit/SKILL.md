---
name: commit
description: Analyze staged git changes for this Neovim plugin, write an appropriate Conventional Commit message, and create the commit. Use ! and a BREAKING CHANGE footer for real public API breaks.
---

# Commit

Use this skill when the user wants the agent to inspect staged changes, come up with the right commit message, and commit them.

## Workflow

1. Inspect staged changes with:
   - `git diff --cached --stat`
   - `git diff --cached --name-only`
   - focused `git diff --cached -- <files>` when needed
2. Identify the dominant intent:
   - `feat`, `fix`, `refactor`, `docs`, `test`, `chore`
3. Prefer a specific scope when useful: `spotlight`, `picker`, `api`, `commands`, `config`, `tests`, `docs`.
4. Write a concise Conventional Commit subject:
   - `type(scope): summary`
5. Use `!` only for real breaking changes to public APIs, documented commands, config, keymaps, or user-configured action names.
6. Add a short body only when it helps, especially for renames, removed options, or migration notes.
7. Commit with `git commit`.

## Repo Guidance

This is a Neovim plugin. Prefer user-facing framing over implementation detail.

Good:
- `fix(spotlight): keep cursor on current hunk after refresh`
- `feat(picker): add default keymaps for preview navigation`
- `refactor(git): split patch building into dedicated helpers`

If the change is only an internal move, do not mark it breaking.

## Breaking Changes

`!` in the subject marks the commit as breaking.

Use it when the staged change breaks a real public contract, such as a documented Lua API, command, config key, keymap, or user-configured action name.

Add a `BREAKING CHANGE:` footer when the break needs explanation, migration guidance, or could be ambiguous from the subject alone.

Practical rule:
- use `!` for the signal
- use `BREAKING CHANGE:` for the explanation

Examples:

```text
refactor(api)!: rename spotlight action callbacks
```

```text
refactor(api)!: rename spotlight action callbacks

BREAKING CHANGE: configured action callbacks using the old names must be updated.
```

## Output

When asked to commit:
- state the proposed commit message briefly
- run `git commit`
- report the created commit hash

If staged changes mix unrelated concerns, say so and suggest splitting instead of forcing one bad commit.
