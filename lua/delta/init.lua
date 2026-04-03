--- delta.nvim public API.
--- Changed-files picker + diff spotlight.

---@class Delta
local M = {}

local Config = require("delta.config")
local Notify = require("delta.notify")

local is_initialized = false

local function setup_highlight_autocmds()
    local group = vim.api.nvim_create_augroup("DeltaHighlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
            require("delta.status").setup()
            require("delta.picker").setup()
            require("delta.spotlight").setup()
        end,
    })
end

--- Set up delta.nvim. Must be called before use.
---@param opts? delta.Options
function M.setup(opts)
    if is_initialized then
        Notify.warn("setup() called more than once, ignoring")
        return
    end
    is_initialized = true

    Config.setup(opts)
    require("delta.status").setup()
    require("delta.picker").setup()
    require("delta.spotlight").setup()
    require("delta.commands").setup()
    setup_highlight_autocmds()
end

--- @type delta.Picker
M.picker = require("delta.picker")

--- @type delta.Spotlight
M.spotlight = require("delta.spotlight")

return M
