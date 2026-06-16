--- Highlight group definitions for delta.diff.

local M = {}

M.groups = {
    file_winbar = "DeltaDiffFileWinbar",
    file_winbar_base = "DeltaDiffFileWinbarBase",
    file_winbar_current = "DeltaDiffFileWinbarCurrent",
    file_winbar_hint = "DeltaDiffFileWinbarHint",
}

M.FILE_WINHIGHLIGHT = "WinBar:DeltaDiffFileWinbar,WinBarNC:DeltaDiffFileWinbar"

function M.setup()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
    local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })

    vim.api.nvim_set_hl(0, M.groups.file_winbar, { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, M.groups.file_winbar_base, {
        default = true,
        fg = normal.bg,
        bg = comment.fg,
        bold = true,
    })
    vim.api.nvim_set_hl(0, M.groups.file_winbar_current, {
        default = true,
        fg = normal.bg,
        bg = title.fg,
        bold = true,
    })
    vim.api.nvim_set_hl(0, M.groups.file_winbar_hint, { default = true, fg = comment.fg, bg = normal.bg })
end

return M
