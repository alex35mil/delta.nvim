--- Shared key utilities for delta.nvim.

--- A key specification: plain string or table with modes override.
---@alias delta.KeySpec string|{ [1]: string, modes?: delta.KeyModes }

--- Key modes
---@alias delta.KeyModes string|string[]

--- One or more key specifications.
---@alias delta.KeySpecs delta.KeySpec|delta.KeySpec[]

local M = {}

--- Normalize a KeySpecs value into a list of KeySpec.
---@param keyspecs delta.KeySpecs
---@return delta.KeySpec[]
function M.resolve(keyspecs)
    if type(keyspecs) == "string" then
        return { keyspecs }
    end
    -- Table with .modes → single KeySpec.
    if type(keyspecs) == "table" and keyspecs.modes then
        return { keyspecs }
    end
    -- Table of KeySpecs.
    return keyspecs
end

--- Extract the LHS string from a KeySpec.
---@param key delta.KeySpec
---@return string
function M.lhs(key)
    if type(key) == "table" then
        return key[1]
    end
    return key --[[@as string]]
end

--- Normalize an lhs for effective-key comparisons.
---@param lhs string
---@return string
function M.normalize_lhs(lhs)
    local normalized = lhs:gsub("<([^>]+)>", function(token)
        return "<" .. token:lower() .. ">"
    end)
    return vim.api.nvim_replace_termcodes(normalized, true, true, true)
end

--- Normalize a mode string/table to a mode list.
---@param modes string|string[]
---@return string[]
function M.normalize_modes(modes)
    if type(modes) == "table" then
        return modes
    end
    local result = {}
    for i = 1, #modes do
        result[#result + 1] = modes:sub(i, i)
    end
    return result
end

--- Resolve the modes for a KeySpec, falling back to defaults.
---@param key delta.KeySpec
---@param default_modes string|string[]
---@return string[]
function M.modes(key, default_modes)
    if type(key) == "table" and key.modes then
        return M.normalize_modes(key.modes)
    end
    return M.normalize_modes(default_modes)
end

return M
