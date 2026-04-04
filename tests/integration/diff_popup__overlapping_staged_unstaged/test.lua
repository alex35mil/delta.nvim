local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["prefers overlapping unstaged hunk over staged hunk"] = function()
    local case = "diff_popup__overlapping_staged_unstaged"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    nvim.api.nvim_win_set_cursor(0, { 7, 0 })
    nvim.lua_notify([[require('delta.spotlight.core').toggle_stage_hunk()]])

    H.nvim_wait_for_git_diff(nvim, "test.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "test.txt", false, false, 5000, 20)

    H.apply_case_state(repo, case, 2)
    nvim.cmd("edit!")

    H.nvim_wait_for_git_diff(nvim, "test.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "test.txt", false, true, 5000, 20)

    local ready = nvim.lua_func(function()
        local toggle = require("delta.spotlight.core").toggle_stage_hunk
        local file_for_buf = _G.find_upvalue(toggle, "file_for_buf")
        assert(type(file_for_buf) == "function", "failed to resolve file_for_buf upvalue")

        return vim.wait(5000, function()
            local file = file_for_buf(vim.api.nvim_get_current_buf())
            return file ~= nil
                and file.path ~= ""
                and file.raw_hunks ~= nil
                and #file.raw_hunks.staged == 1
                and #file.raw_hunks.unstaged == 1
        end, 20)
    end)
    assert(ready, "timed out waiting for overlapping staged/unstaged hunks")

    nvim.api.nvim_win_set_cursor(0, { 7, 0 })

    local resolved = nvim.lua_func(function()
        local diff = require("delta.spotlight.diff")
        local resolve_current_hunk_opts = _G.find_upvalue(diff.open, "resolve_current_hunk_opts")
        assert(type(resolve_current_hunk_opts) == "function", "failed to resolve popup hunk selector")

        local opts, err = resolve_current_hunk_opts()
        assert(opts ~= nil, err or "failed to resolve popup hunk")

        return {
            type = opts.hunk.type,
            added_count = opts.hunk.added.count,
            removed_count = opts.hunk.removed.count,
        }
    end)

    H.eq(resolved.type, "delete")
    H.eq(resolved.added_count, 0)
    H.eq(resolved.removed_count, 1)
end

return T
