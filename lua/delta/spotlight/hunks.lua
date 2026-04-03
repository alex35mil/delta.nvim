local M = {}

local Mode = require("delta.spotlight.mode")
local Paths = require("delta.spotlight.paths")
local Notify = require("delta.notify")

---@param file delta.spotlight.FileState
---@param scratch delta.spotlight.ScratchBufContentType
---@return delta.Hunk[]
local function rendered_scratch_hunks(file, scratch)
    if file.kind ~= "managed" then
        return {}
    end
    local scratch_buf = file.bufs.scratch[scratch]
    return (scratch_buf and scratch_buf.rendered_hunks) or file.hunks.staged
end

--- Get hunks for navigation (from spotlight state or git diff).
---@param mode delta.spotlight.ResolvedMode
---@param hunks delta.Hunks
---@return delta.Hunk[]
local function resolve(mode, hunks)
    if mode == "unstaged" then
        return hunks.unstaged
    elseif mode == "staged" then
        return hunks.staged
    elseif mode == "none" then
        return {}
    else
        error("Unexpected spotlight mode: " .. mode)
    end
end

---@param bufid delta.BufId
---@return delta.HunkSide
local function visible_side(bufid)
    return Paths.visible_side(vim.api.nvim_buf_get_name(bufid))
end

--- Build navigation groups from hunks.
--- Navigation should stop at each visible hunk location so review can step through
--- every diff chunk. Only exact same-line duplicates collapse into one stop.
---@param hunks delta.Hunk[]
---@param side delta.HunkSide
---@return { start_line: number, end_line: number }[]
local function merge_groups(hunks, side)
    if #hunks == 0 then
        return {}
    end

    local groups = {}

    for _, h in ipairs(hunks) do
        local group = { start_line = h:start_line(side), end_line = h:end_line(side) }
        local last = groups[#groups]

        if not last then
            table.insert(groups, group)
        elseif group.start_line == last.start_line and group.end_line == last.end_line then
            -- Skip exact duplicates.
        else
            table.insert(groups, group)
        end
    end

    return groups
end

---@param mode delta.spotlight.ResolvedMode
---@param hunks delta.Hunks
---@return delta.Hunk[]
function M.for_mode(mode, hunks)
    return resolve(mode, hunks)
end

---@param winid delta.WinId
---@param bufid delta.BufId
---@param win delta.spotlight.WinState?
---@param file delta.spotlight.FileState?
---@return delta.Hunk[]?
---@return { start_line: number, end_line: number }[]?
function M.resolve(winid, bufid, win, file)
    if not file then
        Notify.error(
            "Failed to get hunks for navigation - no file state found." .. " Win: " .. winid .. " Buf: " .. bufid
        )
        return
    end

    if file.kind ~= "managed" then
        return {}, {}
    end

    local mode = win and win.resolved_mode or Mode.resolve(file.path, "auto", file.status)
    local side = visible_side(bufid)
    local _, scratch = Paths.normalize(vim.api.nvim_buf_get_name(bufid))
    local hunks = scratch and rendered_scratch_hunks(file, scratch) or resolve(mode, file.hunks)
    local groups = merge_groups(hunks, side)

    return hunks, groups
end

return M
