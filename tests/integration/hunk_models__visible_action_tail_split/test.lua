local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["builds distinct raw, visible, and action hunks for a visible/action tail split"] = function()
    local case = "hunk_models__visible_action_tail_split"
    local repo = H.init_repo_from_case(case)
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.apply_case_state(repo, case, 1)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])
    H.nvim_edit(nvim, repo .. "/test.txt")
    H.nvim_wait_for_delta_file_state(nvim)

    local models = nvim.lua_func(function()
        local toggle = require("delta.spotlight.core").toggle_stage_hunk
        local file_for_buf

        for idx = 1, 20 do
            local name, value = debug.getupvalue(toggle, idx)
            if name == "file_for_buf" then
                file_for_buf = value
                break
            end
        end

        assert(type(file_for_buf) == "function", "failed to resolve file_for_buf upvalue")

        local file = file_for_buf(vim.api.nvim_get_current_buf())
        assert(file and file.kind == "managed", "expected managed spotlight file state")

        local function summarize(hunks)
            local out = {}
            for _, hunk in ipairs(hunks or {}) do
                out[#out + 1] = {
                    type = hunk.type,
                    start_line = hunk:start_line(),
                    end_line = hunk:end_line(),
                    target = hunk:target(),
                    added_start = hunk.added.start,
                    added_count = hunk.added.count,
                    removed_start = hunk.removed.start,
                    removed_count = hunk.removed.count,
                }
            end
            return out
        end

        return {
            raw = summarize(file.raw_hunks.unstaged),
            visible = summarize(file.visible_hunks.unstaged),
            action = summarize(file.action_hunks.unstaged),
        }
    end)

    H.eq(models.raw, {
        {
            type = "delete",
            start_line = 1,
            end_line = 1,
            target = 1,
            added_start = 1,
            added_count = 0,
            removed_start = 2,
            removed_count = 6,
        },
        {
            type = "change",
            start_line = 4,
            end_line = 4,
            target = 4,
            added_start = 4,
            added_count = 1,
            removed_start = 10,
            removed_count = 1,
        },
        {
            type = "add",
            start_line = 7,
            end_line = 15,
            target = 7,
            added_start = 7,
            added_count = 9,
            removed_start = 12,
            removed_count = 0,
        },
    })

    H.eq(models.visible, {
        {
            type = "change",
            start_line = 2,
            end_line = 2,
            target = 2,
            added_start = 2,
            added_count = 1,
            removed_start = 2,
            removed_count = 1,
        },
        {
            type = "change",
            start_line = 5,
            end_line = 5,
            target = 5,
            added_start = 5,
            added_count = 1,
            removed_start = 5,
            removed_count = 1,
        },
        {
            type = "change",
            start_line = 8,
            end_line = 8,
            target = 8,
            added_start = 8,
            added_count = 1,
            removed_start = 8,
            removed_count = 1,
        },
        {
            type = "change",
            start_line = 11,
            end_line = 11,
            target = 11,
            added_start = 11,
            added_count = 1,
            removed_start = 11,
            removed_count = 1,
        },
        {
            type = "add",
            start_line = 12,
            end_line = 14,
            target = 12,
            added_start = 12,
            added_count = 3,
            removed_start = 11,
            removed_count = 0,
        },
    })

    H.eq(models.action, {
        {
            type = "change",
            start_line = 2,
            end_line = 2,
            target = 2,
            added_start = 2,
            added_count = 1,
            removed_start = 2,
            removed_count = 1,
        },
        {
            type = "change",
            start_line = 5,
            end_line = 5,
            target = 5,
            added_start = 5,
            added_count = 1,
            removed_start = 5,
            removed_count = 1,
        },
        {
            type = "change",
            start_line = 8,
            end_line = 8,
            target = 8,
            added_start = 8,
            added_count = 1,
            removed_start = 8,
            removed_count = 1,
        },
        {
            type = "change",
            start_line = 11,
            end_line = 14,
            target = 11,
            added_start = 11,
            added_count = 4,
            removed_start = 11,
            removed_count = 1,
        },
    })
end

return T
