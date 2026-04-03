--- Shared git-status definitions for delta.nvim.

local M = {}

M.highlights = {
    modified = "DeltaStatusModified",
    added = "DeltaStatusAdded",
    deleted = "DeltaStatusDeleted",
    renamed = "DeltaStatusRenamed",
    copied = "DeltaStatusCopied",
    untracked = "DeltaStatusUntracked",
    unmerged = "DeltaStatusUnmerged",
}

---@param code delta.GitStatusCode
---@return string?
function M.icon(code)
    local icons = require("delta.config").options.git.status
    if code == "M" then
        return icons.modified
    elseif code == "A" then
        return icons.added
    elseif code == "D" then
        return icons.deleted
    elseif code == "R" then
        return icons.renamed
    elseif code == "C" then
        return icons.copied
    elseif code == "U" then
        return icons.unmerged
    elseif code == "?" then
        return icons.untracked
    end
end

---@param code delta.GitStatusCode
---@return string?
function M.highlight(code)
    if code == "M" then
        return M.highlights.modified
    elseif code == "A" then
        return M.highlights.added
    elseif code == "D" then
        return M.highlights.deleted
    elseif code == "R" then
        return M.highlights.renamed
    elseif code == "C" then
        return M.highlights.copied
    elseif code == "U" then
        return M.highlights.unmerged
    elseif code == "?" then
        return M.highlights.untracked
    end
end

function M.setup()
    local defs = {
        [M.highlights.modified] = { link = "DiffChange" },
        [M.highlights.added] = { link = "DiffAdd" },
        [M.highlights.deleted] = { link = "DiffDelete" },
        [M.highlights.renamed] = { link = "DiffChange" },
        [M.highlights.copied] = { link = "DiffChange" },
        [M.highlights.untracked] = { link = "Comment" },
        [M.highlights.unmerged] = { link = "DiagnosticWarn" },
    }
    for name, def in pairs(defs) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
    end
end

return M
