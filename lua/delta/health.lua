--- Health check for delta.nvim.

local M = {}

M.check = function()
    vim.health.start("delta.nvim")

    if vim.fn.executable("git") == 1 then
        vim.health.ok("`git` executable found")
    else
        vim.health.error("`git` not found in PATH")
    end

    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.warn("Neovim >= 0.10 recommended")
    end
end

return M
