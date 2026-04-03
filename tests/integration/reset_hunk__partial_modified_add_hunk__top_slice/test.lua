local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["resets selected top slice from modified+add hunk"] = function()
    local case = "reset_hunk__partial_modified_add_hunk__top_slice"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup({ reset = { confirm = false } })]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.lua_func(function()
        local spotlight = require("delta").spotlight
        local actions = spotlight.actions

        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        vim.cmd("normal! Vj")
        actions.reset_hunk(spotlight.context())
    end)

    H.nvim_wait_for_git_diff_eq(
        nvim,
        "test.txt",
        false,
        H.read_case_fixture(case, "result/expected/worktree.diff"),
        5000,
        20
    )

    local cached_diff = H.normalize_diff(H.git(repo, "diff", "--cached", "--", "test.txt"))
    local worktree_diff = H.normalize_diff(H.git(repo, "diff", "--", "test.txt"))

    H.write_case_actual(case, "cached.diff", cached_diff)
    H.write_case_actual(case, "worktree.diff", worktree_diff)

    H.eq(cached_diff, H.read_case_fixture(case, "result/expected/cached.diff"))
    H.eq(worktree_diff, H.read_case_fixture(case, "result/expected/worktree.diff"))
end

return T
