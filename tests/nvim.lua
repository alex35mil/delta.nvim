local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.g.did_load_ftplugin = 1
vim.cmd("filetype off")

vim.opt.runtimepath:prepend(root)
vim.cmd("set noswapfile")
vim.cmd("set shada=")
vim.cmd("set shortmess+=I")

_G.find_upvalue = function(fn, target, limit)
    for i = 1, limit or 50 do
        local name, value = debug.getupvalue(fn, i)
        if not name then
            break
        end
        if name == target then
            return value
        end
    end
end
