--- Delta URI namespace, construction, and parsing.
local M = {}

M.scheme = "delta://"

---@param ... string|number URI components, including absolute paths where applicable.
---@return string
function M.name(...)
    return M.scheme .. table.concat({ ... }, "/")
end

---@param name string
---@return string? kind
---@return string? path Remaining URI components, without changing path separators.
function M.parse(name)
    if not vim.startswith(name, M.scheme) then
        return nil
    end
    return name:sub(#M.scheme + 1):match("^([^/]+)/(.+)$")
end

return M
