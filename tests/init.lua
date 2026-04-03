local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local mini_path = root .. "/tests/deps/mini.test"

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(mini_path)

vim.cmd("set noswapfile")
vim.cmd("set shada=")
vim.cmd("set shortmess+=I")

_G.MiniTest = require("mini.test")
