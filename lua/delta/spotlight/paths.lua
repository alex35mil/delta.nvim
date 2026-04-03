local M = {}

M.scheme = "delta://"

---@param path string
---@return delta.FilePath?
---@return delta.spotlight.ScratchBufContentType?
function M.normalize(path)
    if path == "" then
        return nil
    end

    local scratch_content, scratch_path = path:match("^" .. M.scheme .. "([^/]+)/(.+)$")
    if scratch_content == "staged" or scratch_content == "deleted" then
        return scratch_path, scratch_content
    end

    local rel = vim.fn.fnamemodify(path, ":.")
    if rel == "" then
        return nil
    end

    return rel
end

---@param content_type delta.spotlight.ScratchBufContentType
---@param path delta.FilePath
---@return string
function M.scratch(content_type, path)
    return M.scheme .. content_type .. "/" .. path
end

---@param path string
---@return delta.HunkSide
function M.visible_side(path)
    local _, scratch_content = M.normalize(path)
    return scratch_content == "deleted" and "removed" or "added"
end

return M
