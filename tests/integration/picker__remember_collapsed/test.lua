local T = MiniTest.new_set()

local H = require("tests.support.helpers")

local files = {
    ["src/ui/a.lua"] = { "old" },
    ["src/ui/b.lua"] = { "old" },
    ["src/core/c.lua"] = { "old" },
    ["docs/d.md"] = { "old" },
    ["top.txt"] = { "old" },
}

local function make_repo()
    local repo = H.init_repo(files)
    H.finally_rm(repo)
    for path in pairs(files) do
        H.write_file(repo .. "/" .. path, { "new" })
    end
    return repo
end

---@param remember boolean
local function start(remember)
    local repo = make_repo()
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    nvim.lua_func(function(remember_collapsed)
        _G.errors = {}
        vim.notify = function(msg, level)
            if level == vim.log.levels.ERROR then
                errors[#errors + 1] = msg
            end
        end
        _G.picker = require("delta.picker")
        _G.ui = require("delta.picker.ui")
        _G.picker_state = function()
            return find_upvalue(ui.show, "state")
        end
        _G.flush = function()
            local done = false
            vim.schedule(function()
                vim.schedule(function()
                    done = true
                end)
            end)
            assert(vim.wait(5000, function()
                return done
            end, 10))
        end
        _G.ready = function()
            local s = picker_state()
            return s and s.phase == "ready" and #s.nodes > 0
        end
        _G.open = function(opts)
            picker.show(opts)
            assert(vim.wait(5000, ready, 10), "picker did not open")
            flush()
        end
        _G.node_index = function(path)
            for i, node in ipairs(picker_state().nodes) do
                if node and node.path == path and node.section == "unstaged" then
                    return i
                end
            end
        end
        _G.visible = function(path)
            return node_index(path) ~= nil
        end
        _G.selected = function()
            local s = picker_state()
            local node = s.nodes[s.cursor_idx]
            return node and node.path or nil
        end
        _G.context = nil
        _G.act = function(name, path)
            local s = picker_state()
            if path then
                s.cursor_idx = assert(node_index(path), "node not visible: " .. path)
            end
            local buf = s.input_buf
            for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
                if map.lhs == "x" then
                    map.callback()
                    break
                end
            end
            assert(context, "action context missing")
            context[name]()
            context = nil
        end
        _G.cycle = function(name)
            local s = picker_state()
            -- The source switch refreshes asynchronously, then replaces the collapsed set and re-renders.
            local before_collapsed = s.collapsed
            local before_nodes = s.nodes
            act(name)
            assert(vim.wait(5000, function()
                local cur = picker_state()
                return cur and cur.collapsed ~= before_collapsed and cur.nodes ~= before_nodes
            end, 10), "source switch did not finish")
            flush()
        end
        _G.set_query = function(query)
            local s = picker_state()
            local prompt = vim.fn.prompt_getprompt(s.input_buf)
            vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { prompt .. query })
            vim.api.nvim_exec_autocmds("TextChanged", { buffer = s.input_buf })
            flush()
        end
        _G.reopen = function(opts)
            picker.close()
            flush()
            open(opts)
        end
        _G.resolve = function(path)
            local file
            require("delta.git").async(function()
                local ok, ref = require("delta.git").resolve_file(vim.fn.getcwd() .. "/" .. path)
                assert(ok)
                file = ref
            end)
            assert(vim.wait(5000, function()
                return file ~= nil
            end, 10))
            return file
        end
        _G.reopen_after_stage = function(path)
            picker.close()
            flush()
            ui.reopen_after_stage({ file = resolve(path) })
            assert(vim.wait(5000, ready, 10), "picker did not reopen")
            flush()
        end
        require("delta").setup({
            picker = {
                initial_mode = "n",
                remember_collapsed = remember_collapsed,
                sources = { review = { label = "Review", files = { "src/ui/a.lua", "docs/d.md" } } },
                actions = {
                    capture = {
                        "x",
                        function(ctx)
                            _G.context = ctx
                        end,
                    },
                },
            },
        })
    end, remember)
    return nvim, repo
end

local function check(nvim, code)
    nvim.lua(code)
    nvim.lua("assert(#errors == 0, vim.inspect(errors))")
end

T["defaults to remembering collapsed directories"] = function()
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.eq(nvim.lua_get("require('delta.config').options.picker.remember_collapsed"), true)
end

T["disabled: reopen and source switching start expanded"] = function()
    local nvim = start(false)
    check(
        nvim,
        [[
        open()
        act('collapse', 'src/ui')
        assert(not visible('src/ui/a.lua'))
        reopen()
        assert(visible('src/ui/a.lua'), 'collapsed state survived reopen while disabled')

        act('collapse', 'docs')
        assert(not visible('docs/d.md'))
        cycle('cycle_source')
        cycle('cycle_source_back')
        assert(visible('docs/d.md'), 'collapsed state survived source switch while disabled')
    ]]
    )
end

T["enabled: reopen and reopen after stage restore collapsed directories"] = function()
    local nvim = start(true)
    check(
        nvim,
        [[
        open()
        act('collapse', 'src/ui')
        assert(not visible('src/ui/a.lua'))
        reopen()
        assert(visible('src/ui') and not visible('src/ui/a.lua'), 'not restored on reopen')

        reopen_after_stage('top.txt')
        assert(visible('src/ui') and not visible('src/ui/a.lua'), 'not restored after stage reopen')

        act('expand', 'src/ui')
        reopen()
        assert(visible('src/ui/a.lua'), 'expansion not remembered')
    ]]
    )
end

T["enabled: sources keep separate collapsed state"] = function()
    local nvim = start(true)
    check(
        nvim,
        [[
        open()
        act('collapse', 'docs')
        cycle('cycle_source')
        assert(picker_state().source_keys[picker_state().source_idx] == 'review')
        assert(visible('docs/d.md'), 'git state leaked into review source')
        act('collapse', 'src/ui')
        cycle('cycle_source_back')
        assert(not visible('docs/d.md'), 'git state not restored on switch back')
        assert(visible('src/ui/a.lua'), 'review state leaked into git source')
        cycle('cycle_source')
        assert(not visible('src/ui/a.lua') and visible('docs/d.md'), 'review state not restored')

        -- Inline source labeled like the named source key stays isolated from it.
        reopen({ source = { label = 'review', files = { 'src/ui/a.lua', 'docs/d.md' } } })
        assert(picker_state().source_keys[picker_state().source_idx] == false)
        assert(visible('src/ui/a.lua'), 'named review state leaked into inline source')
    ]]
    )
end

T["enabled: inline source restores by label"] = function()
    local nvim = start(true)
    check(
        nvim,
        [[
        open({ source = { label = 'Agent', files = { 'src/ui/a.lua', 'top.txt' } } })
        act('collapse', 'src/ui')
        assert(not visible('src/ui/a.lua'))

        reopen({ source = { label = 'Agent', files = { 'src/ui/a.lua', 'top.txt' } } })
        assert(visible('src/ui') and not visible('src/ui/a.lua'), 'inline state not restored on show')

        reopen_after_stage('top.txt')
        assert(picker_state().source_keys[picker_state().source_idx] == false)
        assert(visible('src/ui') and not visible('src/ui/a.lua'), 'inline state not restored after stage')

        reopen({ source = { label = 'Other', files = { 'src/ui/a.lua', 'top.txt' } } })
        assert(visible('src/ui/a.lua'), 'inline state leaked across labels')
    ]]
    )
end

T["enabled: repositories keep separate collapsed state"] = function()
    local nvim, repo = start(true)
    local other = make_repo()
    check(
        nvim,
        [[
        open()
        act('collapse', 'src/ui')
        picker.close()
        flush()
    ]]
    )
    H.nvim_set_cwd(nvim, other)
    check(
        nvim,
        [[
        open()
        assert(visible('src/ui/a.lua'), 'collapsed state leaked across repositories')
        act('collapse', 'docs')
        picker.close()
        flush()
    ]]
    )
    H.nvim_set_cwd(nvim, repo)
    check(
        nvim,
        [[
        open()
        assert(not visible('src/ui/a.lua'), 'first repository state lost')
        assert(visible('docs/d.md'), 'second repository state leaked back')
    ]]
    )
end

T["preselect into collapsed directory expands its ancestors"] = function()
    local nvim = start(true)
    check(
        nvim,
        [[
        open()
        act('collapse_all')
        assert(not visible('src/ui'))
        reopen({ preselect_path = 'src/ui/b.lua' })
        assert(selected() == 'src/ui/b.lua', 'preselected file not selected: ' .. tostring(selected()))
        assert(visible('src/ui/a.lua'))
        assert(not visible('src/core/c.lua'), 'unrelated directory expanded')
        assert(not visible('docs/d.md'), 'unrelated directory expanded')
        reopen()
        assert(visible('src/ui/a.lua'), 'revealed ancestors not remembered as expanded')
    ]]
    )
end

T["zM and zR collapse and expand all directories"] = function()
    local nvim = start(false)
    check(
        nvim,
        [[
        open()
        picker_state().cursor_idx = node_index('src/ui/b.lua')
    ]]
    )
    nvim.api.nvim_input("zM")
    check(
        nvim,
        [[
        flush()
        for _, path in ipairs({ 'src/ui', 'src/core', 'src/ui/a.lua', 'src/core/c.lua', 'docs/d.md' }) do
            assert(not visible(path), 'visible after zM: ' .. path)
        end
        assert(visible('src') and visible('docs') and visible('top.txt'))
        assert(selected() == 'src', 'cursor not on containing top-level entry: ' .. tostring(selected()))
    ]]
    )
    nvim.api.nvim_input("zR")
    check(
        nvim,
        [[
        flush()
        for _, path in ipairs({ 'src/ui/a.lua', 'src/ui/b.lua', 'src/core/c.lua', 'docs/d.md' }) do
            assert(visible(path), 'hidden after zR: ' .. path)
        end
        assert(selected() == 'src', 'cursor moved by zR: ' .. tostring(selected()))
    ]]
    )
end

T["zM with an active query collapses every directory of the source"] = function()
    local nvim = start(true)
    check(
        nvim,
        [[
        open()
        set_query('b.lua')
        -- Filtered tree merges src/ui into a single node.
        assert(visible('src/ui') and visible('src/ui/b.lua') and not visible('docs'))
    ]]
    )
    nvim.api.nvim_input("zM")
    check(
        nvim,
        [[
        flush()
        assert(visible('src/ui') and not visible('src/ui/b.lua'), 'filtered view not collapsed')
        set_query('')
        assert(visible('src') and visible('docs') and visible('top.txt'))
        for _, path in ipairs({ 'src/ui', 'src/core', 'docs/d.md' }) do
            assert(not visible(path), 'visible after clearing query: ' .. path)
        end
    ]]
    )
end

return T
