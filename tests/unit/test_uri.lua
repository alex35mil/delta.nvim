local T = MiniTest.new_set()
local H = require("tests.support.helpers")
local Uri = require("delta.uri")

T["constructs Delta URIs with unchanged components"] = function()
    H.eq(Uri.name("staged", "/repo/file.txt"), "delta://staged//repo/file.txt")
    H.eq(Uri.name("deleted", "/repo/file.txt"), "delta://deleted//repo/file.txt")
    H.eq(Uri.name("diff", 3, "index", "/repo/file.txt"), "delta://diff/3/index//repo/file.txt")
    H.eq(Uri.name("diff", "keymaps", 7), "delta://diff/keymaps/7")
end

T["parses the kind and preserves remaining URI components"] = function()
    local kind, path = Uri.parse("delta://staged//repo/file.txt")
    H.eq({ kind, path }, { "staged", "/repo/file.txt" })
    kind, path = Uri.parse("delta://diff/3/index//repo/file.txt")
    H.eq({ kind, path }, { "diff", "3/index//repo/file.txt" })
    kind, path = Uri.parse("delta://diff/keymaps/7")
    H.eq({ kind, path }, { "diff", "keymaps/7" })
end

T["leaves other URI schemes and filesystem paths unclassified"] = function()
    H.eq(Uri.parse("file:///repo/file.txt"), nil)
    H.eq(Uri.parse("https://example.com/file.txt"), nil)
    H.eq(Uri.parse("/repo/file.txt"), nil)
end

T["shared URI naming keeps Spotlight eligibility separate"] = function()
    local Paths = require("delta.spotlight.paths")
    local Repository = require("delta.repository")
    local absolute = Repository.canonical(vim.fn.getcwd() .. "/README.md")
    local path, kind = Paths.normalize(Uri.name("staged", absolute))
    H.eq({ path, kind }, { absolute, "staged" })
    path, kind = Paths.normalize(Uri.name("deleted", absolute))
    H.eq({ path, kind }, { absolute, "deleted" })
    H.eq(Paths.normalize(Uri.name("diff", 3, "index", absolute)), nil)
    H.eq(Paths.normalize(Uri.name("diff", "keymaps", 7)), nil)
end

return T
