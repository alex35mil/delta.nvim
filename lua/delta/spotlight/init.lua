--- delta.spotlight public API.
--- Focus on git diff hunks by folding everything else away.

---@class delta.Spotlight
local M = {}

local Core = require("delta.spotlight.core")

M.actions = require("delta.spotlight.actions")

function M.setup()
    Core.setup()
end

--- Enable spotlight on the current buffer/window.
---@param mode? delta.spotlight.RequestedMode
function M.ensure(mode)
    Core.ensure(mode)
end

--- Disable spotlight and restore original settings.
---@param buf? delta.BufId
function M.disable(buf)
    Core.disable(buf)
end

--- Toggle spotlight on the current buffer.
---@param mode? delta.spotlight.RequestedMode
function M.toggle(mode)
    Core.toggle(mode)
end

--- Disable spotlight on all active spotlight windows.
function M.disable_all()
    Core.disable_all()
end

--- Check if spotlight is active on a window.
---@param win? delta.WinId defaults to current window
---@return boolean
function M.is_active(win)
    return Core.is_active(win)
end

return M
