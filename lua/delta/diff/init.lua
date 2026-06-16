--- Diff namespace for delta.nvim.

local M = {}

local Config = require("delta.config")

M.hunk = require("delta.diff.hunk")
M.file = require("delta.diff.file")
M.actions = require("delta.diff.actions")

---@param key delta.KeySpec
---@return delta.KeyModes
local function key_modes(key)
    return type(key) == "table" and key.modes or "n"
end

---@return delta.diff.ActionContext
local function make_context()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    return {
        win = win,
        buf = buf,
        path = vim.fn.expand("%:."),
        open_hunk_diff = function()
            M.open_hunk({ winid = win, bufid = buf })
        end,
        open_file_diff = function()
            M.open_file({ winid = win, bufid = buf })
        end,
    }
end

function M.setup()
    require("delta.diff.highlights").setup()

    local SharedKeys = require("delta.keys")
    for name, action in pairs((Config.options.diff or {}).actions or {}) do
        if action then
            local keyspecs = SharedKeys.resolve(action[1])
            local handler = action[2]
            for _, keyspec in ipairs(keyspecs) do
                local lhs = SharedKeys.lhs(keyspec)
                vim.keymap.set(key_modes(keyspec), lhs, function()
                    handler(make_context())
                end, { nowait = true, desc = "delta.diff." .. name })
            end
        end
    end
end

function M.open_hunk(opts)
    return M.hunk.open(opts)
end

function M.open_file(opts)
    return M.file.open(opts)
end

function M.close_file(tab)
    return M.file.close(tab)
end

function M.close_all()
    return M.file.close_all()
end

return M
