# Plan

## Overview

Closing the picker while Git is loading currently closes ordinary editing windows. Reopening immediately also lets the old load use the new picker's state, producing errors and orphaned picker windows. Fix ownership at the picker lifecycle boundary so closing is safe during loading and work from a closed instance cannot affect its replacement.

### Plan highlights

- Only close windows actually created and owned by the closing picker instance.
- Bind asynchronous loading, action refreshes, and deferred UI callbacks to their originating instance.
- Preserve existing editing windows and buffers across close and immediate reopen.
- Keep public APIs, configuration, source selection, and ordinary picker behavior unchanged; record the fix in the changelog.

## Root cause

### Symptom

With three ordinary editing windows, immediately call `picker.toggle({ source = "git" })` three times: open, close while loading, reopen. The second toggle destroys two editing windows. Pending Git work then reports `lua/delta/picker/ui.lua:1650: Invalid window id`.

### Evidence

- Reproduced on the current checkout using headless Neovim v0.12.0 with `-u NONE`, real Git, and no injected delays. Closing during loading left one of three editing windows and produced a nil-state error at `ui.lua:355`. Immediate reopening left one editing window and reported an invalid window at `ui.lua:1650` (ID 1002 in the observed run).
- Buffer contents survived those runs; their editing windows did not. Ordinary asynchronous open followed by close preserved all three windows without errors.
- `M.show` publishes state with `input_win = 0` and `tree_win = 0` before Git completes. `M.close` accepts both through `nvim_win_is_valid` and passes them to `nvim_win_close`; Neovim interprets 0 as the current window.
- `Git.async` starts a coroutine immediately. Git commands yield through `vim.system`, then resume on `vim.schedule`. `refresh_files` and `refresh_files_for_reopen` read module-level `state` after that yield. Initial-load completion also updates and creates windows through that shared state.
- Both source-cycle actions, stage/unstage, and reset use the same refresh boundary. Scheduled insert-mode, WinLeave, and cursor-focus callbacks also refer to whichever instance is current when they run. Text-change handlers, keymaps, and action contexts belong to the instance that created them.
- Preview operations in `lua/delta/picker/preview.lua` are synchronous. Prevent obsolete picker callbacks from reaching them rather than adding cancellation to the preview or Git layers.
- Existing `tests/integration/picker__stage_selection_after_removed_dir/test.lua` passed (one case), but does not cover closing during loading.

### Cause

The picker conflates a loading instance with an instance that owns real windows, using Neovim's current-window alias as an absent-resource value. Its asynchronous consumers also lack instance ownership: closing clears only the shared pointer, not the authority of callbacks already in flight. A later `show` replaces that pointer while older work still holds permission to read and write it.

This is a normal event-loop ordering, not a theoretical race: consecutive public API calls run before scheduled Git completion. They destroy editing windows immediately; subsequent completion either dereferences nil or updates a replacement instance. The observed window loss and errors justify explicit lifecycle/resource ownership and identity checks at asynchronous boundaries. A general cancellation framework or changes to the Git runner are unnecessary.

## Proposed fix

### Instance and resource ownership

In `lua/delta/picker/ui.lua`, capture the concrete picker state for each opening and use its identity as the ownership token. Represent loading without fake window or buffer IDs; real owned resources become available only when created. Update internal types and consumers coherently so loading and window-ready use are distinct.

Detach the active instance before closing its resources. Close only its actual valid windows and its preview. Closing an already-closed picker remains a no-op. Loading remains an open instance for `is_open` and `toggle`, matching the existing public contract.

Make refresh operations explicitly carry their originating instance. Validate ownership before starting work and after each Git yield before reading source state, applying results, or performing UI work. A failed obsolete load must not clear a newer instance. Only the active load may remember its source, create windows, render, select an entry, or request focus.

### Affected consumers

- Initial opening, including reopen-after-stage source selection and fallback.
- Forward and backward source cycling and subsequent file refresh/layout/title updates.
- Stage/unstage and reset completion refreshes and picker action callbacks. Already-started Git mutations may finish; abandoning the picker is not rollback or cancellation of a requested repository operation. Their obsolete UI continuations must stop without touching a replacement instance.
- Scheduled insert-mode entry, WinLeave close, and CursorMoved focus restoration.
- Buffer text-change handlers, buffer keymaps, and retained action contexts, so callbacks from an old picker cannot act on the replacement.
- Synchronous preview calls remain owned by the active picker; no preview or Git API change is planned.

Keep shared synchronous rendering helpers where their callers establish current ownership. Do not add a line-1650-only workaround, silent error swallowing, retries, or a general asynchronous framework.

### Lifecycle decision table

| Event | Instance ownership | Required behavior |
| --- | --- | --- |
| Show while an instance exists, including loading | Current instance | Keep existing no-op behavior. |
| Close before loading completes | Current loading instance; no windows owned | Detach it; preserve all editing windows and buffers. |
| Close a visible picker | Current window-owning instance | Detach it and close only its picker/preview windows. |
| Load or refresh completes after close | Originating instance is obsolete | Discard picker continuation; do not create windows, mutate current state, close another picker, or steal focus. |
| Close then reopen before old completion | New instance is current | Only new work may initialize and update the new UI. |
| Active load fails | Originating instance is still current | Preserve existing error reporting and release only that instance. |
| Requested Git mutation completes after close | Git work already started; picker obsolete | Let the requested repository operation finish; do not run its abandoned picker UI continuation. |
| Ordinary load/action completion | Originating instance is still current | Preserve current rendering, selection, preview, action, and focus behavior. |

### Documentation and scope

Record the important fix in `CHANGELOG.md`. No public names, defaults, configuration options, or keybindings change. Same-instance source-request ordering and general external window destruction are outside this bugfix unless investigation demonstrates they are required to enforce the approved instance boundary.

## Verify

Add focused coverage in `tests/integration/picker__lifecycle/test.lua`, using existing test helpers and child headless Neovim. Use controlled completion only to make the already-reproduced real event-loop overlap deterministic; keep real-Git smoke coverage as well.

- Open then close before loading finishes: no picker windows appear afterward, `is_open` is false, and no asynchronous errors occur.
- Open, close, reopen while old loading is pending: exercise old-first and new-first completion, including an obsolete failure. Exactly one current picker remains, its state/resources are unchanged by old completion, and closing it leaves no orphaned floats.
- Preserve original editing window IDs, window-to-buffer mappings, buffer contents, and modified flags across those sequences, including after pending work has drained.
- Exercise stale forward/backward source refresh and stage/unstage/reset UI continuations after close/reopen. Preserve the requested repository mutation while preventing stale rendering, selection, callbacks, or closing of the replacement.
- Exercise deferred focus/close behavior across replacement and verify ordinary opening, filtering, source cycling, selection, preview, and closing continue to work through focused coverage plus existing integration tests.
- Run `make test-file FILE=tests/integration/picker__lifecycle/test.lua` during development and `make test` before final review, since lifecycle ownership affects shared picker behavior and Spotlight reopening consumers.
- Repeat the original three-window real-Git scenario with headless Neovim `-u NONE` after the fix, asserting window/buffer preservation, no notifications at error severity, and no orphaned picker windows. Also verify ordinary open/close.

Record actual results and any unavailable interactive UI verification in `result.md`; do not claim interactive rendering was checked from headless tests.
