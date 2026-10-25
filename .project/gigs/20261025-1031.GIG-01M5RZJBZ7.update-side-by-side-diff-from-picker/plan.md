# Update side-by-side diff when opening a file from the picker

## Overview

If you open the picker from a side-by-side file diff tab and pick a file, the file currently opens as a normal buffer inside one of the diff panes. That breaks the diff tab. One pane loses diff mode and the delta diff keymaps, so the configured `diff.file.keys.close` key (for example `<D-w>`) falls through to the user's global mapping instead of closing the diff tab. This fix keeps the tab a diff and makes it show the picked file.

The same review loop exists after staging. With `spotlight.reopen_picker_after_stage = true`, staging a whole file from a side-by-side diff currently closes the diff tab and reopens the picker over the original window, so the next pick opens a normal buffer. With this fix, the diff tab stays open, the picker reopens from inside it with the next unstaged file preselected, and picking a file updates the diff. You can review, stage and move to the next file without leaving the side-by-side diff.

### Plan highlights

- When the picker was opened from a pane of a side-by-side diff tab, every picker open action (`open`, `open_vsplit`, `open_hsplit`, `spotlight`, and custom handlers calling `ctx.open`) replaces that tab's diff with the selected file's diff. It opens no buffer, split, or Spotlight view.
- The selected entry's picker section picks the diff mode: unstaged entries show INDEX ↔ WORKTREE, and staged entries show HEAD ↔ INDEX.
- Both panes stay delta diff buffers, so every `diff.file.keys` action, including close, keeps working from either pane.
- Closing a diff that was switched to another file returns to the original window showing that file, with the cursor on the diff's cursor line. This is the same cursor handoff that closing an unswitched diff already does.
- When a side-by-side diff's stage action fully stages the file and `reopen_picker_after_stage` is on, the diff tab stays open and shows that file's staged view (HEAD ↔ INDEX). The picker reopens from the diff tab with the next unstaged file preselected. If the picker is dismissed, the staged view stays. After that, the diff picks its mode automatically: unstaging it again shows the unstaged view instead of closing the tab. If the file has no staged diff left (its index now matches HEAD), the tab closes as it does today and the picker reopens from the original window.
- `toggle_stage_file_and_close`, unstaging, and staging with `reopen_picker_after_stage = false` behave as they do now.
- Picker behavior outside side-by-side diff tabs is unchanged.
- Side-by-side diffs compare the final newline too. The extra empty line at the end of the WORKTREE pane is gone, and a change that only adds or removes the final newline still counts as a change: the side without a final newline shows a `\ No newline at end of file` marker line, as Git does.

## Root cause

### Symptom

1. Open a side-by-side diff with `diff.open_file()`.
2. Open the picker from one of the diff panes.
3. Choose another changed file with `<CR>`.

The diff tab now holds one delta diff pane and one ordinary file buffer. In that ordinary pane, diff mode is off and the delta diff keymaps are gone. Pressing the configured diff close key runs the user's global mapping (for example, a buffer delete) instead of closing the diff tab.

### Evidence

In headless Neovim with `diff.file.keys.close = "<D-w>"`:

- Before the picker: both panes are `delta://diff/...` buffers with `'diff'` on and `<D-w>` mapped to `delta.diff.file.close`.
- After choosing `g.txt` in the picker: one pane is `/private/tmp/dprobe/g.txt` with `'diff'` off and no `<D-w>` buffer mapping.

### Cause

The picker's `open` context in `lua/delta/picker/ui.lua` always calls `find_target_win(origin_win)` and then `Spotlight.open_picker_entry`, which runs `:edit`, `:vsplit` or `:split` in that window. When the picker was opened from a diff pane, `origin_win` is that pane. If the pane holds a `nofile` diff buffer, `find_target_win` falls back to another non-floating window in the same tab, which is the other diff pane. Nothing checks whether the window belongs to a side-by-side diff tab. The diff module (`lua/delta/diff/file.lua`) also has no operation to switch an open diff tab to another file.

## Proposed fix

### `lua/delta/diff/file.lua`

Add two module functions next to `open`/`close`:

- `M.owns_win(winid)` returns whether `winid` is the left or right pane of a live side-by-side diff tab.
- `M.replace(winid, file, mode)` switches the diff tab that owns `winid` to `file` (a `delta.RepositoryFile`) with `mode` (`"unstaged"|"staged"`):
  1. Load lines asynchronously with the existing `load_diff_lines(file, mode, nil)`. The worktree side is read from disk, the same as `open({ path = ... })` for a file not shown in the current buffer.
  2. If loading fails, the existing error notifications apply and the current diff stays unchanged. If the file has no changes in that mode, notify `No changes for <path>` and keep the current diff.
  3. Otherwise, create new left/right side buffers with `create_side_buffer` and put them in the existing panes. The old buffers are wiped because of `bufhidden = wipe`. Re-run `setup_window` and `diffthis` on both panes, then `diffupdate`.
  4. Update the tab state in place: `path`, `file`, `requested_mode`, `resolved_mode`, `left_buf`, `right_buf`. Clear the source-buffer tracking (`source_bufid`, `source_changedtick`, `source_cursor_line`, `used_source_buffer = false`). Existing stage/reset safety therefore treats the new file like a path-opened diff: unsaved changes in an open buffer for that file block stage/reset with the existing error.
  5. Keep the tab, its `origin_tab`/`origin_win`, the current context width, and the keymap-hint mode. Rebind the file keymaps on the new buffers through `setup_keymaps`, then refresh the winbars.
  6. Put both panes' cursors on the first changed line.
  7. Ignore the request if the tab closed or another replacement started while loading. Only the latest request is applied.

The existing `TabClosed` cleanup, `close`, and diffopt reference counting keep working because the state object and tab stay the same.

`replace` also sets `state.replaced = true`.

### Returning to the switched file on close

In `M.close`, after the tab closes and focus goes back to `origin_win`: if `state.replaced` is true and the origin window's buffer is not `state.path` (compared with `Repository.buffer_path`, as `restore_origin_cursor` already does), open `state.path` in `origin_win` with `:edit` before restoring the cursor. The existing `restore_origin_cursor` then moves the cursor to the diff's cursor line, because the origin buffer's path now matches.

- If the worktree file no longer exists (for example, a deleted file), the origin window is not switched, so closing never creates an empty buffer for a missing path.
- If `:edit` fails (for example, `nohidden` with a modified origin buffer), notify `diff: could not open <path>: <error>` and leave the origin window as it is.
- A diff never switched with `replace` keeps today's close behavior. This includes `open_file({ path = ... })` targeting a file other than the origin buffer, which today returns to the origin buffer without moving the cursor, as "does not move cursor when diff closes to another file" covers.
- If the diff is switched back to the origin buffer's file, no `:edit` is needed and today's cursor restore applies.

This applies to the configured close key, to `toggle_stage_file_and_close` and `reset_file_and_close`, and to the tab closing because no diff remains. Each of them calls `M.close`. A manual `:tabclose` goes through `TabClosed` cleanup and does not refocus the origin window, so it is unchanged.

### `lua/delta/picker/ui.lua`

In the `open` action context, before `find_target_win`, check `require("delta.diff.file").owns_win(origin_win)`, using a lazy require like the existing cross-module calls. If it returns true and the node is a file:

1. Close the picker and focus `origin_win`.
2. Call `replace(origin_win, node.file, node.section == "staged" and "staged" or "unstaged")`.
3. Return `true`. The `cmd` and `spotlight` options are ignored, so all built-in open actions and custom handlers that call `ctx.open` behave the same way.

Otherwise, keep the current path unchanged.

### Staying in the diff after stage with picker reopen

The picker reopen must start only after the diff has settled. Otherwise it could open inside a tab that the staged-view refresh is about to close.

In `lua/delta/spotlight/core.lua`, split `M.reopen_picker_after_stage(file, origin_win)` into two functions:

- `M.should_reopen_picker_after_stage(file)`: the option check and the fresh `Git.file_status` check (no unstaged changes left). Must be called inside `Git.async`. It returns `should_reopen, status`.
- `M.schedule_picker_reopen(file, origin_win)`: the existing `vim.schedule` reopen, run in `origin_win` when that window is valid.

`M.reopen_picker_after_stage` keeps its signature and current behavior by calling both, so the Spotlight callers are unchanged.

In `lua/delta/diff/file.lua`, `refresh_state(state, on_done)` gets an optional callback. It runs after the refresh finishes: after the new lines are applied, or after the tab is closed because no diff remains. It does not run when loading fails.

In `toggle_stage_file`, after a successful stage of unstaged changes with `close_after = false`, when `should_reopen_picker_after_stage` returns true:

1. Do not close the tab. Set `state.requested_mode = "auto"` and call `refresh_state(state, on_done)`. `should_reopen_picker_after_stage` already confirmed that no unstaged changes remain, so `auto` resolves to the file's HEAD ↔ INDEX diff. Unlike a fixed `staged` mode, unstaging later goes back to INDEX ↔ WORKTREE, and the tab doesn't close because no staged diff remains.
2. In `on_done`, if the tab is still open (`tabs[state.tab] == state`), call `schedule_picker_reopen(state.file, active_diff_win(state))`. The picker then opens from the diff tab, and picking a file goes through `replace` above. If `refresh_state` closed the tab because no staged diff remains, call `schedule_picker_reopen(state.file, state.origin_win)`, the same as today.

With `close_after = true` (`toggle_stage_file_and_close`), keep today's behavior: close the tab and reopen the picker from `state.origin_win`. Unstaging never reopens the picker, so it is unchanged. When no reopen is scheduled (option off, or unstaged changes remain), keep today's `refresh_state`/close behavior.

### Final newline in side-by-side diffs

Today the WORKTREE pane shows one extra empty line at the end, while HEAD and INDEX don't. `Git.get_worktree_lines` reads with `readfile(path, "b")`, which keeps a trailing `""` for the final newline, while `git show` output is split with the final newline dropped. Simply dropping that `""` would hide changes that only add or remove the final newline: for example, index `a` without a final newline and worktree `a\n` would compare as equal, the diff would report "No changes", and `replace` couldn't show the file.

Fix it where the side-by-side diff loads its content:

1. `lua/delta/git.lua` adds `M.get_content(file, source)`, where `source` is `"head"`, `"index"` or `"worktree"`. It returns `ok, content, err`, with `content = { lines: string[], eol: boolean }`. `lines` never includes the trailing empty element, and `eol` says whether the content ends with a newline. An empty file, or one missing from that source, gives `{ lines = {}, eol = false }`. The existing `get_head_lines`, `get_index_lines` and `get_worktree_lines` keep their behavior for Spotlight. `get_content` shares the existing `git show` call and missing-blob handling, so a missing blob still loads as empty.
2. When the diff uses the source buffer's lines, its `eol` is the newline the buffer would write: `vim.bo.endofline or (vim.bo.fixendofline and not vim.bo.binary)`. A truly empty buffer (one empty line and zero bytes, `nvim_buf_get_offset(buf, 1) == 0`) maps to `{ lines = {}, eol = false }`, matching an empty file.
3. `load_diff_lines` loads both sides through `get_content` (or the source buffer). The sides are equal only when both their lines and their `eol` match.
4. A side whose `eol` is false while the other side's is true gets an extra display line, `\ No newline at end of file`, so the newline change is visible and highlighted in the diff. Display lines go only into the side buffers, which are read-only and never written. Stage, reset and Git calls work on files and the index, never on these lines.

### Documentation

In `README.md`, under the Picker section, say that opening a file from a picker launched in a side-by-side diff tab updates that diff instead of opening a buffer. Mention that this applies to every open action and that the picker section selects unstaged or staged mode.

Update the `reopen_picker_after_stage` text in the Spotlight section and the Review workflow tip: after a stage from a side-by-side diff, the diff tab stays open on the staged view and the reopened picker updates it, while `toggle_stage_file_and_close` still closes the tab.

In the Side-by-side file diff section, next to the existing close-behavior sentence, say that closing a diff switched through the picker opens the switched-to file in the original window with the cursor on the diff's cursor line, and leaves the window unchanged when that file no longer exists on disk.

## Verify

Add integration cases to `tests/integration/diff__side_by_side_tab/test.lua`, driving the real picker in headless Neovim:

- From the right pane, `<CR>` on another unstaged file keeps exactly 2 tabs and 2 windows in the diff tab. Both panes are `delta://diff/...` buffers for the new file with `'diff'` on, the side contents match the new file's index and worktree lines, the winbars show the new path, and both panes' cursors are on the new file's first changed line even when the original diff's cursor was further down.
- From the left pane, the same holds. Afterwards, the configured close key pressed in the left pane closes the diff tab and returns to the original window (the reported symptom).
- `open_vsplit`, `open_hsplit`, and `spotlight` actions from a diff pane each update the diff without adding windows or enabling Spotlight.
- A staged picker entry switches the diff to HEAD ↔ INDEX mode.
- After replacement, the stage key acts on the new file, not the original one.
- After replacement, moving the right pane's cursor and pressing the close key returns to the original window. That window now shows the new file with the cursor on that line. The previous buffer stays loaded (`:ls`), and no extra window or tab exists.
- Switching back to the origin buffer's file and closing restores the cursor without changing the buffer.
- After a stage with picker reopen and dismissing the picker, pressing the stage key again unstages the file. The tab stays open and switches to the unstaged view (INDEX ↔ WORKTREE).
- Final newline: a normal change shows the same line count on both sides, with no extra trailing empty line on the WORKTREE side. A worktree change that only adds the final newline (index `a` without one, worktree `a\n`) opens with `open_file({ path = ... })`, and also through `replace`. The INDEX pane shows `a` plus the `\ No newline at end of file` marker, and the WORKTREE pane shows `a`. Staging that change from the diff works.
- Final newline with the source buffer: the origin buffer has `noendofline` and `nofixendofline` while the file on disk has a final newline. The diff shows the marker on the WORKTREE side.
- An unchanged, empty, tracked file opened from its buffer reports `No changes for current file` and opens no diff tab.
- With `reopen_picker_after_stage = true`, the stage key in a side-by-side diff stages the file, keeps the diff tab open in staged mode (left pane shows HEAD, right pane shows INDEX), and reopens the picker from the diff tab with the next unstaged file preselected. `<CR>` then updates the diff to that file. Dismissing the picker instead leaves the staged view of the staged file.
- Empty staged diff after staging, with `reopen_picker_after_stage = true`: commit a change to the file, stage a further change, then revert the worktree to HEAD so the diff shows only unstaged changes. Pressing the stage key makes the index equal HEAD. The diff tab closes, and the picker reopens exactly once from the original window with the next unstaged file preselected. The test waits for the final state and checks that no picker float is left inside a closed tab.
- Update the existing reopen cases that currently expect the tab to close after `toggle_stage_file` ("reopens picker after staging file from auto side-by-side diff", the two custom-source cases, and the inline-source case) to expect the tab to stay open in staged mode with the next file preselected. "reopens picker from origin after side-by-side stage and close" stays as it is and still covers `toggle_stage_file_and_close`.

Run `make test-file FILE=tests/integration/diff__side_by_side_tab/test.lua`, then `make test`. The existing picker split/spotlight cases cover the unchanged behavior outside diff tabs. Repeat the headless reproduction above to confirm the fix.

Not verifiable here: how the swap looks in an interactive UI (flicker, fold rendering).
