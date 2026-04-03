--- delta.picker public API.

---@class delta.Picker
local M = {}

local UI = require("delta.picker.ui")
local Highlights = require("delta.picker.highlights")

M.actions = require("delta.picker.actions")

function M.setup()
    Highlights.setup()
end

--- Show the picker.
---@param opts? delta.ShowOpts
function M.show(opts)
    UI.show(opts)
end

--- Toggle the picker.
---@param opts? delta.ShowOpts
function M.toggle(opts)
    UI.toggle(opts)
end

--- Close the picker.
function M.close()
    UI.close()
end

--- Check if the picker is currently open.
---@return boolean
function M.is_open()
    return UI.is_open()
end

return M
