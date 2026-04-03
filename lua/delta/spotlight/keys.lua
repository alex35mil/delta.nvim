--- Key-binding utilities for delta.spotlight.
--- Saves and restores pre-existing buffer-local mappings.

local M = {}

--- Lookup key for saved original mappings: "buf:mode:lhs".
---@type table<string, table|false>
local originals = {}

---@param modes string|string[]
---@return string[]
local function normalize_modes(modes)
    if type(modes) == "table" then
        return modes
    end
    local result = {}
    for i = 1, #modes do
        result[#result + 1] = modes:sub(i, i)
    end
    return result
end

---@param bufid delta.BufId
---@param mode string
---@param lhs string
---@return string
local function make_key(bufid, mode, lhs)
    return bufid .. ":" .. mode .. ":" .. lhs
end

---@param bufid delta.BufId
---@param mode string
---@param lhs string
local function snapshot(bufid, mode, lhs)
    local k = make_key(bufid, mode, lhs)
    if originals[k] ~= nil then
        return
    end
    local existing = vim.fn.maparg(lhs, mode, false, true)
    if existing and existing.buffer == 1 then
        originals[k] = existing
    else
        originals[k] = false
    end
end

---@param bufid delta.BufId
---@param mode string
---@param lhs string
local function restore(bufid, mode, lhs)
    local k = make_key(bufid, mode, lhs)
    local prev = originals[k]
    originals[k] = nil

    if prev then
        local rhs = prev.callback or prev.rhs or ""
        vim.keymap.set(mode, lhs, rhs, {
            buffer = bufid,
            silent = prev.silent == 1,
            nowait = prev.nowait == 1,
            expr = prev.expr == 1,
            noremap = prev.noremap == 1,
            desc = prev.desc,
        })
    else
        pcall(vim.keymap.del, mode, lhs, { buffer = bufid })
    end
end

---@param key delta.KeySpec
---@param default_modes string|string[]
---@return string[]
local function resolve_modes(key, default_modes)
    return normalize_modes(type(key) == "table" and key.modes or default_modes)
end

--- Bind a KeySpec to a buffer, saving any pre-existing mapping.
---@param bufid delta.BufId
---@param key delta.KeySpec
---@param handler function
---@param opts? { modes?: string|string[], desc?: string, nowait?: boolean }
function M.bind(bufid, key, handler, opts)
    opts = opts or {}
    local default_modes = opts.modes or "n"
    local lhs = M.lhs(key)
    local modes = resolve_modes(key, default_modes)

    for _, mode in ipairs(modes) do
        snapshot(bufid, mode, lhs)
    end

    vim.keymap.set(modes, lhs, handler, {
        buffer = bufid,
        desc = opts.desc,
        nowait = opts.nowait,
    })
end

--- Unbind a KeySpec from a buffer, restoring any prior mapping.
---@param bufid delta.BufId
---@param key delta.KeySpec
---@param modes? string|string[]
function M.unbind(bufid, key, modes)
    modes = modes or "n"
    local lhs = M.lhs(key)

    for _, mode in ipairs(resolve_modes(key, modes)) do
        restore(bufid, mode, lhs)
    end
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
