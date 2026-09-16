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
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_node(nvim, "next.txt", "unstaged")
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
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_node(nvim, "next.txt", "unstaged")
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
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_node(nvim, "next.txt", "unstaged")
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
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_node(nvim, "next.txt", "unstaged")
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
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_source(nvim, "review")
    wait_for_picker_node(nvim, "next.txt", "unstaged")
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
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_source(nvim, "review")
    wait_for_picker_node(nvim, "zzz-review.txt", "unstaged")
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
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    wait_for_picker_source(nvim, "git")
    wait_for_picker_node(nvim, "aaa-git.txt", "unstaged")
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

return T
