# Plan

## Overview

Make review and Git actions follow the repository owning the selected file rather than Neovim's working directory. A user editing a nested-repository file can open its changed-files picker, inspect diffs, and stage or reset changes while keeping cwd at the parent checkout. Files and actions from different repositories remain separate even when their relative names match.

### Plan highlights

- Select one repository from the invoking file; use cwd when the buffer cannot identify a repository. Each picker lists only that repository's changes.
- Capture repository and file identity once for a picker or file-diff session and use it for every subsequent read, refresh, action, and automatic picker reopen.
- Give shared Git operations explicit repository/file context. Use absolute paths for filesystem identity and repository-relative paths for Git arguments and display.
- Preserve existing public commands, configuration, keymaps, and ordinary string path inputs. Document repository selection and path interpretation.
- Verify parent/nested isolation, cwd changes, scratch views, submodules, linked worktrees, and existing picker, diff, and hunk behavior in headless Neovim.

## Behavior and selection rules

Repository selection happens before listing or reading Git data. Use Git's repository discovery from the target file's containing directory, walking to an existing ancestor when a deleted file's directory no longer exists. Resolve both the worktree root and absolute Git directory through Git, supporting `.git` directories and `.git` files without interpreting them manually.

| Entry point or condition | Behavior |
| --- | --- |
| Picker invoked from a normal parent-repository file | List changes from the parent repository. |
| Picker invoked from a normal nested-repository file | List changes from that nested repository, including an ignored nested repository, regardless of cwd. |
| Picker invoked from a Delta-owned staged, deleted, or side-by-side diff buffer | Select the repository of its underlying file. |
| Picker invoked from an unnamed/non-file buffer, or a file outside every repository | Resolve the repository containing invocation cwd. |
| File diff or Spotlight on a normal file with an owning repository | Read and mutate that file in its nearest owning repository. |
| Explicit `diff.open_file({ path = ... })` | Use the explicit target file's repository. Interpret a relative target against invocation cwd, as before. |
| File without an owning repository | Retain the existing no-repository/outsider notifications and Spotlight presentation; do not read or mutate that file through an unrelated repository. |
| Picker has no repository from either the invoking buffer or cwd | Report the missing repository using existing notification behavior and finish without leaving picker windows open. |
| Git discovery fails for a reason other than absence of a repository | Surface the actual failure; do not substitute another repository. |
| cwd or focused window changes after a view opens | Keep that view and its actions attached to the captured repository and file. |
| Fully staging a file triggers automatic picker reopen | Reopen for the staged file's repository and select the next unstaged file there. |

A parent picker retains Git's normal parent-repository entries, including submodule entries. Selecting a file inside the child repository opens a child-repository review session. This feature does not add submodule management or expand child changes into a parent picker.

## Shared repository and file model

Implement the owning contract in `lua/delta/git.lua`, with shared type declarations in `lua/delta/types.lua` and a small dedicated repository/path module only where separating discovery and identity materially improves cohesion.

- A repository reference contains the absolute worktree root and Git directory.
- A repository-file reference contains its repository, repository-relative Git path, and normalized absolute filesystem path. Missing/deleted worktree files remain valid file references.
- All effectful Git entry points require an explicit repository or repository-file reference. Repository listing uses a repository reference; status, content, staging, reset, and file/hunk patch construction use file references; patch application also receives its repository explicitly.
- The shared command runner sets process cwd to the captured repository root for every command. Discovery commands use their explicit discovery directory. Filesystem reads, existence checks, snapshots, buffer opening, and reset undo destinations use the absolute file path.
- Keep porcelain output and patch headers repository-relative, including `show HEAD:path` and index lookups. Preserve rename handling and existing staged/unstaged behavior.
- Keep pure status, parsing, hunk-selection, line-mapping, and patch-building helpers independent of cwd and repository discovery.
- Replace internal implicit-cwd Git call sites and their direct tests coherently. Do not retain compatibility overloads that silently rediscover a repository or fall back to current cwd.

Resolve entry-point paths before asynchronous work can yield. Subsequent operations use the captured references, not the current buffer, cwd, or focused window. Discovery is not repeated for every Git command; no recursive filesystem scan, global root override, or permanent root cache is needed.

## Consumer changes

### Picker and tree

Update `lua/delta/picker/ui.lua`, `tree.lua`, `preview.lua`, and affected type annotations.

- Loading state captures the invocation buffer and cwd; resolve its repository before fetching changed files. Preserve existing loading/close cancellation and retained-action-context lifecycle guards.
- Keep each entry's repository-file reference through tree construction and action contexts. Tree paths, filters, collapse state, and section matching stay repository-relative within the picker instance.
- Preview and opening resolve actual buffers/files by absolute identity while keeping repository-relative titles and labels.
- Stage, unstage, directory actions, reset, and unsaved-buffer checks use entry identities and the picker's stored repository.
- Normalize absolute source-provider paths and absolute `preselect_path` values against the selected repository. Relative source/preselection values retain repository-relative matching against Git-status entries. Files outside that repository do not enter its result set.
- Keep the selected repository through source cycling, refreshes, and reopen-after-stage. Source selection memory must not cause repository identity to leak between independent picker invocations.

### Spotlight and scratch buffers

Update `lua/delta/spotlight/core.lua`, `paths.lua`, and related mode/winbar consumers.

- Key file caches, path locks, render callbacks, source-buffer lookups, picker handoff state, and unsaved-buffer protection by normalized absolute file identity.
- Managed file state stores the repository-file reference. Fetch status, HEAD/index/worktree contents, raw hunks, and mutation context through that reference.
- Keep repository-relative display paths separate from stable internal identity; public action-context path strings identify the managed file within its owning repository.
- Staged and deleted scratch buffers preserve the underlying file reference in buffer metadata and collision-free names. They remain associated with the same file across cwd changes and staged/deleted transitions.
- Continue watching actual Git directories with the existing watcher lifecycle. Refresh each managed file through its stored context, including when visible windows show different repositories; do not derive the refresh repository from whichever window is focused.
- Keep autosave prompts, partial-hunk math, deleted anchors, folds, and reset safety behavior unchanged.

### File and hunk diffs

Update `lua/delta/diff/file.lua`, `hunk.lua`, `init.lua`, and affected action-context annotations.

- File-diff state retains the repository-file reference across tab creation, refresh, stage/unstage, reset, closing, and automatic picker reopen.
- Diff scratch buffers carry their underlying file identity for subsequent picker and diff actions. Source-buffer comparisons and unsaved-file checks use absolute identity, not cwd-relative names.
- Preserve existing mode selection, native diff behavior, source-buffer freshness checks, cursor synchronization, and popup rendering.
- Hunk actions apply patches in the owning repository with repository-relative headers. Shared pure hunk algorithms do not change.

## Implementation sequence and documentation

1. Add explicit repository/file discovery and identity, migrate shared Git operations, and add owning-boundary tests.
2. Migrate Spotlight file state, paths, scratch metadata, Git calls, and refreshes to explicit file context.
3. Migrate picker listing/tree entries, source filtering, previews, actions, handoff, and reopen behavior.
4. Migrate file/hunk diff state and remaining shared consumers. Update affected direct Git tests and helpers for the explicit internal contract.
5. Update `README.md` with current-file-first repository selection, cwd fallback, pinned view behavior, nested repository/submodule/worktree examples, and relative/absolute source, preselection, and explicit diff target semantics. Keep public command/config/keymap names unchanged.
6. Complete regression coverage and run the full suite before final review.

## Verification

The cause was reproduced before product changes using a temporary parent repository with an ignored nested repository. The nested tracked file had an actual worktree change, while current Delta reported a clean status, zero raw hunks, and no picker entries from parent cwd. Existing picker lifecycle tests passed 14 cases; side-by-side file-diff tests passed 31 cases.

Add owning-boundary and integration tests that establish:

- Current-file-first discovery selects parent or child correctly with cwd fixed at the parent, and unnamed/non-file buffers use invocation cwd. A missing repository and real Git errors retain deliberate, visible handling.
- Independent nested repositories, ignored nested repositories, actual submodules, and a linked Git worktree discover the correct root and Git directory. Deleted files with removed parent directories still resolve through the existing repository ancestor.
- Status, HEAD/index/worktree reads, whole-file stage/unstage/reset, and partial hunk staging/unstaging/reset operate only on the selected repository. Parent HEAD/index/worktree data are unchanged by child actions.
- Same relative file names in two repositories remain isolated in buffers, caches, locks, scratch names, diff tabs, previews, and unsaved-buffer checks.
- A view opened before `:cd`/window-local cwd changes keeps its original repository for actions and refreshes. Two visible Spotlight windows from different repositories refresh using their own Git directories.
- Staged-only, mixed staged/unstaged, and deleted-file scratch views preserve repository identity. A picker opened from each Delta-owned view selects its owning repository.
- Picker preview, normal/split opening, file/directory stage/reset, source cycling/filtering, explicit preselection, and automatic reopen-after-stage preserve selection and file identity.
- Existing public string inputs, action names, loading cancellation, partial hunk behavior, and native diff lifecycle remain covered without weakening assertions to accommodate the change.

Run targeted new tests with `make test-file FILE=...` while developing, rerun affected existing picker/diff/hunk tests, then run `make test` because this changes shared Git behavior. Use temporary repositories and inspect their real Git indexes and worktrees, not only mocked call arguments. Include explicit cwd-unchanged assertions.

Headless Neovim verifies executable behavior. Interactive visual appearance is not verified in this environment and will be stated as a final verification limitation.
