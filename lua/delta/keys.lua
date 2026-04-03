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

return M
