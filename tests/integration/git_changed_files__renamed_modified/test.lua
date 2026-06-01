local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["uses new path for renamed and modified files"] = function()
    local repo = H.init_repo({
        ["old.res"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    H.git(repo, "mv", "old.res", "new.res")
    H.write_file(repo .. "/new.res", { "one", "two changed", "three" })

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)

    H.nvim_set_cwd(nvim, repo)

    local result = nvim.lua_func(function()
        local done = false
        local ok, changed
        require("delta.git").async(function()
            ok, changed = require("delta.git").get_changed_files()
            done = true
        end)

        local completed = vim.wait(5000, function()
            return done
        end, 20)

        return {
            completed = completed,
            ok = ok,
            unstaged = changed and changed.unstaged or {},
            staged = changed and changed.staged or {},
        }
    end)

    assert(result.completed, "timed out waiting for git status")
    assert(result.ok, "git status failed")
    H.eq(#result.unstaged, 1)
    H.eq(#result.staged, 1)
    H.eq(result.unstaged[1].path, "new.res")
    H.eq(result.staged[1].path, "new.res")
end

return T
