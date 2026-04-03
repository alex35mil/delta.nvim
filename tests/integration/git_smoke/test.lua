local T = MiniTest.new_set()

local H = require("tests.support.helpers")

T["creates repo and sees worktree diff"] = function()
    local repo = H.init_repo({
        ["file.txt"] = { "one", "two", "three" },
    })
    H.finally_rm(repo)

    H.write_file(repo .. "/file.txt", { "one", "two changed", "three" })

    local diff = H.git(repo, "diff", "--", "file.txt")
    assert(diff ~= "")
    assert(diff:find("two changed", 1, true) ~= nil)
end

return T
