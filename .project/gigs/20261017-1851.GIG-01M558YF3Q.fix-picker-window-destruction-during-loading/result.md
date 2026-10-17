# Result

## Overview

Closing the picker during Git loading now preserves editing windows and buffers. Immediate reopening creates one current picker; work from the closed instance cannot create windows, rewrite the new tree, change selection or preview, steal focus, or close its replacement.

Loading and ready instances are represented explicitly. Loading owns no window or buffer IDs. File refreshes, action contexts, buffer handlers, and scheduled focus/close callbacks carry their originating instance and stop their picker continuation once that instance is obsolete. Already-started Git mutations may finish; closing is not a repository rollback.

Public APIs, configuration, keybindings, and ordinary picker behavior remain unchanged. The fix is recorded in the changelog. Same-instance request ordering and unrelated external window destruction remain outside this fix.

## Verification

- `make test-file FILE=tests/integration/picker__lifecycle/test.lua` — all 14 cases passed. Coverage includes closing during loading; old-first, new-first, and obsolete-failure completion; active load failure; reopen-after-stage loading; stale source-cycle, stage/unstage/reset refreshes; retained contexts/keymaps; deferred close/focus/insert-mode work; and ordinary filtering, cycling, selection, preview, and closing. Original editing window IDs, buffer mappings, unsaved contents, and modified flags are checked. Replacement state, windows, focus, preview, and tree-buffer change counts remain unchanged after obsolete work completes.
- `make test` — all 86 cases passed, including existing picker staging and Spotlight/side-by-side reopening tests.
- Headless Neovim v0.12.0 with `-u NONE -i NONE`, real Git, and no controlled completions — open/close during loading, immediate open/close/reopen, and ordinary open/close each preserved all three original editing windows and buffers, including unsaved contents. No error notifications, duplicate picker windows, or orphaned floats remained after completion and close.
- `stylua --check lua/delta/picker/ui.lua tests/integration/picker__lifecycle/test.lua` — passed.
- `git diff --check` — passed.

**Not run:**

- Interactive UI rendering and manual keyboard interaction — verification used headless Neovim; visual appearance was not checked interactively.
