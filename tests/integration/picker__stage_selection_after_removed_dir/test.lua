local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["staging last file in a directory selects next unstaged entry"] = function()
    local repo = H.init_repo({
        ["dir/current.txt"] = { "old" },
        ["next.txt"] = { "old" },
        ["zzz.txt"] = { "old" },
    })
    H.finally_rm(repo)

    H.write_file(repo .. "/dir/current.txt", { "new" })
    H.write_file(repo .. "/next.txt", { "new" })
    H.write_file(repo .. "/zzz.txt", { "new" })

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)
    nvim.lua([[
        require('delta').setup({
            picker = {
                initial_mode = 'n',
                actions = {
                    toggle_stage = { 's', require('delta.picker.actions').toggle_stage },
                },
            },
        })

        _G.picker_state = function()
            return find_upvalue(require('delta.picker.ui').show, 'state')
        end

        require('delta.picker').show({ preselect_path = 'dir/current.txt' })
    ]])

    H.nvim_wait_for(nvim, [[
        (function()
            local state = _G.picker_state()
            local node = state and state.nodes[state.cursor_idx]
            return node and node.path == 'dir/current.txt'
        end)()
    ]], 5000, 20)

    nvim.api.nvim_input("s")

    H.nvim_wait_for(nvim, [[
        (function()
            local state = _G.picker_state()
            local node = state and state.nodes[state.cursor_idx]
            return node and node.path == 'next.txt' and node.section == 'unstaged'
        end)()
    ]], 5000, 20)
end

return T
