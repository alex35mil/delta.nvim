local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["next_hunk lands on deleted hunk anchor line"] = function()
    local case = "hunk_navigation__deleted_hunk"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.api.nvim_win_set_cursor(0, { 1, 0 })
    nvim.lua_notify([[require('delta').spotlight.next_hunk(vim.api.nvim_get_current_buf())]])

    local line = nvim.lua_func(function()
        return vim.api.nvim_win_get_cursor(0)[1]
    end)

    H.eq(line, 3)
end

T["prev_hunk lands on deleted hunk anchor line"] = function()
    local case = "hunk_navigation__deleted_hunk"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.api.nvim_win_set_cursor(0, { 10, 0 })
    nvim.lua_notify([[require('delta').spotlight.prev_hunk(vim.api.nvim_get_current_buf())]])

    local line = nvim.lua_func(function()
        return vim.api.nvim_win_get_cursor(0)[1]
    end)

    H.eq(line, 3)
end

return T
