local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["does nothing for staged-only hunk"] = function()
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

    local before_cached = H.normalize_diff(H.git(repo, "diff", "--cached", "--", "file.txt"))
    local before_worktree = H.normalize_diff(H.git(repo, "diff", "--", "file.txt"))

    nvim.api.nvim_win_set_cursor(0, { 2, 0 })
    nvim.lua_notify([[require('delta').spotlight.reset_hunk()]])

    H.nvim_wait_for_delta_file_state(nvim)

    local after_cached = H.normalize_diff(H.git(repo, "diff", "--cached", "--", "file.txt"))
    local after_worktree = H.normalize_diff(H.git(repo, "diff", "--", "file.txt"))

    H.eq(after_cached, before_cached)
    H.eq(after_worktree, before_worktree)
end

return T
