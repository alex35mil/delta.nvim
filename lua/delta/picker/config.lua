--- Default configuration for delta.picker.

local Actions = require("delta.picker.actions")

--- Context passed to picker action handlers.
---@class delta.picker.OpenOpts
---@field cmd? "edit"|"vsplit"|"split"
---@field spotlight? boolean

---@class delta.picker.ActionContext
---@field node delta.Node|nil Current node under cursor
---@field move fun(step: number) Move cursor by step lines
---@field move_to_top fun() Move cursor to first node
---@field move_to_bottom fun() Move cursor to last node
---@field expand fun() Expand directory under cursor
---@field collapse fun() Collapse directory under cursor
---@field cycle_source fun() Cycle to the next source
---@field cycle_source_back fun() Cycle to the previous source
---@field toggle_stage fun(cb?: fun()): boolean Toggle staged/unstaged for current file (refreshes view)
---@field reset_file fun(cb?: fun()): boolean Reset current file/directory to its section baseline
---@field toggle_preview fun() Toggle the preview pane
---@field scroll_preview fun(step: number) Scroll the preview by step lines
---@field open fun(opts?: delta.picker.OpenOpts): boolean Close picker and open current file (no-op on dirs/nil)
---@field close fun() Close the picker

--- A picker action handler.
---@alias delta.picker.ActionHandler fun(ctx: delta.picker.ActionContext)

--- A picker action entry: { keyspec, handler }.
--- Set to false to disable a default action.
---@alias delta.picker.ActionEntry { [1]: delta.KeySpecs, [2]: delta.picker.ActionHandler }|false

--- A registered source in config. "git" is reserved (no files).
---@class delta.SourceConfig
---@field label string Display name in picker header
---@field files? fun(): string[] File provider (required for non-git sources)

--- An inline source passed to show().
---@class delta.SourceDef
---@field label string Display name in picker header
---@field files string[]|fun(): string[] File paths or provider (required)

--- Options passed to show() / toggle().
---@class delta.ShowOpts
---@field source? string|delta.SourceDef Source name (key in config sources) or inline source def
---@field preselect_path? string Preselect this file path in the picker if present

---@class delta.picker.WinIcons
---@field dir_open string
---@field dir_closed string
---@field file string
---@field tree_mid string
---@field tree_last string
---@field tree_vert string
---@field tree_blank string
---@field prompt string

--- A Neovim window title value.
---@alias delta.WinTitle string|{[1]: string, [2]: string}[]

--- Main panel title: static or function receiving source label.
---@alias delta.picker.MainTitle delta.WinTitle|fun(source: string): delta.WinTitle

--- Preview panel title: static or function receiving file path.
---@alias delta.picker.PreviewTitle delta.WinTitle|fun(path: string): delta.WinTitle

---@class delta.picker.MainLayout
---@field width number Width in columns (>=1) or fraction of screen (<1)
---@field title delta.picker.MainTitle
---@field border? string|string[] Border style
---@field icons delta.picker.WinIcons

---@class delta.picker.PreviewLayout
---@field enabled boolean Show preview by default
---@field width number Width in columns (>=1) or fraction of screen (<1)
---@field title? delta.picker.PreviewTitle
---@field border? string|string[] Border style
---@field wo? table<string, any> Window options (e.g. number, signcolumn)

---@class delta.picker.Layout
---@field height number|{ [1]: number, [2]: number } Fixed height, or { min, max } range (lines >=1 or fraction <1)
---@field main delta.picker.MainLayout
---@field preview delta.picker.PreviewLayout

---@alias delta.picker.InitialMode "i"|"n"

---@class delta.PickerConfig
---@field initial_mode delta.picker.InitialMode Initial mode when opening the picker
---@field layout delta.picker.Layout
---@field sources table<string, delta.SourceConfig> Named source definitions ("git" is built-in)
---@field actions table<string, delta.picker.ActionEntry>

---@type delta.PickerConfig
local defaults = {
    initial_mode = "i",
    sources = {
        git = { label = "Git" },
    },
    layout = {
        height = { 0.5, 0.9 },
        main = {
            width = 0.3,
            title = function(source)
                return " 󰇂 Delta" .. " · " .. source .. " "
            end,
            border = "rounded",
            icons = {
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
            enabled = false,
            width = 0.5,
            title = "Preview",
            border = "rounded",
            wo = {
                number = true,
                relativenumber = false,
                signcolumn = "yes",
                cursorline = false,
            },
        },
    },
    actions = {
        open = { "<CR>", Actions.open },
        toggle_preview = { "<C-p>", Actions.toggle_preview },
        cycle_source = { "<Tab>", Actions.cycle_source },
        cycle_source_back = { "<S-Tab>", Actions.cycle_source_back },
        close = { { "<Esc>", modes = "n" }, Actions.close },
    },
}

return defaults
