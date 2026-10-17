# Changelog

## 2026-10-17

- **FIXED:** Preserve editing windows when closing the picker during loading, and prevent pending work from affecting a reopened picker.

## 2026-09-16

- **FIXED:** Reopen the picker after staging from side-by-side file diffs when `spotlight.reopen_picker_after_stage` is enabled.

## 2026-07-02

- **FIXED:** Avoid picker preview errors on unsupported binary/image files.

## 2026-06-22

- **FIXED:** Sync side-by-side file diff cursor location when opening and closing diffs.

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
