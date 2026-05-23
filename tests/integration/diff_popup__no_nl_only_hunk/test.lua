local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["popup resolves newline-at-EOF-only hunk"] = function()
    local repo = H.tmpdir()
    H.finally_rm(repo)

    H.git(repo, "init")
    H.git(repo, "config", "user.name", "delta-tests")
    H.git(repo, "config", "user.email", "delta-tests@nvim.com")

    vim.fn.writefile({ "line" }, repo .. "/test.txt", "b")
    H.git(repo, "add", ".")
    H.git(repo, "commit", "-m", "initial")
    vim.fn.writefile({ "line" }, repo .. "/test.txt")

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim, [[function(file)
        return #file.raw_hunks.unstaged == 1 and #file.visible_hunks.unstaged == 1
    end]], 5000, 20)

    local popup_hunk = nvim.lua_func(function()
        local Diff = require("delta.spotlight.diff")
        local resolve_current_hunk_opts = _G.find_upvalue(Diff.open, "resolve_current_hunk_opts")
        assert(type(resolve_current_hunk_opts) == "function", "failed to resolve popup hunk helper")

        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        local resolved, err = resolve_current_hunk_opts({
            winid = vim.api.nvim_get_current_win(),
            bufid = vim.api.nvim_get_current_buf(),
        })
        assert(resolved, err)

        local hunk = resolved.hunk
        return {
            type = hunk.type,
            start_line = hunk:start_line(resolved.side),
            end_line = hunk:end_line(resolved.side),
            added_count = hunk.added.count,
            removed_count = hunk.removed.count,
            added_no_nl = hunk.added.no_nl_at_eof or false,
            removed_no_nl = hunk.removed.no_nl_at_eof or false,
            added_lines = hunk.added.lines,
            removed_lines = hunk.removed.lines,
        }
    end)

    H.eq(popup_hunk, {
        type = "change",
        start_line = 1,
        end_line = 1,
        added_count = 1,
        removed_count = 1,
        added_no_nl = false,
        removed_no_nl = true,
        added_lines = { "line" },
        removed_lines = { "line" },
    })
end

return T
