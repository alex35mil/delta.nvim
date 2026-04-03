--- File system watcher for git index changes.

local M = {}

local Notify = require("delta.notify")

local DEBOUNCE_MS = 200

---@type table<string, { handle: uv.uv_fs_event_t, timer: uv.uv_timer_t }>
local watchers = {}

---@type fun()[]
local callbacks = {}

local function notify_callbacks()
    for _, cb in ipairs(callbacks) do
        cb()
    end
end

--- Start watching the given git directory for changes.
--- No-op if already watching this gitdir.
---@param gitdir string
function M.start(gitdir)
    if watchers[gitdir] then
        return
    end

    local handle = vim.uv.new_fs_event()
    local timer = vim.uv.new_timer()

    if not handle or not timer then
        Notify.error("Failed to create fs watcher")
        return
    end

    watchers[gitdir] = {
        handle = handle,
        timer = timer,
    }

    handle:start(gitdir, {}, function(err, filename)
        if err then
            Notify.error("Git dir watcher error: " .. err)
            return
        end

        -- Ignore lock files
        if filename and vim.startswith(filename, "index.lock") then
            return
        end

        -- Debounce: restart timer on each event
        timer:stop()
        timer:start(DEBOUNCE_MS, 0, function()
            vim.schedule(notify_callbacks)
        end)
    end)
end

--- Stop watcher for a specific gitdir.
---@param gitdir string
function M.stop_for(gitdir)
    local w = watchers[gitdir]
    if not w then
        return
    end
    w.timer:stop()
    w.timer:close()
    w.handle:stop()
    w.handle:close()
    watchers[gitdir] = nil
end

--- Stop all watchers.
function M.stop()
    for gitdir, w in pairs(watchers) do
        w.timer:stop()
        w.timer:close()
        w.handle:stop()
        w.handle:close()
        watchers[gitdir] = nil
    end
    callbacks = {}
end

--- Register a callback for git index changes.
---@param cb fun()
function M.on_update(cb)
    callbacks[#callbacks + 1] = cb
end

--- Remove a callback.
---@param cb fun()
function M.off_update(cb)
    for i, c in ipairs(callbacks) do
        if c == cb then
            table.remove(callbacks, i)
            return
        end
    end
end

return M
