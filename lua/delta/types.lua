--- Shared type aliases for delta.nvim.

---@alias delta.BufId integer Neovim buffer handle
---@alias delta.WinId integer Neovim window handle
---@alias delta.TabId integer Neovim tabpage handle

---@class delta.Repository
---@field root string Absolute worktree root.
---@field gitdir string Absolute Git directory (including submodule/worktree Git directories).

---@class delta.RepositoryFile
---@field repo delta.Repository
---@field path string Repository-relative Git/display path.
---@field absolute_path string Stable absolute filesystem identity.
