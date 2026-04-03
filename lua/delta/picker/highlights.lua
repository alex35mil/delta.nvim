--- Highlight group definitions for delta.picker.

local M = {}

local Status = require("delta.status")

M.groups = {
    dialog = "DeltaPickerDialog",
    title = "DeltaPickerTitle",
    border = "DeltaPickerBorder",
    prompt = "DeltaPickerPrompt",
    file = "DeltaPickerFile",
    directory = "DeltaPickerDirectory",
    section_header = "DeltaPickerSectionHeader",
    cursor_line = "DeltaPickerCursorLine",
    active_branch = "DeltaPickerActiveBranch",
    inactive_branch = "DeltaPickerInactiveBranch",
    tree_connector = "DeltaPickerTreeConnector",
    empty = "DeltaPickerEmpty",
    status_modified = Status.highlights.modified,
    status_added = Status.highlights.added,
    status_deleted = Status.highlights.deleted,
    status_renamed = Status.highlights.renamed,
    status_untracked = Status.highlights.untracked,
    status_unmerged = Status.highlights.unmerged,
}

function M.setup()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local directory = vim.api.nvim_get_hl(0, { name = "Directory", link = false })

    local defs = {
        [M.groups.dialog] = { link = "Normal" },
        [M.groups.title] = { link = "Normal" },
        [M.groups.border] = { link = "Comment" },
        [M.groups.prompt] = { link = "Normal" },
        [M.groups.file] = { fg = normal.fg },
        [M.groups.directory] = { fg = directory.fg },
        [M.groups.section_header] = { link = "Title" },
        [M.groups.cursor_line] = { link = "Visual" },
        [M.groups.active_branch] = { fg = normal.fg },
        [M.groups.inactive_branch] = { link = "Comment" },
        [M.groups.tree_connector] = { link = "NonText" },
        [M.groups.empty] = { link = "NonText" },
    }
    for name, def in pairs(defs) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
    end
end

return M
