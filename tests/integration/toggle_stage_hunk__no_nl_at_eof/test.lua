local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["stages hunk with no newline at EOF"] = function()
    local case = "toggle_stage_hunk__no_nl_at_eof"
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
    nvim.lua_notify([[require('delta.spotlight.core').toggle_stage_hunk()]])

    H.nvim_wait_for_git_diff(nvim, "test.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "test.txt", false, false, 5000, 20)

    local cached_diff = H.normalize_diff(H.git(repo, "diff", "--cached", "--", "test.txt"))
    local worktree_diff = H.normalize_diff(H.git(repo, "diff", "--", "test.txt"))

    H.write_case_actual(case, "cached.diff", cached_diff)
    H.write_case_actual(case, "worktree.diff", worktree_diff)

    H.eq(cached_diff, H.read_case_fixture(case, "result/expected/cached.diff"))
    H.eq(worktree_diff, H.read_case_fixture(case, "result/expected/worktree.diff"))
end

return T
