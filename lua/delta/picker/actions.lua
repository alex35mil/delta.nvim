--- Built-in action factories for delta.nvim.

local M = {}

--- Move the cursor by a number of lines.
---@param step number
---@return delta.picker.ActionHandler
function M.move(step)
    return function(ctx)
        ctx.move(step)
    end
end

--- Move cursor to first node.
---@param ctx delta.picker.ActionContext
function M.move_to_top(ctx)
    ctx.move_to_top()
end

--- Move cursor to last node.
---@param ctx delta.picker.ActionContext
function M.move_to_bottom(ctx)
    ctx.move_to_bottom()
end

--- Expand directory under cursor (no-op on files).
---@param ctx delta.picker.ActionContext
function M.expand(ctx)
    ctx.expand()
end

--- Collapse directory under cursor (no-op on files).
---@param ctx delta.picker.ActionContext
function M.collapse(ctx)
    ctx.collapse()
end

--- Open file or toggle directory.
---@param ctx delta.picker.ActionContext
---@return boolean true if a file was opened
function M.open(ctx)
    if not ctx.node then
        return false
    end
    if ctx.node.is_dir then
        if ctx.node.expanded then
            ctx.collapse()
        else
            ctx.expand()
        end
        return false
    end
    return ctx.open()
end

--- Open file in vertical split (no-op on directories).
---@param ctx delta.picker.ActionContext
function M.open_vsplit(ctx)
    ctx.open({ cmd = "vsplit" })
end

--- Open file in horizontal split (no-op on directories).
---@param ctx delta.picker.ActionContext
function M.open_hsplit(ctx)
    ctx.open({ cmd = "split" })
end

--- Open file with spotlight enabled (no-op on directories).
---@param ctx delta.picker.ActionContext
function M.spotlight(ctx)
    ctx.open({ cmd = "edit", spotlight = true })
end

--- Toggle staged/unstaged for current file (no-op on directories).
---@param ctx delta.picker.ActionContext
function M.toggle_stage(ctx)
    ctx.toggle_stage()
end

--- Toggle staged/unstaged for current file, then run cb on success.
---@param cb fun()
---@return delta.picker.ActionHandler
function M.toggle_stage_and(cb)
    return function(ctx)
        ctx.toggle_stage(cb)
    end
end

--- Reset current entry to its section baseline.
---@param ctx delta.picker.ActionContext
function M.reset(ctx)
    ctx.reset()
end

--- Reset current entry to its section baseline, then run cb on success.
---@param cb fun()
---@return delta.picker.ActionHandler
function M.reset_and(cb)
    return function(ctx)
        ctx.reset(cb)
    end
end


--- Cycle to the next source.
---@param ctx delta.picker.ActionContext
function M.cycle_source(ctx)
    ctx.cycle_source()
end

--- Cycle to the previous source.
---@param ctx delta.picker.ActionContext
function M.cycle_source_back(ctx)
    ctx.cycle_source_back()
end

--- Toggle the preview pane.
---@param ctx delta.picker.ActionContext
function M.toggle_preview(ctx)
    ctx.toggle_preview()
end

--- Scroll the preview pane by a number of lines.
---@param step number
---@return delta.picker.ActionHandler
function M.scroll_preview(step)
    return function(ctx)
        ctx.scroll_preview(step)
    end
end

--- Close the picker.
---@param ctx delta.picker.ActionContext
function M.close(ctx)
    ctx.close()
end

return M
