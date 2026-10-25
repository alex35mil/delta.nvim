local T = MiniTest.new_set()

local H = require("tests.support.helpers")

local function numbered_lines(count)
    local lines = {}
    for i = 1, count do
        lines[i] = "line " .. i
    end
    return lines
end

local function init_cursor_sync_repo()
    local lines = numbered_lines(100)
    local repo = H.init_repo({
        ["file.txt"] = lines,
        ["other.txt"] = numbered_lines(100),
    })

    local changed = vim.deepcopy(lines)
    changed[20] = "line 20 changed"
    changed[80] = "line 80 changed"
    H.write_file(repo .. "/file.txt", changed)

    return repo
end

local function setup_file_diff(nvim)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    context = { base = 1, step = 2 },
                    keys = { close = 'q' },
                },
            },
        })
    ]])
end

local function open_file_diff(nvim)
    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
end

local function diff_cursor_lines(nvim)
    return nvim.lua_func(function()
        local tab = vim.api.nvim_get_current_tabpage()
        local wins = vim.api.nvim_tabpage_list_wins(tab)
        return {
            left = vim.api.nvim_win_get_cursor(wins[1])[1],
            right = vim.api.nvim_win_get_cursor(wins[2])[1],
        }
    end)
end

local function set_right_diff_cursor(nvim, line)
    nvim.lua_func(function(target_line)
        local tab = vim.api.nvim_get_current_tabpage()
        local wins = vim.api.nvim_tabpage_list_wins(tab)
        vim.api.nvim_set_current_win(wins[2])
        vim.api.nvim_win_set_cursor(wins[2], { target_line, 0 })
    end, line)
end

local function install_picker_state_helper(nvim)
    nvim.lua([[
        _G.picker_state = function()
            return find_upvalue(require('delta.picker.ui').show, 'state')
        end
    ]])
end

local function install_spotlight_wins_helper(nvim)
    nvim.lua([[
        _G.spotlight_wins = function()
            return find_upvalue(require('delta.spotlight.core').ensure, 'wins')
        end
    ]])
end

local function wait_for_picker_node(nvim, path, section)
    H.nvim_wait_for(nvim, string.format([[
        (function()
            local state = _G.picker_state and _G.picker_state()
            local node = state and state.nodes[state.cursor_idx]
            return node and node.path == %q and node.section == %q
        end)()
    ]], path, section), 5000, 20)
end

local function install_diff_state_helper(nvim)
    nvim.lua([[
        _G.diff_tabs = function()
            return find_upvalue(require('delta.diff.file').close, 'tabs')
        end
        _G.current_diff_state = function()
            local tabs = _G.diff_tabs() or {}
            for _, state in pairs(tabs) do
                return state
            end
        end
    ]])
end

-- Diff tab stays open in staged mode on `path` and the picker reopened from inside it.
local function wait_for_staged_diff_with_picker(nvim, path, next_path)
    install_diff_state_helper(nvim)
    H.nvim_wait_for(nvim, string.format([[
        (function()
            local state = _G.current_diff_state and _G.current_diff_state()
            return state ~= nil
                and state.file.path == %q
                and state.resolved_mode == 'staged'
                and #vim.api.nvim_list_tabpages() == 2
        end)()
    ]], path), 5000, 20)
    wait_for_picker_node(nvim, next_path, "unstaged")
    H.eq(nvim.lua([[
        local state = _G.current_diff_state()
        local picker = _G.picker_state()
        return picker.origin_win == state.left_win or picker.origin_win == state.right_win
    ]]), true)
end

local function wait_for_picker_source(nvim, key)
    H.nvim_wait_for(nvim, string.format([[
        (function()
            local state = _G.picker_state and _G.picker_state()
            return state
                and state.input_buf ~= 0
                and vim.api.nvim_buf_is_valid(state.input_buf)
                and state.source_keys[state.source_idx] == %q
        end)()
    ]], key), 5000, 20)
end

T["opens side-by-side diff tab and closes back to origin"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        local diff_actions = require('delta').diff.actions
        require('delta').setup({
            diff = {
                actions = {
                    open_file_diff = { { 'gD', modes = 'n' }, diff_actions.open_file_diff },
                },
                file = {
                    context = { base = 1, step = 2 },
                    keys = { close = 'q', expand_context = '+', shrink_context = '_' },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    local origin = nvim.lua_func(function()
        return {
            tab = vim.api.nvim_get_current_tabpage(),
            win = vim.api.nvim_get_current_win(),
        }
    end)

    nvim.api.nvim_input("gD")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    local opened = nvim.lua_func(function()
        local tab = vim.api.nvim_get_current_tabpage()
        local wins = vim.api.nvim_tabpage_list_wins(tab)
        local left_buf = vim.api.nvim_win_get_buf(wins[1])
        local right_buf = vim.api.nvim_win_get_buf(wins[2])

        return {
            wins = #wins,
            left_diff = vim.wo[wins[1]].diff,
            right_diff = vim.wo[wins[2]].diff,
            left_name = vim.api.nvim_buf_get_name(left_buf),
            right_name = vim.api.nvim_buf_get_name(right_buf),
            left_winhighlight = vim.wo[wins[1]].winhighlight,
            right_winhighlight = vim.wo[wins[2]].winhighlight,
            left_winbar = vim.wo[wins[1]].winbar,
            right_winbar = vim.wo[wins[2]].winbar,
            left_wrap = vim.wo[wins[1]].wrap,
            right_wrap = vim.wo[wins[2]].wrap,
            left_line = vim.api.nvim_buf_get_lines(left_buf, 1, 2, false)[1],
            right_line = vim.api.nvim_buf_get_lines(right_buf, 1, 2, false)[1],
        }
    end)

    H.eq(opened.wins, 2)
    H.eq(opened.left_diff, true)
    H.eq(opened.right_diff, true)
    assert(opened.left_winhighlight:find("WinBar:DeltaDiffFileWinbar", 1, true) ~= nil)
    assert(opened.right_winhighlight:find("WinBar:DeltaDiffFileWinbar", 1, true) ~= nil)
    assert(opened.left_winbar:find("DeltaDiffFileWinbarBase", 1, true) ~= nil)
    assert(opened.right_winbar:find("DeltaDiffFileWinbarCurrent", 1, true) ~= nil)
    assert(opened.right_winbar:find("?=keymaps", 1, true) ~= nil)
    assert(opened.right_winbar:find("+=expand", 1, true) == nil)
    assert(opened.right_winbar:find("_=shrink", 1, true) == nil)
    assert(opened.right_winbar:find("q=close", 1, true) == nil)
    assert(opened.left_name:find("delta://diff/", 1, true) ~= nil)
    assert(opened.right_name:find("delta://diff/", 1, true) ~= nil)
    H.eq(opened.left_wrap, false)
    H.eq(opened.right_wrap, false)
    H.eq(opened.left_line, "two")
    H.eq(opened.right_line, "two changed")
    H.eq(nvim.lua("return vim.go.diffopt:match('context:(%d+)')"), "1")

    nvim.api.nvim_input("?")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):find('delta://diff/keymaps/', 1, true) ~= nil", 5000, 20)
    local help = nvim.lua_func(function()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end)
    assert(help:find("Expand context: +", 1, true) ~= nil)
    assert(help:find("Shrink context: _", 1, true) ~= nil)
    assert(help:find("Close: q", 1, true) ~= nil)
    nvim.api.nvim_input("q")

    nvim.api.nvim_input("+")
    H.nvim_wait_for(nvim, "vim.go.diffopt:match('context:(%d+)') == '3'", 5000, 20)
    nvim.api.nvim_input("_")
    H.nvim_wait_for(nvim, "vim.go.diffopt:match('context:(%d+)') == '1'", 5000, 20)

    nvim.lua_notify([[require('delta.diff').close_all()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)

    local closed = nvim.lua_func(function()
        return {
            tab = vim.api.nvim_get_current_tabpage(),
            win = vim.api.nvim_get_current_win(),
            name = vim.api.nvim_buf_get_name(0),
        }
    end)

    H.eq(closed.tab, origin.tab)
    H.eq(closed.win, origin.win)
    H.eq(vim.uv.fs_realpath(closed.name), vim.uv.fs_realpath(repo .. "/file.txt"))
end

T["syncs file diff cursor on open"] = function()
    local repo = init_cursor_sync_repo()
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)
    setup_file_diff(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua([[vim.api.nvim_win_set_cursor(0, { 79, 0 })]])
    open_file_diff(nvim)
    H.eq(diff_cursor_lines(nvim), { left = 79, right = 79 })

    nvim.lua_notify([[require('delta.diff').close_all()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)

    nvim.lua([[vim.api.nvim_win_set_cursor(0, { 70, 0 })]])
    open_file_diff(nvim)
    H.eq(diff_cursor_lines(nvim), { left = 80, right = 80 })
end

T["does not sync unrelated origin cursor on path or mismatched buffer open"] = function()
    local repo = init_cursor_sync_repo()
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)
    setup_file_diff(nvim)
    H.nvim_edit(nvim, repo .. "/other.txt")
    nvim.lua([[vim.api.nvim_win_set_cursor(0, { 50, 0 })]])

    nvim.lua_func(function(path)
        require("delta.diff").open_file({ path = path })
    end, repo .. "/file.txt")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    local cursors = diff_cursor_lines(nvim)
    assert(cursors.left ~= 50, vim.inspect(cursors))
    assert(cursors.right ~= 50, vim.inspect(cursors))

    nvim.lua_notify([[require('delta.diff').close_all()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)

    H.nvim_edit(nvim, repo .. "/file.txt")
    local file_buf = nvim.lua("return vim.api.nvim_get_current_buf()")
    H.nvim_edit(nvim, repo .. "/other.txt")
    nvim.lua([[vim.api.nvim_win_set_cursor(0, { 50, 0 })]])

    nvim.lua_func(function(bufid)
        require("delta.diff").open_file({ winid = vim.api.nvim_get_current_win(), bufid = bufid })
    end, file_buf)
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    cursors = diff_cursor_lines(nvim)
    assert(cursors.left ~= 50, vim.inspect(cursors))
    assert(cursors.right ~= 50, vim.inspect(cursors))
end

T["syncs file diff cursor on close"] = function()
    local repo = init_cursor_sync_repo()
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)
    setup_file_diff(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    open_file_diff(nvim)
    set_right_diff_cursor(nvim, 80)
    nvim.lua_notify([[require('delta.diff').close_all()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.eq(nvim.lua("return vim.api.nvim_win_get_cursor(0)[1]"), 80)

    open_file_diff(nvim)
    set_right_diff_cursor(nvim, 20)
    local tabs = nvim.lua_func(function()
        return {
            diff = vim.api.nvim_get_current_tabpage(),
            origin = vim.api.nvim_list_tabpages()[1],
        }
    end)
    nvim.lua_func(function(tab)
        vim.api.nvim_set_current_tabpage(tab)
    end, tabs.origin)
    nvim.lua_func(function(tab)
        require("delta.diff").close_file(tab)
    end, tabs.diff)
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.eq(nvim.lua("return vim.api.nvim_win_get_cursor(0)[1]"), 20)
end

T["does not move cursor when diff closes to another file"] = function()
    local repo = init_cursor_sync_repo()
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)
    setup_file_diff(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    open_file_diff(nvim)
    local tabs = nvim.lua_func(function()
        return {
            diff = vim.api.nvim_get_current_tabpage(),
            origin = vim.api.nvim_list_tabpages()[1],
        }
    end)
    nvim.lua_func(function(origin_tab, other_path)
        vim.api.nvim_set_current_tabpage(origin_tab)
        vim.cmd.edit(vim.fn.fnameescape(other_path))
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
    end, tabs.origin, repo .. "/other.txt")
    nvim.lua_func(function(diff_tab)
        vim.api.nvim_set_current_tabpage(diff_tab)
    end, tabs.diff)
    set_right_diff_cursor(nvim, 80)

    nvim.lua_notify([[require('delta.diff').close_all()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)

    local closed = nvim.lua_func(function()
        return {
            name = vim.api.nvim_buf_get_name(0),
            line = vim.api.nvim_win_get_cursor(0)[1],
        }
    end)
    H.eq(vim.uv.fs_realpath(closed.name), vim.uv.fs_realpath(repo .. "/other.txt"))
    H.eq(closed.line, 5)
end

T["aliases true file diff keymap hints to dialog mode"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    keymap_hints = true,
                    keys = { close = 'x' },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    local right_winbar = nvim.lua_func(function()
        local wins = vim.api.nvim_tabpage_list_wins(0)
        return vim.wo[wins[2]].winbar
    end)

    assert(right_winbar:find("?=keymaps", 1, true) ~= nil)
    assert(right_winbar:find("x=close", 1, true) == nil)

    nvim.api.nvim_input("?")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):find('delta://diff/keymaps/', 1, true) ~= nil", 5000, 20)
    local help = nvim.lua_func(function()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end)
    assert(help:find("Close: x, q, <Esc>, <CR>", 1, true) ~= nil)
    nvim.api.nvim_input("x")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):find('delta://diff/keymaps/', 1, true) == nil", 5000, 20)
end

T["shows side-by-side diff keymap hints in winbar mode"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    keymap_hints = 'winbar',
                    keys = { close = 'q', expand_context = '+', shrink_context = '-' },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    local right_winbar = nvim.lua_func(function()
        local wins = vim.api.nvim_tabpage_list_wins(0)
        return vim.wo[wins[2]].winbar
    end)

    assert(right_winbar:find("+=expand", 1, true) ~= nil)
    assert(right_winbar:find("-=shrink", 1, true) ~= nil)
    assert(right_winbar:find("q=close", 1, true) ~= nil)
    assert(right_winbar:find("?=keymaps", 1, true) == nil)
end

T["hides side-by-side diff keymap hints when disabled"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    keymap_hints = false,
                    keys = { close = 'q', expand_context = '+', shrink_context = '-' },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    local opened = nvim.lua_func(function()
        local tab = vim.api.nvim_get_current_tabpage()
        local wins = vim.api.nvim_tabpage_list_wins(tab)
        return {
            left_winbar = vim.wo[wins[1]].winbar,
            right_winbar = vim.wo[wins[2]].winbar,
        }
    end)

    assert(opened.left_winbar:find("DeltaDiffFileWinbarBase", 1, true) ~= nil)
    assert(opened.right_winbar:find("DeltaDiffFileWinbarCurrent", 1, true) ~= nil)
    assert(opened.right_winbar:find("?=keymaps", 1, true) == nil)
    assert(opened.right_winbar:find("+=expand", 1, true) == nil)
    assert(opened.right_winbar:find("-=shrink", 1, true) == nil)
    assert(opened.right_winbar:find("q=close", 1, true) == nil)
    H.eq(nvim.lua([[return vim.fn.maparg('?', 'n', false, true).buffer == 1]]), false)

    nvim.api.nvim_input("q")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
end

T["omits file diff keymap help when question mark collides"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    keys = { close = '?' },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    local right_winbar = nvim.lua_func(function()
        local wins = vim.api.nvim_tabpage_list_wins(0)
        return vim.wo[wins[2]].winbar
    end)
    assert(right_winbar:find("?=keymaps", 1, true) == nil)

    nvim.api.nvim_input("?")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
end

T["warns once and falls back to dialog for unsupported file diff keymap hints"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        _G.delta_notifications = {}
        vim.notify = function(msg, level)
            _G.delta_notifications[#_G.delta_notifications + 1] = { msg = msg, level = level }
        end
        require('delta').setup({
            diff = {
                file = {
                    keymap_hints = 'bad-mode',
                    keys = { close = 'q', expand_context = '+' },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    local opened = nvim.lua_func(function()
        local wins = vim.api.nvim_tabpage_list_wins(0)
        return {
            right_winbar = vim.wo[wins[2]].winbar,
            notifications = _G.delta_notifications,
        }
    end)
    assert(opened.right_winbar:find("?=keymaps", 1, true) ~= nil)
    H.eq(#opened.notifications, 1)
    assert(opened.notifications[1].msg:find("unsupported diff.file.keymap_hints", 1, true) ~= nil)

    nvim.api.nvim_input("+")
    H.nvim_wait_for(nvim, "vim.go.diffopt:match('context:(%d+)') == '11'", 5000, 20)
    H.eq(nvim.lua("return #_G.delta_notifications"), 1)
end

T["wraps markdown side-by-side diff windows only"] = function()
    local repo = H.init_repo({
        ["note.md"] = { "one", "two" },
        ["doc.markdown"] = { "alpha", "beta" },
        ["plain.txt"] = { "red", "blue" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/note.md", { "one", "two changed" })
    H.write_file(repo .. "/doc.markdown", { "alpha", "beta changed" })
    H.write_file(repo .. "/plain.txt", { "red", "blue changed" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[require('delta').setup()]])

    local opts = nvim.lua_func(function(paths)
        local diff = require('delta.diff')
        local results = {}
        for _, path in ipairs(paths) do
            diff.open_file({ path = path })
            vim.wait(5000, function()
                return #vim.api.nvim_list_tabpages() == 2
            end, 20)

            local tab = vim.api.nvim_get_current_tabpage()
            local wins = vim.api.nvim_tabpage_list_wins(tab)
            local left_buf = vim.api.nvim_win_get_buf(wins[1])
            local right_buf = vim.api.nvim_win_get_buf(wins[2])
            results[path] = {
                left_filetype = vim.bo[left_buf].filetype,
                right_filetype = vim.bo[right_buf].filetype,
                left_wrap = vim.wo[wins[1]].wrap,
                right_wrap = vim.wo[wins[2]].wrap,
                left_linebreak = vim.wo[wins[1]].linebreak,
                right_linebreak = vim.wo[wins[2]].linebreak,
            }

            diff.close_file(tab)
            vim.wait(5000, function()
                return #vim.api.nvim_list_tabpages() == 1
            end, 20)
        end
        return results
    end, { "note.md", "doc.markdown", "plain.txt" })

    H.eq(opts["note.md"].left_filetype, "markdown")
    H.eq(opts["note.md"].right_filetype, "markdown")
    H.eq(opts["note.md"].left_wrap, true)
    H.eq(opts["note.md"].right_wrap, true)
    H.eq(opts["note.md"].left_linebreak, true)
    H.eq(opts["note.md"].right_linebreak, true)

    H.eq(opts["doc.markdown"].left_filetype, "markdown")
    H.eq(opts["doc.markdown"].right_filetype, "markdown")
    H.eq(opts["doc.markdown"].left_wrap, true)
    H.eq(opts["doc.markdown"].right_wrap, true)
    H.eq(opts["doc.markdown"].left_linebreak, true)
    H.eq(opts["doc.markdown"].right_linebreak, true)

    H.eq(opts["plain.txt"].left_wrap, false)
    H.eq(opts["plain.txt"].right_wrap, false)
end

T["keeps diffopt owned until all side-by-side diff tabs close"] = function()
    local repo = H.init_repo({
        ["one.txt"] = { "one", "two", "three" },
        ["two.txt"] = { "alpha", "beta", "gamma" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/one.txt", { "one", "two changed", "three" })
    H.write_file(repo .. "/two.txt", { "alpha", "beta changed", "gamma" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        vim.go.diffopt = 'internal,filler,closeoff,context:8'
        require('delta').setup({
            diff = {
                file = {
                    context = { base = 1, step = 2 },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/one.txt")

    local tabs = nvim.lua_func(function(one, two)
        local diff = require('delta.diff')
        local origin = vim.api.nvim_get_current_tabpage()
        diff.open_file({ path = one })
        vim.wait(5000, function()
            return #vim.api.nvim_list_tabpages() == 2
        end, 20)
        local first = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_set_current_tabpage(origin)
        diff.open_file({ path = two })
        vim.wait(5000, function()
            return #vim.api.nvim_list_tabpages() == 3
        end, 20)
        local second = vim.api.nvim_get_current_tabpage()
        return { first = first, second = second }
    end, "one.txt", "two.txt")

    H.eq(nvim.lua("return vim.go.diffopt:match('context:(%d+)')"), "1")
    nvim.lua_func(function(tab)
        require('delta.diff').close_file(tab)
    end, tabs.first)
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    H.eq(nvim.lua("return vim.go.diffopt:match('context:(%d+)')"), "1")
    nvim.lua_func(function(tab)
        require('delta.diff').close_file(tab)
    end, tabs.second)
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.eq(nvim.lua("return vim.go.diffopt:match('context:(%d+)')"), "8")
end

T["manual tabclose cleans up side-by-side diff state"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        vim.go.diffopt = 'internal,filler,closeoff,context:8'
        require('delta').setup({
            diff = {
                file = {
                    context = { base = 1 },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    H.eq(nvim.lua("return vim.go.diffopt:match('context:(%d+)')"), "1")

    nvim.lua([[vim.cmd('tabclose')]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.eq(nvim.lua("return vim.go.diffopt:match('context:(%d+)')"), "8")
end

T["resets file from side-by-side diff and closes when no selected diff remains"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            reset = { confirm = false },
            diff = {
                file = {
                    keys = {
                        reset_file = 'r',
                    },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("r")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, false, 5000, 20)
    H.eq(vim.fn.readfile(repo .. "/file.txt"), { "one", "two", "three" })
end

T["resets untracked file from side-by-side diff by deleting it"] = function()
    local repo = H.init_repo({
        ["tracked.txt"] = { "tracked" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/new.txt", { "new", "file" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            reset = { confirm = false },
            diff = {
                file = {
                    keys = {
                        reset_file = 'r',
                    },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/new.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("r")
    H.nvim_wait_for(nvim, "vim.uv.fs_stat('new.txt') == nil", 5000, 20)
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.eq(vim.uv.fs_stat(repo .. "/new.txt") == nil, true)
end

T["stages file from side-by-side diff and closes when no selected diff remains"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, false, 5000, 20)
    H.eq(nvim.lua("return _G.picker_state() == nil"), true)
end

T["reopens picker after staging file from auto side-by-side diff"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
        ["next.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })
    H.write_file(repo .. "/next.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = { initial_mode = 'n' },
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "file.txt", "next.txt")
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, false, 5000, 20)
end

T["reopens picker from origin after side-by-side stage and close"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
        ["next.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })
    H.write_file(repo .. "/next.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = { initial_mode = 'n' },
            diff = {
                file = {
                    keys = {
                        toggle_stage_file_and_close = 'S',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("S")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_node(nvim, "next.txt", "unstaged")
end

T["reopens picker with custom-source nav after staging deleted file from side-by-side diff"] = function()
    local repo = H.init_repo({
        ["deleted.txt"] = { "deleted" },
        ["next.txt"] = { "old" },
        ["outside.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    vim.fn.delete(repo .. "/deleted.txt")
    H.write_file(repo .. "/next.txt", { "new" })
    H.write_file(repo .. "/outside.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = {
                initial_mode = 'n',
                sources = {
                    review = {
                        label = 'Review',
                        files = function()
                            return { 'deleted.txt', 'next.txt' }
                        end,
                    },
                },
            },
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    nvim.lua([[require('delta.picker').show({ source = 'review', preselect_path = 'deleted.txt' })]])
    wait_for_picker_node(nvim, "deleted.txt", "unstaged")

    nvim.api.nvim_input("\r")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):find('delta://', 1, true) ~= nil", 5000, 20)

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "deleted.txt", "next.txt")
    H.nvim_wait_for_git_diff(nvim, "deleted.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "deleted.txt", false, false, 5000, 20)
end

T["reopens picker with custom-source nav after staging regular file from side-by-side diff"] = function()
    local repo = H.init_repo({
        ["aaa-outside.txt"] = { "old" },
        ["current.txt"] = { "old" },
        ["next.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/aaa-outside.txt", { "new" })
    H.write_file(repo .. "/current.txt", { "new" })
    H.write_file(repo .. "/next.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = {
                initial_mode = 'n',
                sources = {
                    review = {
                        label = 'Review',
                        files = function()
                            return { 'current.txt', 'next.txt' }
                        end,
                    },
                },
            },
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    nvim.lua([[require('delta.picker').show({ source = 'review', preselect_path = 'current.txt' })]])
    wait_for_picker_node(nvim, "current.txt", "unstaged")

    nvim.api.nvim_input("\r")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):match('current%.txt$') ~= nil", 5000, 20)

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "current.txt", "next.txt")
    H.nvim_wait_for_git_diff(nvim, "current.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "current.txt", false, false, 5000, 20)
end

T["reopens picker with inline source after staging from side-by-side diff"] = function()
    local repo = H.init_repo({
        ["aaa-outside.txt"] = { "old" },
        ["current.txt"] = { "old" },
        ["next.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/aaa-outside.txt", { "new" })
    H.write_file(repo .. "/current.txt", { "new" })
    H.write_file(repo .. "/next.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = { initial_mode = 'n' },
            diff = { file = { keys = { toggle_stage_file = 's' } } },
        })
    ]])
    install_picker_state_helper(nvim)
    nvim.lua([[
        require('delta.picker').show({
            source = { label = 'Inline', files = function() return { 'current.txt', 'next.txt' } end },
            preselect_path = 'current.txt',
        })
    ]])
    wait_for_picker_node(nvim, "current.txt", "unstaged")

    nvim.api.nvim_input("\r")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):match('current%.txt$') ~= nil", 5000, 20)

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "current.txt", "next.txt")
end

T["reopens picker with source selected by cycling"] = function()
    local repo = H.init_repo({
        ["alpha.txt"] = { "old" },
        ["current.txt"] = { "old" },
        ["next.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/alpha.txt", { "new" })
    H.write_file(repo .. "/current.txt", { "new" })
    H.write_file(repo .. "/next.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        local picker_actions = require('delta').picker.actions
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = {
                initial_mode = 'n',
                actions = {
                    cycle_source = { 'c', picker_actions.cycle_source },
                },
                sources = {
                    alpha = { label = 'Alpha', files = function() return { 'alpha.txt' } end },
                    review = { label = 'Review', files = function() return { 'current.txt', 'next.txt' } end },
                },
            },
            diff = { file = { keys = { toggle_stage_file = 's' } } },
        })
    ]])
    install_picker_state_helper(nvim)
    nvim.lua([[require('delta.picker').show({ source = 'alpha' })]])
    wait_for_picker_source(nvim, "alpha")

    nvim.lua([[
        local state = _G.picker_state()
        local cycled = false
        local mapped = {}
        for _, mode in ipairs({ 'n', 'i' }) do
            for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.input_buf, mode)) do
                mapped[#mapped + 1] = mode .. ':' .. map.lhs
                if map.lhs == 'c' or map.lhs == '<Tab>' then
                    map.callback()
                    cycled = true
                    break
                end
            end
            if cycled then
                break
            end
        end
        assert(cycled, 'cycle source mapping was not found: ' .. table.concat(mapped, ', '))
    ]])
    wait_for_picker_source(nvim, "review")
    wait_for_picker_node(nvim, "current.txt", "unstaged")

    nvim.api.nvim_input("\r")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):match('current%.txt$') ~= nil", 5000, 20)

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "current.txt", "next.txt")
    wait_for_picker_source(nvim, "review")
end

T["reopens remembered source at first unstaged when staged path leaves source"] = function()
    local repo = H.init_repo({
        ["aaa-git.txt"] = { "old" },
        ["current.txt"] = { "old" },
        ["zzz-review.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/aaa-git.txt", { "new" })
    H.write_file(repo .. "/current.txt", { "new" })
    H.write_file(repo .. "/zzz-review.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        _G.include_current_in_review = true
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = {
                initial_mode = 'n',
                sources = {
                    review = {
                        label = 'Review',
                        files = function()
                            if _G.include_current_in_review then
                                return { 'current.txt', 'zzz-review.txt' }
                            end
                            return { 'zzz-review.txt' }
                        end,
                    },
                },
            },
            diff = { file = { keys = { toggle_stage_file = 's' } } },
        })
    ]])
    install_picker_state_helper(nvim)
    nvim.lua([[require('delta.picker').show({ source = 'review', preselect_path = 'current.txt' })]])
    wait_for_picker_node(nvim, "current.txt", "unstaged")

    nvim.api.nvim_input("\r")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):match('current%.txt$') ~= nil", 5000, 20)
    nvim.lua([[ _G.include_current_in_review = false ]])

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "current.txt", "zzz-review.txt")
    wait_for_picker_source(nvim, "review")
end

T["falls back to git when remembered source has no unstaged files"] = function()
    local repo = H.init_repo({
        ["aaa-git.txt"] = { "old" },
        ["current.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/aaa-git.txt", { "new" })
    H.write_file(repo .. "/current.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            picker = {
                initial_mode = 'n',
                sources = {
                    review = { label = 'Review', files = function() return { 'current.txt' } end },
                },
            },
            diff = { file = { keys = { toggle_stage_file = 's' } } },
        })
    ]])
    install_picker_state_helper(nvim)
    nvim.lua([[require('delta.picker').show({ source = 'review', preselect_path = 'current.txt' })]])
    wait_for_picker_node(nvim, "current.txt", "unstaged")

    nvim.api.nvim_input("\r")
    H.nvim_wait_for(nvim, "vim.api.nvim_buf_get_name(0):match('current%.txt$') ~= nil", 5000, 20)

    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "current.txt", "aaa-git.txt")
    wait_for_picker_source(nvim, "git")
end

T["opens staged picker entry in split using staged mode"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "base" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "staged" })
    H.git(repo, "add", "file.txt")
    H.write_file(repo .. "/file.txt", { "unstaged" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        local picker_actions = require('delta').picker.actions
        require('delta').setup({
            picker = {
                initial_mode = 'n',
                actions = {
                    open_vsplit = { 'v', picker_actions.open_vsplit },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    install_spotlight_wins_helper(nvim)

    nvim.lua([[require('delta.picker').show()]])
    H.nvim_wait_for(nvim, [[
        (function()
            local state = _G.picker_state and _G.picker_state()
            if not state or state.input_buf == 0 or not vim.api.nvim_buf_is_valid(state.input_buf) then
                return false
            end
            for _, node in ipairs(state.nodes) do
                if node and node.path == 'file.txt' and node.section == 'staged' then
                    return true
                end
            end
            return false
        end)()
    ]], 5000, 20)
    nvim.lua([[
        local state = _G.picker_state()
        for i, node in ipairs(state.nodes) do
            if node and node.path == 'file.txt' and node.section == 'staged' then
                state.cursor_idx = i
                break
            end
        end
        local opened = false
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.input_buf, 'n')) do
            if map.lhs == 'v' then
                map.callback()
                opened = true
                break
            end
        end
        assert(opened, 'open_vsplit mapping was not found')
    ]])

    H.nvim_wait_for(nvim, "#vim.api.nvim_tabpage_list_wins(0) == 2", 5000, 20)
    H.nvim_wait_for(nvim, [[
        (function()
            local wins = _G.spotlight_wins and _G.spotlight_wins()
            if not wins then
                return false
            end
            for _, win in pairs(wins) do
                if win.resolved_mode == 'staged' then
                    return true
                end
            end
            return false
        end)()
    ]], 5000, 20)
end

T["opens staged picker entry in active spotlight window using staged mode"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "base" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "staged" })
    H.git(repo, "add", "file.txt")
    H.write_file(repo .. "/file.txt", { "unstaged" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            picker = { initial_mode = 'n' },
        })
    ]])
    install_picker_state_helper(nvim)
    install_spotlight_wins_helper(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    nvim.lua([[require('delta.spotlight.core').ensure()]])
    H.nvim_wait_for(nvim, [[
        (function()
            local wins = _G.spotlight_wins and _G.spotlight_wins()
            return wins and wins[vim.api.nvim_get_current_win()] ~= nil
        end)()
    ]], 5000, 20)

    nvim.lua([[require('delta.picker').show()]])
    H.nvim_wait_for(nvim, [[
        (function()
            local state = _G.picker_state and _G.picker_state()
            if not state or state.input_buf == 0 or not vim.api.nvim_buf_is_valid(state.input_buf) then
                return false
            end
            for _, node in ipairs(state.nodes) do
                if node and node.path == 'file.txt' and node.section == 'staged' then
                    return true
                end
            end
            return false
        end)()
    ]], 5000, 20)
    nvim.lua([[
        local state = _G.picker_state()
        for i, node in ipairs(state.nodes) do
            if node and node.path == 'file.txt' and node.section == 'staged' then
                state.cursor_idx = i
                break
            end
        end
        local opened = false
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.input_buf, 'n')) do
            if map.lhs == '<CR>' then
                map.callback()
                opened = true
                break
            end
        end
        assert(opened, 'open mapping was not found')
    ]])

    H.nvim_wait_for(nvim, [[
        (function()
            local wins = _G.spotlight_wins and _G.spotlight_wins()
            local win = wins and wins[vim.api.nvim_get_current_win()]
            return win and win.resolved_mode == 'staged'
        end)()
    ]], 5000, 20)
end

T["does not reopen picker after unstaging from side-by-side diff"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
        ["next.txt"] = { "old" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })
    H.git(repo, "add", "file.txt")
    H.write_file(repo .. "/next.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'staged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, false, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, true, 5000, 20)
    H.eq(nvim.lua("return _G.picker_state() == nil"), true)
end

T["saves visible unsaved changes before staging from side-by-side diff"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")
    nvim.lua([[vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'two unsaved' })]])

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, false, 5000, 20)
    H.eq(vim.fn.readfile(repo .. "/file.txt"), { "one", "two unsaved", "three" })
end

T["does not stage unseen unsaved changes from stale side-by-side diff"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    local source_buf = nvim.api.nvim_get_current_buf()
    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    nvim.lua_func(function(buf)
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "two unseen" })
    end, source_buf)

    nvim.api.nvim_input("s")
    vim.uv.sleep(200)
    H.eq(nvim.lua("return #vim.api.nvim_list_tabpages()"), 2)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, false, 5000, 20)
    H.eq(vim.fn.readfile(repo .. "/file.txt"), { "one", "two changed", "three" })
    H.eq(nvim.lua("return _G.picker_state() == nil"), true)
end

T["does not stage saved changes from stale side-by-side diff"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            spotlight = { reopen_picker_after_stage = true },
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    install_picker_state_helper(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")

    local source_buf = nvim.api.nvim_get_current_buf()
    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    nvim.lua_func(function(buf)
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "two saved unseen" })
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("write")
        end)
    end, source_buf)

    nvim.api.nvim_input("s")
    vim.uv.sleep(200)
    H.eq(nvim.lua("return #vim.api.nvim_list_tabpages()"), 2)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, false, 5000, 20)
    H.eq(vim.fn.readfile(repo .. "/file.txt"), { "one", "two saved unseen", "three" })
    H.eq(nvim.lua("return _G.picker_state() == nil"), true)
end

T["does not unstage staged diff when buffer has unseen unsaved changes"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })
    H.git(repo, "add", "file.txt")

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            diff = {
                file = {
                    keys = {
                        toggle_stage_file = 's',
                    },
                },
            },
        })
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")
    nvim.lua([[vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'two unseen' })]])

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'staged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    vim.uv.sleep(200)
    H.eq(nvim.lua("return #vim.api.nvim_list_tabpages()"), 2)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, true, 5000, 20)
end

-- Picker launched from a side-by-side diff tab.

local function init_replace_repo()
    local other = numbered_lines(60)
    local repo = H.init_repo({
        ["file.txt"] = numbered_lines(100),
        ["other.txt"] = other,
    })
    local changed = numbered_lines(100)
    changed[90] = "line 90 changed"
    H.write_file(repo .. "/file.txt", changed)
    local other_changed = vim.deepcopy(other)
    other_changed[40] = "line 40 changed"
    H.write_file(repo .. "/other.txt", other_changed)
    return repo
end

local function setup_replace(nvim, extra)
    nvim.lua(string.format([[
        local picker_actions = require('delta').picker.actions
        require('delta').setup({
            %s
            picker = {
                initial_mode = 'n',
                actions = {
                    open_vsplit = { 'v', picker_actions.open_vsplit },
                    open_hsplit = { 'x', picker_actions.open_hsplit },
                    spotlight = { 'z', picker_actions.spotlight },
                },
            },
            diff = { file = { keys = { close = '<D-w>', toggle_stage_file = 's' } } },
        })
    ]], extra or ""))
    install_picker_state_helper(nvim)
    install_spotlight_wins_helper(nvim)
    install_diff_state_helper(nvim)
end

---@param pane "left"|"right"
local function open_picker_from_pane(nvim, pane, cursor_line)
    nvim.lua_func(function(side, line)
        local state = _G.current_diff_state()
        local win = side == "left" and state.left_win or state.right_win
        vim.api.nvim_set_current_win(win)
        if line then
            vim.api.nvim_win_set_cursor(win, { line, 0 })
        end
    end, pane, cursor_line)
    nvim.lua([[require('delta.picker').show()]])
end

local function select_picker_node(nvim, path, section)
    H.nvim_wait_for(nvim, string.format([[
        (function()
            local state = _G.picker_state and _G.picker_state()
            if not state or state.input_buf == 0 or not vim.api.nvim_buf_is_valid(state.input_buf) then
                return false
            end
            for i, node in ipairs(state.nodes) do
                if node and node.path == %q and node.section == %q then
                    state.cursor_idx = i
                    return true
                end
            end
            return false
        end)()
    ]], path, section), 5000, 20)
end

local function press_picker_key(nvim, lhs)
    nvim.lua_func(function(key)
        local state = _G.picker_state()
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.input_buf, "n")) do
            if map.lhs == key then
                map.callback()
                return
            end
        end
        error("picker mapping not found: " .. key)
    end, lhs)
end

local function wait_for_diff_file(nvim, path, mode)
    H.nvim_wait_for(nvim, string.format([[
        (function()
            local state = _G.current_diff_state and _G.current_diff_state()
            return state ~= nil and state.file.path == %q and state.resolved_mode == %q
                and vim.api.nvim_win_get_buf(state.left_win) == state.left_buf
                and vim.api.nvim_win_get_buf(state.right_win) == state.right_buf
        end)()
    ]], path, mode), 5000, 20)
end

local function diff_tab_snapshot(nvim)
    return nvim.lua([[
        local state = _G.current_diff_state()
        local function pane(win)
            local buf = vim.api.nvim_win_get_buf(win)
            local map = vim.api.nvim_win_call(win, function()
                return vim.fn.maparg('<D-w>', 'n', false, true)
            end)
            return {
                name = vim.api.nvim_buf_get_name(buf),
                diff = vim.wo[win].diff,
                lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
                cursor = vim.api.nvim_win_get_cursor(win)[1],
                winbar = vim.wo[win].winbar,
                close = map.desc,
            }
        end
        return {
            tabs = #vim.api.nvim_list_tabpages(),
            wins = #vim.api.nvim_tabpage_list_wins(state.tab),
            left = pane(state.left_win),
            right = pane(state.right_win),
            picker_open = _G.picker_state() ~= nil,
            spotlight = next(_G.spotlight_wins() or {}) ~= nil,
        }
    ]])
end

local function assert_replaced(nvim, repo, path, old_lines, new_lines, first_line)
    local snap = diff_tab_snapshot(nvim)
    H.eq(snap.tabs, 2)
    H.eq(snap.wins, 2)
    H.eq(snap.picker_open, false)
    H.eq(snap.spotlight, false)
    for _, side in ipairs({ "left", "right" }) do
        local pane = snap[side]
        assert(pane.name:find("^delta://diff/"), pane.name)
        assert(pane.name:find(repo .. "/" .. path, 1, true) or pane.name:find(path, 1, true), pane.name)
        H.eq(pane.diff, true)
        H.eq(pane.close, "delta.diff.file.close")
        assert(pane.winbar:find(path, 1, true), pane.winbar)
        H.eq(pane.cursor, first_line)
    end
    H.eq(snap.left.lines, old_lines)
    H.eq(snap.right.lines, new_lines)
end

local function other_lines(changed)
    local lines = numbered_lines(60)
    if changed then
        lines[40] = "line 40 changed"
    end
    return lines
end

T["picker open from right diff pane updates the diff"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    open_file_diff(nvim)

    open_picker_from_pane(nvim, "right", 90)
    select_picker_node(nvim, "other.txt", "unstaged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "other.txt", "unstaged")

    assert_replaced(nvim, repo, "other.txt", other_lines(false), other_lines(true), 40)
end

T["picker open from left diff pane updates the diff and close key closes the tab"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    local origin_win = nvim.lua("return vim.api.nvim_get_current_win()")
    open_file_diff(nvim)

    open_picker_from_pane(nvim, "left", 90)
    select_picker_node(nvim, "other.txt", "unstaged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "other.txt", "unstaged")
    assert_replaced(nvim, repo, "other.txt", other_lines(false), other_lines(true), 40)

    nvim.lua([[vim.api.nvim_set_current_win(_G.current_diff_state().left_win)]])
    nvim.api.nvim_input("<D-w>")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.eq(nvim.lua("return vim.api.nvim_get_current_win()"), origin_win)
    H.eq(nvim.lua("return next(_G.diff_tabs()) == nil"), true)
end

T["split and spotlight picker actions from a diff pane update the diff"] = function()
    for _, key in ipairs({ "v", "x", "z" }) do
        local repo = init_replace_repo()
        H.finally_rm(repo)
        local nvim = H.new_nvim()
        MiniTest.finally(nvim.stop)
        H.nvim_set_cwd(nvim, repo)
        setup_replace(nvim)
        H.nvim_edit(nvim, repo .. "/file.txt")
        open_file_diff(nvim)

        open_picker_from_pane(nvim, "right")
        select_picker_node(nvim, "other.txt", "unstaged")
        press_picker_key(nvim, key)
        wait_for_diff_file(nvim, "other.txt", "unstaged")

        assert_replaced(nvim, repo, "other.txt", other_lines(false), other_lines(true), 40)
        nvim.stop()
    end
end

T["staged picker entry switches the diff to staged mode"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.git(repo, "add", "other.txt")
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    open_file_diff(nvim)

    open_picker_from_pane(nvim, "right")
    select_picker_node(nvim, "other.txt", "staged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "other.txt", "staged")

    assert_replaced(nvim, repo, "other.txt", other_lines(false), other_lines(true), 40)
    local snap = diff_tab_snapshot(nvim)
    assert(snap.left.winbar:find("HEAD", 1, true), snap.left.winbar)
    assert(snap.right.winbar:find("INDEX", 1, true), snap.right.winbar)
end

T["stage key after replacement acts on the new file"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    open_file_diff(nvim)

    open_picker_from_pane(nvim, "right")
    select_picker_node(nvim, "other.txt", "unstaged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "other.txt", "unstaged")

    nvim.api.nvim_input("s")
    H.nvim_wait_for_git_diff(nvim, "other.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "other.txt", false, false, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, false, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, true, 5000, 20)
end

T["closing a switched diff returns to origin showing the new file at the diff cursor"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    local origin = nvim.lua("return { win = vim.api.nvim_get_current_win(), buf = vim.api.nvim_get_current_buf() }")
    open_file_diff(nvim)

    open_picker_from_pane(nvim, "right")
    select_picker_node(nvim, "other.txt", "unstaged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "other.txt", "unstaged")

    nvim.lua([[
        local state = _G.current_diff_state()
        vim.api.nvim_set_current_win(state.right_win)
        vim.api.nvim_win_set_cursor(state.right_win, { 41, 0 })
    ]])
    nvim.api.nvim_input("<D-w>")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)

    local result = nvim.lua_func(function(origin_buf)
        local buf = vim.api.nvim_get_current_buf()
        return {
            win = vim.api.nvim_get_current_win(),
            name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"),
            cursor = vim.api.nvim_win_get_cursor(0)[1],
            wins = #vim.api.nvim_tabpage_list_wins(0),
            origin_loaded = vim.api.nvim_buf_is_loaded(origin_buf),
        }
    end, origin.buf)
    H.eq(result, { win = origin.win, name = "other.txt", cursor = 41, wins = 1, origin_loaded = true })
end

T["closing a diff switched back to the origin file keeps the buffer and restores cursor"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    local origin = nvim.lua("return { win = vim.api.nvim_get_current_win(), buf = vim.api.nvim_get_current_buf() }")
    open_file_diff(nvim)

    open_picker_from_pane(nvim, "right")
    select_picker_node(nvim, "other.txt", "unstaged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "other.txt", "unstaged")
    open_picker_from_pane(nvim, "right")
    select_picker_node(nvim, "file.txt", "unstaged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "file.txt", "unstaged")

    nvim.lua([[
        local state = _G.current_diff_state()
        vim.api.nvim_set_current_win(state.right_win)
        vim.api.nvim_win_set_cursor(state.right_win, { 88, 0 })
    ]])
    nvim.api.nvim_input("<D-w>")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)

    local result = nvim.lua([[
        return {
            win = vim.api.nvim_get_current_win(),
            buf = vim.api.nvim_get_current_buf(),
            cursor = vim.api.nvim_win_get_cursor(0)[1],
        }
    ]])
    H.eq(result, { win = origin.win, buf = origin.buf, cursor = 88 })
end

T["stage with picker reopen stays in the diff and the picker updates it"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim, "spotlight = { reopen_picker_after_stage = true },")
    H.nvim_edit(nvim, repo .. "/file.txt")
    open_file_diff(nvim)

    nvim.lua([[vim.api.nvim_set_current_win(_G.current_diff_state().right_win)]])
    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "file.txt", "other.txt")
    local staged = numbered_lines(100)
    staged[90] = "line 90 changed"
    local snap = diff_tab_snapshot(nvim)
    H.eq(snap.left.lines, numbered_lines(100))
    H.eq(snap.right.lines, staged)
    assert(snap.left.winbar:find("HEAD", 1, true), snap.left.winbar)
    assert(snap.right.winbar:find("INDEX", 1, true), snap.right.winbar)

    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "other.txt", "unstaged")
    assert_replaced(nvim, repo, "other.txt", other_lines(false), other_lines(true), 40)
end

T["dismissing the reopened picker keeps the staged view"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim, "spotlight = { reopen_picker_after_stage = true },")
    H.nvim_edit(nvim, repo .. "/file.txt")
    open_file_diff(nvim)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "file.txt", "other.txt")
    nvim.api.nvim_input("<Esc>")
    H.nvim_wait_for(nvim, "_G.picker_state() == nil", 5000, 20)

    local state = nvim.lua([[
        local state = _G.current_diff_state()
        return { path = state.file.path, mode = state.resolved_mode, tabs = #vim.api.nvim_list_tabpages() }
    ]])
    H.eq(state, { path = "file.txt", mode = "staged", tabs = 2 })
end

T["unstaging after dismissing the reopened picker returns to the unstaged view"] = function()
    local repo = init_replace_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim, "spotlight = { reopen_picker_after_stage = true },")
    H.nvim_edit(nvim, repo .. "/file.txt")
    open_file_diff(nvim)

    nvim.api.nvim_input("s")
    wait_for_staged_diff_with_picker(nvim, "file.txt", "other.txt")
    nvim.api.nvim_input("<Esc>")
    H.nvim_wait_for(nvim, "_G.picker_state() == nil", 5000, 20)

    nvim.lua([[vim.api.nvim_set_current_win(_G.current_diff_state().right_win)]])
    nvim.api.nvim_input("s")
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, false, 5000, 20)
    wait_for_diff_file(nvim, "file.txt", "unstaged")
    H.eq(nvim.lua("return #vim.api.nvim_list_tabpages()"), 2)
    local snap = diff_tab_snapshot(nvim)
    assert(snap.left.winbar:find("INDEX", 1, true), snap.left.winbar)
    assert(snap.right.winbar:find("WORKTREE", 1, true), snap.right.winbar)
end

local function diff_side_lines(nvim)
    return nvim.lua([[
        local state = _G.current_diff_state()
        return {
            left = vim.api.nvim_buf_get_lines(state.left_buf, 0, -1, false),
            right = vim.api.nvim_buf_get_lines(state.right_buf, 0, -1, false),
        }
    ]])
end

local NO_NL = "\\ No newline at end of file"

T["final newline: normal change has no extra trailing line"] = function()
    local repo = H.init_repo({ ["file.txt"] = { "one", "two" } })
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.write_file(repo .. "/file.txt", { "one", "two changed" })
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    nvim.lua_notify([[require('delta.diff').open_file({ path = 'file.txt' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    H.eq(diff_side_lines(nvim), { left = { "one", "two" }, right = { "one", "two changed" } })
end

local function init_no_eol_repo()
    local repo = H.tmpdir()
    H.git(repo, "init")
    H.git(repo, "config", "user.name", "delta-tests")
    H.git(repo, "config", "user.email", "delta-tests@nvim.com")
    local f = assert(io.open(repo .. "/noeol.txt", "wb"))
    f:write("a")
    f:close()
    H.write_file(repo .. "/other.txt", { "old" })
    H.git(repo, "add", ".")
    H.git(repo, "commit", "-m", "initial")
    H.write_file(repo .. "/noeol.txt", { "a" })
    H.write_file(repo .. "/other.txt", { "new" })
    return repo
end

T["final newline: newline-only change opens by path and stages"] = function()
    local repo = init_no_eol_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    nvim.lua_notify([[require('delta.diff').open_file({ path = 'noeol.txt' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    H.eq(diff_side_lines(nvim), { left = { "a", NO_NL }, right = { "a" } })

    nvim.lua([[vim.api.nvim_set_current_win(_G.current_diff_state().right_win)]])
    nvim.api.nvim_input("s")
    H.nvim_wait_for_git_diff(nvim, "noeol.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "noeol.txt", false, false, 5000, 20)
end

T["final newline: newline-only change opens through the picker"] = function()
    local repo = init_no_eol_repo()
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    nvim.lua_notify([[require('delta.diff').open_file({ path = 'other.txt' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    open_picker_from_pane(nvim, "right")
    select_picker_node(nvim, "noeol.txt", "unstaged")
    nvim.api.nvim_input("\r")
    wait_for_diff_file(nvim, "noeol.txt", "unstaged")
    H.eq(diff_side_lines(nvim), { left = { "a", NO_NL }, right = { "a" } })
end

T["final newline: source buffer without eol shows the marker on the worktree side"] = function()
    local repo = H.init_repo({ ["file.txt"] = { "a", "b" } })
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    -- The file on disk has an unstaged change and a final newline; the unsaved buffer drops the newline.
    H.write_file(repo .. "/file.txt", { "a", "b changed" })
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    nvim.lua([[
        vim.bo.endofline = false
        vim.bo.fixendofline = false
    ]])
    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    H.eq(diff_side_lines(nvim), { left = { "a", "b" }, right = { "a", "b changed", NO_NL } })
end

T["final newline: unchanged empty tracked file reports no changes"] = function()
    local repo = H.tmpdir()
    H.finally_rm(repo)
    H.git(repo, "init")
    H.git(repo, "config", "user.name", "delta-tests")
    H.git(repo, "config", "user.email", "delta-tests@nvim.com")
    local f = assert(io.open(repo .. "/empty.txt", "wb"))
    f:close()
    H.git(repo, "add", ".")
    H.git(repo, "commit", "-m", "initial")

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    nvim.lua([[
        _G.notes = {}
        local notify = vim.notify
        vim.notify = function(msg, ...)
            table.insert(_G.notes, msg)
            return notify(msg, ...)
        end
    ]])
    H.nvim_edit(nvim, repo .. "/empty.txt")
    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, [[vim.iter(_G.notes):any(function(m) return m:find('No changes for current file', 1, true) ~= nil end)]], 5000, 20)
    H.eq(nvim.lua("return #vim.api.nvim_list_tabpages()"), 1)
end

T["final newline: emptied source buffer shows an empty worktree side"] = function()
    local repo = H.init_repo({ ["file.txt"] = { "x" } })
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    -- The file on disk differs from the index, so auto mode compares content.
    H.write_file(repo .. "/file.txt", { "y" })
    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim)
    H.nvim_edit(nvim, repo .. "/file.txt")
    -- With noendofline, an unmapped empty buffer would read as { "" } without a final newline and get a marker line.
    nvim.lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
        vim.bo.endofline = false
        vim.bo.fixendofline = false
    ]])
    nvim.lua_notify([[require('delta.diff').open_file()]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)
    -- An empty side buffer always holds one empty line; the empty buffer must not add a marker or a stray line.
    H.eq(diff_side_lines(nvim), { left = { "x" }, right = { "" } })
    H.eq(nvim.lua("return _G.current_diff_state().used_source_buffer"), true)
end

T["stage leaving no staged diff closes the tab and reopens picker from origin once"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one" },
        ["next.txt"] = { "old" },
    })
    H.finally_rm(repo)
    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.write_file(repo .. "/file.txt", { "staged" })
    H.git(repo, "add", "file.txt")
    H.write_file(repo .. "/file.txt", { "one" })
    H.write_file(repo .. "/next.txt", { "new" })

    H.nvim_set_cwd(nvim, repo)
    setup_replace(nvim, "spotlight = { reopen_picker_after_stage = true },")
    nvim.lua([[
        _G.picker_shows = 0
        local UI = require('delta.picker.ui')
        local show = UI.show
        _G.picker_state = function()
            return find_upvalue(show, 'state')
        end
        UI.show = function(...)
            _G.picker_shows = _G.picker_shows + 1
            return show(...)
        end
    ]])
    H.nvim_edit(nvim, repo .. "/file.txt")
    local origin_win = nvim.lua("return vim.api.nvim_get_current_win()")
    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_node(nvim, "next.txt", "unstaged")
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, false, 5000, 20)
    nvim.lua("vim.wait(200)")

    local result = nvim.lua(string.format([[
        local state = _G.picker_state()
        return {
            shows = _G.picker_shows,
            origin = state.origin_win == %d,
            float_tab = vim.api.nvim_win_get_tabpage(state.tree_win) == vim.api.nvim_get_current_tabpage(),
            diff_tabs = next(_G.diff_tabs()) == nil,
        }
    ]], origin_win))
    H.eq(result, { shows = 1, origin = true, float_tab = true, diff_tabs = true })
end

return T
