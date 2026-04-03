local T = MiniTest.new_set()

T["loads delta and runs setup"] = function()
    local ok, delta = pcall(require, "delta")

    assert(ok)
    assert(type(delta) == "table")

    delta.setup()
end

return T
