local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["stages deletion of worktree-removed staged line"] = function()
    local case = "toggle_stage_hunk__deleted_line_after_staged_add"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    -- Step 1: add -- bar
    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    -- Stage the added -- bar line
    nvim.api.nvim_win_set_cursor(0, { 7, 0 })
    nvim.lua_notify([[require('delta').spotlight.toggle_stage_hunk()]])

    H.nvim_wait_for_git_diff(nvim, "test.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "test.txt", false, false, 5000, 20)

    -- Step 2: delete -- bar from worktree
    H.apply_case_state(repo, case, 2)
    nvim.cmd("edit!")

    H.nvim_wait_for_git_diff(nvim, "test.txt", false, true, 5000, 20)
    H.nvim_wait_for_delta_file_state(nvim)

    -- Stage the deletion
    nvim.api.nvim_win_set_cursor(0, { 7, 0 })
    nvim.lua_notify([[require('delta').spotlight.toggle_stage_hunk()]])

    H.nvim_wait_for_git_diff(nvim, "test.txt", true, false, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "test.txt", false, false, 5000, 20)

    local cached_diff = H.normalize_diff(H.git(repo, "diff", "--cached", "--", "test.txt"))
    local worktree_diff = H.normalize_diff(H.git(repo, "diff", "--", "test.txt"))

    H.write_case_actual(case, "cached.diff", cached_diff)
    H.write_case_actual(case, "worktree.diff", worktree_diff)

    H.eq(cached_diff, H.read_case_fixture(case, "result/expected/cached.diff"))
    H.eq(worktree_diff, H.read_case_fixture(case, "result/expected/worktree.diff"))
end

return T
