local T = MiniTest.new_set()

local H = require("tests.support.helpers")

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
    assert(opened.left_name:find("delta://diff/", 1, true) ~= nil)
    assert(opened.right_name:find("delta://diff/", 1, true) ~= nil)
    H.eq(opened.left_line, "two")
    H.eq(opened.right_line, "two changed")
    H.eq(nvim.lua("return vim.go.diffopt:match('context:(%d+)')"), "1")

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
    H.nvim_edit(nvim, repo .. "/file.txt")

    nvim.lua_notify([[require('delta.diff').open_file({ mode = 'unstaged' })]])
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 2", 5000, 20)

    nvim.api.nvim_input("s")
    H.nvim_wait_for(nvim, "#vim.api.nvim_list_tabpages() == 1", 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", true, true, 5000, 20)
    H.nvim_wait_for_git_diff(nvim, "file.txt", false, false, 5000, 20)
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
