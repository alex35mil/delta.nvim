# Changelog

## 2026-06-21

- **ADDED:** Add configurable side-by-side file diff keymap hints with `?` help, inline winbar hints, and disabled mode.

## 2026-06-18

- **CHANGED:** Wrap Markdown side-by-side file diffs for readability.
- **FIXED:** Keep picker selection on the next changed file after staging an entry.

## 2026-06-16

- **BREAKING:** Move hunk diff configuration from `spotlight.diff` to `diff.hunk`.
- **BREAKING:** Move the hunk diff action from `spotlight.actions.open_diff` to `diff.actions.open_hunk_diff`.
- **ADDED:** Add the `delta.diff` API namespace for hunk popups and side-by-side file diffs.
- **ADDED:** Add `:DeltaFileDiff [mode]` for opening side-by-side file diffs.
