--- Default configuration for delta.spotlight.

local Actions = require("delta.spotlight.actions")

---@return integer
local function default_diff_context()
    local default = 6
    for item in string.gmatch(vim.o.diffopt or "", "[^,]+") do
        local value = item:match("^context:(%d+)$")
        if value then
            return tonumber(value) or default
        end
    end
    return default
end

--- Context passed to spotlight action handlers.
---@class delta.spotlight.ActionContext
---@field is_active boolean Whether spotlight is active on the current buffer
---@field buf delta.BufId Current buffer
---@field win delta.WinId Current window
---@field path string Relative file path
---@field requested_mode delta.spotlight.RequestedMode Current requested diff mode (only when active)
---@field resolved_mode delta.spotlight.ResolvedMode Current resolved diff mode (only when active)
---@field hunks delta.Hunk[] Current hunks (only when active)
---@field visual? { start_line: number, end_line: number } Visual selection range (nil in normal mode)
---@field expand fun(step?: number) Expand context lines
---@field shrink fun(step?: number) Shrink context lines
---@field next_hunk fun() Jump to next hunk
---@field prev_hunk fun() Jump to previous hunk
---@field cycle_mode fun() Cycle diff mode
---@field toggle_stage fun(cb?: fun()) Toggle staged/unstaged for current file
---@field reset_file fun(cb?: fun()) Reset current file to the active baseline
---@field toggle_stage_hunk fun(cb?: fun()) Stage/unstage hunk under cursor (or visual selection)
---@field reset_hunk fun(cb?: fun()) Reset unstaged hunk under cursor (or visual selection)
---@field exit fun() Disable spotlight

--- A spotlight action handler.
---@alias delta.spotlight.ActionHandler fun(ctx: delta.spotlight.ActionContext)

--- A spotlight action entry: { keyspec, handler, global? }.
--- Buffer-local by default. Set global = true for always-active keymaps.
--- Set to false to disable a default action.
---@alias delta.spotlight.ActionEntry { [1]: delta.KeySpecs, [2]: delta.spotlight.ActionHandler, global?: boolean }|false

---@class delta.spotlight.ContextConfig
---@field base number Initial context lines around each hunk
---@field step number Lines added/removed per expand/shrink

---@class delta.spotlight.StatusEntry
---@field icon? string
---@field label? string

---@alias delta.spotlight.StatusKey "staged"|"unstaged"|"mixed"|"conflict"|"untracked"|"clean"|"error"|"outsider"|"no_repo"|"non_editable"

---@alias delta.spotlight.StatusConfig table<delta.spotlight.StatusKey, delta.spotlight.StatusEntry>

---@alias delta.spotlight.DiffMode "auto"|"inline"|"side-by-side"

---@class delta.spotlight.DiffKeysConfig
---@field scroll_up? delta.KeySpecs
---@field scroll_down? delta.KeySpecs
---@field focus_left? delta.KeySpecs
---@field focus_right? delta.KeySpecs
---@field close? delta.KeySpecs

---@class delta.spotlight.DiffLayoutConfig
---@field border string
---@field max_width? integer
---@field max_height? integer
---@field zindex integer
---@field focusable boolean
---@field follow_scroll boolean
---@field min_side_by_side_width integer
---@field scroll_step integer

---@class delta.spotlight.DiffConfig
---@field mode delta.spotlight.DiffMode
---@field layout delta.spotlight.DiffLayoutConfig
---@field keys delta.spotlight.DiffKeysConfig

---@class delta.SpotlightConfig
---@field context delta.spotlight.ContextConfig
---@field title string Winbar title
---@field status delta.spotlight.StatusConfig Status display for winbar
---@field autosave_before_stage boolean Save modified buffers automatically before hunk stage/unstage
---@field reopen_picker_after_stage boolean Reopen picker on next unstaged file after staging a file completely
---@field actions table<string, delta.spotlight.ActionEntry>
---@field diff delta.spotlight.DiffConfig

---@type delta.SpotlightConfig
local defaults = {
    title = "󱦇 󰬀󰫽󰫼󰬁󰫹󰫶󰫴󰫵󰬁",
    context = {
        base = default_diff_context(),
        step = 5,
    },
    status = {
        staged = { icon = "󰕥", label = "staged" },
        unstaged = { icon = "󰒙", label = "unstaged" },
        mixed = { icon = "", label = "mixed" },
        untracked = { icon = "󰫛", label = "untracked" },
        clean = { icon = "", label = "clean" },
        conflict = { icon = "󰻌", label = "conflict" },
        error = { icon = "", label = "error" },
        outsider = { icon = "", label = "outsider" },
        no_repo = { icon = "", label = "no repo" },
        non_editable = { icon = "󱀰", label = "" },
    },
    autosave_before_stage = false,
    reopen_picker_after_stage = false,
    actions = {
        expand_context = { "+", Actions.expand_context },
        shrink_context = { "-", Actions.shrink_context },
        cycle_mode = { "m", Actions.cycle_mode },
        exit = { "q", Actions.exit },
    },
    diff = {
        mode = "auto",
        layout = {
            border = "rounded",
            max_width = nil,
            max_height = nil,
            zindex = 50,
            focusable = true,
            follow_scroll = true,
            min_side_by_side_width = 120,
            scroll_step = 4,
        },
        keys = {
            scroll_up = nil,
            scroll_down = nil,
            focus_left = "<Tab>",
            focus_right = "<Tab>",
            close = "<Esc>",
        },
    },
}

return defaults
