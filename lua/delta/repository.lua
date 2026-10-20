--- Repository/file identities and buffer handoff. No Git commands or cwd changes.
local M = {}

---@param path string
---@param base? string Required for relative inputs.
---@return string
function M.absolute(path, base)
    assert(path ~= "", "file path must not be empty")
    if not vim.startswith(path, "/") then
        assert(base and vim.startswith(base, "/"), "relative paths require an absolute base")
        path = base .. "/" .. path
    end
    return vim.fs.normalize(path)
end

--- Find the nearest existing directory, including for deleted files/directories.
---@param path string
---@return string physical
---@return string original
function M.directory(path)
    while true do
        local stat, err, code = vim.uv.fs_stat(path)
        if stat and stat.type == "directory" then
            return assert(vim.uv.fs_realpath(path)), path
        end
        if not stat and code ~= "ENOENT" and code ~= "ENOTDIR" then
            error(err)
        end
        local parent = vim.fs.dirname(path)
        assert(parent and parent ~= path, "no existing directory for " .. path)
        path = parent
    end
end

--- Canonicalize the containing directory, not the leaf: Git tracks symlinks as files.
---@param path string
---@return string
function M.canonical(path)
    local directory, existing = M.directory(vim.fs.dirname(path))
    return M.absolute(directory .. path:sub(#existing + 1))
end

---@param repo delta.Repository
---@param path string Absolute or repository-relative path.
---@return delta.RepositoryFile?
function M.file(repo, path)
    local absolute = M.canonical(M.absolute(path, repo.root))
    local prefix = repo.root == "/" and "/" or repo.root .. "/"
    if not vim.startswith(absolute, prefix) then
        return nil
    end
    return { repo = repo, path = absolute:sub(#prefix + 1), absolute_path = absolute }
end

---@param bufid integer
---@return delta.RepositoryFile?
function M.buffer_file(bufid)
    return vim.b[bufid].delta_file
end

--- Capture a file-backed or Delta-owned buffer's identity before yielding.
---@param bufid integer
---@return string?
function M.buffer_path(bufid)
    local file = M.buffer_file(bufid)
    if file then
        return file.absolute_path
    end
    local name = vim.api.nvim_buf_get_name(bufid)
    if name == "" or vim.bo[bufid].buftype ~= "" or name:match("^%a[%w+.-]*://") then
        return nil
    end
    return M.canonical(M.absolute(name))
end

---@param bufid integer
---@param file delta.RepositoryFile
function M.bind_buffer(bufid, file)
    vim.b[bufid].delta_file = file
end

return M
