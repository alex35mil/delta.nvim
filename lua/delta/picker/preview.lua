--- Preview pane for delta.picker.
--- Shows file contents with syntax highlighting.

local M = {}

local Config = require("delta.config")
local Highlights = require("delta.picker.highlights")
local Layout = require("delta.picker.layout")

local hl = Highlights.groups

local PREVIEW_UNAVAILABLE = {
    "Preview unavailable",
}

---@class delta.picker.PreviewState
---@field win delta.WinId preview window
---@field buf delta.BufId current preview buffer
---@field path? string currently previewed file path
---@field scratch_buf delta.BufId empty scratch buffer for reset

---@type delta.picker.PreviewState|nil
local preview = nil

--- Create the preview floating window with an empty scratch buffer.
---@param row number
---@param col number
---@param width number
---@param height number
---@return delta.BufId buf
---@return delta.WinId win
local function create_win(row, col, width, height)
    local preview_cfg = Config.options.picker.layout.preview
    local border = preview_cfg.border or { "", "", "", " ", " ", " ", " ", " " }

    -- Account for border rows so preview matches main panel height visually.
    local border_chars = Layout.resolve_border(border)
    local top_rows, bottom_rows = Layout.border_rows(border_chars)
    height = height - top_rows - bottom_rows

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"

    local title = nil
    local title_pos = nil
    if preview_cfg.title then
        local t = preview_cfg.title
        title = type(t) == "function" and t("") or t
        title_pos = "center"
    end

    local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        border = border,
        title = title,
        title_pos = title_pos,
    })

    vim.wo[win].winhighlight = "NormalFloat:" .. hl.dialog .. ",FloatBorder:" .. hl.border .. ",FloatTitle:" .. hl.title
    vim.wo[win].spell = false
    vim.wo[win].wrap = false
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].colorcolumn = ""
    vim.wo[win].list = false

    -- Apply window options from config.
    local wo = preview_cfg.wo or {}
    for k, v in pairs(wo) do
        vim.wo[win][k] = v
    end

    return buf, win
end

--- Reapply window options from config (needed after buffer swaps).
local function reapply_wo()
    if not preview or not vim.api.nvim_win_is_valid(preview.win) then
        return
    end
    vim.wo[preview.win].winhighlight = "NormalFloat:"
        .. hl.dialog
        .. ",FloatBorder:"
        .. hl.border
        .. ",FloatTitle:"
        .. hl.title
    local wo = Config.options.picker.layout.preview.wo or {}
    for k, v in pairs(wo) do
        vim.wo[preview.win][k] = v
    end
end

---@param lines string[]
local function show_scratch(lines)
    if not preview or not vim.api.nvim_win_is_valid(preview.win) then
        return
    end
    if not vim.api.nvim_buf_is_valid(preview.scratch_buf) then
        preview.scratch_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[preview.scratch_buf].bufhidden = "hide"
    end

    vim.bo[preview.scratch_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview.scratch_buf, 0, -1, false, lines)
    vim.bo[preview.scratch_buf].modifiable = false

    vim.api.nvim_win_set_buf(preview.win, preview.scratch_buf)
    preview.buf = preview.scratch_buf
    reapply_wo()
    vim.wo[preview.win].number = false
    vim.wo[preview.win].relativenumber = false
end

--- Load a file into the preview. Uses the existing buffer if loaded, otherwise reads from disk.
---@param path string
function M.update(path)
    if not preview or not vim.api.nvim_win_is_valid(preview.win) then
        return
    end

    -- Skip if already showing this file.
    if preview.path == path then
        return
    end
    preview.path = path

    local win = preview.win

    -- Update title only when it is dynamic.
    local preview_cfg = Config.options.picker.layout.preview
    if type(preview_cfg.title) == "function" and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, {
            relative = "editor",
            row = vim.api.nvim_win_get_position(win)[1],
            col = vim.api.nvim_win_get_position(win)[2],
            title = preview_cfg.title(path),
            title_pos = "center",
        })
    end

    -- Check if a buffer is already loaded for this file.
    local abs = vim.fn.fnamemodify(path, ":p")
    local existing = vim.fn.bufnr(abs)

    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
        -- Reuse existing loaded buffer (fast, syntax already set up).
        vim.api.nvim_win_set_buf(win, existing)
        preview.buf = existing
        reapply_wo()
    else
        -- Load from disk into a scratch buffer.
        local ok, lines = pcall(vim.fn.readfile, path)
        if not ok then
            show_scratch(PREVIEW_UNAVAILABLE)
            return
        end

        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = "wipe"

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false

        vim.api.nvim_win_set_buf(win, buf)
        preview.buf = buf
        reapply_wo()

        -- Set filetype for syntax highlighting.
        local ft = vim.filetype.match({ filename = path, buf = buf })
        if ft then
            local ei = vim.o.eventignore
            vim.o.eventignore = "all"
            vim.bo[buf].filetype = ft
            vim.o.eventignore = ei
        end

        -- Try treesitter, fall back to syntax.
        local lang = ft and vim.treesitter.language.get_lang(ft)
        if lang and pcall(vim.treesitter.start, buf, lang) then
            -- treesitter active
        elseif ft then
            vim.bo[buf].syntax = ft
        end
    end
end

--- Show the preview pane.
---@param row number
---@param col number
---@param width number
---@param height number
function M.show(row, col, width, height)
    if preview then
        return
    end

    local buf, win = create_win(row, col, width, height)

    preview = {
        buf = buf,
        win = win,
        path = nil,
        scratch_buf = buf,
    }
end

--- Hide and destroy the preview pane.
function M.hide()
    if not preview then
        return
    end

    if vim.api.nvim_win_is_valid(preview.win) then
        vim.api.nvim_win_close(preview.win, true)
    end

    preview = nil
end

--- Clear the preview contents (show empty).
function M.clear()
    if not preview or not vim.api.nvim_win_is_valid(preview.win) then
        return
    end
    preview.path = nil

    -- Switch back to scratch buffer.
    if vim.api.nvim_buf_is_valid(preview.scratch_buf) then
        show_scratch({})
    end
end

--- Check if the preview pane is visible.
---@return boolean
function M.is_visible()
    return preview ~= nil
end

--- Get the preview window if it is still valid.
---@return delta.WinId|nil
function M.get_win()
    if preview and vim.api.nvim_win_is_valid(preview.win) then
        return preview.win
    end
    return nil
end

--- Scroll the preview by a number of lines.
---@param delta number
function M.scroll(delta)
    if not preview or not vim.api.nvim_win_is_valid(preview.win) then
        return
    end
    local key = delta > 0 and "\5" or "\25" -- <C-e> / <C-y>
    local count = math.abs(delta)
    vim.api.nvim_win_call(preview.win, function()
        vim.cmd("normal! " .. count .. key)
    end)
end

return M
