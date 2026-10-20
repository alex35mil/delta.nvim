local T = MiniTest.new_set()
local H = require("tests.support.helpers")

local function nested_repo()
    local parent = H.init_repo({ ["file.txt"] = { "parent old" }, ["other.txt"] = { "parent other" } })
    local temp = H.init_repo({ ["file.txt"] = { "one", "two", "three" }, ["other.txt"] = { "child other" } })
    H.finally_rm(parent)
    H.finally_rm(temp)
    local child = parent .. "/nested"
    assert(vim.fn.rename(temp, child) == 0)
    H.write_file(parent .. "/.gitignore", { "nested/" })
    H.git(parent, "add", ".gitignore")
    H.git(parent, "commit", "-m", "ignore nested")
    H.write_file(child .. "/file.txt", { "one", "two changed", "three" })
    return vim.uv.fs_realpath(parent), vim.uv.fs_realpath(child)
end

local function start(parent)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, parent)
    nvim.lua([[
        _G.errors = {}
        vim.notify = function(msg, level)
            if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
        end
        _G.picker_state = function()
            return find_upvalue(require('delta.picker.ui').show, 'state')
        end
        _G.file_state = function(buf)
            return find_upvalue(require('delta.spotlight.core').toggle_stage_hunk, 'file_for_buf')(
                buf or vim.api.nvim_get_current_buf()
            )
        end
        _G.git_call = function(fn)
            local done, result, failure = false
            require('delta.git').async(function()
                local ok, value = pcall(fn)
                if ok then result = value else failure = value end
                done = true
            end)
            assert(vim.wait(5000, function() return done end, 10), vim.inspect(errors))
            assert(not failure, failure)
            return result
        end
        require('delta').setup({
            reset = { confirm = false },
            spotlight = {
                actions = {
                    test_global_hunk = {
                        'X', require('delta.spotlight.actions').toggle_stage_hunk, global = true,
                    },
                },
            },
            picker = {
                initial_mode = 'n',
                actions = {
                    test_stage = { 'x', function(ctx) ctx.toggle_stage() end },
                    test_reset = { 'z', function(ctx) ctx.reset() end },
                },
            },
            diff = { file = { keys = { toggle_stage_file = 's', reset_file = 'r', close = 'q' } } },
        })
    ]])
    return nvim
end

local function wait_picker(nvim)
    H.nvim_wait_for(nvim, "picker_state() and picker_state().phase == 'ready'", 5000, 10)
end

local function capture_action(nvim, action)
    nvim.lua_func(function(name)
        local state = picker_state()
        -- Use configured public keymaps, as an end user does.
        local lhs = ({ stage = "x", reset = "z", open = "<CR>" })[name]
        local expected = vim.api.nvim_replace_termcodes(lhs, true, true, true)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.input_buf, "n")) do
            if map.lhs == lhs or map.lhs == expected then
                map.callback()
                return
            end
        end
        error("missing picker action: " .. name)
    end, action)
end

T["Git file references read and mutate the child with parent cwd"] = function()
    local parent, child = nested_repo()
    local nvim = start(parent)
    local result = nvim.lua_func(function(path)
        return git_call(function()
            local Git = require("delta.git")
            local cwd = vim.fn.getcwd()
            local ok, file = Git.resolve_file(path)
            assert(ok)
            local status_ok, status = Git.file_status(file)
            local head_ok, head = Git.get_head_lines(file)
            local index_ok, index = Git.get_index_lines(file)
            local work_ok, work = Git.get_worktree_lines(file)
            local patch_ok, header, hunks = Git.get_patch_data(file, false)
            assert(status_ok and head_ok and index_ok and work_ok and patch_ok)
            local patch = Git.build_hunk_patch(header, hunks[1])
            assert(Git.apply_patch(file.repo, patch))
            assert(Git.apply_patch(file.repo, patch, { reverse = true }))
            assert(Git.stage(file))
            assert(Git.unstage(file))
            assert(Git.reset_file(file, "index"))
            assert(vim.fn.getcwd() == cwd)
            return { file = file, status = status:key(), head = head, index = index, work = work }
        end)
    end, child .. "/file.txt")
    H.eq(result.file.repo.root, child)
    H.eq(result.file.path, "file.txt")
    H.eq(result.status, " M")
    H.eq(result.head, { "one", "two", "three" })
    H.eq(result.index, result.head)
    H.eq(result.work, { "one", "two changed", "three", "" })
    H.eq(H.git(parent, "diff"), "")
    H.eq(H.git(parent, "diff", "--cached"), "")
    H.eq(H.git(child, "diff"), "")
    H.eq(H.git(child, "diff", "--cached"), "")
end

T["picker selects the invoking file and stays pinned across cwd changes"] = function()
    local parent, child = nested_repo()
    H.write_file(parent .. "/file.txt", { "parent changed" })
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    H.nvim_wait_for_delta_file_state(nvim)
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), child)
    H.eq(nvim.lua_get("picker_state().unstaged[1].path"), "file.txt")
    local elsewhere = H.init_repo({ ["file.txt"] = { "unrelated" } })
    H.finally_rm(elsewhere)
    H.nvim_set_cwd(nvim, elsewhere)
    capture_action(nvim, "stage")
    H.nvim_wait_for(nvim, "picker_state() and #picker_state().staged == 1", 5000, 10)
    assert(H.git(child, "diff", "--cached"):find("two changed", 1, true))
    H.eq(H.git(parent, "diff", "--cached"), "")
    nvim.lua("require('delta.picker').close()")
    H.nvim_edit(nvim, parent .. "/file.txt")
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), parent)
    H.eq(nvim.lua_get("picker_state().unstaged[1].path"), "file.txt")
    H.eq(nvim.lua_get("errors"), {})
end

T["Spotlight hunk actions use the child and isolate same-named parent files"] = function()
    local parent, child = nested_repo()
    H.write_file(parent .. "/file.txt", { "parent changed" })
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    H.nvim_wait_for_delta_file_state(nvim)
    nvim.api.nvim_win_set_cursor(0, { 2, 0 })
    nvim.lua_notify("require('delta.spotlight.core').toggle_stage_hunk()")
    H.nvim_wait_for(nvim, "#errors == 0 and file_state() and #file_state().raw_hunks.staged > 0", 5000, 10)
    assert(H.git(child, "diff", "--cached"):find("two changed", 1, true))
    H.eq(H.git(parent, "diff", "--cached"), "")
    H.eq(H.git(child, "diff"), "")
    H.eq(nvim.lua_get("errors"), {})
end

T["file diff captures the child repository through tab creation and staging"] = function()
    local parent, child = nested_repo()
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    nvim.lua_notify("require('delta.diff').open_file()")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 10)
    H.eq(
        nvim.lua_get(
            "vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[1]), 0, -1, false)"
        ),
        { "one", "two", "three" }
    )
    local elsewhere = H.init_repo({ ["file.txt"] = { "unrelated" } })
    H.finally_rm(elsewhere)
    H.nvim_set_cwd(nvim, elsewhere)
    nvim.api.nvim_input("s")
    nvim.lua([[
        local tabs = find_upvalue(require('delta.diff.file').close, 'tabs')
        _G.wait_diff_mode = function(mode)
            assert(vim.wait(5000, function()
                local state = tabs[vim.api.nvim_get_current_tabpage()]
                return state and state.resolved_mode == mode and not state.mutating
            end, 10), vim.inspect(errors))
        end
        wait_diff_mode('staged')
    ]])
    assert(H.git(child, "diff", "--cached"):find("two changed", 1, true))
    nvim.api.nvim_input("s")
    nvim.lua("wait_diff_mode('unstaged')")
    H.eq(H.git(child, "diff", "--cached"), "")
    nvim.api.nvim_input("s")
    nvim.lua("wait_diff_mode('staged')")
    nvim.api.nvim_input("r")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 10)
    H.eq(vim.fn.readfile(child .. "/file.txt"), { "one", "two", "three" })
    H.eq(H.git(child, "diff", "--cached"), "")
    H.eq(H.git(parent, "diff", "--cached"), "")
    H.eq(H.git(elsewhere, "diff", "--cached"), "")
    H.eq(nvim.lua_get("errors"), {})
end

T["unnamed buffers fall back to cwd and removed directories still resolve"] = function()
    local parent, child = nested_repo()
    local nvim = start(parent)
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), parent)
    local result = nvim.lua_func(function(path)
        return git_call(function()
            local ok, file = require("delta.git").resolve_file(path)
            assert(ok)
            return file
        end)
    end, child .. "/removed/deep/file.txt")
    H.eq(result.repo.root, child)
    H.eq(result.path, "removed/deep/file.txt")
end

for _, kind in ipairs({ "submodule", "worktree" }) do
    T[kind .. " discovery and mutations use the checkout's Git directory"] = function()
        local parent = H.init_repo({ ["file.txt"] = { "parent old" } })
        H.finally_rm(parent)
        parent = vim.uv.fs_realpath(parent)
        local checkout = parent .. "/checkout"
        if kind == "submodule" then
            local source = H.init_repo({ ["file.txt"] = { "child old" } })
            H.finally_rm(source)
            H.git(parent, "-c", "protocol.file.allow=always", "submodule", "add", source, "checkout")
            H.git(parent, "commit", "-m", "add submodule")
        else
            H.git(parent, "worktree", "add", "-b", "nested-review", checkout)
        end
        H.write_file(checkout .. "/file.txt", { "child changed" })
        local nvim = start(parent)
        local result = nvim.lua_func(function(path)
            return git_call(function()
                local Git = require("delta.git")
                local ok, file = Git.resolve_file(path)
                assert(ok)
                assert(Git.stage(file))
                return file
            end)
        end, checkout .. "/file.txt")
        H.eq(result.repo.root, checkout)
        H.eq(result.repo.gitdir, vim.trim(H.git(checkout, "rev-parse", "--absolute-git-dir")))
        H.eq(vim.uv.fs_stat(checkout .. "/.git").type, "file")
        assert(H.git(checkout, "diff", "--cached"):find("child changed", 1, true))
        H.eq(H.git(parent, "diff", "--cached"), "")
        H.nvim_edit(nvim, checkout .. "/file.txt")
        nvim.lua("require('delta.picker').show()")
        wait_picker(nvim)
        H.eq(nvim.lua_get("picker_state().repo.root"), checkout)
        H.eq(nvim.lua_get("picker_state().staged[1].path"), "file.txt")
        H.eq(nvim.lua_get("errors"), {})
    end
end

for _, content in ipairs({ "staged", "deleted" }) do
    T[content .. " scratch buffers preserve the nested repository for picker handoff"] = function()
        local parent, child = nested_repo()
        if content == "staged" then
            H.git(child, "add", "file.txt")
            H.write_file(child .. "/file.txt", { "one changed", "two changed", "three" })
        else
            H.git(child, "rm", "-f", "file.txt")
        end
        local nvim = start(parent)
        H.nvim_edit(nvim, child .. "/file.txt")
        nvim.lua("require('delta.picker').show()")
        wait_picker(nvim)
        nvim.lua([[
            local state = picker_state()
            for i, node in ipairs(state.nodes) do
                if node and node.path == 'file.txt' and node.section == 'staged' then
                    state.cursor_idx = i
                    return
                end
            end
            error('staged node missing')
        ]])
        capture_action(nvim, "open")
        nvim.lua([[
            assert(vim.wait(5000, function()
                return require('delta.repository').buffer_file(vim.api.nvim_get_current_buf()) ~= nil
            end, 10), vim.inspect({
                errors = errors,
                buffer = vim.api.nvim_buf_get_name(0),
                normalized = require('delta.spotlight.paths').normalize(vim.api.nvim_buf_get_name(0)),
                file = file_state(),
            }))
        ]])
        H.eq(nvim.lua_get("require('delta.repository').buffer_file(vim.api.nvim_get_current_buf()).repo.root"), child)
        assert(nvim.lua_get("vim.api.nvim_buf_get_name(0)"):find("delta://" .. content .. "/", 1, true))
        nvim.lua("require('delta.picker').show()")
        wait_picker(nvim)
        H.eq(nvim.lua_get("picker_state().repo.root"), child)
        H.eq(nvim.lua_get("errors"), {})
    end
end

T["picker from a side-by-side diff keeps the underlying nested repository"] = function()
    local parent, child = nested_repo()
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    nvim.lua_notify("require('delta.diff').open_file()")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 10)
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), child)
    H.eq(nvim.lua_get("picker_state().unstaged[1].path"), "file.txt")
    H.eq(nvim.lua_get("errors"), {})
end

T["sources, absolute preselection, and preview use the selected repository"] = function()
    local parent, child = nested_repo()
    H.write_file(child .. "/other.txt", { "child other changed" })
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    nvim.lua_func(function(repo, outer)
        require("delta.config").options.picker.layout.preview.enabled = true
        require("delta.picker").show({
            source = { label = "Review", files = { "other.txt", repo .. "/file.txt", outer .. "/file.txt" } },
            preselect_path = repo .. "/other.txt",
        })
    end, child, parent)
    wait_picker(nvim)
    H.eq(nvim.lua_get("#picker_state().unstaged"), 2)
    H.eq(nvim.lua_get("picker_state().nodes[picker_state().cursor_idx].path"), "other.txt")
    H.eq(
        nvim.lua_get(
            "vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require('delta.picker.preview').get_win()), 0, -1, false)"
        ),
        { "child other changed" }
    )
    capture_action(nvim, "open")
    H.eq(nvim.lua_get("require('delta.repository').buffer_path(vim.api.nvim_get_current_buf())"), child .. "/other.txt")
    H.eq(nvim.lua_get("vim.fn.getcwd()"), parent)
    H.eq(nvim.lua_get("errors"), {})
end

T["automatic reopen after staging stays in the child's source and repository"] = function()
    local parent, child = nested_repo()
    H.write_file(child .. "/other.txt", { "next child change" })
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    H.nvim_wait_for_delta_file_state(nvim)
    nvim.lua([[
        require('delta.config').options.spotlight.reopen_picker_after_stage = true
        require('delta.spotlight').ensure()
    ]])
    local elsewhere = H.init_repo({ ["file.txt"] = { "unrelated" } })
    H.finally_rm(elsewhere)
    H.nvim_set_cwd(nvim, elsewhere)
    nvim.lua_notify("require('delta.spotlight.core').toggle_stage_file()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), child)
    H.eq(nvim.lua_get("picker_state().nodes[picker_state().cursor_idx].path"), "other.txt")
    H.eq(H.git(parent, "diff", "--cached"), "")
    H.eq(H.git(elsewhere, "diff", "--cached"), "")
    H.eq(nvim.lua_get("errors"), {})
end

for _, action in ipairs({ "toggle_stage_hunk", "reset_hunk" }) do
    T["nested partial " .. action .. " uses the child baseline"] = function()
        local parent, child = nested_repo()
        H.write_file(child .. "/file.txt", { "one changed", "two changed", "three" })
        local nvim = start(parent)
        H.nvim_edit(nvim, child .. "/file.txt")
        H.nvim_wait_for_delta_file_state(nvim)
        nvim.lua_func(function(name)
            require("delta.spotlight.core")[name](nil, 1, 1)
        end, action)
        if action == "toggle_stage_hunk" then
            H.nvim_wait_for(nvim, "file_state() and #file_state().raw_hunks.staged == 1", 5000, 10)
            H.eq(H.git(child, "show", ":file.txt"), "one changed\ntwo\nthree\n")
        else
            H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'one'", 5000, 10)
            H.eq(vim.fn.readfile(child .. "/file.txt"), { "one", "two changed", "three" })
        end
        H.eq(H.git(parent, "diff"), "")
        H.eq(H.git(parent, "diff", "--cached"), "")
        H.eq(nvim.lua_get("errors"), {})
    end
end

T["watcher refreshes preserve both visible repositories with the same relative filename"] = function()
    local parent, child = nested_repo()
    H.write_file(parent .. "/file.txt", { "parent changed" })
    local nvim = start(parent)
    H.nvim_edit(nvim, parent .. "/file.txt")
    H.nvim_wait_for_delta_file_state(nvim)
    nvim.lua("require('delta.spotlight').ensure(); parent_buf = vim.api.nvim_get_current_buf(); vim.cmd('vsplit')")
    H.nvim_edit(nvim, child .. "/file.txt")
    H.nvim_wait_for_delta_file_state(nvim)
    nvim.lua("require('delta.spotlight').ensure(); child_buf = vim.api.nvim_get_current_buf()")
    H.git(child, "add", "file.txt")
    H.nvim_wait_for(
        nvim,
        "file_state(child_buf).status:has_staged() and file_state(parent_buf).status:has_unstaged()",
        5000,
        10
    )
    H.eq(nvim.lua_get("file_state(parent_buf).file.repo.root"), parent)
    H.eq(nvim.lua_get("file_state(child_buf).file.repo.root"), child)
    H.eq(nvim.lua_get("file_state(parent_buf).status:has_staged()"), false)
    H.eq(H.git(parent, "diff", "--cached"), "")
    H.eq(nvim.lua_get("errors"), {})
end

T["missing repositories close loading and discovery errors do not fall back"] = function()
    local no_repo = H.tmpdir()
    H.finally_rm(no_repo)
    local nvim = start(no_repo)
    nvim.lua("require('delta.picker').show()")
    H.nvim_wait_for(nvim, "not require('delta.picker').is_open()", 5000, 10)
    H.eq(nvim.lua_get("#vim.api.nvim_list_wins()"), 1)
    local parent, child = nested_repo()
    H.write_file(child .. "/.git/config", { "invalid git configuration" })
    local result = nvim.lua_func(function(path, cwd)
        return git_call(function()
            local ok, repo, err = require("delta.git").select_repository(path, cwd)
            return { ok = ok, repo = repo, err = err }
        end)
    end, child .. "/file.txt", parent)
    H.eq(result.ok, false)
    H.eq(result.repo, nil)
    H.eq(result.err, nil)
    H.eq(nvim.lua_get("#errors"), 1)
    assert(nvim.lua_get("errors[1]"):find("config", 1, true))
end

T["directory stage and reset ignore unsaved same-named files in the parent"] = function()
    local parent, child = nested_repo()
    for _, repo in ipairs({ parent, child }) do
        H.write_file(repo .. "/dir/a.txt", { "old a" })
        H.write_file(repo .. "/dir/b.txt", { "old b" })
        H.git(repo, "add", "dir")
        H.git(repo, "commit", "-m", "add directory")
    end
    H.write_file(child .. "/dir/a.txt", { "new a" })
    H.write_file(child .. "/dir/b.txt", { "new b" })
    local nvim = start(parent)
    H.nvim_edit(nvim, parent .. "/dir/a.txt")
    nvim.lua([[
        parent_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(parent_buf, 0, -1, false, { 'unsaved parent' })
        vim.cmd('vsplit')
        vim.fn.confirm = function() return 1 end
    ]])
    H.nvim_edit(nvim, child .. "/dir/a.txt")
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    local function select_directory(section)
        nvim.lua_func(function(wanted)
            for i, node in ipairs(picker_state().nodes) do
                if node and node.path == "dir" and node.is_dir and node.section == wanted then
                    picker_state().cursor_idx = i
                    return
                end
            end
            error("directory missing: " .. wanted)
        end, section)
    end
    select_directory("unstaged")
    capture_action(nvim, "stage")
    H.nvim_wait_for(nvim, "#picker_state().staged == 2", 5000, 10)
    select_directory("staged")
    capture_action(nvim, "reset")
    H.nvim_wait_for(nvim, "#picker_state().staged == 0", 5000, 10)
    H.eq(vim.fn.readfile(child .. "/dir/a.txt"), { "old a" })
    H.eq(vim.fn.readfile(child .. "/dir/b.txt"), { "old b" })
    H.eq(nvim.lua_get("vim.api.nvim_buf_get_lines(parent_buf, 0, -1, false)"), { "unsaved parent" })
    H.eq(nvim.lua_get("vim.bo[parent_buf].modified"), true)
    H.eq(H.git(parent, "diff", "--cached"), "")
    H.eq(H.git(parent, "diff"), "")
    H.eq(nvim.lua_get("errors"), {})
end

T["files outside repositories and non-file buffers use picker cwd fallback"] = function()
    local parent, child = nested_repo()
    local outside = H.tmpdir()
    H.finally_rm(outside)
    H.write_file(outside .. "/file.txt", { "outside" })
    local nvim = start(parent)
    H.nvim_edit(nvim, outside .. "/file.txt")
    H.nvim_wait_for(nvim, "file_state() and file_state().status == 'outsider'", 5000, 10)
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), parent)
    nvim.lua("require('delta.picker').close()")
    H.nvim_edit(nvim, child .. "/other.txt")
    nvim.lua("vim.bo.buftype = 'nofile'; require('delta.picker').show()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), parent)
    H.eq(nvim.lua_get("errors"), {})
end

T["picker split opening and explicit relative diff targets preserve cwd semantics"] = function()
    local parent, child = nested_repo()
    local nvim = start(parent)
    H.nvim_edit(nvim, parent .. "/file.txt")
    nvim.lua_notify("require('delta.diff').open_file({ path = 'nested/file.txt' })")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 10)
    H.eq(nvim.lua_get("require('delta.repository').buffer_file(vim.api.nvim_get_current_buf()).repo.root"), child)
    nvim.lua([[
        require('delta.diff').close_file()
        require('delta.config').options.picker.actions.test_split = {
            'v', require('delta.picker.actions').open_vsplit,
        }
    ]])
    H.nvim_edit(nvim, child .. "/file.txt")
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    nvim.lua([[
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(picker_state().input_buf, 'n')) do
            if map.lhs == 'v' then map.callback(); return end
        end
        error('split action missing')
    ]])
    H.eq(nvim.lua_get("#vim.api.nvim_list_wins()"), 2)
    H.eq(nvim.lua_get("require('delta.repository').buffer_path(vim.api.nvim_get_current_buf())"), child .. "/file.txt")
    H.eq(nvim.lua_get("vim.fn.getcwd()"), parent)
    H.eq(nvim.lua_get("errors"), {})
end

T["staged deletion resolves a missing index blob to empty lines"] = function()
    local parent, child = nested_repo()
    H.git(child, "rm", "-f", "file.txt")
    local nvim = start(parent)
    local lines = nvim.lua_func(function(path)
        return git_call(function()
            local Git = require("delta.git")
            local found, file = Git.resolve_file(path)
            assert(found)
            local ok, result, err = Git.get_index_lines(file)
            assert(ok, err)
            return result
        end)
    end, child .. "/file.txt")
    H.eq(lines, {})
end

T["unignored independent nested checkouts are selected without combining repositories"] = function()
    local parent, child = nested_repo()
    H.git(parent, "rm", ".gitignore")
    H.git(parent, "commit", "-m", "unignore nested")
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    H.eq(nvim.lua_get("picker_state().repo.root"), child)
    H.eq(nvim.lua_get("#picker_state().unstaged"), 1)
    H.eq(nvim.lua_get("picker_state().unstaged[1].path"), "file.txt")
    local paths = nvim.lua_func(function(root)
        return git_call(function()
            local Git = require("delta.git")
            local found, repo = Git.resolve_repository(root)
            assert(found)
            local ok, files = Git.get_changed_files(repo)
            assert(ok)
            return vim.tbl_map(function(entry)
                return entry.path
            end, files.unstaged)
        end)
    end, parent)
    H.eq(paths, { "nested" })
    H.eq(nvim.lua_get("errors"), {})
end

T["window-local cwd does not redirect picker mutations"] = function()
    local parent, child = nested_repo()
    local elsewhere = H.init_repo({ ["file.txt"] = { "unrelated" } })
    H.finally_rm(elsewhere)
    elsewhere = vim.uv.fs_realpath(elsewhere)
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    nvim.lua("require('delta.picker').show()")
    wait_picker(nvim)
    nvim.lua_func(function(dir)
        vim.cmd("lcd " .. vim.fn.fnameescape(dir))
    end, elsewhere)
    capture_action(nvim, "stage")
    H.nvim_wait_for(nvim, "#picker_state().staged == 1", 5000, 10)
    assert(H.git(child, "diff", "--cached"):find("two changed", 1, true))
    H.eq(H.git(parent, "diff", "--cached"), "")
    H.eq(H.git(elsewhere, "diff", "--cached"), "")
    H.eq(nvim.lua_get("vim.fn.getcwd()"), elsewhere)
end

T["untracked reset deletes only the nested file and undo hints retain repository context"] = function()
    local parent, child = nested_repo()
    H.write_file(parent .. "/new.txt", { "keep parent" })
    H.write_file(child .. "/new.txt", { "delete child" })
    local nvim = start(parent)
    local hint = nvim.lua_func(function(path)
        return git_call(function()
            local Git = require("delta.git")
            local found, file = Git.resolve_file(path)
            assert(found)
            local ok, undo, err = Git.reset_file(file, "delete")
            assert(ok, err)
            return undo
        end)
    end, child .. "/new.txt")
    H.eq(vim.uv.fs_stat(child .. "/new.txt"), nil)
    H.eq(vim.fn.readfile(parent .. "/new.txt"), { "keep parent" })
    assert(hint:find("git -C " .. vim.fn.shellescape(child), 1, true))
    assert(hint:find(vim.fn.shellescape(child .. "/new.txt"), 1, true))
    H.eq(nvim.lua_get("errors"), {})
end

for _, pane in ipairs({ 1, 2 }) do
    T["global hunk toggle does not mutate the index from native diff pane " .. pane] = function()
        local parent, child = nested_repo()
        H.git(child, "add", "file.txt")
        H.write_file(child .. "/file.txt", { "one", "unseen worktree edit", "three" })
        local index_before = H.git(child, "show", ":file.txt")
        local worktree_before = vim.fn.readfile(child .. "/file.txt")
        local nvim = start(parent)
        H.nvim_edit(nvim, child .. "/file.txt")
        H.nvim_wait_for_delta_file_state(nvim)
        nvim.lua_notify("require('delta.diff').open_file({ mode = 'staged' })")
        H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 10)
        nvim.lua_func(function(side, path)
            local win = vim.api.nvim_tabpage_list_wins(0)[side]
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { 2, 0 })
            local mapping = vim.fn.maparg("X", "n", false, true)
            assert(type(mapping.callback) == "function", "global hunk mapping missing")
            mapping.callback()
            local locks = find_upvalue(require("delta.spotlight.core").toggle_stage_hunk, "mutating_file_state_locks")
            assert(
                vim.wait(5000, function()
                    return not locks:locked(path)
                end, 10),
                vim.inspect(errors)
            )
        end, pane, child .. "/file.txt")
        H.eq(H.git(child, "show", ":file.txt"), index_before)
        H.eq(vim.fn.readfile(child .. "/file.txt"), worktree_before)
        H.eq(H.git(parent, "diff", "--cached"), "")
        H.eq(nvim.lua_get("errors"), {})
    end
end

T["file diff handoff from a native pane uses stored repository metadata"] = function()
    local parent, child = nested_repo()
    local nvim = start(parent)
    H.nvim_edit(nvim, child .. "/file.txt")
    nvim.lua_notify("require('delta.diff').open_file()")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 10)
    nvim.lua_notify("require('delta.diff').open_file()")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 3", 5000, 10)
    H.eq(nvim.lua_get("require('delta.repository').buffer_file(vim.api.nvim_get_current_buf()).repo.root"), child)
    H.eq(nvim.lua_get("errors"), {})
end

return T
