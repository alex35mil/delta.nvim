local M = {}

local Mode = require("delta.spotlight.mode")
local Paths = require("delta.spotlight.paths")
local Notify = require("delta.notify")

---@class delta.VisibleSegment
---@field kind "add"|"delete"|"change"
---@field start_line integer
---@field end_line integer
---@field old_start integer?
---@field old_end integer?
---@field new_start integer?
---@field new_end integer?
---@field old_count integer
---@field new_count integer
---@field old_lines string[]
---@field new_lines string[]
---@field source_block delta.VisibleDiffBlock?

---@param lines string[]
---@param start integer
---@param count integer
---@return string[]
local function slice_lines(lines, start, count)
    if count <= 0 then
        return {}
    end
    return vim.list_slice(lines, start, start + count - 1)
end

---@param maps integer[]
---@param start integer
---@param count integer
---@param fallback integer
---@return integer
local function mapped_start(maps, start, count, fallback)
    if count > 0 and start > 0 then
        return maps[start] or fallback
    end
    if start <= 0 then
        return maps[1] or fallback
    end
    return maps[start] or ((maps[#maps] or (fallback - 1)) + 1)
end

---@param maps integer[]
---@param start integer
---@param count integer
---@param fallback integer
---@return integer?
local function mapped_end(maps, start, count, fallback)
    if count <= 0 then
        return nil
    end
    local idx = start + count - 1
    return maps[idx] or (mapped_start(maps, start, count, fallback) + count - 1)
end

---@param old_lines string[]
---@param new_lines string[]
---@param old_map integer[]
---@param new_map integer[]
---@param old_fallback integer
---@param new_fallback integer
---@param source_block delta.VisibleDiffBlock?
---@param opts? vim.diff.Opts
---@return delta.VisibleSegment[]
local function visible_segments_from_diff(old_lines, new_lines, old_map, new_map, old_fallback, new_fallback, source_block, opts)
    local diff_opts = vim.tbl_extend("force", {
        result_type = "indices",
        linematch = 40,
    }, opts or {})

    local a = table.concat(old_lines, "\n") .. "\n"
    local b = table.concat(new_lines, "\n") .. "\n"
    local ok, indices = pcall(vim.diff, a, b, diff_opts)
    if not ok or type(indices) ~= "table" or #indices == 0 then
        return {}
    end

    local segments = {}
    for _, item in ipairs(indices) do
        local start_a, count_a, start_b, count_b = unpack(item)
        if count_a > 0 or count_b > 0 then
            local mapped_old_start = mapped_start(old_map, start_a, count_a, old_fallback)
            local mapped_new_start = mapped_start(new_map, start_b, count_b, new_fallback)
            local start_line = count_b > 0 and mapped_new_start or math.max(mapped_new_start, 1)
            local segment = {
                kind = count_b == 0 and "delete" or count_a == 0 and "add" or "change",
                start_line = start_line,
                end_line = count_b > 0 and (mapped_end(new_map, start_b, count_b, new_fallback) or start_line) or start_line,
                old_start = mapped_old_start,
                old_end = mapped_end(old_map, start_a, count_a, old_fallback),
                new_start = mapped_new_start,
                new_end = count_b > 0 and mapped_end(new_map, start_b, count_b, new_fallback) or nil,
                old_count = count_a,
                new_count = count_b,
                old_lines = slice_lines(old_lines, start_a, count_a),
                new_lines = slice_lines(new_lines, start_b, count_b),
                source_block = source_block,
            }
            segments[#segments + 1] = segment
        end
    end

    return segments
end

---@param block delta.VisibleDiffBlock
---@return delta.VisibleSegment[]
function M.visible_segments_for_block(block)
    return visible_segments_from_diff(
        block.old_lines,
        block.new_lines,
        block.old_map,
        block.new_map,
        block.old_start,
        block.new_start,
        block,
        nil
    )
end

---@param blocks delta.VisibleDiffBlock[]
---@return delta.VisibleSegment[]
function M.visible_segments(blocks)
    local segments = {}
    for _, block in ipairs(blocks or {}) do
        vim.list_extend(segments, M.visible_segments_for_block(block))
    end
    return segments
end

---@param old_lines string[]
---@param new_lines string[]
---@param opts? vim.diff.Opts
---@return delta.VisibleSegment[]
function M.visible_segments_from_lines(old_lines, new_lines, opts)
    local old_map = {}
    for i = 1, #old_lines do
        old_map[i] = i
    end

    local new_map = {}
    for i = 1, #new_lines do
        new_map[i] = i
    end

    return visible_segments_from_diff(old_lines, new_lines, old_map, new_map, 1, 1, nil, opts)
end

---@param old_lines string[]
---@param new_lines string[]
---@return delta.VisibleSegment[]
function M.linematch_segments_from_lines(old_lines, new_lines)
    return M.visible_segments_from_lines(old_lines, new_lines, {
        linematch = 40,
    })
end

---@param old_lines string[]
---@param new_lines string[]
---@return delta.VisibleSegment[]
function M.contiguous_segments_from_lines(old_lines, new_lines)
    return M.visible_segments_from_lines(old_lines, new_lines, {
        linematch = false,
    })
end

---@param file delta.spotlight.FileState
---@param scratch delta.spotlight.ScratchBufContentType
---@return delta.Hunk[]
local function rendered_scratch_hunks(file, scratch)
    if file.kind ~= "managed" then
        return {}
    end
    local scratch_buf = file.bufs.scratch[scratch]
    return (scratch_buf and scratch_buf.rendered_hunks) or file.raw_hunks.staged
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

---@param file delta.spotlight.FileState
---@return delta.Hunks
local function visible_hunks_for_file(file)
    return file.kind == "managed" and file.visible_hunks or file.raw_hunks
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
---@param line_count integer
---@return { start_line: number, end_line: number }[]
local function merge_groups(hunks, side, line_count)
    if #hunks == 0 or line_count <= 0 then
        return {}
    end

    local groups = {}

    for _, h in ipairs(hunks) do
        local start_line = h:start_line(side)
        local end_line = h:end_line(side)

        if start_line <= line_count then
            local group = {
                start_line = math.max(1, start_line),
                end_line = math.max(math.max(1, start_line), math.min(end_line, line_count)),
            }
            local last = groups[#groups]

            if not last then
                table.insert(groups, group)
            elseif group.start_line == last.start_line and group.end_line == last.end_line then
                -- Skip exact duplicates.
            else
                table.insert(groups, group)
            end
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
    local hunks = scratch and rendered_scratch_hunks(file, scratch) or resolve(mode, visible_hunks_for_file(file))
    local line_count = vim.api.nvim_buf_line_count(bufid)
    local groups = merge_groups(hunks, side, line_count)

    return hunks, groups
end

return M
