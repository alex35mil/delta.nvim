--- Built-in action handlers for delta.spotlight.

local M = {}

--- Expand context lines around hunks.
---@param ctx delta.spotlight.ActionContext
function M.expand_context(ctx)
    ctx.expand()
end

--- Expand context lines around hunks by a specific step.
---@param step number
---@return delta.spotlight.ActionHandler
function M.expand_context_by(step)
    return function(ctx)
        ctx.expand(step)
    end
end

--- Shrink context lines around hunks.
---@param ctx delta.spotlight.ActionContext
function M.shrink_context(ctx)
    ctx.shrink()
end

--- Shrink context lines around hunks by a specific step.
---@param step number
---@return delta.spotlight.ActionHandler
function M.shrink_context_by(step)
    return function(ctx)
        ctx.shrink(step)
    end
end

--- Jump to next hunk. Context-aware: visible hunks only if spotlight is active.
---@param ctx delta.spotlight.ActionContext
function M.next_hunk(ctx)
    ctx.next_hunk()
end

--- Jump to previous hunk. Context-aware: visible hunks only if spotlight is active.
---@param ctx delta.spotlight.ActionContext
function M.prev_hunk(ctx)
    ctx.prev_hunk()
end

--- Cycle between unstaged/staged/all modes.
---@param ctx delta.spotlight.ActionContext
function M.cycle_mode(ctx)
    ctx.cycle_mode()
end

--- Toggle staged/unstaged for the current file.
---@param ctx delta.spotlight.ActionContext
function M.toggle_stage_file(ctx)
    ctx.toggle_stage_file()
end

--- Toggle staged/unstaged for the current file, then run cb on success.
---@param cb fun()
---@return delta.spotlight.ActionHandler
function M.toggle_stage_file_and(cb)
    return function(ctx)
        ctx.toggle_stage_file(cb)
    end
end

--- Reset the current file to the active baseline.
---@param ctx delta.spotlight.ActionContext
function M.reset_file(ctx)
    ctx.reset_file()
end

--- Reset the current file to the active baseline, then run cb on success.
---@param cb fun()
---@return delta.spotlight.ActionHandler
function M.reset_file_and(cb)
    return function(ctx)
        ctx.reset_file(cb)
    end
end

--- Stage/unstage hunk under cursor. In visual mode, stage/unstage selected lines only.
---@param ctx delta.spotlight.ActionContext
function M.toggle_stage_hunk(ctx)
    ctx.toggle_stage_hunk()
end

--- Stage/unstage hunk under cursor, then run cb on success.
---@param cb fun()
---@return delta.spotlight.ActionHandler
function M.toggle_stage_hunk_and(cb)
    return function(ctx)
        ctx.toggle_stage_hunk(cb)
    end
end

--- Reset unstaged hunk under cursor. In visual mode, reset selected lines only.
---@param ctx delta.spotlight.ActionContext
function M.reset_hunk(ctx)
    ctx.reset_hunk()
end

--- Reset unstaged hunk under cursor, then run cb on success.
---@param cb fun()
---@return delta.spotlight.ActionHandler
function M.reset_hunk_and(cb)
    return function(ctx)
        ctx.reset_hunk(cb)
    end
end

--- Exit spotlight on the current buffer.
---@param ctx delta.spotlight.ActionContext
function M.exit(ctx)
    ctx.exit()
end

--- Open hunk diff popup for the current hunk, or focus it if already visible.
---@param ctx delta.spotlight.ActionContext
function M.open_diff(ctx)
    require("delta.spotlight.diff").open({
        winid = ctx.win,
        bufid = ctx.buf,
    })
end

return M
