local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["updates folds above cursor after staging and jumping to next hunk"] = function()
    local base = {}
    local changed = {}
    for i = 1, 60 do
        base[i] = string.format("line %02d", i)
        changed[i] = base[i]
    end
    changed[5] = "changed 05"
    changed[45] = "changed 45"

    local repo = H.init_repo({ ["test.txt"] = base })
    H.finally_rm(repo)
    H.write_file(repo .. "/test.txt", changed)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup({ spotlight = { context = { base = 0 } } })]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    nvim.lua([[require('delta').spotlight.ensure()]])
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.api.nvim_win_set_cursor(0, { 5, 0 })
    nvim.lua_notify([[require('delta.spotlight.core').toggle_stage_hunk()]])

    H.nvim_wait_for_git_diff(nvim, "test.txt", true, true, 5000, 20)
    H.nvim_wait_for_delta_file_state(nvim, [[function(file)
        return #file.raw_hunks.staged == 1 and #file.raw_hunks.unstaged == 1
    end]], 5000, 20)
    H.nvim_wait_for(nvim, [[vim.api.nvim_win_get_cursor(0)[1] == 45]], 5000, 20)

    local fold_state = nvim.lua_func(function()
        return {
            cursor = vim.api.nvim_win_get_cursor(0)[1],
            foldclosed = vim.fn.foldclosed(1),
            foldclosedend = vim.fn.foldclosedend(1),
            foldenable = vim.wo.foldenable,
            foldlevel = vim.wo.foldlevel,
            foldmethod = vim.wo.foldmethod,
        }
    end)

    assert(fold_state.foldclosed ~= -1, vim.inspect(fold_state))
    assert(fold_state.foldclosedend < fold_state.cursor, vim.inspect(fold_state))
end

return T
