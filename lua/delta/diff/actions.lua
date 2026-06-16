--- Built-in action handlers for delta.diff.

local M = {}

--- Open hunk diff popup for the current hunk, or focus it if already visible.
---@param ctx? delta.diff.ActionContext
function M.open_hunk_diff(ctx)
    require("delta.diff").open_hunk(ctx and { winid = ctx.win, bufid = ctx.buf } or nil)
end

--- Open a side-by-side diff tab for the current file.
---@param ctx? delta.diff.ActionContext
function M.open_file_diff(ctx)
    require("delta.diff").open_file(ctx and { winid = ctx.win, bufid = ctx.buf } or nil)
end

return M
