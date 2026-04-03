local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["resets current file to HEAD from staged state"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })
    H.git(repo, "add", "file.txt")

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup({ reset = { confirm = false } })]])
    H.nvim_edit(nvim, repo .. "/file.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.lua_notify([[require('delta').spotlight.cycle_mode()]])
    nvim.lua_notify([[require('delta').spotlight.reset_file()]])

    H.nvim_wait_for_git_diff(nvim, "file.txt", true, false, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, false, 5000, 20)
    H.eq(table.concat(vim.fn.readfile(repo .. "/file.txt"), "\n"), "one\ntwo\nthree")
end

return T
