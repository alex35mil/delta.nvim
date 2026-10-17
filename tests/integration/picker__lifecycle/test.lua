local T = MiniTest.new_set()

local H = require("tests.support.helpers")

local function start()
    local repo = H.init_repo({ ["a.txt"] = { "old a" }, ["b.txt"] = { "old b" } })
    H.finally_rm(repo)
    H.write_file(repo .. "/a.txt", { "new a" })
    H.write_file(repo .. "/b.txt", { "new b" })

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        _G.errors = {}
        vim.notify = function(msg, level)
            if level == vim.log.levels.ERROR then errors[#errors + 1] = msg end
        end
        vim.o.hidden = true
        vim.cmd('vsplit')
        vim.cmd('split')
        _G.editors = {}
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(win, buf)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved ' .. win })
            editors[#editors + 1] = {
                win = win, buf = buf,
                lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
                modified = vim.bo[buf].modified,
            }
        end
        _G.assert_editors = function()
            for _, e in ipairs(editors) do
                assert(vim.api.nvim_win_is_valid(e.win), 'editing window destroyed')
                assert(vim.api.nvim_win_get_buf(e.win) == e.buf, 'editing buffer replaced')
                assert(vim.deep_equal(vim.api.nvim_buf_get_lines(e.buf, 0, -1, false), e.lines))
                assert(vim.bo[e.buf].modified == e.modified, 'modified flag changed')
            end
        end
        _G.picker = require('delta.picker')
        _G.picker_state = function()
            return find_upvalue(require('delta.picker.ui').show, 'state')
        end
        _G.picker_win = function(ft)
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == ft then return win end
            end
        end
        _G.flush = function()
            local done = false
            vim.schedule(function() vim.schedule(function() done = true end) end)
            assert(vim.wait(5000, function() return done end, 10))
        end
        _G.hold_status = false
        _G.status_requests = {}
        local system = vim.system
        vim.system = function(cmd, opts, cb)
            if hold_status and cmd[1] == 'git' and cmd[2] == 'status' then
                local request = {}
                status_requests[#status_requests + 1] = request
                return system(cmd, opts, function(result)
                    request.result = result
                    request.callback = cb
                end)
            end
            return system(cmd, opts, cb)
        end
        _G.release_status = function(index, fail)
            local request = status_requests[index]
            assert(request and request.result, 'status not ready')
            assert(not request.released, 'status already released')
            request.released = true
            request.callback(fail and { code = 1, stdout = '', stderr = 'status failed' } or request.result)
            flush()
        end
        _G.snapshot_picker = function()
            flush()
            _G.saved_state = picker_state()
            _G.saved_contents = vim.deepcopy(saved_state)
            _G.saved_windows = vim.api.nvim_list_wins()
            _G.saved_focus = vim.api.nvim_get_current_win()
            _G.saved_preview = require('delta.picker.preview').get_win()
            _G.saved_tree_buf = vim.api.nvim_win_get_buf(picker_win('delta-filetree'))
            _G.saved_tree_tick = vim.api.nvim_buf_get_changedtick(saved_tree_buf)
        end
        _G.assert_picker_unchanged = function()
            flush()
            assert(picker_state() == saved_state, 'picker instance replaced or closed')
            assert(vim.deep_equal(picker_state(), saved_contents), 'picker state changed')
            assert(vim.deep_equal(vim.api.nvim_list_wins(), saved_windows), 'picker windows changed')
            assert(vim.api.nvim_get_current_win() == saved_focus, 'focus changed')
            assert(require('delta.picker.preview').get_win() == saved_preview, 'preview changed')
            assert(vim.api.nvim_buf_get_changedtick(saved_tree_buf) == saved_tree_tick, 'tree buffer rewritten')
            assert_editors()
            assert(#errors == 0, vim.inspect(errors))
        end
        _G.context = nil
        require('delta').setup({
            reset = { confirm = false },
            picker = {
                initial_mode = 'n',
                sources = { review = { label = 'Review', files = { 'a.txt' } } },
                actions = {
                    capture = { 'x', function(ctx) _G.context = ctx end },
                },
            },
        })
    ]])
    return nvim, repo
end

local function wait_status(nvim, index)
    H.nvim_wait_for(nvim, "status_requests[" .. index .. "] and status_requests[" .. index .. "].result ~= nil")
end

local function wait_open(nvim)
    H.nvim_wait_for(nvim, "picker_win('delta-filetree') ~= nil")
    nvim.lua("flush()")
end

local function capture_context(nvim)
    nvim.lua([[
        local buf = vim.api.nvim_win_get_buf(picker_win('delta-input'))
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
            if map.lhs == 'x' then map.callback(); break end
        end
        assert(context, 'action context missing')
    ]])
end

local function close_and_check(nvim)
    nvim.lua([[
        picker.close()
        flush()
        assert_editors()
        assert(not picker.is_open())
        assert(#vim.api.nvim_list_wins() == #editors, 'orphaned picker windows')
        assert(#errors == 0, vim.inspect(errors))
    ]])
end

T["close during initial loading preserves editors and discards completion"] = function()
    local nvim = start()
    nvim.lua([[
        hold_status = true
        picker.show({ source = 'git' })
        assert(picker.is_open() and picker_state().phase == 'loading')
        picker.show()
        assert(#status_requests == 1, 'show while loading started another load')
        picker.close()
        assert_editors()
        assert(not picker.is_open())
    ]])
    wait_status(nvim, 1)
    nvim.lua("release_status(1)")
    close_and_check(nvim)
end

T["failed active load releases only its loading instance"] = function()
    local nvim = start()
    nvim.lua("hold_status = true; picker.show()")
    wait_status(nvim, 1)
    nvim.lua([[
        release_status(1, true)
        assert(not picker.is_open())
        assert(#errors == 1 and errors[1]:find('status failed', 1, true))
        errors = {}
    ]])
    close_and_check(nvim)
end

T["obsolete reopen-after-stage load cannot affect replacement"] = function()
    local nvim = start()
    nvim.lua([[
        hold_status = true
        require('delta.picker.ui').reopen_after_stage({ staged_path = 'a.txt' })
        picker.close()
        picker.show({ source = 'review' })
    ]])
    wait_status(nvim, 1)
    wait_status(nvim, 2)
    nvim.lua("release_status(2)")
    wait_open(nvim)
    nvim.lua("snapshot_picker(); release_status(1); assert_picker_unchanged()")
    close_and_check(nvim)
end

T["queued insert-mode entry belongs to its opening instance"] = function()
    local nvim = start()
    nvim.lua([[
        require('delta.config').options.picker.initial_mode = 'i'
        hold_status = true
        picker.show()
    ]])
    wait_status(nvim, 1)
    nvim.lua([[
        -- Hold the Git continuation, then execute it while capturing the UI work
        -- it schedules. This leaves startinsert pending across close/reopen.
        local schedule = vim.schedule
        _G.queued = {}
        vim.schedule = function(fn) queued[#queued + 1] = fn end
        status_requests[1].callback(status_requests[1].result)
        assert(#queued == 1)
        table.remove(queued, 1)()
        vim.schedule = schedule
        assert(picker_win('delta-input'))
        assert(#queued > 0)
        picker.close()
        require('delta.config').options.picker.initial_mode = 'n'
        hold_status = false
        picker.show()
    ]])
    wait_open(nvim)
    nvim.lua([[
        snapshot_picker()
        local cmd = vim.cmd
        local insert_requests = 0
        vim.cmd = function(command)
            if command == 'startinsert' then insert_requests = insert_requests + 1 end
            return cmd(command)
        end
        for _, fn in ipairs(queued) do fn() end
        vim.cmd = cmd
        assert(insert_requests == 0, 'obsolete load requested insert mode')
        assert_picker_unchanged()
    ]])
    close_and_check(nvim)
end

for _, order in ipairs({ "old-first", "new-first", "old-failure" }) do
    T["reopen isolates initial loads: " .. order] = function()
        local nvim = start()
        nvim.lua([[
            hold_status = true
            picker.toggle({ source = 'git' })
            picker.toggle({ source = 'git' })
            assert_editors()
            picker.toggle({ source = 'review', preselect_path = 'a.txt' })
        ]])
        wait_status(nvim, 1)
        wait_status(nvim, 2)
        if order == "old-first" then
            nvim.lua([[
                release_status(1)
                assert(picker.is_open())
                assert(not picker_win('delta-input'), 'old load created windows')
                release_status(2)
            ]])
        else
            nvim.lua("release_status(2)")
            wait_open(nvim)
            nvim.lua("snapshot_picker()")
            if order == "old-failure" then
                nvim.lua([[
                    release_status(1, true)
                    assert(#errors == 1 and errors[1]:find('status failed', 1, true))
                    errors = {}
                ]])
            else
                nvim.lua("release_status(1)")
            end
            nvim.lua("assert_picker_unchanged()")
        end
        wait_open(nvim)
        nvim.lua([[
            assert(picker_state().source_idx == 2)
            assert(#picker_state().unstaged == 1)
        ]])
        close_and_check(nvim)
    end
end

for _, action in ipairs({ "cycle_source", "cycle_source_back", "toggle_stage", "unstage", "reset" }) do
    T["obsolete action refresh cannot update replacement: " .. action] = function()
        local nvim, repo = start()
        if action == "unstage" then
            H.git(repo, "add", "a.txt")
        end
        nvim.lua("picker.show({ preselect_path = 'a.txt' })")
        wait_open(nvim)
        capture_context(nvim)
        nvim.lua("hold_status = true; callback_ran = false")
        if action == "cycle_source" or action == "cycle_source_back" then
            nvim.lua("context." .. action .. "()")
        elseif action == "reset" then
            nvim.lua("context.reset(function() callback_ran = true; picker.close() end)")
        else
            nvim.lua("context.toggle_stage(function() callback_ran = true; picker.close() end)")
        end
        wait_status(nvim, 1)
        nvim.lua("picker.close(); hold_status = false; picker.show({ source = 'review' })")
        wait_open(nvim)
        nvim.lua("snapshot_picker(); release_status(1); assert_picker_unchanged(); assert(not callback_ran)")
        if action == "toggle_stage" then
            H.eq(H.git(repo, "show", ":a.txt"), "new a\n")
        elseif action == "unstage" then
            H.eq(H.git(repo, "diff", "--cached", "--name-only"), "")
        elseif action == "reset" then
            H.eq(vim.fn.readfile(repo .. "/a.txt"), { "old a" })
        end
        close_and_check(nvim)
    end
end

T["retained action contexts and deferred UI callbacks cannot affect replacement"] = function()
    local nvim = start()
    nvim.lua("picker.show()")
    wait_open(nvim)
    capture_context(nvim)
    nvim.lua([[
        _G.old_context = context
        _G.old_events = {}
        local buf = vim.api.nvim_win_get_buf(picker_win('delta-input'))
        for _, event in ipairs(vim.api.nvim_get_autocmds({ buffer = buf })) do
            old_events[event.event] = event.callback
        end
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
            if map.lhs == 'x' then _G.old_keymap = map.callback end
        end
        local tree_buf = vim.api.nvim_win_get_buf(picker_win('delta-filetree'))
        for _, event in ipairs(vim.api.nvim_get_autocmds({ buffer = tree_buf })) do
            old_events[event.event] = event.callback
        end
        -- Queue real old-instance callbacks, then replace the picker before they run.
        old_events.WinLeave()
        old_events.CursorMoved()
        picker.close()
        picker.show({ source = 'review' })
    ]])
    wait_open(nvim)
    nvim.lua([[
        snapshot_picker()
        context = nil
        old_keymap()
        assert(context == nil, 'obsolete keymap ran its handler')
        old_events.TextChanged()
        old_events.CursorMoved()
        old_context.move(1)
        old_context.move_to_top()
        old_context.move_to_bottom()
        old_context.expand()
        old_context.collapse()
        old_context.cycle_source()
        old_context.cycle_source_back()
        old_context.toggle_preview()
        old_context.scroll_horizontal(1)
        old_context.scroll_preview(1)
        old_context.toggle_stage()
        old_context.reset()
        old_context.open()
        old_context.close()
        assert_picker_unchanged()
    ]])
    close_and_check(nvim)
end

T["ordinary real-Git opening filtering cycling preview and closing work"] = function()
    local nvim = start()
    nvim.lua("picker.show({ preselect_path = 'b.txt' })")
    wait_open(nvim)
    capture_context(nvim)
    nvim.lua([[
        assert(context.node.path == 'b.txt')
        local preview = require('delta.picker.preview')
        if not preview.is_visible() then context.toggle_preview() end
        assert(preview.is_visible())
        local buf = vim.api.nvim_win_get_buf(picker_win('delta-input'))
        local prompt = vim.fn.prompt_getprompt(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prompt .. 'a.txt' })
        vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
        local s = picker_state()
        for _, node in ipairs(s.nodes) do
            assert(not node or node.is_dir or node.path == 'a.txt')
        end
        context.cycle_source()
    ]])
    H.nvim_wait_for(nvim, "picker_state().source_idx == 2 and #picker_state().unstaged == 1")
    capture_context(nvim)
    nvim.lua("context.cycle_source_back()")
    H.nvim_wait_for(nvim, "picker_state().source_idx == 1 and #picker_state().unstaged == 2")
    close_and_check(nvim)
end

return T
