local M = {}

---@alias delta.spotlight.RequestedMode "auto"|"unstaged"|"staged"
---@alias delta.spotlight.ResolvedMode "unstaged"|"staged"|"none"

---@param path delta.FilePath
---@param mode delta.spotlight.RequestedMode
---@param status delta.FileStatus
---@param picker_override? delta.spotlight.PickerOverride
---@return delta.spotlight.ResolvedMode resolved_mode
function M.resolve(path, mode, status, picker_override)
    if picker_override and picker_override.path == path then
        mode = picker_override.mode
    end
    if mode == "auto" then
        if status:is_untracked() then
            return "none"
        end
        if status:has_unstaged() then
            return "unstaged"
        end
        if status:has_staged() then
            return "staged"
        end
        -- Clean: no changes.
        return "none"
    elseif mode == "unstaged" then
        return "unstaged"
    elseif mode == "staged" then
        return "staged"
    else
        error("Unexpected spotlight mode: " .. mode)
    end
end

return M
