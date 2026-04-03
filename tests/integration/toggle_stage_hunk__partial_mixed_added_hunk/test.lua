local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["stages selected lines from mixed staged and unstaged added hunk"] = function()
    local case = "toggle_stage_hunk__partial_mixed_added_hunk"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.lua_func(function()
        local spotlight = require("delta.spotlight.core")
        local actions = require("delta").spotlight.actions
        local setup_global_keymaps = _G.find_upvalue(spotlight.setup, "setup_global_keymaps")
        local make_context = _G.find_upvalue(setup_global_keymaps, "make_context")

        vim.api.nvim_win_set_cursor(0, { 8, 0 })
        vim.cmd("normal! V")
        actions.toggle_stage_hunk(make_context(vim.api.nvim_get_current_buf()))
    end)

    H.nvim_wait_for_git_diff(nvim, "test.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "test.txt", false, true, 5000, 20)

    local first_cached_diff = H.normalize_diff(H.git(repo, "diff", "--cached", "--", "test.txt"))

    H.apply_case_state(repo, case, 2)
    nvim.cmd("edit!")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.lua_func(function()
        local spotlight = require("delta.spotlight.core")
        local actions = require("delta").spotlight.actions
        local setup_global_keymaps = _G.find_upvalue(spotlight.setup, "setup_global_keymaps")
        local make_context = _G.find_upvalue(setup_global_keymaps, "make_context")

        vim.api.nvim_win_set_cursor(0, { 8, 0 })
        vim.cmd("normal! Vj")
        actions.toggle_stage_hunk(make_context(vim.api.nvim_get_current_buf()))
    end)

    H.nvim_wait_for(nvim, string.format([[ (function()
        local out = vim.system({ 'git', 'diff', '--cached', '--', 'test.txt' }, { text = true }):wait().stdout or ''
        local lines = vim.split(out, '\n', { plain = true })
        local normalized = {}
        for _, line in ipairs(lines) do
            if not line:match('^index ') then
                normalized[#normalized + 1] = line
            end
        end
        return table.concat(normalized, '\n') ~= %q
    end)()]], first_cached_diff), 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "test.txt", false, true, 5000, 20)

    local cached_diff = H.normalize_diff(H.git(repo, "diff", "--cached", "--", "test.txt"))
    local worktree_diff = H.normalize_diff(H.git(repo, "diff", "--", "test.txt"))

    H.write_case_actual(case, "cached.diff", cached_diff)
    H.write_case_actual(case, "worktree.diff", worktree_diff)

    H.eq(cached_diff, H.read_case_fixture(case, "result/expected/cached.diff"))
    H.eq(worktree_diff, H.read_case_fixture(case, "result/expected/worktree.diff"))
end

return T
