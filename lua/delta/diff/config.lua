--- Default configuration for delta.diff.

---@alias delta.diff.HunkMode "auto"|"inline"|"side-by-side"

---@class delta.diff.HunkKeysConfig
---@field scroll_up? delta.KeySpecs
---@field scroll_down? delta.KeySpecs
---@field focus_left? delta.KeySpecs
---@field focus_right? delta.KeySpecs
---@field close? delta.KeySpecs

---@class delta.diff.HunkLayoutConfig
---@field border string
---@field max_width? integer
---@field max_height? integer
---@field zindex integer
---@field focusable boolean
---@field follow_scroll boolean
---@field min_side_by_side_width integer
---@field scroll_step integer

---@class delta.diff.HunkConfig
---@field mode delta.diff.HunkMode
---@field layout delta.diff.HunkLayoutConfig
---@field keys delta.diff.HunkKeysConfig

---@alias delta.diff.FileMode "auto"|"unstaged"|"staged"

---@class delta.diff.FileKeysConfig
---@field close? delta.KeySpecs
---@field toggle_stage_file? delta.KeySpecs
---@field toggle_stage_file_and_close? delta.KeySpecs
---@field reset_file? delta.KeySpecs
---@field reset_file_and_close? delta.KeySpecs
---@field expand_context? delta.KeySpecs
---@field shrink_context? delta.KeySpecs

---@class delta.diff.FileContextConfig
---@field base? number Initial diff context lines; nil uses current 'diffopt'
---@field step number Lines added/removed per expand/shrink

---@class delta.diff.FileConfig
---@field keys delta.diff.FileKeysConfig
---@field context delta.diff.FileContextConfig
---@field keymap_hints? "dialog"|"winbar"|boolean

--- Context passed to diff action handlers.
---@class delta.diff.ActionContext
---@field buf delta.BufId Current buffer
---@field win delta.WinId Current window
---@field path string Current buffer path
---@field open_hunk_diff fun() Open hunk diff popup
---@field open_file_diff fun() Open side-by-side file diff tab

--- A diff action handler.
---@alias delta.diff.ActionHandler fun(ctx: delta.diff.ActionContext)

--- A diff action entry: { keyspec, handler }.
--- Set to false to disable an action.
---@alias delta.diff.ActionEntry { [1]: delta.KeySpecs, [2]: delta.diff.ActionHandler }|false

---@class delta.DiffConfig
---@field actions table<string, delta.diff.ActionEntry>
---@field hunk delta.diff.HunkConfig
---@field file delta.diff.FileConfig

---@type delta.DiffConfig
return {
    file = {
        context = {
            base = nil,
            step = 5,
        },
        keymap_hints = "dialog",
        keys = {
            expand_context = "+",
            shrink_context = "-",
            toggle_stage_file = nil,
            toggle_stage_file_and_close = nil,
            reset_file = nil,
            reset_file_and_close = nil,
            close = nil,
        },
    },
    hunk = {
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
    actions = {},
}
