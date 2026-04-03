--- Configuration for delta.nvim.
--- Merges picker and spotlight defaults.

---@class delta.GitStatusIcons
---@field modified string
---@field added string
---@field deleted string
---@field renamed string
---@field copied string
---@field unmerged string
---@field untracked string
---@field ignored string

---@class delta.GitConfig
---@field status delta.GitStatusIcons

---@class delta.ResetConfig
---@field confirm boolean

---@class delta.Options
---@field git delta.GitConfig
---@field reset delta.ResetConfig
---@field picker delta.PickerConfig
---@field spotlight delta.SpotlightConfig

---@class delta.ConfigModule
---@field options delta.Options
local M = {}

---@type delta.Options
local defaults = {
    git = {
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
        confirm = true,
    },
    picker = require("delta.picker.config"),
    spotlight = require("delta.spotlight.config"),
}

---@type delta.Options
M.options = vim.tbl_deep_extend("force", {}, defaults)

--- Atomic override for action entries (prevent index-level deep merge).
---@param merged table<string, any>
---@param user table<string, any>
local function override_actions(merged, user)
    for name, entry in pairs(user) do
        merged[name] = entry
    end
end

---@param opts? delta.Options
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", {}, defaults, opts or {})
    if opts then
        if opts.picker and opts.picker.actions then
            override_actions(M.options.picker.actions, opts.picker.actions)
        end
        if opts.spotlight and opts.spotlight.actions then
            override_actions(M.options.spotlight.actions, opts.spotlight.actions)
        end
    end
end

return M
