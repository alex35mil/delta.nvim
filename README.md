# delta.nvim

Git-focused review tool for Neovim.

> [!NOTE]
> I created this tool while rebuilding my config around an agentic workflow, so I could focus on changes and have a [`pi.nvim`](https://github.com/alex35mil/pi.nvim) agent hanging around on a single screen.

`delta.nvim` has two core pieces.

<p align="center">
  <h2 align="center">Picker</h2>
</p>

<p align="center">
  <img width="462" height="500" alt="Delta Picker" src="https://github.com/user-attachments/assets/3c0bc900-6f84-4e18-b527-a855d1b15a04" />
</p>

<p align="center">
  A floating changed-files picker with tree view, filtering, preview, stage/unstage/reset actions and more.
</p>

<p align="center">
  <h2 align="center">Spotlight</h2>
</p>

<p align="center">
  <img width="2560" height="1440" alt="Delta Spotlight" src="https://github.com/user-attachments/assets/c676d17a-b602-44cc-82e1-cb6ac93eb48d" />
</p>

<p align="center">
  A view that folds away unchanged lines and lets you see diff and stage/unstage/reset at file or hunk level.
</p>

## Requirements

- Neovim 0.10+
- `git` in `$PATH`

Run `:checkhealth delta` to verify.

## Installation

### vim.pack

```lua
vim.pack.add({ "https://github.com/alex35mil/delta.nvim" })

-- if you're fine with defaults:
require("delta").setup()

-- or, if you want to customize:
require("delta").setup({
    picker = { ... },
    spotlight = { ... },
})
```

### lazy.nvim

```lua
{
    "alex35mil/delta.nvim",

    -- if you're fine with defaults:
    config = true,

    -- or, if you want to customize:
    opts = {
        picker = { ... },
        spotlight = { ... },
    },
}
```

## Quick start

Use:

- `:DeltaPicker` to toggle the changed-files picker
- `:DeltaSpotlight` to toggle spotlight for the current buffer

## Configuration

Top-level configuration is split into `git`, `reset`, `picker`, and `spotlight` sections.

All options are optional. These are the defaults:

```lua
local delta = require("delta")
local picker = delta.picker
local spotlight = delta.spotlight

---@type delta.Options
delta.setup({
    git = {
        -- Icons used for git status indicators in picker/spotlight UI.
        status = {
            modified = "󰬔",
            added = "󰬈",
            deleted = "󰬋",
            renamed = "󰬙",
            copied = "󰬊",
            unmerged = "󰬟",
            untracked = "󰬜",
            ignored = "󰬐",
        },
    },

    reset = {
        -- Ask for confirmation before file reset operations.
        confirm = true,
    },

    picker = {
        -- Start in insert mode for immediate filtering, or "n" for normal mode.
        initial_mode = "i",
        sources = {
            -- Built-in source; add more named sources alongside it.
            git = { label = "Git" },
            -- Primary use-case for additional sources is providing a set of files changed by an agent.
            -- agent = { label = "Agent", files = require("pi").changed_files },
        },
        layout = {
            -- Picker height: number for fixed height, or { min, max } range.
            -- Values < 1 are screen fractions; values >= 1 are line counts.
            height = { 0.5, 0.9 },
            main = {
                -- Main picker width: fraction (<1) or columns (>=1).
                width = 0.3,
                border = "rounded",
                -- Static title or function(source) -> title.
                title = function(source)
                    return " 󰇂 Delta" .. " · " .. source .. " "
                end,
                icons = {
                    -- UI glyphs used by the tree and prompt.
                    prompt = " 󰍉 ",
                    dir_open = "󰝰 ",
                    dir_closed = "󰉋 ",
                    file = "󰈔 ",
                    tree_mid = "├╴",
                    tree_last = "└╴",
                    tree_vert = "│  ",
                    tree_blank = "   ",
                },
            },
            preview = {
                -- Open preview pane together with the picker by default.
                enabled = false,
                -- Preview width: fraction (<1) or columns (>=1).
                width = 0.5,
                -- Static title or function(path) -> title.
                title = "Preview",
                border = "rounded",
                -- Window-local options applied to the preview window.
                wo = {
                    number = true,
                    relativenumber = false,
                    signcolumn = "yes",
                    cursorline = false,
                },
            },
        },
        -- These are the default picker actions.
        -- See Picker Actions section below for more options.
        actions = {
            -- Keymaps are { lhs, handler } pairs.
            -- If no modes are provided, `n` + `i` is the default.
            -- Set an entry to false to disable it.
            -- See Keymaps section below for more details.
            open = { "<CR>", picker.actions.open },
            spotlight = { "<M-CR>", picker.actions.spotlight },
            move_up = { { { "k", modes = "n" }, "<Up>" }, picker.actions.move(-1) },
            move_down = { { { "j", modes = "n" }, "<Down>" }, picker.actions.move(1) },
            toggle_preview = { "<C-p>", picker.actions.toggle_preview },
            cycle_source = { "<Tab>", picker.actions.cycle_source },
            cycle_source_back = { "<S-Tab>", picker.actions.cycle_source_back },
            close = { { "<Esc>", modes = "n" }, picker.actions.close },
        },
    },

    spotlight = {
        -- Winbar title shown while spotlight is active.
        title = "󱦇 󰬀󰫽󰫼󰬁󰫹󰫶󰫴󰫵󰬁",
        -- Visible context around git hunks.
        context = {
            -- Initial visible context around each hunk.
            base = 6, -- defaults to current 'diffopt' context, or 6 if unset
            -- Default number of lines added/removed by expand/shrink actions.
            step = 5,
        },
        status = {
            -- Winbar labels/icons for each resolved file status.
            staged = { icon = "󰕥", label = "staged" },
            unstaged = { icon = "󰒙", label = "unstaged" },
            mixed = { icon = "", label = "mixed" },
            untracked = { icon = "󰫛", label = "untracked" },
            clean = { icon = "", label = "clean" },
            conflict = { icon = "󰻌", label = "conflict" },
            error = { icon = "", label = "error" },
            outsider = { icon = "", label = "outsider" },
            no_repo = { icon = "", label = "no repo" },
            -- Extra marker for scratch/read-only spotlight views.
            non_editable = { icon = "󱀰", label = "" },
        },
        -- Save modified buffers automatically before hunk stage/unstage/reset.
        autosave_before_stage = false,
        -- After fully staging a file, optionally reopen picker on next unstaged file.
        reopen_picker_after_stage = false,
        -- These are the default spotlight actions.
        -- See Spotlight Actions section below for more options.
        actions = {
            -- Keymaps are { lhs, handler } pairs.
            -- If no modes are provided, `n` is the default.
            -- Set an entry to false to disable it.
            -- See Keymaps section below for more details.
            expand_context = { "+", spotlight.actions.expand_context },
            shrink_context = { "-", spotlight.actions.shrink_context },
            cycle_mode = { "m", spotlight.actions.cycle_mode },
            exit = { "q", spotlight.actions.exit },
        },
        -- Popup diffs.
        diff = {
            -- Popup diff rendering mode: "auto"|"inline"|"side-by-side"
            -- "auto" prefers side-by-side when there is enough editor width and the popup fits,
            -- otherwise it falls back to inline.
            mode = "auto",
            layout = {
                border = "rounded",
                -- Max popup size; nil means computed automatically.
                max_width = nil,
                max_height = nil,
                zindex = 50,
                -- Whether popup windows can receive focus.
                focusable = true,
                -- Keep popup anchored to hunk while scrolling.
                follow_scroll = true,
                -- Minimum editor width before side-by-side mode is allowed.
                min_side_by_side_width = 120,
                -- Scroll amount used by popup scroll keymaps.
                scroll_step = 4,
            },
            keys = {
                -- Optional popup-local keymaps; nil leaves them unset.
                -- If no modes are provided, `n` + `v` is the default.
                -- You can set multiple keymaps for the same actions. See Keymaps section below.
                scroll_up = nil,
                scroll_down = nil,
                focus_left = "<Tab>",
                focus_right = "<Tab>",
                close = "<Esc>",
            },
        },
    },
})
```

## Keymaps and actions

### Defaults
`delta.nvim` intentionally ships with a very small default keymap set. Keymaps tend to be highly personal, and many users already have their own conventions, leader-based layouts, or other mapping systems. Delta tries to provide the actions and a few sensible defaults, while leaving the final keymap design to you.

### Structure of keymaps actions
Both `picker.actions` and `spotlight.actions` are configured as named entries of the form:

```lua
name = { lhs, handler }
```

Where:

- `name` is just your config key; it does not need to match a built-in action name and can be anything
- `lhs` is a key or key spec
- `handler` is usually one of the functions from `require("delta").picker.actions` or `require("delta").spotlight.actions`

Basic example:

```lua
close = { "<Esc>", picker.actions.close }
```

You can use a key spec with modes:

```lua
close = { { "<C-q>", modes = { "n", "i" } }, picker.actions.close }
```

You can define multiple keys for the same action:

```lua
close = {
    {
        "<Esc>",
        { "<C-q>", modes = { "n", "i" } },
    },
    picker.actions.close,
}
```

### Custom actions

An action is just a `fun(ctx)` that receives an action context (`delta.picker.ActionContext` or `delta.spotlight.ActionContext`). The built-ins in `require("delta").picker.actions` and `require("delta").spotlight.actions` are composable: you can wrap any of them in your own function to add pre- or post-hooks, and still bind it like a normal action.

```lua
local actions = require("delta").picker.actions

local function open_with_hook(action)
    ---@param ctx delta.picker.ActionContext
    return function(ctx)
        -- pre-hook
        action(ctx)
        -- post-hook
    end
end

require("delta").setup({
    picker = {
        actions = {
            open        = { "<CR>",  open_with_hook(actions.open) },
            open_vsplit = { "<C-v>", open_with_hook(actions.open_vsplit) },
        },
    },
})
```

## Picker

<img width="462" height="500" alt="Delta Picker" src="https://github.com/user-attachments/assets/3c0bc900-6f84-4e18-b527-a855d1b15a04" />


The picker shows git-changed files in a tree, split into unstaged and staged sections. You can filter by typing, open files, switch sources, preview files, stage/unstage/reset files or directories.

The picker prompt buffer uses the `delta-input` filetype. You can target it from your own config however you need.

### Default picker keys

| Key | Action |
| --- | --- |
| `k` / `<Up>` | Move selection up |
| `j` / `<Down>` | Move selection down |
| `<CR>` | Open file, or expand/collapse directory |
| `<C-p>` | Toggle preview |
| `<Tab>` | Cycle to next source |
| `<S-Tab>` | Cycle to previous source |
| `<Esc>` | Close picker in normal mode |

### Picker actions

Built-in picker actions live in `require("delta").picker.actions`.

Available built-ins:

- `move(step)` — Move the picker selection by `step` entries.
- `move_to_top` — Jump to the first visible entry.
- `move_to_bottom` — Jump to the last visible entry.
- `expand` — Expand the directory under the cursor.
- `collapse` — Collapse the directory under the cursor.
- `open` — Open the selected file, or toggle a directory open/closed.
- `open_vsplit` — Open the selected file in a vertical split.
- `open_hsplit` — Open the selected file in a horizontal split.
- `spotlight` — Open the selected file and enable spotlight for it.
- `toggle_stage` — Stage or unstage the selected entry.
- `toggle_stage_and(cb)` — Run `toggle_stage`, then call `cb()` on success.
- `reset` — Reset the selected entry to its section baseline.
- `reset_and(cb)` — Run `reset`, then call `cb()` on success.
- `cycle_source` — Switch to the next configured picker source.
- `cycle_source_back` — Switch to the previous configured picker source.
- `toggle_preview` — Show or hide the preview pane.
- `scroll_preview(step)` — Scroll the preview pane by `step` lines.
- `close` — Close the picker.

#### Picker action context

Every action receives context object as an argument: 

```lua
---@class delta.picker.OpenOpts
---@field cmd? "edit"|"vsplit"|"split"
---@field spotlight? boolean

---@class delta.picker.ActionContext
---@field node delta.Node|nil Current node under cursor
---@field move fun(step: number)
---@field move_to_top fun()
---@field move_to_bottom fun()
---@field expand fun()
---@field collapse fun()
---@field cycle_source fun()
---@field cycle_source_back fun()
---@field toggle_stage fun(cb?: fun()): boolean
---@field reset fun(cb?: fun()): boolean
---@field toggle_preview fun()
---@field scroll_preview fun(step: number)
---@field open fun(opts?: delta.picker.OpenOpts): boolean
---@field close fun()
```

#### Example: add vim-style movement and reset

```lua
local actions = require("delta").picker.actions

require("delta").setup({
    picker = {
        actions = {
            move_top = { { "gg", modes = "n" }, actions.move_to_top },
            move_bottom = { { "G", modes = "n" }, actions.move_to_bottom },
            stage_toggle = { { "-", modes = "n" }, actions.toggle_stage },
            reset = { { "R", modes = "n" }, actions.reset },
        },
    },
})
```

### Custom sources

By default, the picker uses the built-in `git` source. You can register additional named sources under `picker.sources`.

For non-`git` sources, `files` function should return file paths. Delta intersects that list with git status so entries still keep staged/unstaged classification.

Press `<Tab>` / `<S-Tab>` in the picker to switch sources.

### Register a source

```lua
require("delta").setup({
    picker = {
        sources = {
            git = { label = "Git" },
            agent = {
                label = "Agent",
                files = function()
                    return require("pi").changed_files()
                end,
            },
        },
    },
})
```

Then open it with:

```lua
vim.cmd("DeltaPicker agent")
-- or
require("delta").picker.show({ source = "agent" })
```

### Inline source

```lua
require("delta").picker.show({
    source = {
        label = "Static",
        files = { "lua/foo.lua", "lua/bar.lua" },
    },
})
```

## Spotlight

<img width="2560" height="1440" alt="Delta Spotlight" src="https://github.com/user-attachments/assets/c676d17a-b602-44cc-82e1-cb6ac93eb48d" />


Spotlight focuses the current window on diff hunks by folding away unchanged lines. It supports file-level and hunk-level stage/unstage and reset operations.

If `spotlight.reopen_picker_after_stage = true`, fully staging a file from spotlight can reopen the picker and preselect the next unstaged file. It is disabled by default to follow the principle of least surprise, but enabling it can make review workflows much smoother.

When `spotlight.toggle_stage_hunk` or `spotlight.reset_hunk` runs on a modified buffer, delta needs to save the file first so the operation matches Git's worktree view. By default delta asks for confirmation; set `spotlight.autosave_before_stage = true` to save automatically.

### Default spotlight keys

| Key | Action |
| --- | --- |
| `+` | Expand context |
| `-` | Shrink context |
| `m` | Cycle mode |
| `q` | Exit spotlight |

### Spotlight actions

Built-in spotlight actions live in `require("delta").spotlight.actions`.

Available built-ins:

- `expand_context` — Increase the visible context around hunks.
- `expand_context_by(step)` — Increase the visible context around hunks by `step` lines.
- `shrink_context` — Reduce the visible context around hunks.
- `shrink_context_by(step)` — Reduce the visible context around hunks by `step` lines.
- `next_hunk` — Jump to the next visible hunk.
- `prev_hunk` — Jump to the previous visible hunk.
- `cycle_mode` — Cycle spotlight mode between `auto`, `unstaged`, and `staged`.
- `toggle_stage_file` — Stage or unstage the current file.
- `toggle_stage_file_and(cb)` — Run `toggle_stage_file`, then call `cb()` on success.
- `reset_file` — Reset the current file to the active baseline.
- `reset_file_and(cb)` — Run `reset_file`, then call `cb()` on success.
- `toggle_stage_hunk` — Stage or unstage the hunk under the cursor, or the visual selection.
- `toggle_stage_hunk_and(cb)` — Run `toggle_stage_hunk`, then call `cb()` on success.
- `reset_hunk` — Reset the unstaged hunk under the cursor, or the visual selection.
- `reset_hunk_and(cb)` — Run `reset_hunk`, then call `cb()` on success.
- `open_diff` — Open the diff popup for the hunk under the cursor.
- `exit` — Disable spotlight for the current buffer/window.

#### Global actions

Spotlight action entries also support `global = true`:

```lua
next_hunk = { "<C-Down>", actions.next_hunk, global = true }
prev_hunk = { "<C-Up>", actions.prev_hunk, global = true }
```

By default, spotlight actions are buffer-local and only active for spotlight-enabled buffers. Set `global = true` to make an action always active instead. This is useful for actions like hunk navigation that you may want available regardless of the spotlight status.

#### Spotlight action context

Every action receives context object as an argument:

```lua
---@class delta.spotlight.ActionContext
---@field is_active boolean
---@field buf integer
---@field win integer
---@field path string
---@field requested_mode "auto"|"unstaged"|"staged"|nil
---@field resolved_mode "unstaged"|"staged"|"none"|nil
---@field hunks delta.Hunk[]|nil
---@field visual? { start_line: number, end_line: number }
---@field expand fun(step?: number)
---@field shrink fun(step?: number)
---@field next_hunk fun()
---@field prev_hunk fun()
---@field cycle_mode fun()
---@field toggle_stage_file fun(cb?: fun())
---@field reset_file fun(cb?: fun())
---@field toggle_stage_hunk fun(cb?: fun())
---@field reset_hunk fun(cb?: fun())
---@field exit fun()
```

### Example: add hunk navigation, reset, and diff popup

```lua
local actions = require("delta").spotlight.actions

require("delta").setup({
    spotlight = {
        actions = {
            next_hunk = { { "]h", modes = "n" }, actions.next_hunk, global = true },
            prev_hunk = { { "[h", modes = "n" }, actions.prev_hunk, global = true },
            toggle_stage_file = { { "-", modes = "n" }, actions.toggle_stage_file },
            reset_file = { { "R", modes = "n" }, actions.reset_file },
            toggle_stage_hunk = { { "<CR>", modes = "n" }, actions.toggle_stage_hunk },
            reset_hunk = { { "gR", modes = { "n", "v" } }, actions.reset_hunk },
            open_diff = { { "gd", modes = "n" }, actions.open_diff, global = true },
        },
    },
})
```

### Diff popup

`spotlight.actions.open_diff` opens a popup for the hunk under the cursor so you can inspect the detailed diff.

<img width="1020" height="197" alt="Delta diff popup" src="https://github.com/user-attachments/assets/26768755-e06c-469b-8077-7eb72b0f434d" />


## Tips

### Disable spotlight before saving a session

Spotlight modifies buffer folds and window state that should not be persisted across sessions. If you use a session manager (`resession.nvim`, `persistence.nvim`, plain `:mksession`, ...), disable spotlight on the pre-save hook:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "PersistenceSavePre", -- or your session manager's equivalent
    callback = function()
        require("delta").spotlight.disable_all()
    end,
})
```

### Review workflow

This is already mentioned in the configuration section, but it's worth a dedicated tip. If you use delta primarily to walk through changes file-by-file, the `reopen_picker_after_stage` option turns the picker + spotlight into a focused review loop: open the picker, land on a spotlighted file, stage hunks or the whole file, and the picker automatically reopens with the next unstaged file preselected.

```lua
require("delta").setup({
    spotlight = {
        reopen_picker_after_stage = true,
    },
})
```

## Commands

| Command | Description |
| --- | --- |
| `:DeltaPicker [source]` | Toggle the picker, optionally opening a named source |
| `:DeltaSpotlight [mode]` | Toggle spotlight for the current buffer |
| `:DeltaSpotlightDisableAll` | Disable spotlight in all windows |

Spotlight modes accepted by `:DeltaSpotlight`:

- `auto`
- `unstaged`
- `staged`

## API

Top-level:

```lua
local delta = require("delta")

delta.setup(opts?)

delta.picker
delta.spotlight
```

### Picker API

```lua
local picker = require("delta").picker

picker.show(opts?)
picker.toggle(opts?)
picker.close()
picker.is_open() -- boolean
picker.actions
```

`opts` for `show()` / `toggle()`:

```lua
---@class delta.SourceDef
---@field label string
---@field files string[]|fun(): string[]

---@class delta.ShowOpts
---@field source? string|delta.SourceDef
---@field preselect_path? string
```

### Spotlight API

```lua
local spotlight = require("delta").spotlight

spotlight.ensure(mode?)
spotlight.toggle(mode?)
spotlight.disable(bufid?)
spotlight.disable_all()
spotlight.is_active(winid?) -- boolean
spotlight.actions
```

## Highlight groups

All highlight groups are defined with `default = true`, so they can be overridden by your colorscheme or after setup.

### Shared status groups

| Group | Default link |
| --- | --- |
| `DeltaStatusModified` | `DiffChange` |
| `DeltaStatusAdded` | `DiffAdd` |
| `DeltaStatusDeleted` | `DiffDelete` |
| `DeltaStatusRenamed` | `DiffChange` |
| `DeltaStatusCopied` | `DiffChange` |
| `DeltaStatusUntracked` | `Comment` |
| `DeltaStatusUnmerged` | `DiagnosticWarn` |

### Picker

| Group | Default |
| --- | --- |
| `DeltaPickerDialog` | `Normal` |
| `DeltaPickerTitle` | `Normal` |
| `DeltaPickerBorder` | `Comment` |
| `DeltaPickerPrompt` | `Normal` |
| `DeltaPickerFile` | foreground from `Normal` |
| `DeltaPickerDirectory` | foreground from `Directory` |
| `DeltaPickerSectionHeader` | `Title` |
| `DeltaPickerCursorLine` | `Visual` |
| `DeltaPickerActiveBranch` | foreground from `Normal` |
| `DeltaPickerInactiveBranch` | `Comment` |
| `DeltaPickerTreeConnector` | `NonText` |
| `DeltaPickerEmpty` | `NonText` |

### Spotlight

| Group | Default link |
| --- | --- |
| `DeltaSpotlightWinbar` | `WinBar` |
| `DeltaSpotlightWinbarTitle` | `WinBar` |
| `DeltaSpotlightWinbarLabel` | `Comment` |
| `DeltaSpotlightWinbarNumericValue` | `Number` |
| `DeltaSpotlightStatusStaged` | `DiffAdd` |
| `DeltaSpotlightStatusUnstaged` | `DiffChange` |
| `DeltaSpotlightStatusMixed` | `DiagnosticWarn` |
| `DeltaSpotlightStatusConflict` | `DiagnosticError` |
| `DeltaSpotlightStatusUntracked` | `Comment` |
| `DeltaSpotlightStatusClean` | `Comment` |
| `DeltaSpotlightStatusOutsider` | `DiagnosticWarn` |
| `DeltaSpotlightStatusNoRepo` | `Comment` |
| `DeltaSpotlightStatusError` | `DiagnosticError` |
| `DeltaSpotlightScratchDiffAdd` | `DiffAdd` |
| `DeltaSpotlightScratchDiffChange` | `DiffChange` |
| `DeltaSpotlightScratchDiffDelete` | `DiffDelete` |
| `DeltaSpotlightPopup` | `NormalFloat` |
| `DeltaSpotlightPopupBorder` | `FloatBorder` |
| `DeltaSpotlightPopupTitle` | `Title` |
| `DeltaSpotlightPopupAdded` | background from `DiffAdd` when available, else `DiffAdd` |
| `DeltaSpotlightPopupRemoved` | background from `DiffDelete` when available, else `DiffDelete` |
| `DeltaSpotlightPopupAddedText` | `DiffText` |
| `DeltaSpotlightPopupRemovedText` | `DiffText` |
| `DeltaSpotlightPopupNeutral` | `DeltaSpotlightPopup` |
| `DeltaSpotlightPopupLineNr` | `Comment` |
