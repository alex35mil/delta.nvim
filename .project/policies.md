# Project Policies

## Labels

When choosing labels for new or existing work:

- **Area** (one or more): apply every area the work affects, not only the primary one.
- **Area: Config & API** is added alongside the feature area whenever the work adds, changes, or removes a setup option, public Lua API, command, or keymap.
- **Area: Git** is added only when the git layer itself changes (repository selection, status parsing, staging/reset patch logic), not merely because a feature triggers git operations.
- **Popups and diffs:** the hunk diff popup and side-by-side file diff belong to `Area: Diff`, even when opened from Spotlight or the picker.
- **Area: Docs** is for work whose main deliverable is user documentation; README/CHANGELOG updates that accompany a code change don't add it. Docs-only work also carries the areas it documents.
- **Tests:** tests added with a change belong to that change's areas; test infrastructure (`tests/run.lua`, helpers, `Makefile`) belongs to `Area: Tooling`.
- **Breaking** is applied to every Deliverable that breaks public config, API, commands, keymaps, or action names; it requires a `!` commit and a `**BREAKING:**` CHANGELOG entry. Internal moves are not breaking.
