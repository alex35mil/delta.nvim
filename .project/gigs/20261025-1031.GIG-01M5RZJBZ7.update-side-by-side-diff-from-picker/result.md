# Result

## Overview

- Opening a file from a picker launched in a side-by-side diff tab now updates that diff in place instead of opening a buffer in one of its panes. This applies to every open action (`open`, `open_vsplit`, `open_hsplit`, `spotlight`, and custom handlers calling `ctx.open`). The picker section picks the mode: unstaged entries show INDEX ↔ WORKTREE, and staged entries show HEAD ↔ INDEX. Both panes stay delta diff buffers, so every `diff.file.keys` action, including the close key, keeps working from either pane. This fixes the reported symptom: the close key (for example `<D-w>`) used to fall through to the user's global mapping in a pane that had become a normal buffer.
- After a switch, both panes' cursors move to the new file's first changed line.
- Closing a switched diff returns to the original window showing the switched-to file, with the cursor on the diff's cursor line. The previous buffer stays loaded. If the file no longer exists on disk, the window isn't switched. If `:edit` fails, an error is shown and the window stays as it was.
- With `spotlight.reopen_picker_after_stage = true`, staging a whole file from a side-by-side diff keeps the tab open on that file's staged view (HEAD ↔ INDEX). The picker reopens from inside the tab, with the next unstaged file preselected, and picking a file updates the diff. If you dismiss the picker, the staged view stays; the diff then picks its mode automatically, so unstaging again shows the unstaged view instead of closing the tab. If staging leaves no staged diff, the tab closes and the picker reopens once from the original window. The picker reopens only after the diff has finished refreshing, so it never opens inside a tab that is about to close.
- Unchanged: `toggle_stage_file_and_close`, unstaging, staging with `reopen_picker_after_stage = false`, picker behavior outside side-by-side diff tabs, and diffs never switched through the picker.
- Side-by-side diffs now compare the final newline. The extra empty line at the end of the WORKTREE pane (an existing bug) is gone, and a change that only adds or removes the final newline still shows as a change. The side without a final newline gets a `\ No newline at end of file` line, as in Git. An empty source buffer counts as an empty file. Spotlight's worktree reads are unchanged.
- Limitation: a diff opened from a buffer in the default `auto` mode still chooses its mode from `git status` on disk. If the only difference is an unsaved final-newline change in the buffer, it reports `No changes`. This is existing behavior.

## Implementation walkthrough

- `lua/delta/diff/file.lua`: adds `M.owns_win(winid)` and `M.replace(winid, file, mode)`. `replace` loads asynchronously and applies only the latest request. It swaps fresh side buffers into the existing panes, updates the tab state in place, clears source-buffer tracking (so stage/reset treat the file like a path-opened diff), rebinds keymaps and refreshes winbars. When the file has no changes in that mode, it shows `No changes for <path>` and keeps the current diff. `refresh_state` takes an optional callback that runs once the refresh finishes. `M.close` opens the switched-to file in the origin window before restoring the cursor.
- `lua/delta/git.lua`: adds `M.get_content(file, source)`, which returns `{ lines, eol }` for HEAD, the index or the worktree, with the same missing-blob handling as the existing reads. `load_diff_lines` in `lua/delta/diff/file.lua` uses it. The source buffer's content uses its `endofline`/`fixendofline` settings, and a no-newline marker line is added for display only. Cursor placement after a switch uses the existing linematch segment helper instead of `vim.diff`.
- `lua/delta/spotlight/core.lua`: `reopen_picker_after_stage` is split into `should_reopen_picker_after_stage` and `schedule_picker_reopen`. The original function keeps its signature and behavior for Spotlight callers.
- `lua/delta/picker/ui.lua`: the `open` action context hands off to `replace` when the picker's origin window is a pane of a side-by-side diff.
- `README.md`: documents the picker behavior inside diff tabs and the new stay-in-the-diff review loop for `reopen_picker_after_stage`.

## Verification

- `make test`: 133 cases pass. `tests/integration/diff__side_by_side_tab/test.lua` adds 17 cases, all driving the real picker in headless Neovim:
  - opening from the right pane, and from the left pane, after which the close key closes the tab and returns to the origin window;
  - the vsplit, hsplit and spotlight actions;
  - a staged entry switching the diff to HEAD ↔ INDEX;
  - the stage key acting on the switched-to file;
  - closing after a switch (the origin window shows the new file at the diff cursor);
  - switching back to the origin file and closing;
  - stage with picker reopen staying in the diff;
  - dismissing the reopened picker;
  - an empty staged diff after staging (the tab closes and the picker reopens exactly once from the origin window);
  - unstaging after dismissing the reopened picker (the tab stays open on the unstaged view);
  - final newline: no extra trailing line for a normal change; a newline-only change opened by path (marker shown, staging works) and through the picker; a source buffer with `noendofline` showing the marker on the worktree side; an unchanged empty tracked file reporting `No changes`; an emptied source buffer (with `noendofline`) showing an empty WORKTREE side with no marker. That last test fails when the empty-buffer mapping is disabled.
- The planned source-buffer newline case uses a file that also has an unstaged content change on disk. With an unchanged file, `auto` mode reports `No changes` from `git status` before content is compared (the limitation above).
- Updated the 7 existing reopen cases that expected the tab to close after `toggle_stage_file`. They now expect the tab to stay open in staged mode with the next file preselected. The `toggle_stage_file_and_close` case is unchanged.
- Headless reproduction with `diff.file.keys.close = "<D-w>"`: after picking `g.txt` from a picker opened in a diff pane, both panes are `delta://diff/...` buffers for `g.txt` with `'diff'` on and `<D-w>` mapped to `delta.diff.file.close`. Before the fix, one pane was the plain `g.txt` buffer with diff off and no mapping.
- `git diff --check`: clean.

**Not run:**

- Interactive UI check of how the switch looks (flicker, fold rendering): it requires a real terminal session.
