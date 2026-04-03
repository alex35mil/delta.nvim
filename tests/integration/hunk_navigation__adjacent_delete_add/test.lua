local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["next_hunk stops on delete anchor then added hunk"] = function()
    local case = "hunk_navigation__adjacent_delete_add"
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
    nvim.lua_notify([[require('delta.spotlight.core').next_hunk(vim.api.nvim_get_current_buf())]])

    local first = nvim.lua_func(function()
        return vim.api.nvim_win_get_cursor(0)[1]
    end)
    H.eq(first, 2)

    nvim.lua_notify([[require('delta.spotlight.core').next_hunk(vim.api.nvim_get_current_buf())]])

    local second = nvim.lua_func(function()
        return vim.api.nvim_win_get_cursor(0)[1]
    end)
    H.eq(second, 5)
end

T["prev_hunk stops on added hunk then delete anchor"] = function()
    local case = "hunk_navigation__adjacent_delete_add"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.api.nvim_win_set_cursor(0, { 9, 0 })
    nvim.lua_notify([[require('delta.spotlight.core').prev_hunk(vim.api.nvim_get_current_buf())]])

    local first = nvim.lua_func(function()
        return vim.api.nvim_win_get_cursor(0)[1]
    end)
    H.eq(first, 5)

    nvim.lua_notify([[require('delta.spotlight.core').prev_hunk(vim.api.nvim_get_current_buf())]])

    local second = nvim.lua_func(function()
        return vim.api.nvim_win_get_cursor(0)[1]
    end)
    H.eq(second, 2)
end

return T
