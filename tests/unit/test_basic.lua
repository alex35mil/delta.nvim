local T = MiniTest.new_set()

T["loads delta and runs setup"] = function()
    local ok, delta = pcall(require, "delta")

    assert(ok)
    assert(type(delta) == "table")

    delta.setup()
end

T["failed setup does not poison later setup attempts"] = function()
    package.loaded["delta"] = nil
    local delta = require("delta")

    local ok_config = pcall(delta.setup, { diff = { keys = {} } })
    assert(not ok_config)

    local ok_late = pcall(delta.setup, {
        diff = {
            actions = {
                broken = { 42, function() end },
            },
        },
    })
    assert(not ok_late)

    delta.setup()
end

T["errors on old diff config paths"] = function()
    local Config = require("delta.config")

    local ok_spotlight, err_spotlight = pcall(Config.setup, { spotlight = { diff = {} } })
    assert(not ok_spotlight)
    assert(tostring(err_spotlight):find("spotlight.diff moved to diff.hunk", 1, true) ~= nil)

    local ok_file, err_file = pcall(Config.setup, { diff = { keys = {} } })
    assert(not ok_file)
    assert(tostring(err_file):find("diff.keys moved to diff.file.keys", 1, true) ~= nil)

    local ok_action, err_action = pcall(Config.setup, {
        spotlight = {
            actions = {
                open_diff = { "gd", function() end },
            },
        },
    })
    assert(not ok_action)
    assert(
        tostring(err_action):find("spotlight.actions.open_diff moved to diff.actions.open_hunk_diff", 1, true) ~= nil
    )
end

return T
