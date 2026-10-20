# Result

## Overview

The picker now selects the repository owning the invoking file, including independent nested checkouts, ignored nested repositories, submodules, and linked Git worktrees. Unnamed/non-file buffers and files outside repositories use cwd for picker selection. Each picker still shows one repository.

Spotlight, file diffs, previews, staging, unstaging, resets, hunk actions, and automatic picker reopen retain the selected file's repository across window and cwd changes. Same-named files in different repositories have separate identities. Delta leaves Neovim's cwd unchanged.

Existing command, configuration, and keymap names remain unchanged. README documents repository selection and relative/absolute path semantics. Recursive repository discovery, combined change lists, and submodule management are not added.

## Implementation walkthrough

Shared repository/file references separate absolute filesystem identity from repository-relative Git and display paths. Git discovery resolves the worktree root and actual Git directory; every subsequent Git command runs with an explicit repository cwd. Buffer metadata preserves the underlying file identity in staged/deleted and side-by-side diff views. Repository handoff is separate from Spotlight source-buffer eligibility: native diff panes can open the correct picker or another file diff, but global Spotlight hunk actions cannot mutate their underlying source file. Picker loading cancellation and retained-action lifecycle guards remain intact.

The shared `delta.uri` module owns the `delta://` namespace and name construction/parsing for Spotlight, native diff, and keymap-help views. Spotlight retains its source-view classification, and generated names remain unchanged.

Two verified Git-boundary fixes support these paths: status inspection no longer takes optional index-refresh locks from actual Git mutations, and a staged deletion missing from both disk and index returns an empty index side so deleted-file scratch views can load. Reset undo hints include the owning repository and absolute destination.

## Verification

- `make test` — passed all 116 cases, including 26 new repository-context integration cases and four URI-helper cases.
- `make test-file FILE=tests/unit/test_uri.lua` — passed all four cases.
- `make test-file FILE=tests/integration/repository_context/test.lua` — passed all 26 cases.
- `make test-file FILE=tests/integration/diff__side_by_side_tab/test.lua` — passed all 31 cases.
- `git diff --check` — passed.

The new tests use real temporary repositories and inspect Git indexes, worktree contents, buffers, and view state. Coverage includes ignored/unignored nested checkouts, actual submodules and linked worktrees, fallback and discovery errors, removed directories and staged deletions, scratch-buffer handoff, sources/preselection/preview/split opening, matching relative filenames, file/directory stage/unstage/reset, partial hunks, untracked deletion, undo hints, global/window-local cwd changes, automatic picker reopen, simultaneous watcher refreshes for two repositories, and index/worktree preservation when a global hunk mapping runs in either native staged-diff pane.

**Not run:**

- Interactive visual review — this environment runs headless Neovim; executable picker, Spotlight, and diff behavior was exercised through integration tests.
