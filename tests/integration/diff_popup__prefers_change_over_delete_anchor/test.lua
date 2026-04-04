local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["popup selects change hunk over overlapping delete anchor"] = function()
    local case = "diff_popup__prefers_change_over_delete_anchor"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    local popup_hunk = nvim.lua_func(function()
        local Diff = require("delta.spotlight.diff")
        local _, resolve_current_hunk_opts = debug.getupvalue(Diff.open, 4)
        assert(type(resolve_current_hunk_opts) == "function", "failed to resolve popup hunk helper")

        vim.api.nvim_win_set_cursor(0, { 2, 0 })

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
            target = hunk:target(resolved.side),
            added_count = hunk.added.count,
            removed_count = hunk.removed.count,
        }
    end)

    H.eq(popup_hunk, {
        type = "change",
        start_line = 2,
        end_line = 2,
        target = 2,
        added_count = 1,
        removed_count = 1,
    })
end

return T
