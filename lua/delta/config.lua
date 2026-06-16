--- Configuration for delta.nvim.
--- Merges diff, picker, and spotlight defaults.

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
---@field diff delta.DiffConfig
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
    diff = require("delta.diff.config"),
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
local function validate_migrations(opts)
    if not opts then
        return
    end
    if opts.spotlight and opts.spotlight.diff ~= nil then
        error("delta.nvim: spotlight.diff moved to diff.hunk", 3)
    end
    if opts.diff and opts.diff.keys ~= nil then
        error("delta.nvim: diff.keys moved to diff.file.keys", 3)
    end
    if opts.spotlight and opts.spotlight.actions and opts.spotlight.actions.open_diff ~= nil then
        error("delta.nvim: spotlight.actions.open_diff moved to diff.actions.open_hunk_diff", 3)
    end
end

---@param opts? delta.Options
function M.setup(opts)
    validate_migrations(opts)

    M.options = vim.tbl_deep_extend("force", {}, defaults, opts or {})
    if opts then
        if opts.diff and opts.diff.actions then
            override_actions(M.options.diff.actions, opts.diff.actions)
        end
        if opts.picker and opts.picker.actions then
            override_actions(M.options.picker.actions, opts.picker.actions)
        end
        if opts.spotlight and opts.spotlight.actions then
            override_actions(M.options.spotlight.actions, opts.spotlight.actions)
        end
    end
end

return M
