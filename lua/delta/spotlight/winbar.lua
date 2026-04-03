--- Winbar rendering for delta.spotlight.

local M = {}

local Status = require("delta.status")
local Config = require("delta.config")
local Highlights = require("delta.spotlight.highlights")
local Paths = require("delta.spotlight.paths")

local hl = Highlights.groups

--- Status key → highlight group.
local status_hl = {
    staged = hl.status_staged,
    unstaged = hl.status_unstaged,
    mixed = hl.status_mixed,
    conflict = hl.status_conflict,
    untracked = hl.status_untracked,
    clean = hl.status_clean,
    outsider = hl.status_outsider,
    no_repo = hl.status_no_repo,
    error = hl.status_error,
}

---@param mode delta.spotlight.ResolvedMode
---@param hunks delta.Hunks
---@return delta.Hunk[]
local function resolve_hunks(mode, hunks)
    if mode == "unstaged" then
        return hunks.unstaged
    elseif mode == "staged" then
        return hunks.staged
    end
    return {}
end

---@param winid delta.WinId
---@param win delta.spotlight.WinState
---@param file delta.spotlight.FileState
---@return integer?
---@return integer
function M.current_hunk_position(winid, win, file)
    if file.kind ~= "managed" then
        return nil, 0
    end

    local hunks = resolve_hunks(win.resolved_mode, file.hunks)
    local total = #hunks
    if total == 0 then
        return nil, 0
    end

    local bufid = vim.api.nvim_win_get_buf(winid)
    local side = Paths.visible_side(vim.api.nvim_buf_get_name(bufid))
    local line = vim.api.nvim_win_get_cursor(winid)[1]
    local last_passed = nil

    for i, hunk in ipairs(hunks) do
        local start_line = hunk:start_line(side)
        local end_line = hunk:end_line(side)

        if line >= start_line and line <= end_line then
            return i, total
        end
        if line > end_line then
            last_passed = i
        elseif line < start_line then
            break
        end
    end

    if last_passed then
        return last_passed, total
    end

    return 1, total
end

--- Get git status key for a file.
---@param file delta.spotlight.FileState
---@return delta.spotlight.StatusKey
local function git_status_key(file)
    if file.kind == "unmanaged" then
        return file.status
    end

    local status = file.status
    if not status then
        return "error"
    end
    if status:is_conflicted() then
        return "conflict"
    end
    if status:is_untracked() then
        return "untracked"
    end
    if status:has_staged() and status:has_unstaged() then
        return "mixed"
    end
    if status:has_staged() then
        return "staged"
    end
    if status:has_unstaged() then
        return "unstaged"
    end
    return "clean"
end

---@param file delta.spotlight.FileState
---@return delta.FileStatus?
local function managed_status(file)
    return file.kind == "managed" and file.status or nil
end

---@class delta.spotlight.StatusDetailPart
---@field icon string
---@field hl string

---@param code delta.GitStatusCode
---@return delta.spotlight.StatusDetailPart?
local function detail_part(code)
    local icon = Status.icon(code)
    local detail_hl = Status.highlight(code)
    if not icon or not detail_hl then
        return nil
    end
    return { icon = icon, hl = detail_hl }
end

---@param status delta.FileStatus?
---@param key delta.spotlight.StatusKey
---@return delta.spotlight.StatusDetailPart[]
local function status_detail(status, key)
    if not status then
        return {}
    end

    local parts = {}
    local function add(code)
        local part = detail_part(code)
        if part then
            table.insert(parts, part)
        end
    end

    if key == "conflict" or key == "mixed" then
        add(status.index)
        add(status.worktree)
        return parts
    end

    if key == "staged" then
        add(status.index)
        return parts
    end

    if key == "unstaged" then
        add(status.worktree)
        return parts
    end

    if key == "untracked" then
        add("?")
        return parts
    end

    return parts
end

--- Update the winbar to show spotlight status.
--- Must be called inside Git.async() (calls Git.file_status).
---@param winid delta.WinId
---@param win delta.spotlight.WinState
---@param file delta.spotlight.FileState
---@param fold delta.spotlight.FoldState|nil
---@param hunks integer
---@param current_hunk? integer
---@param total_hunks? integer
function M.update(winid, win, file, fold, hunks, current_hunk, total_hunks)
    local hl_wb = hl.winbar
    local hl_title = hl.winbar_title
    local hl_label = hl.winbar_label
    local hl_value = hl.winbar_numeric_value

    local bufid = vim.api.nvim_win_get_buf(winid)
    local _, scratch = Paths.normalize(vim.api.nvim_buf_get_name(bufid))
    local title = Config.options.spotlight.title
    local key = git_status_key(file)
    local entry = Config.options.spotlight.status[key] or {}
    local hl_status = status_hl[key] or hl_label
    local non_editable = Config.options.spotlight.status.non_editable or {}
    local has_non_editable_label = non_editable.label ~= nil and non_editable.label ~= ""

    local parts = {
        "%#" .. hl_wb .. "# ",
        "%#" .. hl_title .. "# " .. title,
    }

    local mode_label = win.requested_mode

    if mode_label == "auto" and hunks > 0 then
        mode_label = "auto:" .. win.resolved_mode
    end
    table.insert(parts, "%#" .. hl_label .. "#  " .. mode_label)

    if hunks > 0 then
        local context = fold and fold.context or Config.options.spotlight.context.base
        current_hunk = current_hunk or M.current_hunk_position(winid, win, file)
        total_hunks = total_hunks or hunks
        table.insert(parts, "%#" .. hl_label .. "#  ctx:%#" .. hl_value .. "# ±" .. context)
        if current_hunk then
            table.insert(
                parts,
                "%#" .. hl_label .. "#  hunk:%#" .. hl_value .. "# " .. current_hunk .. "/" .. total_hunks
            )
        else
            table.insert(parts, "%#" .. hl_label .. "#  hunks:%#" .. hl_value .. "# " .. hunks)
        end
    end

    table.insert(parts, "%=")

    if entry.icon then
        table.insert(parts, "%#" .. hl_status .. "#" .. entry.icon)
    end
    if entry.label then
        table.insert(parts, "%#" .. hl_label .. "# " .. entry.label)
    end

    local detail = status_detail(managed_status(file), key)
    if (entry.icon or entry.label) and #detail > 0 then
        table.insert(parts, "%#" .. hl_label .. "# ")
    end
    for _, part in ipairs(detail) do
        table.insert(parts, "%#" .. part.hl .. "# " .. part.icon)
    end

    if scratch and (entry.icon or entry.label or #detail > 0) and (non_editable.icon or has_non_editable_label) then
        table.insert(parts, "  ")
    end
    if scratch and non_editable.icon then
        table.insert(parts, "%#" .. hl_label .. "#" .. non_editable.icon)
    end
    if scratch and has_non_editable_label then
        table.insert(parts, "%#" .. hl_label .. "# " .. non_editable.label)
    end

    if entry.icon or entry.label or #detail > 0 or (scratch and (non_editable.icon or has_non_editable_label)) then
        table.insert(parts, "  ")
    end

    vim.wo[winid].winbar = table.concat(parts)
end

return M
