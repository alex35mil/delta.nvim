--- Highlight group definitions for delta.spotlight.

local M = {}

M.groups = {
    winbar = "DeltaSpotlightWinbar",
    winbar_title = "DeltaSpotlightWinbarTitle",
    winbar_label = "DeltaSpotlightWinbarLabel",
    winbar_numeric_value = "DeltaSpotlightWinbarNumericValue",
    status_staged = "DeltaSpotlightStatusStaged",
    status_unstaged = "DeltaSpotlightStatusUnstaged",
    status_mixed = "DeltaSpotlightStatusMixed",
    status_conflict = "DeltaSpotlightStatusConflict",
    status_untracked = "DeltaSpotlightStatusUntracked",
    status_clean = "DeltaSpotlightStatusClean",
    status_outsider = "DeltaSpotlightStatusOutsider",
    status_no_repo = "DeltaSpotlightStatusNoRepo",
    status_error = "DeltaSpotlightStatusError",
    scratch_diff_add = "DeltaSpotlightScratchDiffAdd",
    scratch_diff_change = "DeltaSpotlightScratchDiffChange",
    scratch_diff_delete = "DeltaSpotlightScratchDiffDelete",
    popup = "DeltaSpotlightPopup",
    popup_border = "DeltaSpotlightPopupBorder",
    popup_title = "DeltaSpotlightPopupTitle",
    popup_added = "DeltaSpotlightPopupAdded",
    popup_removed = "DeltaSpotlightPopupRemoved",
    popup_neutral = "DeltaSpotlightPopupNeutral",
    popup_line_nr = "DeltaSpotlightPopupLineNr",
}

function M.setup()
    local function bg_only(group, fallback)
        local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
        if ok and existing and existing.bg then
            return { bg = existing.bg, ctermbg = existing.ctermbg }
        end
        return fallback
    end

    local defs = {
        [M.groups.winbar] = { link = "WinBar" },
        [M.groups.winbar_title] = { link = "WinBar" },
        [M.groups.winbar_label] = { link = "Comment" },
        [M.groups.winbar_numeric_value] = { link = "Number" },
        [M.groups.status_staged] = { link = "DiffAdd" },
        [M.groups.status_unstaged] = { link = "DiffChange" },
        [M.groups.status_mixed] = { link = "DiagnosticWarn" },
        [M.groups.status_conflict] = { link = "DiagnosticError" },
        [M.groups.status_untracked] = { link = "Comment" },
        [M.groups.status_clean] = { link = "Comment" },
        [M.groups.status_outsider] = { link = "DiagnosticWarn" },
        [M.groups.status_no_repo] = { link = "Comment" },
        [M.groups.status_error] = { link = "DiagnosticError" },
        [M.groups.scratch_diff_add] = { link = "DiffAdd" },
        [M.groups.scratch_diff_change] = { link = "DiffChange" },
        [M.groups.scratch_diff_delete] = { link = "DiffDelete" },
        [M.groups.popup] = { link = "NormalFloat" },
        [M.groups.popup_border] = { link = "FloatBorder" },
        [M.groups.popup_title] = { link = "Title" },
        [M.groups.popup_added] = bg_only("DiffAdd", { link = "DiffAdd" }),
        [M.groups.popup_removed] = bg_only("DiffDelete", { link = "DiffDelete" }),
        [M.groups.popup_neutral] = { link = M.groups.popup },
        [M.groups.popup_line_nr] = { link = "Comment" },
    }
    for name, def in pairs(defs) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
    end
end

return M
