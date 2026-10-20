local M = {}
local Repository = require("delta.repository")
local Uri = require("delta.uri")

---@param path string
---@return delta.FilePath?
---@return delta.spotlight.ScratchBufContentType?
function M.normalize(path)
    if path == "" then
        return nil
    end

    local scratch_content, scratch_path = Uri.parse(path)
    if scratch_content == "staged" or scratch_content == "deleted" then
        return Repository.canonical(Repository.absolute(scratch_path, vim.fn.getcwd())), scratch_content
    end

    if path:match("^%a[%w+.-]*://") then
        -- Other views may identify a repository file without being Spotlight sources.
        return nil
    end

    return Repository.canonical(Repository.absolute(path, vim.fn.getcwd()))
end

---@param content_type delta.spotlight.ScratchBufContentType
---@param path delta.FilePath
---@return string
function M.scratch(content_type, path)
    return Uri.name(content_type, path)
end

---@param path string
---@return delta.HunkSide
function M.visible_side(path)
    local _, scratch_content = M.normalize(path)
    return scratch_content == "deleted" and "removed" or "added"
end

return M
