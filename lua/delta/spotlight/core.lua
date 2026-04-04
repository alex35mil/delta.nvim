--- delta.spotlight core internal implementation.
--- Focus on git diff hunks by folding everything else away.

---@alias delta.FilePath string

local M = {}

local Git = require("delta.git")
local Config = require("delta.config")
local Notify = require("delta.notify")
local Keys = require("delta.spotlight.keys")
local Mode = require("delta.spotlight.mode")
local Hunks = require("delta.spotlight.hunks")
local Paths = require("delta.spotlight.paths")
local Watchers = require("delta.spotlight.watchers")
local Winbar = require("delta.spotlight.winbar")
local Highlights = require("delta.spotlight.highlights")

M.actions = require("delta.spotlight.actions")

--- State

---@class delta.spotlight.OriginalFolds
---@field foldmethod string
---@field foldexpr string
---@field foldlevel integer
---@field foldenable boolean
---@field foldminlines integer

---@class delta.spotlight.OriginalWindowState
---@field winbar string
---@field winhighlight string
---@field folds delta.spotlight.OriginalFolds

---@class delta.spotlight.PickerOverride
---@field path delta.FilePath
---@field mode delta.spotlight.RequestedMode

---@class delta.spotlight.WinState
---@field id delta.WinId
---@field requested_mode delta.spotlight.RequestedMode
---@field resolved_mode delta.spotlight.ResolvedMode
---@field picker_override? delta.spotlight.PickerOverride
---@field last_hunk_index integer?
---@field last_hunk_total integer?
---@field original delta.spotlight.OriginalWindowState

--- Per-window spotlight state.
---@type table<delta.WinId, delta.spotlight.WinState>
local wins = {}

---@class delta.spotlight.PickerNav
---@field source_key string|false|nil
---@field opened_path string
---@field unstaged_paths string[]
---@field opened_index integer

---@class delta.spotlight.PickerContext
---@field path delta.FilePath
---@field section delta.picker.Section
---@field nav? delta.spotlight.PickerNav
---@field timestamp integer

---@class delta.spotlight.PickerOpenOpts
---@field section delta.picker.Section
---@field status delta.FileStatus
---@field cmd "edit"|"split"|"vsplit"
---@field spotlight boolean
---@field nav? delta.spotlight.PickerNav

---@class delta.spotlight.Buf
---@field buf delta.BufId Neovim buffer for this realization.
---@field last_rendered_on_enter integer? Last BufEnter render timestamp for this buffer, if relevant.
---@field rendered_hunks? delta.Hunk[] Scratch-only hunks remapped into rendered buffer coordinates.

---@class delta.spotlight.ScratchBufs
---@field staged? delta.spotlight.Buf
---@field deleted? delta.spotlight.Buf

---@class delta.spotlight.Bufs
---@field source delta.spotlight.Buf Real file-backed buffer state for this path.
---@field scratch delta.spotlight.ScratchBufs Synthetic spotlight buffers keyed by content type.

---@alias delta.spotlight.BufKind "source"|"scratch"

---@alias delta.spotlight.ScratchBufContentType "staged"|"deleted"

---@class delta.spotlight.ManagedFileState
---@field kind "managed"
---@field path delta.FilePath Canonical file path used for git operations and buffer lookup.
---@field gitdir string Absolute .git directory for the source path.
---@field status delta.FileStatus Cached git status for the source path.
---@field bufs delta.spotlight.Bufs Buffer realizations associated with this source path.
---@field raw_hunks delta.Hunks Cached raw git patch hunks for the source path.
---@field visible_hunks delta.Hunks Cached linematch-visible hunks for spotlight UI resolution/navigation.
---@field action_hunks delta.Hunks Cached contiguous full-text hunks for stage/reset target resolution.
---@field picker_nav? delta.spotlight.PickerNav Picker navigation metadata associated with the source path.

---@class delta.spotlight.FileData
---@field status delta.FileStatus
---@field raw_hunks delta.Hunks
---@field visible_hunks delta.Hunks
---@field action_hunks delta.Hunks

---@class delta.spotlight.UnmanagedFileState
---@field kind "unmanaged"
---@field path delta.FilePath Canonical file path used for git operations and buffer lookup.
---@field status "outsider"|"no_repo" Extra non-git status shown in the winbar.
---@field bufs delta.spotlight.Bufs Buffer realizations associated with this source path.
---@field picker_nav? delta.spotlight.PickerNav Picker navigation metadata associated with the source path.

---@alias delta.spotlight.FileState delta.spotlight.ManagedFileState|delta.spotlight.UnmanagedFileState

--- Per-file spotlight state.
---@type table<delta.FilePath, delta.spotlight.FileState>
local files = {}

---@class delta.spotlight.FoldState
---@field context integer?
---@field visibility table<integer, boolean>
---@field total_visible integer

---@type table<delta.BufId, delta.spotlight.FoldState>
local folds = {}

---@class delta.spotlight.PathLocks
---@field held table<delta.FilePath, true>
local PathLocks = {}
PathLocks.__index = PathLocks

---@return delta.spotlight.PathLocks
function PathLocks.new()
    return setmetatable({ held = {} }, PathLocks)
end

---@param path delta.FilePath
---@return boolean acquired
function PathLocks:acquire(path)
    if self.held[path] then
        return false
    end

    self.held[path] = true
    return true
end

---@param path delta.FilePath
function PathLocks:release(path)
    self.held[path] = nil
end

---@param path delta.FilePath
---@return boolean
function PathLocks:locked(path)
    return self.held[path] ~= nil
end

---@param path delta.FilePath
---@param on_ready fun()
---@param opts? { on_timeout?: fun() }
function PathLocks:wait(path, on_ready, opts)
    opts = opts or {}

    local max_retries = 10
    local interval_ms = 10
    local attempts = 0

    local function poll()
        attempts = attempts + 1
        if not self:locked(path) then
            on_ready()
        elseif attempts < max_retries then
            vim.defer_fn(poll, interval_ms)
        elseif opts.on_timeout then
            opts.on_timeout()
        else
            Notify.error("Failed to wait for file state." .. " Path: " .. path)
        end
    end

    poll()
end

local refreshing_file_state_locks = PathLocks.new()
local mutating_file_state_locks = PathLocks.new()

---@type table<delta.WinId, delta.spotlight.PickerContext>
local picker_contexts = {}

---@type table<delta.WinId, table<delta.FilePath, fun(path: delta.FilePath, winid: delta.WinId, bufid: delta.BufId)>>
local render_callbacks = {}

---@param winid delta.WinId
---@param path delta.FilePath
---@param cb fun(path: delta.FilePath, winid: delta.WinId, bufid: delta.BufId)
---@return boolean registered
local function register_render_callback(winid, path, cb)
    if not wins[winid] then
        return false
    end

    render_callbacks[winid] = render_callbacks[winid] or {}
    render_callbacks[winid][path] = cb
    return true
end

---@param winid delta.WinId
---@param path delta.FilePath
---@return fun(path: delta.FilePath, winid: delta.WinId, bufid: delta.BufId)?
local function take_render_callback(winid, path)
    local callbacks = render_callbacks[winid]
    if not callbacks then
        return nil
    end

    local cb = callbacks[path]
    callbacks[path] = nil

    if vim.tbl_isempty(callbacks) then
        render_callbacks[winid] = nil
    end

    return cb
end

---@param winid delta.WinId
---@param path? delta.FilePath
local function clear_render_callbacks(winid, path)
    if path then
        take_render_callback(winid, path)
        return
    end

    render_callbacks[winid] = nil
end

---@param bufid delta.BufId
---@return delta.FilePath?
---@return delta.spotlight.ScratchBufContentType?
local function path_for_buf(bufid)
    return Paths.normalize(vim.api.nvim_buf_get_name(bufid))
end

---@param bufid delta.BufId
---@return boolean
local function is_related_buf(bufid)
    local name = vim.api.nvim_buf_get_name(bufid)
    if name == "" then
        return false
    end

    local path, scratch = Paths.normalize(name)
    if scratch then
        return true
    end

    if vim.bo[bufid].buftype ~= "" then
        return false
    end

    if name:match("^%a[%w+.-]*://") then
        return false
    end

    return path ~= nil
end

---@param bufid delta.BufId
---@return delta.spotlight.FileState?
---@return delta.FilePath?
---@return delta.spotlight.ScratchBufContentType?
local function file_and_path_for_buf(bufid)
    local path, scratch = path_for_buf(bufid)
    if not path then
        return nil
    end
    return files[path], path, scratch
end

---@param bufid delta.BufId
---@return delta.spotlight.FileState?
local function file_for_buf(bufid)
    local file, _, _ = file_and_path_for_buf(bufid)
    return file
end

---@param bufid delta.BufId
---@return delta.HunkSide
local function visible_hunk_side_for_buf(bufid)
    local _, scratch = path_for_buf(bufid)
    return scratch == "deleted" and "removed" or "added"
end

---@param file delta.spotlight.FileState?
---@return delta.spotlight.ManagedFileState?
local function as_managed_file(file)
    if file and file.kind == "managed" then
        return file
    end
end

---@return delta.Hunks
local function empty_hunks()
    return { staged = {}, unstaged = {} }
end

---@param file delta.spotlight.FileState?
---@return delta.Hunks
local function file_raw_hunks(file)
    local managed = as_managed_file(file)
    return managed and managed.raw_hunks or empty_hunks()
end

---@return delta.Hunks
local function file_visible_hunks(file)
    local managed = as_managed_file(file)
    return managed and managed.visible_hunks or file_raw_hunks(file)
end

---@param file delta.spotlight.FileState
---@param requested_mode delta.spotlight.RequestedMode
---@param picker_override? delta.spotlight.PickerOverride
---@return delta.spotlight.ResolvedMode
local function resolve_mode_for_file(file, requested_mode, picker_override)
    local managed = as_managed_file(file)
    if managed then
        return Mode.resolve(managed.path, requested_mode, managed.status, picker_override)
    end
    return "none"
end

--- Picker

local PICKER_CONTEXT_TTL_NS = 1000000000

---@param winid delta.WinId
---@param path delta.FilePath
---@return delta.spotlight.PickerContext?
local function get_picker_context(winid, path)
    local context = picker_contexts[winid]
    if not context then
        return
    end

    if vim.uv.hrtime() - context.timestamp > PICKER_CONTEXT_TTL_NS then
        picker_contexts[winid] = nil
        return
    end

    if context.path ~= path then
        return
    end

    return context
end

---@param winid delta.WinId
---@param file delta.spotlight.FileState
---@param path delta.FilePath
---@return boolean consumed
---@return delta.spotlight.PickerOverride? picker_override
local function process_picker_context(winid, file, path)
    local context = get_picker_context(winid, path)
    if not context then
        return false, nil
    end

    if context.nav then
        file.picker_nav = context.nav
    end

    picker_contexts[winid] = nil
    return true, context.section == "staged" and { path = path, mode = "staged" } or nil
end

---@param winid delta.WinId
---@param bufid delta.BufId
local function sync_picker_context(winid, bufid)
    local win = wins[winid]
    if not win then
        return
    end

    local file, path = file_and_path_for_buf(bufid)
    if not path or not file then
        return
    end

    local consumed, picker_override = process_picker_context(winid, file, path)
    if consumed then
        win.picker_override = picker_override
        return
    end

    if win.picker_override and win.picker_override.path ~= path then
        win.picker_override = nil
    end
end

---@param source_key string|false|nil
---@return delta.SourceConfig|nil source
local function resolve_picker_source(source_key)
    if not source_key or source_key == "git" then
        return Config.options.picker.sources.git
    end
    return Config.options.picker.sources[source_key]
end

---@param entries string[]|fun(): string[]
---@return table<string, boolean>
local function resolve_source_files(entries)
    if type(entries) == "function" then
        entries = entries()
    end

    local cwd = vim.fn.getcwd() .. "/"
    local path_set = {}
    for _, file in ipairs(entries) do
        if file:sub(1, #cwd) == cwd then
            path_set[file:sub(#cwd + 1)] = true
        elseif not vim.startswith(file, "/") then
            path_set[file] = true
        end
    end
    return path_set
end

---@param source_key string|false|nil
---@param changed delta.ChangedFiles
---@return string[]
local function get_unstaged_paths_for_source(source_key, changed)
    local source = resolve_picker_source(source_key)
    local unstaged = changed.unstaged

    if source and source.files then
        unstaged = Git.filter_by_paths(unstaged, resolve_source_files(source.files))
    end

    local paths = {}
    for i, file in ipairs(unstaged) do
        paths[i] = file.path
    end
    return paths
end

---@param list string[]
---@return table<string, boolean>
local function to_path_set(list)
    local set = {}
    for _, path in ipairs(list) do
        set[path] = true
    end
    return set
end

---@param nav delta.spotlight.PickerNav|nil
---@param current_unstaged string[]
---@return string?
local function find_next_picker_path(nav, current_unstaged)
    if not nav or not nav.opened_index then
        return
    end

    local current_set = to_path_set(current_unstaged)
    for i = nav.opened_index + 1, #nav.unstaged_paths do
        local path = nav.unstaged_paths[i]
        if current_set[path] then
            return path
        end
    end
    for i = nav.opened_index - 1, 1, -1 do
        local path = nav.unstaged_paths[i]
        if current_set[path] then
            return path
        end
    end
end

---@param changed delta.ChangedFiles
---@param nav delta.spotlight.PickerNav|nil
---@return string|delta.SourceDef|nil source
---@return string? preselect_path
local function resolve_picker_reopen_target(changed, nav)
    local current_unstaged = get_unstaged_paths_for_source(nav and nav.source_key or "git", changed)
    local next_path = find_next_picker_path(nav, current_unstaged)
    if next_path then
        return nav and nav.source_key or "git", next_path
    end

    local keys = vim.tbl_keys(Config.options.picker.sources)
    table.sort(keys)
    table.insert(keys, 1, "git")

    local seen = {}
    local ordered_keys = {}
    if nav and nav.source_key then
        ordered_keys[#ordered_keys + 1] = nav.source_key
        seen[nav.source_key] = true
    else
        ordered_keys[#ordered_keys + 1] = "git"
        seen.git = true
    end

    for _, key in ipairs(keys) do
        if not seen[key] then
            ordered_keys[#ordered_keys + 1] = key
            seen[key] = true
        end
    end

    for _, key in ipairs(ordered_keys) do
        local paths = get_unstaged_paths_for_source(key, changed)
        if #paths > 0 then
            return key, paths[1]
        end
    end
end

---@param file delta.spotlight.FileState
local function maybe_reopen_picker_after_stage(file)
    local mfile = as_managed_file(file)
    if not Config.options.spotlight.reopen_picker_after_stage or not mfile then
        return
    end

    local ok, status = Git.file_status(mfile.path)
    if not ok or not status then
        return
    end

    mfile.status = status
    if status:has_unstaged() then
        return
    end

    local cok, changed = Git.get_changed_files()
    if not cok or not changed then
        return
    end

    local source, preselect_path = resolve_picker_reopen_target(changed, file.picker_nav)
    vim.schedule(function()
        if preselect_path then
            require("delta.picker").show({ source = source, preselect_path = preselect_path })
        else
            Notify.info("Everything is staged")
        end
    end)
end

--- Build the action context for a buffer.
---@param bufid delta.BufId
---@return delta.spotlight.ActionContext
local function make_context(bufid)
    local winid = vim.api.nvim_get_current_win()

    local win = wins[winid]
    local file = file_for_buf(bufid)

    local path = file and file.path or vim.fn.expand("%:.")

    -- Capture visual selection if in visual mode.
    local mode = vim.fn.mode()
    local visual = nil
    if mode == "v" or mode == "V" or mode == "\22" then
        local start = vim.fn.line("v")
        local finish = vim.fn.line(".")
        if start > finish then
            start, finish = finish, start
        end
        visual = { start_line = start, end_line = finish }
    end

    return {
        is_active = win ~= nil,
        buf = bufid,
        win = winid,
        path = path,
        requested_mode = win and win.requested_mode or nil,
        resolved_mode = win and win.resolved_mode or nil,
        hunks = file_raw_hunks(file),
        visual = visual,
        expand = function(step)
            M.expand_context(bufid, step)
        end,
        shrink = function(step)
            M.shrink_context(bufid, step)
        end,
        next_hunk = function()
            M.next_hunk(bufid)
        end,
        prev_hunk = function()
            M.prev_hunk(bufid)
        end,
        cycle_mode = function()
            M.cycle_mode(bufid)
        end,
        toggle_stage_file = function(cb)
            M.toggle_stage_file(bufid, cb)
        end,
        reset_file = function(cb)
            M.reset_file(bufid, cb)
        end,
        toggle_stage_hunk = function(cb)
            if visual then
                M.toggle_stage_hunk(bufid, visual.start_line, visual.end_line, cb)
            else
                M.toggle_stage_hunk(bufid, nil, nil, cb)
            end
        end,
        reset_hunk = function(cb)
            if visual then
                M.reset_hunk(bufid, visual.start_line, visual.end_line, cb)
            else
                M.reset_hunk(bufid, nil, nil, cb)
            end
        end,
        exit = function()
            M.disable(bufid)
        end,
    }
end

---@param bufid? delta.BufId
---@return delta.spotlight.ActionContext
function M.context(bufid)
    return make_context(bufid or vim.api.nvim_get_current_buf())
end

---@param line integer
---@param unstaged_hunks delta.Hunk[]
---@return integer
local function index_to_worktree_line(line, unstaged_hunks)
    local mapped = line
    for _, hunk in ipairs(unstaged_hunks or {}) do
        local delta = hunk.added.count - hunk.removed.count
        if hunk.removed.count == 0 then
            if mapped >= hunk.removed.start then
                mapped = mapped + delta
            end
        else
            local removed_end = hunk.removed.start + hunk.removed.count - 1
            if mapped > removed_end then
                mapped = mapped + delta
            end
        end
    end
    return mapped
end

---@param hunk delta.Hunk
---@param unstaged_hunks delta.Hunk[]
---@return delta.Hunk
local function remap_staged_hunk_to_worktree(hunk, unstaged_hunks)
    local clone = hunk:clone()
    clone.added.start = index_to_worktree_line(hunk.added.start, unstaged_hunks)
    clone.removed.start = index_to_worktree_line(hunk.removed.start, unstaged_hunks)
    clone.vend = clone.added.start + math.max(clone.added.count - 1, 0)
    return clone
end

---@param hunks delta.Hunk[]
---@param side delta.HunkSide
local function sort_hunks_by_visible_position(hunks, side)
    table.sort(hunks, function(a, b)
        local a_start, b_start = a:start_line(side), b:start_line(side)
        if a_start ~= b_start then
            return a_start < b_start
        end

        local a_end, b_end = a:end_line(side), b:end_line(side)
        if a_end ~= b_end then
            return a_end < b_end
        end

        if a.added.start ~= b.added.start then
            return a.added.start < b.added.start
        end
        if a.removed.start ~= b.removed.start then
            return a.removed.start < b.removed.start
        end
        return a.header < b.header
    end)
end

---@param bufid? delta.BufId
---@return delta.Hunk[]
---@return delta.HunkSide
---@return delta.spotlight.FileState?
function M.hunks_for_buf(bufid)
    bufid = bufid or vim.api.nvim_get_current_buf()
    local file, _, scratch = file_and_path_for_buf(bufid)
    local side = visible_hunk_side_for_buf(bufid)
    local raw_hunks = file_raw_hunks(file)
    local visible_hunks = file_visible_hunks(file)

    if scratch then
        local managed = as_managed_file(file)
        local scratch_buf = managed and managed.bufs.scratch[scratch] or nil
        return (scratch_buf and scratch_buf.rendered_hunks) or raw_hunks.staged, side, file
    end

    local visible = {}
    for _, hunk in ipairs(visible_hunks.unstaged) do
        visible[#visible + 1] = hunk
    end
    for _, hunk in ipairs(visible_hunks.staged) do
        visible[#visible + 1] = remap_staged_hunk_to_worktree(hunk, raw_hunks.unstaged)
    end

    sort_hunks_by_visible_position(visible, side)
    return visible, side, file
end

--- Keymaps

--- Bind global keymaps (always active, not buffer-local).
local function setup_global_keymaps()
    local SharedKeys = require("delta.keys")
    local actions = Config.options.spotlight.actions
    for _, action in pairs(actions) do
        if action and action.global then
            local keyspecs = SharedKeys.resolve(action[1])
            local handler = action[2]
            for _, keyspec in ipairs(keyspecs) do
                local lhs = SharedKeys.lhs(keyspec)
                ---@type delta.KeyModes
                local modes = "n"
                if type(keyspec) == "table" and keyspec.modes then
                    modes = keyspec.modes --[[@as delta.KeyModes]]
                end
                vim.keymap.set(modes, lhs, function()
                    local buf = vim.api.nvim_get_current_buf()
                    handler(make_context(buf))
                end, { nowait = true, desc = "delta.spotlight" })
            end
        end
    end
end

--- Set buffer-local keymaps for an active spotlight buffer.
---@param bufid delta.BufId
local function setup_local_keymaps(bufid)
    local SharedKeys = require("delta.keys")
    local actions = Config.options.spotlight.actions
    for _, action in pairs(actions) do
        if action and not action.global then
            local keyspecs = SharedKeys.resolve(action[1])
            local handler = action[2]
            for _, keyspec in ipairs(keyspecs) do
                Keys.bind(bufid, keyspec, function()
                    handler(make_context(bufid))
                end, { nowait = true })
            end
        end
    end
end

--- Remove buffer-local keymaps from a buffer.
---@param bufid delta.BufId
local function clear_local_keymaps(bufid)
    local SharedKeys = require("delta.keys")
    local actions = Config.options.spotlight.actions
    for _, action in pairs(actions) do
        if action and not action.global then
            for _, keyspec in ipairs(SharedKeys.resolve(action[1])) do
                Keys.unbind(bufid, keyspec)
            end
        end
    end
end

--- Win Styles

--- Apply spotlight winhighlight overrides to a window.
---@param winid delta.WinId
local function setup_winhighlight(winid)
    local hl = Highlights.groups
    local whl = vim.wo[winid].winhighlight
    local winbar_entry = "WinBar:" .. hl.winbar .. ",WinBarNC:" .. hl.winbar
    if not whl:find(hl.winbar, 1, true) then
        vim.wo[winid].winhighlight = whl ~= "" and (whl .. "," .. winbar_entry) or winbar_entry
    end
end

--- Restore original winbar and winhighlight for a window from saved state.
---@param winid delta.WinId
---@param win delta.spotlight.WinState?
local function restore_winbar_and_winhighlight(winid, win)
    if win and vim.api.nvim_win_is_valid(winid) then
        vim.wo[winid].winbar = win.original.winbar or ""
        vim.wo[winid].winhighlight = win.original.winhighlight or ""
    end
end

--- Folds

local FOLDEXPR = "v:lua.require'delta.spotlight.core'.foldexpr(v:lnum)"

--- Foldexpr: "0" for visible lines, "1" for folded.
---@param lnum integer
---@return string
function M.foldexpr(lnum)
    local buf = vim.api.nvim_get_current_buf()
    local fold = folds[buf]
    if not fold then
        return "0"
    end
    local vis = fold.visibility
    if not vis then
        return "0"
    end
    return vis[lnum] and "0" or "1"
end

--- Rebuild the visible line set from hunks and context.
---@param bufid delta.BufId
---@param hunks delta.Hunk[]
local function update_folds_visibility(bufid, hunks)
    local fold = folds[bufid]
    local context = fold and fold.context or Config.options.spotlight.context.base
    local side = visible_hunk_side_for_buf(bufid)

    local total = vim.api.nvim_buf_line_count(bufid)
    local visibility = {}
    local total_visible = 0
    for _, hunk in ipairs(hunks) do
        local hunk_line = hunk:target(side)
        local vis_start = math.max(1, hunk_line - context)
        local vis_end = math.min(total, hunk_line + hunk:lines(side) - 1 + context)
        for l = vis_start, vis_end do
            if not visibility[l] then
                visibility[l] = true
                total_visible = total_visible + 1
            end
        end
    end

    if fold then
        folds[bufid].visibility = visibility
        folds[bufid].total_visible = total_visible
    else
        folds[bufid] = {
            visibility = visibility,
            total_visible = total_visible,
        }
    end
end

--- Force folds to update by toggling foldmethod and recomputing folds.
---@param winid delta.WinId
---@param method? "expr"|"manual"|string
local function rerender_folds(winid, method)
    if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_call(winid, function()
            vim.wo[winid].foldmethod = "manual"
            vim.wo[winid].foldmethod = method or "expr"
            vim.cmd("silent! normal! zx")
        end)
    end
end

---@param winid delta.WinId
---@param bufid delta.BufId
---@return boolean
local function has_closed_folds(winid, bufid)
    if not vim.api.nvim_win_is_valid(winid) or not vim.api.nvim_buf_is_valid(bufid) then
        return false
    end

    return vim.api.nvim_win_call(winid, function()
        local line_count = vim.api.nvim_buf_line_count(bufid)
        local lnum = 1

        while lnum <= line_count do
            local fold_end = vim.fn.foldclosedend(lnum)
            if fold_end ~= -1 then
                return true
            end
            lnum = lnum + 1
        end

        return false
    end)
end

--- Restore original fold options for a window from saved state.
---@param winid delta.WinId
---@param win delta.spotlight.WinState?
local function restore_folds(winid, win)
    if win and vim.api.nvim_win_is_valid(winid) then
        vim.wo[winid].foldmethod = win.original.folds.foldmethod
        vim.wo[winid].foldexpr = win.original.folds.foldexpr
        vim.wo[winid].foldlevel = win.original.folds.foldlevel
        vim.wo[winid].foldenable = win.original.folds.foldenable
        vim.wo[winid].foldminlines = win.original.folds.foldminlines

        rerender_folds(winid, win.original.folds.foldmethod)
    end
end

--- Clear fold state for a buffer.
---@param bufid delta.BufId
local function clear_folds(bufid)
    folds[bufid] = nil
end

--- 🚀

-- Flows:
-- 1. User loads buffer in window: handled via autocmds.
-- 2. User manually enables spotlight: handled via M.ensure().
--
-- Decision table for render flow handling. *Might be (and prolly already is) outdated*
--
-- - Maam, I want ADTs!
-- - We have ADTs at home.
--  ADTs at home:
--
-- Inputs:
--    a. path: general vs delta://
--    b. file_state: new vs existing
--    c. spotlight: on vs off
--
-- Outputs:
--    a. path_kind: general; file_state: new; spotlight: on;
--       - fetch git data
--       - ensure source buf <-> real buf mapping
--       - sync picker context
--       - resolve mode
--       - resolve(source) / create(scratch) target buffer
--       - render
--    b. path_kind: general; file_state: new; spotlight: off;
--       - fetch git data
--       - ensure source buf <-> real buf mapping
--    c. path_kind: general; file_state: existing; spotlight: on;
--       - ensure source buf <-> real buf mapping
--       - sync picker context
--       - resolve mode
--       - resolve(source) / create(scratch) target buffer
--       - render
--    d. path_kind: general; file_state: existing; spotlight: off;
--       - ensure source buf <-> real buf mapping
--    e. path_kind: delta://; file_state: new; spotlight: on;
--       - fetch git data
--       - sync picker context
--       - resolve mode
--       - resolve(source) / create(scratch) target buffer
--       - render
--    f. path_kind: delta://; file_state: new; spotlight: off;
--       - fetch git data
--       - resolve(source) / create(scratch) target buffer
--       - render
--    g. path_kind: delta://; file_state: existing; spotlight: on;
--       - sync picker context
--       - resolve mode
--       - resolve(source) / create(scratch) target buffer
--       - render
--    h. path_kind: delta://; file_state: existing; spotlight: off;
--       - resolve(source) / create(scratch) target buffer
--       - render
--
-- Note on file state refreshing: when some branch starts refreshing a file state and rendering spotlight, it acquires refreshing_file_state_locks for the path.
-- So before handling a render flow, execution should bail if the lock for the path cannot be acquired.

---@param segment delta.VisibleSegment
---@return delta.Hunk
local function visible_hunk_from_segment(segment)
    local removed_start = segment.old_start or 0
    local added_start = segment.new_start or segment.start_line
    local hunk = Git.Hunk.new(removed_start, segment.old_count, added_start, segment.new_count)
    hunk.removed.lines = vim.deepcopy(segment.old_lines)
    hunk.added.lines = vim.deepcopy(segment.new_lines)
    return hunk
end

---@param base_lines string[]
---@param current_lines string[]
---@param contiguous? boolean
---@return delta.Hunk[]
local function visible_hunks_from_lines(base_lines, current_lines, contiguous)
    local segments = contiguous and Hunks.contiguous_segments_from_lines(base_lines, current_lines)
        or Hunks.linematch_segments_from_lines(base_lines, current_lines)
    local visible = {}
    for _, segment in ipairs(segments) do
        visible[#visible + 1] = visible_hunk_from_segment(segment)
    end
    return visible
end

---@param path string
---@param source_bufid? delta.BufId
---@return string[]?
local function visible_current_lines(path, source_bufid)
    local bufid = source_bufid
    if not bufid then
        local current = as_managed_file(files[path])
        bufid = current and current.bufs.source and current.bufs.source.buf or nil
    end

    if
        bufid
        and vim.api.nvim_buf_is_valid(bufid)
        and vim.api.nvim_buf_is_loaded(bufid)
        and path_for_buf(bufid) == path
        and vim.bo[bufid].buftype == ""
    then
        return vim.api.nvim_buf_get_lines(bufid, 0, -1, false)
    end
end

--- Fetch fresh file status and diff hunks for a path.
--- Must be called inside Git.async().
---@param path string
---@param source_bufid? delta.BufId
---@return boolean ok
---@return delta.spotlight.FileData? data
---@return delta.GitContextErrorKind? errkind
local function fetch_file_data(path, source_bufid)
    local sok, status, sctxerr = Git.file_status(path)
    if not sok or not status then
        return false, nil, sctxerr
    end

    local hok, raw_hunks = Git.get_diff_hunks(path)
    if not hok then
        return false, nil, nil
    end

    local visible_hunks = { staged = {}, unstaged = {} }
    local action_hunks = { staged = {}, unstaged = {} }

    local ok_index, index_lines = Git.get_index_lines(path)
    if not ok_index or not index_lines then
        return false, nil, nil
    end

    local current_lines = visible_current_lines(path, source_bufid)
    if not current_lines then
        local ok_worktree, worktree_lines = Git.get_worktree_lines(path)
        if not ok_worktree or not worktree_lines then
            return false, nil, nil
        end
        current_lines = worktree_lines
    end
    visible_hunks.unstaged = visible_hunks_from_lines(index_lines, current_lines)
    action_hunks.unstaged = visible_hunks_from_lines(index_lines, current_lines, true)

    local ok_head, head_lines = Git.get_head_lines(path)
    if not ok_head or not head_lines then
        return false, nil, nil
    end
    visible_hunks.staged = visible_hunks_from_lines(head_lines, index_lines)
    action_hunks.staged = visible_hunks_from_lines(head_lines, index_lines, true)

    return true,
        {
            status = status,
            raw_hunks = raw_hunks,
            visible_hunks = visible_hunks,
            action_hunks = action_hunks,
        },
        nil
end

---@param file delta.spotlight.FileState
---@param kind delta.spotlight.BufKind
---@param bufid delta.BufId
---@param content_type delta.spotlight.ScratchBufContentType|nil
local function register_file_buf(file, kind, bufid, content_type)
    if not vim.api.nvim_buf_is_valid(bufid) then
        return
    end

    if kind == "source" then
        local current = file.bufs.source
        file.bufs.source = {
            buf = bufid,
            last_rendered_on_enter = current and current.last_rendered_on_enter or nil,
        }
        return
    end

    if not content_type then
        Notify.error("Missing scratch buffer content type for file " .. file.path)
        return
    end

    local current = file.bufs.scratch[content_type]
    if current and vim.api.nvim_buf_is_valid(current.buf) and current.buf ~= bufid then
        Notify.warn(
            "Multiple scratch buffers resolved for the same file."
                .. " Path: "
                .. file.path
                .. " Content: "
                .. content_type
                .. " Canonical: "
                .. current.buf
                .. " Current: "
                .. bufid
        )
    end

    file.bufs.scratch[content_type] = {
        buf = bufid,
        last_rendered_on_enter = current and current.last_rendered_on_enter or nil,
    }
end

--- Refresh shared file state: resolve gitdir, fetch status and hunks, start watcher.
--- Must be called inside Git.async().
---@param path delta.FilePath
---@param source_bufid? delta.BufId
---@return boolean ok
local function refresh_file_state(path, source_bufid)
    local gok, gitdir, giterr = Git.git_dir()
    local current = files[path]
    local bufs = current and current.bufs or {}
    bufs.scratch = bufs.scratch or {}

    if gok and gitdir then
        local dok, file_data, dataerr = fetch_file_data(path, source_bufid)

        if dok and file_data then
            files[path] = {
                kind = "managed",
                path = path,
                gitdir = gitdir,
                bufs = bufs,
                status = file_data.status,
                raw_hunks = file_data.raw_hunks,
                visible_hunks = file_data.visible_hunks,
                action_hunks = file_data.action_hunks,
                picker_nav = current and current.picker_nav or nil,
            }

            if source_bufid ~= nil then
                register_file_buf(files[path], "source", source_bufid, nil)
            end

            Watchers.start(gitdir)
            return true
        end

        if dataerr ~= "outsider" and dataerr ~= "no_repo" then
            return false
        end

        files[path] = {
            kind = "unmanaged",
            path = path,
            bufs = bufs,
            status = dataerr == "no_repo" and "no_repo" or "outsider",
            picker_nav = current and current.picker_nav or nil,
        }

        if source_bufid ~= nil then
            register_file_buf(files[path], "source", source_bufid, nil)
        end

        return true
    end

    if giterr ~= "no_repo" then
        return false
    end

    files[path] = {
        kind = "unmanaged",
        path = path,
        bufs = bufs,
        status = "no_repo",
        picker_nav = current and current.picker_nav or nil,
    }

    if source_bufid ~= nil then
        register_file_buf(files[path], "source", source_bufid, nil)
    end

    return true
end

--- Pick a visible line for the cursor before folds are recomputed.
---@alias delta.spotlight.CursorPolicy "first"|"nearest"|"keep"

---@param win delta.WinId
---@param groups { start_line: number, end_line: number }[]?
---@param policy? delta.spotlight.CursorPolicy
---@return integer? line
local function resolve_cursor_target(win, groups, policy)
    if not groups or #groups == 0 then
        return
    end

    policy = policy or "nearest"

    local current_line = vim.api.nvim_win_get_cursor(win)[1]

    if policy == "keep" then
        return current_line
    end

    if policy == "first" then
        return groups[1].start_line
    end

    local nearest_line = nil
    local nearest_distance = nil

    for _, group in ipairs(groups) do
        if current_line >= group.start_line and current_line <= group.end_line then
            return current_line
        end

        local candidate = current_line < group.start_line and group.start_line or group.end_line
        local distance = math.abs(candidate - current_line)

        if not nearest_distance or distance < nearest_distance then
            nearest_distance = distance
            nearest_line = candidate
        end
    end

    return nearest_line
end

---@param file delta.spotlight.FileState
---@param mode delta.spotlight.ResolvedMode
---@return delta.spotlight.BufKind
local function buffer_kind_for_mode(file, mode)
    local mfile = as_managed_file(file)
    if not mfile then
        return "source"
    end

    if mfile.status:is_deleted() then
        return "scratch"
    end

    if mode == "staged" and mfile.status:has_unstaged() then
        return "scratch"
    end

    return "source"
end

---@param file delta.spotlight.FileState
---@param mode delta.spotlight.ResolvedMode
---@return delta.spotlight.ScratchBufContentType?
local function scratch_content_type_for_mode(file, mode)
    local mfile = as_managed_file(file)
    if not mfile then
        return nil
    end

    if mode == "staged" then
        if mfile.status:has_staged_deletion() then
            return "deleted"
        end

        if mfile.status:has_unstaged() then
            return "staged"
        end
    elseif mode == "unstaged" then
        if mfile.status:has_unstaged_deletion() then
            return "deleted"
        end
    end
end

---@param file delta.spotlight.FileState
---@return delta.spotlight.Buf?
local function ensure_file_source_buf(file)
    if not file.bufs.source then
        Notify.error("Source buffer is missing for file " .. file.path)
        return nil
    end

    if not vim.api.nvim_buf_is_valid(file.bufs.source.buf) then
        Notify.error("Source buffer is invalid for file " .. file.path)
        return nil
    end

    return file.bufs.source
end

---@param file delta.spotlight.FileState
---@param mode delta.spotlight.ResolvedMode
---@return boolean ok
---@return string? text
local function get_deleted_scratch_text(file, mode)
    if mode == "staged" then
        return Git.get_head_file(file.path)
    end
    return Git.get_staged_file(file.path)
end

local scratch_hl_ns = vim.api.nvim_create_namespace("delta.spotlight.scratch")

---@param hunk delta.Hunk
---@return string
local function diff_hl_for_hunk(hunk)
    if hunk.type == "add" then
        return Highlights.groups.scratch_diff_add
    elseif hunk.type == "delete" then
        return Highlights.groups.scratch_diff_delete
    end
    return Highlights.groups.scratch_diff_change
end

---@param lines string[]
---@param hunks delta.Hunk[]
---@return string[], delta.Hunk[]
local function build_staged_scratch_view(lines, hunks)
    local rendered_lines, rendered_hunks = {}, {}
    local source_line = 1
    local inserted = 0

    local function push_line(text)
        rendered_lines[#rendered_lines + 1] = text
    end

    for _, hunk in ipairs(hunks) do
        local anchor = math.max(hunk.added.start, 1)
        local copy_end = math.min(anchor - 1, #lines)

        while source_line <= copy_end do
            push_line(lines[source_line])
            source_line = source_line + 1
        end

        local rendered = hunk:clone()
        rendered.removed.start = hunk.removed.start + inserted

        if hunk.type == "delete" then
            local rendered_start = #rendered_lines + 1
            for _, text in ipairs(hunk.removed.lines) do
                push_line(text)
            end
            if hunk.removed.no_nl_at_eof then
                push_line("\\ No newline at end of file")
            end

            local visible_count = math.max(#hunk.removed.lines + (hunk.removed.no_nl_at_eof and 1 or 0), 1)
            rendered.added.start = rendered_start
            rendered.added.count = visible_count
            rendered.vend = rendered_start + visible_count - 1
            inserted = inserted + visible_count
        else
            rendered.added.start = hunk.added.start + inserted
            rendered.vend = rendered.added.start + math.max(rendered.added.count - 1, 0)
        end

        rendered_hunks[#rendered_hunks + 1] = rendered
    end

    while source_line <= #lines do
        push_line(lines[source_line])
        source_line = source_line + 1
    end

    return rendered_lines, rendered_hunks
end

---@param bufid delta.BufId
---@param file delta.spotlight.FileState
---@param content_type delta.spotlight.ScratchBufContentType
local function apply_scratch_diff_highlights(bufid, file, content_type)
    vim.api.nvim_buf_clear_namespace(bufid, scratch_hl_ns, 0, -1)

    local mfile = as_managed_file(file)
    if not mfile then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufid)
    if line_count == 0 then
        return
    end

    if content_type == "deleted" then
        for line = 0, line_count - 1 do
            vim.api.nvim_buf_set_extmark(bufid, scratch_hl_ns, line, 0, {
                line_hl_group = Highlights.groups.scratch_diff_delete,
            })
        end
        return
    end

    local scratch = mfile.bufs.scratch[content_type]
    local hunks = scratch and scratch.rendered_hunks or mfile.raw_hunks.staged

    for _, hunk in ipairs(hunks) do
        local start_line = math.max(1, math.min(hunk:start_line("added"), line_count))
        local end_line = math.max(start_line, math.min(hunk:end_line("added"), line_count))
        local hl = diff_hl_for_hunk(hunk)

        for line = start_line - 1, end_line - 1 do
            vim.api.nvim_buf_set_extmark(bufid, scratch_hl_ns, line, 0, {
                line_hl_group = hl,
            })
        end
    end
end

---@param file delta.spotlight.FileState
---@param content_type delta.spotlight.ScratchBufContentType
---@param mode delta.spotlight.ResolvedMode
---@return delta.spotlight.Buf?
local function ensure_file_scratch_buf(file, content_type, mode)
    local ok, text
    if content_type == "staged" then
        ok, text = Git.get_staged_file(file.path)
    elseif content_type == "deleted" then
        ok, text = get_deleted_scratch_text(file, mode)
    end
    if not ok or text == nil then
        return nil
    end

    local scratch = file.bufs.scratch[content_type]
    local scratch_name = Paths.scratch(content_type, file.path)
    local bufid = scratch and vim.api.nvim_buf_is_valid(scratch.buf) and scratch.buf or nil

    if not bufid then
        local existing = vim.fn.bufnr(scratch_name)
        if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
            bufid = existing
        else
            bufid = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufid, scratch_name)
        end

        local filetype = vim.filetype.match({ filename = file.path })
        if filetype then
            vim.bo[bufid].filetype = filetype
        end
    end

    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end

    local rendered_hunks
    if content_type == "staged" then
        lines, rendered_hunks = build_staged_scratch_view(lines, file.raw_hunks.staged)
    end

    vim.bo[bufid].buftype = ""
    vim.bo[bufid].bufhidden = "hide"
    vim.bo[bufid].swapfile = false
    vim.bo[bufid].buflisted = false
    vim.bo[bufid].readonly = false
    vim.bo[bufid].modifiable = true
    vim.api.nvim_buf_set_lines(bufid, 0, -1, false, lines)

    file.bufs.scratch[content_type] = {
        buf = bufid,
        last_rendered_on_enter = scratch and scratch.last_rendered_on_enter or nil,
        rendered_hunks = rendered_hunks,
    }

    apply_scratch_diff_highlights(bufid, file, content_type)
    vim.bo[bufid].modified = false
    vim.bo[bufid].modifiable = false
    vim.bo[bufid].readonly = true

    return file.bufs.scratch[content_type]
end

---@param file delta.spotlight.FileState
---@param mode delta.spotlight.ResolvedMode
---@return delta.spotlight.Buf?
local function ensure_file_buf(file, mode)
    local kind = buffer_kind_for_mode(file, mode)

    if kind == "source" then
        return ensure_file_source_buf(file)
    end

    local mfile = as_managed_file(file)
    if not mfile then
        Notify.error("Unexpected unmanaged spotlight scratch buffer")
        return nil
    end

    local content_type = scratch_content_type_for_mode(mfile, mode)
    if not content_type then
        Notify.error("Unexpected spotlight scratch buffer content")
        return nil
    end

    return ensure_file_scratch_buf(mfile, content_type, mode)
end

---@param winid delta.WinId
---@param bufid delta.BufId
---@param file delta.spotlight.FileState
---@param mode delta.spotlight.ResolvedMode
---@return delta.spotlight.Buf?
local function ensure_window_buf(winid, bufid, file, mode)
    local display = ensure_file_buf(file, mode)
    if not display then
        return nil
    end

    local current_bufid = vim.api.nvim_win_get_buf(winid)
    if current_bufid ~= display.buf then
        if current_bufid ~= bufid then -- by this time buffer has changed and we should bail
            return nil
        end

        vim.api.nvim_win_set_buf(winid, display.buf)
    end

    return display
end

--- Render spotlight window.
---@param winid delta.WinId
---@param bufid delta.BufId
---@param opts { cursor?: delta.spotlight.CursorPolicy, trigger: string }
local function render(winid, bufid, opts)
    if not vim.api.nvim_win_is_valid(winid) then
        Notify.error("Invalid window")
        return
    end

    local win = wins[winid]
    local file = file_for_buf(bufid)
    local fold = folds[bufid]

    if not win then
        Notify.error("No window state found." .. " Win: " .. winid .. " Buf: " .. bufid)
        return
    end
    if not file then
        Notify.error("Failed to render - no file state found." .. " Win: " .. winid .. " Buf: " .. bufid)
        return
    end

    -- Notify.debug(
    --     "Rendering."
    --         .. " Trigger: "
    --         .. (opts.trigger or "-")
    --         .. " Win: "
    --         .. winid
    --         .. " Buf: "
    --         .. bufid
    --         .. " Path: "
    --         .. file.path
    -- )

    local hunks, groups = Hunks.resolve(winid, bufid, win, file)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local cursor_target = resolve_cursor_target(winid, groups, opts.cursor)
    local scratch_content_type = scratch_content_type_for_mode(file, win.resolved_mode)
    local foldable = hunks and #hunks > 0 and scratch_content_type ~= "deleted"

    -- render: folds
    if foldable then
        if cursor_target then
            local line_count = vim.api.nvim_buf_line_count(bufid)
            local line = math.max(1, math.min(cursor_target, line_count))
            local col = opts.cursor == "keep" and cursor[2] or 0
            vim.api.nvim_win_set_cursor(winid, { line, col })
        end

        update_folds_visibility(bufid, assert(hunks))
        local has_ufo, ufo = pcall(require, "ufo")
        if has_ufo then
            ufo.detach(bufid)
        end
        vim.wo[winid].foldenable = true
        vim.wo[winid].foldlevel = 0
        vim.wo[winid].foldminlines = 1
        vim.wo[winid].foldexpr = FOLDEXPR
        rerender_folds(winid)
    else
        vim.wo[winid].foldenable = false
    end

    -- render: winbar
    local current_hunk, total_hunks = Winbar.current_hunk_position(winid, win, file)
    win.last_hunk_index = current_hunk
    win.last_hunk_total = total_hunks
    Winbar.update(winid, win, file, fold, hunks and #hunks or 0, current_hunk, total_hunks)

    -- render: center cursor after jump
    if opts.cursor == "first" and cursor_target then
        vim.cmd("normal! zz")
    end

    -- render: storing original window on a buffer
    vim.b[bufid].delta_spotlight = winid

    -- render: fire one-shot callback if registered
    local cb = take_render_callback(winid, file.path)
    if cb then
        cb(file.path, winid, bufid)
    end
end

--- Register all autocmds for spotlight lifecycle management.
local function setup_autocmds()
    local group = vim.api.nvim_create_augroup("delta-spotlight", { clear = true })

    -- BufEnter: main entry point for buffer lifecycle.
    -- 1. Cleans up spotlight artifacts when a buffer with spotlight tag enters a non-spotlight window
    --    (e.g., user opened the same buffer in a split).
    -- 2. Clears leaked winbar when a buffer carries spotlight winbar into a non-spotlight window
    --    (Neovim's global-local winbar sticks to the buffer).
    -- 3. Prepares file state (hunks, status, gitdir) on first load.
    -- 4. Re-renders when a buffer with existing state enters a spotlight window
    --    (needed because other plugins like treesitter may overwrite foldexpr on :e).
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(event)
            local bufid = event.buf

            if vim.bo[bufid].buftype ~= "" or vim.api.nvim_buf_get_name(bufid) == "" then
                return
            end

            local winid = vim.api.nvim_get_current_win()

            local win = wins[winid]

            -- Non-spotlight window: clean up any spotlight artifacts on this buffer.
            if not win then
                if vim.b[bufid].delta_spotlight then
                    -- Buffer was rendered in a spotlight window — restore original options.
                    local src_winid = vim.b[bufid].delta_spotlight
                    local src_win = wins[src_winid]

                    clear_folds(bufid)
                    restore_winbar_and_winhighlight(winid, src_win)
                    restore_folds(winid, src_win)
                    clear_local_keymaps(bufid)

                    vim.b[bufid].delta_spotlight = nil
                else
                    -- If buffer was opened in spotlight-enabled window, the winbar/winhighlight sticks to the buffer regardless of the window.
                    -- This is fucking madness. I'm not sure how to clear these props properly, so removing it here.
                    local hl = Highlights.groups
                    if vim.wo[winid].winbar:find(hl.winbar, 1, true) then
                        local winbar = vim.api.nvim_get_option_info2("winbar", {})
                        vim.wo[winid].winbar = winbar.default --[[@as string]]
                    end
                    if vim.wo[winid].winhighlight:find(hl.winbar, 1, true) then
                        local winhighlight = vim.api.nvim_get_option_info2("winhighlight", {})
                        vim.wo[winid].winhighlight = winhighlight.default --[[@as string]]
                    end
                end
            end

            local file, path, scratch = file_and_path_for_buf(bufid)

            if not path then
                return
            end

            local now = vim.uv.hrtime()

            if not file then
                -- First visit: fetch hunks, status, start watcher.
                if not refreshing_file_state_locks:acquire(path) then
                    return
                end

                Git.async(function()
                    local ok = refresh_file_state(path, scratch and nil or bufid)

                    refreshing_file_state_locks:release(path)

                    if not ok then
                        return
                    end

                    local current_buf = vim.api.nvim_get_current_buf()

                    -- If spotlight is active on this window and user is still on this buffer, render.
                    if win and bufid == current_buf then
                        local new_file = files[path]

                        if not new_file then
                            Notify.error("File was not prepared on BufEnter. Path: " .. path)
                            return
                        end

                        sync_picker_context(winid, bufid)

                        win.resolved_mode = resolve_mode_for_file(new_file, win.requested_mode, win.picker_override)

                        local display = ensure_window_buf(winid, bufid, new_file, win.resolved_mode)
                        if not display then
                            return
                        end

                        render(winid, display.buf, { cursor = "first", trigger = "event:BufEnter[new file]" })
                        setup_winhighlight(winid)
                        setup_local_keymaps(display.buf)

                        display.last_rendered_on_enter = now
                    end
                end)
            elseif win then
                -- Buffer already loaded, spotlight window: re-resolve mode for this buffer's status
                -- and re-render to restore foldexpr and other window-local options that may have been
                -- overwritten (e.g., by treesitter on :e).

                register_file_buf(file, scratch and "scratch" or "source", bufid, scratch)
                sync_picker_context(winid, bufid)
                win.resolved_mode = resolve_mode_for_file(file, win.requested_mode, win.picker_override)

                Git.async(function()
                    local current_bufid = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) or -1
                    local current_path = current_bufid ~= -1 and path_for_buf(current_bufid) or nil
                    local display = ensure_window_buf(winid, bufid, file, win.resolved_mode)
                    if not display then
                        return
                    end

                    if display.last_rendered_on_enter and now - display.last_rendered_on_enter < 100000000 then -- 100ms
                        return
                    end

                    render(winid, display.buf, { cursor = "nearest", trigger = "event:BufEnter[existing file]" })
                    setup_winhighlight(winid)
                    setup_local_keymaps(display.buf)

                    display.last_rendered_on_enter = now
                end)
            else
                register_file_buf(file, scratch and "scratch" or "source", bufid, scratch)
            end
        end,
    })

    -- WinNew: clean up spotlight window options inherited by new windows (eg, via :split).
    -- When a spotlight window is split, Neovim clones all window-local options (winbar, winhighlight,
    -- foldexpr, etc.) into the new window. This handler resets them to defaults so the new window
    -- doesn't inherit spotlight presentation.
    vim.api.nvim_create_autocmd("WinNew", {
        group = group,
        callback = function(_)
            local new_win = vim.api.nvim_get_current_win()

            if wins[new_win] then
                return
            end

            local hl = Highlights.groups

            if vim.wo[new_win].winbar:find(hl.winbar, 1, true) then
                local winbar = vim.api.nvim_get_option_info2("winbar", {})
                vim.wo[new_win].winbar = winbar.default --[[@as string]]
            end

            if vim.wo[new_win].winhighlight:find(hl.winbar, 1, true) then
                local winhighlight = vim.api.nvim_get_option_info2("winhighlight", {})
                vim.wo[new_win].winhighlight = winhighlight.default --[[@as string]]
            end

            if vim.wo[new_win].foldexpr == FOLDEXPR then
                local foldmethod = vim.api.nvim_get_option_info2("foldmethod", {})
                local foldexpr = vim.api.nvim_get_option_info2("foldexpr", {})
                local foldlevel = vim.api.nvim_get_option_info2("foldlevel", {})
                local foldenable = vim.api.nvim_get_option_info2("foldenable", {})
                local foldminlines = vim.api.nvim_get_option_info2("foldminlines", {})

                if foldexpr then
                    vim.wo[new_win].foldexpr = foldexpr.default --[[@as string]]
                end
                if foldlevel then
                    vim.wo[new_win].foldlevel = foldlevel.default --[[@as integer]]
                end
                if foldenable then
                    vim.wo[new_win].foldenable = foldenable.default --[[@as boolean]]
                end
                if foldminlines then
                    vim.wo[new_win].foldminlines = foldminlines.default --[[@as integer]]
                end
                if foldmethod then
                    vim.wo[new_win].foldmethod = foldmethod.default --[[@as string]]
                end
            end
        end,
    })

    -- WinEnter: re-apply spotlight when returning to a spotlight window whose buffer lost its tag.
    -- This happens when the same buffer is opened in a non-spotlight window (e.g., a split) —
    -- BufEnter fires there, clears delta_spotlight, but the buffer is still displayed in the
    -- spotlight window. When the user switches back, WinEnter re-renders it.
    vim.api.nvim_create_autocmd("WinEnter", {
        group = group,
        callback = function(event)
            local winid = vim.api.nvim_get_current_win()
            local bufid = event.buf

            local win = wins[winid]

            if not win then
                return
            end

            local file, _, scratch = file_and_path_for_buf(bufid)

            if file then
                register_file_buf(file, scratch and "scratch" or "source", bufid, scratch)
            end

            if file and not vim.b[bufid].delta_spotlight then
                sync_picker_context(winid, bufid)
                win.resolved_mode = resolve_mode_for_file(file, win.requested_mode, win.picker_override)

                Git.async(function()
                    local display = ensure_window_buf(winid, bufid, file, win.resolved_mode)
                    if not display then
                        return
                    end

                    render(winid, display.buf, { cursor = "nearest", trigger = "event:WinEnter" })
                    setup_winhighlight(winid)
                    setup_local_keymaps(display.buf)
                end)
            end
        end,
    })

    -- CursorMoved: keep the spotlight winbar's current-hunk indicator in sync while navigating.
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        callback = function(event)
            local winid = vim.api.nvim_get_current_win()
            local bufid = event.buf
            local win = wins[winid]

            if not win or not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= bufid then
                return
            end

            local file = file_for_buf(bufid)
            if not file then
                return
            end

            local fold = folds[bufid]
            local hunks = Hunks.for_mode(win.resolved_mode, file_visible_hunks(file))
            local current_hunk, total_hunks = Winbar.current_hunk_position(winid, win, file)
            if win.last_hunk_index == current_hunk and win.last_hunk_total == total_hunks then
                return
            end

            win.last_hunk_index = current_hunk
            win.last_hunk_total = total_hunks
            Winbar.update(winid, win, file, fold, #hunks, current_hunk, total_hunks)
        end,
    })

    -- Refresh hunks after file content changes on disk.
    -- BufReadPost: buffer reloaded via :edit! (e.g., pi applies edits then reloads with :edit!).
    --   Note: :edit! detaches nvim_buf_attach, so on_reload cannot be used for this case.
    -- BufWritePost: user saves from Neovim.
    -- FileChangedShellPost: file changed externally and Neovim reloaded it (autoread).
    -- The git index watcher only detects index changes (stage/unstage/commit).
    -- Working tree changes need explicit refresh.
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, {
        group = group,
        callback = function(event)
            local bufid = event.buf
            local file, path, scratch = file_and_path_for_buf(bufid)
            if not file or not path or scratch or not refreshing_file_state_locks:acquire(path) then
                return
            end

            Git.async(function()
                local ok = refresh_file_state(path, bufid)
                local refreshed = files[path]

                refreshing_file_state_locks:release(path)

                if not ok or not refreshed then
                    return
                end

                -- Re-render spotlight windows currently showing this file.
                for winid, win in pairs(wins) do
                    if vim.api.nvim_win_is_valid(winid) then
                        local winbufid = vim.api.nvim_win_get_buf(winid)
                        local winpath = path_for_buf(winbufid)
                        if winpath == path then
                            sync_picker_context(winid, winbufid)
                            win.resolved_mode =
                                resolve_mode_for_file(refreshed, win.requested_mode, win.picker_override)

                            local display = ensure_window_buf(winid, winbufid, refreshed, win.resolved_mode)
                            if display then
                                local cursor = event.event == "BufWritePost" and "keep" or "nearest"
                                render(winid, display.buf, { cursor = cursor, trigger = "event:" .. event.event })
                                setup_winhighlight(winid)
                            end
                        end
                    end
                end
            end)
        end,
    })

    -- WinClosed: clean up spotlight state when a spotlight window is closed.
    -- Removes win state, render callbacks, and clears spotlight tags/folds/keymaps
    -- on any buffers that were rendered in this window.
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(event)
            local winid = tonumber(event.match)
            if winid and wins[winid] then
                for _, file in pairs(files) do
                    for _, buf in ipairs({ file.bufs.source, file.bufs.scratch.staged, file.bufs.scratch.deleted }) do
                        local bufid = buf and buf.buf or nil
                        if bufid and vim.api.nvim_buf_is_valid(bufid) and vim.b[bufid].delta_spotlight == winid then
                            vim.b[bufid].delta_spotlight = nil
                            clear_folds(bufid)
                            clear_local_keymaps(bufid)
                        end
                    end
                end
                wins[winid] = nil
                picker_contexts[winid] = nil
                clear_render_callbacks(winid)
            end
        end,
    })

    -- BufWipeout: clean up buffer state and stop the gitdir watcher if no other files need it.
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(event)
            local bufid = event.buf
            local file, path, scratch = file_and_path_for_buf(bufid)

            folds[bufid] = nil

            if not file or not path then
                return
            end

            local mfile = as_managed_file(file)
            local gitdir = mfile and mfile.gitdir or nil

            if scratch then
                if file.bufs.scratch[scratch] and file.bufs.scratch[scratch].buf == bufid then
                    file.bufs.scratch[scratch] = nil
                end
            else
                if file.bufs.source and file.bufs.source.buf == bufid then
                    file.bufs.source = nil
                end
            end

            if not file.bufs.source then
                local scratch_shown = false
                for winid, _ in pairs(wins) do
                    if vim.api.nvim_win_is_valid(winid) then
                        local winbufid = vim.api.nvim_win_get_buf(winid)
                        if
                            (file.bufs.scratch.staged and file.bufs.scratch.staged.buf == winbufid)
                            or (file.bufs.scratch.deleted and file.bufs.scratch.deleted.buf == winbufid)
                        then
                            scratch_shown = true
                            break
                        end
                    end
                end

                if not scratch_shown then
                    files[path] = nil
                end
            end

            -- Stop watcher if no remaining files reference this gitdir.
            if gitdir then
                local still_used = false
                for _, other_file in pairs(files) do
                    local mof = as_managed_file(other_file)
                    if mof and mof.gitdir == gitdir then
                        still_used = true
                        break
                    end
                end
                if not still_used then
                    Watchers.stop_for(gitdir)
                end
            end
        end,
    })
end

--- Register git index watcher callback to refresh all buffer states and re-render spotlight windows.
local function setup_watcher()
    Watchers.on_update(function()
        Git.async(function()
            for path, file in pairs(files) do
                local mfile = as_managed_file(file)
                if mfile then
                    local source_bufid = mfile.bufs.source and mfile.bufs.source.buf or nil
                    local ok, file_data = fetch_file_data(mfile.path, source_bufid)

                    if ok and file_data then
                        mfile.status = file_data.status
                        mfile.raw_hunks = file_data.raw_hunks
                        mfile.visible_hunks = file_data.visible_hunks
                        mfile.action_hunks = file_data.action_hunks
                    else
                        refresh_file_state(path)
                    end
                end
            end

            for winid, win in pairs(wins) do
                if vim.api.nvim_win_is_valid(winid) then
                    local winbufid = vim.api.nvim_win_get_buf(winid)
                    local file = file_for_buf(winbufid)
                    if file then
                        sync_picker_context(winid, winbufid)
                        win.resolved_mode = resolve_mode_for_file(file, win.requested_mode, win.picker_override)

                        local display = ensure_window_buf(winid, winbufid, file, win.resolved_mode)
                        if display then
                            render(winid, display.buf, { cursor = "nearest", trigger = "fn:watcher" })
                        end
                    end
                end
            end
        end)
    end)
end

--- Global Spotlight setup
function M.setup()
    Highlights.setup()
    setup_autocmds()
    setup_watcher()
    setup_global_keymaps()
end

---@param winid delta.WinId
---@param path delta.FilePath
---@param opts delta.spotlight.PickerOpenOpts
---@return delta.WinId opened_winid
---@return boolean enable_spotlight
function M.open_picker_entry(winid, path, opts)
    local target_winid = winid
    local target_path = path

    if opts.section == "staged" then
        if opts.status:has_staged_deletion() then
            target_path = Paths.scratch("deleted", path)
        elseif opts.status:has_unstaged() then
            target_path = Paths.scratch("staged", path)
        end
    elseif opts.status:has_unstaged_deletion() then
        target_path = Paths.scratch("deleted", path)
    end

    picker_contexts[target_winid] = {
        path = path,
        section = opts.section,
        nav = opts.nav,
        timestamp = vim.uv.hrtime(),
    }

    vim.api.nvim_win_call(winid, function()
        vim.cmd(opts.cmd .. " " .. vim.fn.fnameescape(target_path))
        target_winid = vim.api.nvim_get_current_win()
    end)

    return target_winid, opts.spotlight or target_path ~= path
end

--- Enable spotlight on the current buffer/window. No-op if already active on this buffer.
---@param mode? delta.spotlight.RequestedMode
function M.ensure(mode)
    local winid = vim.api.nvim_get_current_win()

    if wins[winid] then
        return
    end

    local bufid = vim.api.nvim_get_current_buf()
    if not is_related_buf(bufid) then
        return
    end

    local path, scratch = path_for_buf(bufid)
    if not path then
        return
    end

    local function still_targeting_path()
        if not vim.api.nvim_win_is_valid(winid) then
            return false
        end

        local current_bufid = vim.api.nvim_win_get_buf(winid)
        if not vim.api.nvim_buf_is_valid(current_bufid) then
            return false
        end

        local current_path = path_for_buf(current_bufid)
        return current_path == path
    end

    local function enable(file)
        if
            not vim.api.nvim_win_is_valid(winid)
            or not vim.api.nvim_buf_is_valid(bufid)
            or not still_targeting_path()
        then
            return
        end

        if scratch then
            register_file_buf(file, "scratch", bufid, scratch)
        else
            register_file_buf(file, "source", bufid, nil)
        end

        local requested_mode = mode or "auto"
        local _, picker_override = process_picker_context(winid, file, file.path)
        local resolved_mode = resolve_mode_for_file(file, requested_mode, picker_override)
        local display = ensure_window_buf(winid, bufid, file, resolved_mode)

        if not display then
            return
        end

        clear_render_callbacks(winid)

        wins[winid] = {
            id = winid,
            requested_mode = requested_mode,
            resolved_mode = resolved_mode,
            picker_override = picker_override,
            original = {
                winbar = vim.wo[winid].winbar,
                winhighlight = vim.wo[winid].winhighlight,
                folds = {
                    foldmethod = vim.wo[winid].foldmethod,
                    foldexpr = vim.wo[winid].foldexpr,
                    foldlevel = vim.wo[winid].foldlevel,
                    foldenable = vim.wo[winid].foldenable,
                    foldminlines = vim.wo[winid].foldminlines,
                },
            },
        }

        render(winid, display.buf, { cursor = "nearest", trigger = "fn:ensure" })
        setup_winhighlight(winid)
        setup_local_keymaps(display.buf)
    end

    if not refreshing_file_state_locks:acquire(path) then
        refreshing_file_state_locks:wait(path, function()
            local file = files[path]
            if file and refreshing_file_state_locks:acquire(path) then
                Git.async(function()
                    local ok = refresh_file_state(path, scratch and nil or bufid)
                    refreshing_file_state_locks:release(path)

                    if not ok then
                        Notify.error("Failed to prepare file state." .. " Path: " .. path)
                        return
                    end

                    local refreshed_file = files[path]
                    if refreshed_file then
                        enable(refreshed_file)
                    else
                        Notify.error("File was not prepared on spotlight activation. Path: " .. path)
                    end
                end)
            end
        end)
        return
    end

    Git.async(function()
        local ok = refresh_file_state(path, scratch and nil or bufid)
        refreshing_file_state_locks:release(path)

        if not ok then
            Notify.error("Failed to prepare file state." .. " Path: " .. path)
            return
        end

        local file = files[path]
        if file then
            enable(file)
        else
            Notify.error("File was not prepared on spotlight activation. Path: " .. path)
        end
    end)
end

--- Disable spotlight for one window.
--- If a scratch buffer is currently displayed, it must be replaced before spotlight is off,
--- because scratch buffers are only meaningful as spotlight views.
---
--- Manual disable can afford a filesystem check and tries to reopen the source path
--- because it's a response to user action.
--- disable_all() avoids that and uses only local fallbacks to keep batch teardown stable
--- and minimize side effects to not break session persistance.
---
--- Window spotlight state is cleared before any buffer switch to avoid BufEnter/WinEnter
--- re-entering spotlight logic while we are tearing it down.
---@param winid delta.WinId
---@param bufid delta.BufId
---@param manual boolean
local function disable_window(winid, bufid, manual)
    local win = wins[winid]
    if not win then
        return
    end

    local display_bufid = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) or bufid
    local file = file_for_buf(display_bufid) or file_for_buf(bufid)
    local _, displayed_scratch = path_for_buf(display_bufid)

    restore_winbar_and_winhighlight(winid, win)
    restore_folds(winid, win)

    -- Remove window spotlight state before any buffer switch to avoid spotlight re-entry.
    wins[winid] = nil
    picker_contexts[winid] = nil
    clear_render_callbacks(winid)

    if displayed_scratch and vim.api.nvim_win_is_valid(winid) then
        local switched = false

        if manual and file and vim.uv.fs_stat(file.path) then
            vim.api.nvim_win_call(winid, function()
                local ok = pcall(function()
                    vim.cmd("silent keepalt edit " .. vim.fn.fnameescape(file.path))
                end)
                switched = ok
            end)
        end

        if not switched then
            local infos = vim.fn.getbufinfo({ buflisted = 1 })
            table.sort(infos, function(a, b)
                return (a.lastused or 0) > (b.lastused or 0)
            end)

            for _, info in ipairs(infos) do
                local candidate = info.bufnr
                if candidate ~= display_bufid and vim.api.nvim_buf_is_valid(candidate) then
                    vim.api.nvim_win_set_buf(winid, candidate)
                    switched = true
                    break
                end
            end
        end

        if not switched then
            vim.api.nvim_win_set_buf(winid, vim.api.nvim_create_buf(true, false))
        end

        restore_winbar_and_winhighlight(winid, win)
        restore_folds(winid, win)
    end

    local cleaned = {}

    local function cleanup_buf(target_bufid)
        if not target_bufid or cleaned[target_bufid] then
            return
        end
        cleaned[target_bufid] = true

        clear_folds(target_bufid)
        clear_local_keymaps(target_bufid)

        if vim.api.nvim_buf_is_valid(target_bufid) and vim.b[target_bufid].delta_spotlight == winid then
            vim.b[target_bufid].delta_spotlight = nil
        end

        local has_ufo, ufo = pcall(require, "ufo")
        if has_ufo then
            ufo.attach(target_bufid)
        end
    end

    if file then
        cleanup_buf(file.bufs.source and file.bufs.source.buf or nil)
        cleanup_buf(file.bufs.scratch.staged and file.bufs.scratch.staged.buf or nil)
        cleanup_buf(file.bufs.scratch.deleted and file.bufs.scratch.deleted.buf or nil)
    else
        cleanup_buf(display_bufid)
        cleanup_buf(bufid)
    end
end

--- Disable spotlight and restore original settings.
function M.disable(buf)
    buf = buf or vim.api.nvim_get_current_buf()

    local win = vim.api.nvim_get_current_win()
    disable_window(win, buf, true)
end

--- Toggle spotlight on the current buffer.
---@param mode? delta.spotlight.RequestedMode
function M.toggle(mode)
    local win = vim.api.nvim_get_current_win()
    if wins[win] then
        M.disable()
        return
    end
    M.ensure(mode)
end

--- Disable spotlight on all active spotlight windows.
function M.disable_all()
    for win, _ in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            disable_window(win, vim.api.nvim_win_get_buf(win), false)
        else
            wins[win] = nil
        end
    end
end

--- Check if spotlight is active on a window.
---@param win? delta.WinId defaults to current window
---@return boolean
function M.is_active(win)
    win = win or vim.api.nvim_get_current_win()
    return wins[win] ~= nil
end

--- Expand context by context_step lines.
---@param bufid? delta.BufId defaults to current buffer
---@param step? number amount to expand by; defaults to spotlight.context.step
function M.expand_context(bufid, step)
    bufid = bufid or vim.api.nvim_get_current_buf()

    local fold = folds[bufid]

    if not fold then
        return
    end

    local win = vim.api.nvim_get_current_win()
    if not has_closed_folds(win, bufid) then
        return
    end

    local current_context = fold.context or Config.options.spotlight.context.base
    step = step or Config.options.spotlight.context.step
    fold.context = current_context + step

    render(win, bufid, { cursor = "keep", trigger = "fn:expand_context" })
end

--- Shrink context by context_step lines.
---@param bufid? delta.BufId defaults to current buffer
---@param step? number amount to shrink by; defaults to spotlight.context.step
function M.shrink_context(bufid, step)
    bufid = bufid or vim.api.nvim_get_current_buf()

    local fold = folds[bufid]

    if not fold then
        return
    end

    local current_context = fold.context or Config.options.spotlight.context.base

    if current_context <= Config.options.spotlight.context.base then
        return
    end

    step = step or Config.options.spotlight.context.step
    fold.context = math.max(Config.options.spotlight.context.base, current_context - step)

    local win = vim.api.nvim_get_current_win()
    render(win, bufid, { cursor = "keep", trigger = "fn:shrink_context" })
end

--- Cycle between spotlight modes.
---@type table<delta.spotlight.RequestedMode, delta.spotlight.RequestedMode>
local mode_cycle = {
    auto = "unstaged",
    unstaged = "staged",
    staged = "auto",
}

---@param bufid? delta.BufId defaults to current buffer
function M.cycle_mode(bufid)
    bufid = bufid or vim.api.nvim_get_current_buf()
    local winid = vim.api.nvim_get_current_win()

    local win = wins[winid]
    local mfile = as_managed_file(file_for_buf(bufid))

    if not win or not mfile then
        return
    end

    local current_requested_mode = win.requested_mode

    local next_requested_mode = current_requested_mode == "auto" and mode_cycle[win.resolved_mode]
        or mode_cycle[current_requested_mode]

    win.picker_override = nil
    win.requested_mode = next_requested_mode
    win.resolved_mode = resolve_mode_for_file(mfile, next_requested_mode, win.picker_override)

    Git.async(function()
        local display = ensure_window_buf(winid, bufid, mfile, win.resolved_mode)
        if not display then
            return
        end

        render(winid, display.buf, { cursor = "first", trigger = "fn:cycle_mode" })
    end)
end

---@param winid delta.WinId
---@param bufid delta.BufId
---@param line integer
local function set_cursor_clamped(winid, bufid, line)
    local line_count = vim.api.nvim_buf_line_count(bufid)
    local clamped = math.max(1, math.min(line, math.max(line_count, 1)))
    vim.api.nvim_win_set_cursor(winid, { clamped, 0 })
end

--- Jump to the next hunk group. Wraps to the first if at the end.
---@param bufid delta.BufId
function M.next_hunk(bufid)
    local winid = vim.api.nvim_get_current_win()

    local win = wins[winid]
    local file = file_for_buf(bufid)

    local _, groups = Hunks.resolve(winid, bufid, win, file)

    if not groups or #groups == 0 then
        return
    end

    local cur_line = vim.api.nvim_win_get_cursor(winid)[1]

    for i, g in ipairs(groups) do
        if g.start_line == cur_line then
            local next_group = groups[i + 1] or groups[1]
            set_cursor_clamped(winid, bufid, next_group.start_line)
            vim.cmd("normal! zz")
            return
        end
    end

    for _, g in ipairs(groups) do
        if g.start_line > cur_line then
            set_cursor_clamped(winid, bufid, g.start_line)
            vim.cmd("normal! zz")
            return
        end
    end

    set_cursor_clamped(winid, bufid, groups[1].start_line)
    vim.cmd("normal! zz")
end

--- Jump to the previous hunk group. Wraps to the last if at the start.
---@param bufid delta.BufId
function M.prev_hunk(bufid)
    local winid = vim.api.nvim_get_current_win()

    local win = wins[winid]
    local file = file_for_buf(bufid)

    local _, groups = Hunks.resolve(winid, bufid, win, file)

    if not groups or #groups == 0 then
        return
    end

    local cur_line = vim.api.nvim_win_get_cursor(winid)[1]

    for i, g in ipairs(groups) do
        if g.start_line == cur_line then
            local prev_group = groups[i - 1] or groups[#groups]
            set_cursor_clamped(winid, bufid, prev_group.start_line)
            vim.cmd("normal! zz")
            return
        end
    end

    for i = #groups, 1, -1 do
        local g = groups[i]
        if g.start_line < cur_line then
            set_cursor_clamped(winid, bufid, g.start_line)
            vim.cmd("normal! zz")
            return
        end
    end

    set_cursor_clamped(winid, bufid, groups[#groups].start_line)
    vim.cmd("normal! zz")
end

---@param path string
---@return boolean
local function has_modified_open_buffer(path)
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(candidate) and vim.bo[candidate].modified then
            local candidate_path = path_for_buf(candidate)
            if candidate_path == path then
                return true
            end
        end
    end
    return false
end

---@param status delta.FileStatus
---@param resolved_mode delta.spotlight.ResolvedMode?
---@return delta.ResetTarget?
local function resolve_file_reset_target(status, resolved_mode)
    if status:is_untracked() then
        return "delete"
    end
    if resolved_mode == "staged" and status:has_staged() then
        return "head"
    end
    if status:has_unstaged() then
        return "index"
    end
    if status:has_staged() then
        return "head"
    end
end

--- Toggle staged/unstaged for the current spotlight file.
---@param bufid? delta.BufId defaults to current buffer
---@param cb? fun() Runs after a successful stage/unstage completes
function M.toggle_stage_file(bufid, cb)
    bufid = bufid or vim.api.nvim_get_current_buf()

    local mfile = as_managed_file(file_for_buf(bufid))

    if not mfile or mfile.path == "" then
        return
    end

    local path = mfile.path
    if not mutating_file_state_locks:acquire(path) then
        Notify.info("Another operation is going on on the file")
        return
    end

    Git.async(function()
        local ok_run, err = xpcall(function()
            if mfile.status:has_unstaged() then
                local ok = Git.stage(path)
                if not ok then
                    return
                end
                maybe_reopen_picker_after_stage(mfile)
            else
                local ok = Git.unstage(path)
                if not ok then
                    return
                end
            end

            if cb then
                cb()
            end
        end, debug.traceback)

        mutating_file_state_locks:release(path)

        if not ok_run then
            error(err)
        end
    end)
end

--- Reset the current spotlight file to the active baseline.
---@param bufid? delta.BufId defaults to current buffer
---@param cb? fun() Runs after a successful reset completes
function M.reset_file(bufid, cb)
    bufid = bufid or vim.api.nvim_get_current_buf()

    local mfile = as_managed_file(file_for_buf(bufid))
    if not mfile or mfile.path == "" then
        return
    end

    local path = mfile.path
    if has_modified_open_buffer(path) then
        Notify.error("Reset aborted: file has unsaved changes: " .. path)
        return
    end

    local win = wins[vim.api.nvim_get_current_win()]
    local target = resolve_file_reset_target(mfile.status, win and win.resolved_mode or nil)
    if not target then
        Notify.info("No changes to reset")
        return
    end

    if Config.options.reset.confirm then
        local baseline = target == "head" and "HEAD" or target == "index" and "index" or "deletion"
        local choice = vim.fn.confirm("Reset current file to " .. baseline .. "?", "&Yes\n&No", 2)
        if choice ~= 1 then
            Notify.info("Reset cancelled")
            return
        end
    end

    if not mutating_file_state_locks:acquire(path) then
        Notify.info("Another operation is going on on the file")
        return
    end

    Git.async(function()
        local ok_run, err = xpcall(function()
            local ok, undo_hint, reset_err = Git.reset_file(path, target)
            if not ok then
                Notify.error(reset_err or ("Failed to reset file: " .. path))
                return
            end

            pcall(function()
                vim.cmd("checktime " .. bufid)
            end)

            if undo_hint then
                Notify.info("Reset complete. Undo hint: " .. undo_hint)
            end

            if cb then
                cb()
            end
        end, debug.traceback)

        mutating_file_state_locks:release(path)

        if not ok_run then
            error(err)
        end
    end)
end

---@param hunk delta.Hunk
---@param side delta.HunkSide
---@param start_line number
---@param end_line number
---@return boolean
local function hunk_overlaps_range(hunk, side, start_line, end_line)
    return hunk:start_line(side) <= end_line and hunk:end_line(side) >= start_line
end

---@class delta.spotlight.SerializedHunkRef
---@field added_start number
---@field added_count number
---@field removed_start number
---@field removed_count number

---@class delta.spotlight.SerializedToggleTarget
---@field action "stage"|"unstage"
---@field hunks delta.spotlight.SerializedHunkRef[]

---@param hunk delta.Hunk
---@return string
local function hunk_key(hunk)
    return table.concat({
        hunk.added.start,
        hunk.added.count,
        hunk.removed.start,
        hunk.removed.count,
    }, ":")
end

---@param action "stage"|"unstage"
---@param hunks delta.Hunk[]
---@return delta.spotlight.SerializedToggleTarget
local function serialize_toggle_target(action, hunks)
    local serialized = { action = action, hunks = {} }
    for _, hunk in ipairs(hunks) do
        serialized.hunks[#serialized.hunks + 1] = {
            added_start = hunk.added.start,
            added_count = hunk.added.count,
            removed_start = hunk.removed.start,
            removed_count = hunk.removed.count,
        }
    end
    return serialized
end

---@param source delta.Hunk[]
---@param action "stage"|"unstage"
---@param start_line number
---@param end_line number
---@return { action: "stage"|"unstage", hunks: delta.Hunk[] }?
local function collect_toggle_target(source, action, start_line, end_line)
    local matches = {}

    if start_line == end_line then
        local hunk = Git.find_hunk(source, start_line)
        if not hunk then
            return nil
        end
        matches[1] = hunk
    else
        for _, hunk in ipairs(source) do
            if hunk_overlaps_range(hunk, "added", start_line, end_line) then
                matches[#matches + 1] = hunk
            end
        end

        if #matches == 0 then
            return nil
        end
    end

    return { action = action, hunks = matches }
end

---@param visible_hunks delta.Hunks
---@param raw_hunks delta.Hunks
---@param start_line number
---@param end_line number
---@return { action: "stage"|"unstage", hunks: delta.Hunk[] }?
local function resolve_toggle_target(visible_hunks, raw_hunks, start_line, end_line)
    local unstaged_target = collect_toggle_target(visible_hunks.unstaged, "stage", start_line, end_line)
    if unstaged_target then
        return unstaged_target
    end

    local staged_start, staged_end = Git.worktree_to_index_range(start_line, end_line, raw_hunks.unstaged)
    return collect_toggle_target(raw_hunks.staged, "unstage", staged_start, staged_end)
end

---@param visible_hunks delta.Hunks
---@param start_line number
---@param end_line number
---@return delta.Hunk[]?
local function resolve_reset_hunks(visible_hunks, start_line, end_line)
    local target = collect_toggle_target(visible_hunks.unstaged, "stage", start_line, end_line)
    return target and target.hunks or nil
end

---@param target { action: "stage"|"unstage", hunks: delta.Hunk[] }
---@param other_hunks delta.Hunk[]
---@return boolean
local function target_overlaps_hunks(target, other_hunks)
    for _, target_hunk in ipairs(target.hunks) do
        for _, other_hunk in ipairs(other_hunks) do
            if hunk_overlaps_range(other_hunk, "added", target_hunk:start_line(), target_hunk:end_line()) then
                return true
            end
        end
    end

    return false
end

---@class delta.spotlight.TogglePatchContext
---@field file_header string[]
---@field hunks delta.Hunk[]
---@field base_lines string[]
---@field current_lines string[]

---@param path string
---@param action "stage"|"unstage"
---@return delta.spotlight.TogglePatchContext? ctx
---@return string? err
local function get_toggle_patch_context(path, action)
    local staged = action == "unstage"
    local ok_patch, file_header, hunks, patch_err = Git.get_patch_data(path, staged)
    if not ok_patch then
        return nil, patch_err or "failed to load diff"
    end

    local ok_base, base_lines, base_err
    local ok_current, current_lines, current_err

    if action == "stage" then
        ok_base, base_lines, base_err = Git.get_index_lines(path)
        ok_current, current_lines, current_err = Git.get_worktree_lines(path)
    else
        ok_base, base_lines, base_err = Git.get_head_lines(path)
        ok_current, current_lines, current_err = Git.get_index_lines(path)
    end

    if not ok_base or not base_lines then
        return nil, base_err or "failed to load base file"
    end
    if not ok_current or not current_lines then
        return nil, current_err or "failed to load current file"
    end

    return {
        file_header = file_header,
        hunks = hunks,
        base_lines = base_lines,
        current_lines = current_lines,
    },
        nil
end

---@param path string
---@param target { action: "stage"|"unstage", hunks: delta.Hunk[] }
---@param start_line number
---@param end_line number
---@param partial boolean
---@param source_hunks? delta.Hunk[]
---@return boolean success
---@return string? err
local function apply_toggle_target(path, target, start_line, end_line, partial, source_hunks)
    local ctx, ctx_err = get_toggle_patch_context(path, target.action)
    if not ctx then
        return false, ctx_err
    end

    local raw_hunks_by_key = {}
    for _, hunk in ipairs(ctx.hunks) do
        raw_hunks_by_key[hunk_key(hunk)] = hunk
    end

    local selected_hunks = {}

    if partial then
        local shape = Git.create_partial_hunk(source_hunks or target.hunks, start_line, end_line)
        if shape then
            local source_hunk = (#target.hunks == 1 and raw_hunks_by_key[hunk_key(target.hunks[1])]) or shape
            selected_hunks[1] = Git.populate_hunk_lines(shape, ctx.base_lines, ctx.current_lines, source_hunk)
        end
    else
        for _, target_hunk in ipairs(target.hunks) do
            local source_hunk = raw_hunks_by_key[hunk_key(target_hunk)] or target_hunk
            selected_hunks[#selected_hunks + 1] =
                Git.populate_hunk_lines(target_hunk, ctx.base_lines, ctx.current_lines, source_hunk)
        end
    end

    if #selected_hunks == 0 then
        return false, "no selected hunks"
    end

    local patch = Git.build_patch(ctx.file_header, selected_hunks)
    return Git.apply_patch(patch, { reverse = target.action == "unstage", cached = true })
end

---@return delta.spotlight.TogglePatchContext? ctx
---@return string? err
local function get_reset_patch_context(path)
    local ok_patch, file_header, hunks, patch_err = Git.get_patch_data(path, false)
    if not ok_patch then
        return nil, patch_err or "failed to load diff"
    end

    local ok_base, base_lines, base_err = Git.get_index_lines(path)
    local ok_current, current_lines, current_err = Git.get_worktree_lines(path)
    if not ok_base or not base_lines then
        return nil, base_err or "failed to load base file"
    end
    if not ok_current or not current_lines then
        return nil, current_err or "failed to load current file"
    end

    return {
        file_header = file_header,
        hunks = hunks,
        base_lines = base_lines,
        current_lines = current_lines,
    },
        nil
end

---@param bufid delta.BufId
---@param path string
---@param target_hunks delta.Hunk[]
---@param start_line number
---@param end_line number
---@param partial boolean
---@param source_hunks? delta.Hunk[]
---@return boolean success
---@return string? err
local function apply_reset_hunks(bufid, path, target_hunks, start_line, end_line, partial, source_hunks)
    local ctx, ctx_err = get_reset_patch_context(path)
    if not ctx then
        return false, ctx_err
    end

    local raw_hunks_by_key = {}
    for _, hunk in ipairs(ctx.hunks) do
        raw_hunks_by_key[hunk_key(hunk)] = hunk
    end

    local selected_hunks = {}
    if partial then
        local shape = Git.create_partial_hunk(source_hunks or target_hunks, start_line, end_line)
        if shape then
            local source_hunk = (#target_hunks == 1 and raw_hunks_by_key[hunk_key(target_hunks[1])]) or shape
            selected_hunks[1] = Git.populate_hunk_lines(shape, ctx.base_lines, ctx.current_lines, source_hunk)
        end
    else
        for _, target_hunk in ipairs(target_hunks) do
            local source_hunk = raw_hunks_by_key[hunk_key(target_hunk)] or target_hunk
            selected_hunks[#selected_hunks + 1] =
                Git.populate_hunk_lines(target_hunk, ctx.base_lines, ctx.current_lines, source_hunk)
        end
    end

    if #selected_hunks == 0 then
        return false, "no selected hunks"
    end

    table.sort(selected_hunks, function(a, b)
        return a.added.start > b.added.start
    end)

    for _, hunk in ipairs(selected_hunks) do
        local start_idx, end_idx
        if hunk.type == "delete" then
            start_idx = hunk.added.start
            end_idx = hunk.added.start
        else
            start_idx = hunk.added.start - 1
            end_idx = start_idx + hunk.added.count
        end

        vim.api.nvim_buf_set_lines(bufid, start_idx, end_idx, false, hunk.removed.lines)

        if hunk.removed.no_nl_at_eof ~= hunk.added.no_nl_at_eof then
            local no_eol = hunk.added.no_nl_at_eof or false
            vim.bo[bufid].endofline = no_eol
            vim.bo[bufid].fixendofline = no_eol
        end
    end

    local ok, write_err = pcall(function()
        vim.api.nvim_buf_call(bufid, function()
            vim.cmd("silent write")
        end)
    end)
    if not ok then
        return false, tostring(write_err)
    end

    return true, nil
end

local function exit_visual_mode()
    local mode = vim.api.nvim_get_mode().mode
    if mode == "v" or mode == "V" or mode == "\22" then
        local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
        vim.api.nvim_feedkeys(esc, "nx", false)
    end
end

---@param winid delta.WinId
---@param bufid delta.BufId
---@param file delta.spotlight.FileState
---@param line number
local function jump_to_next_hunk_after_stage_toggle(winid, bufid, file, line)
    local win = wins[winid]
    local hunks = Hunks.resolve(winid, bufid, win, file)
    local side = visible_hunk_side_for_buf(bufid)

    if not hunks or #hunks == 0 then
        return
    end

    for _, hunk in ipairs(hunks) do
        local hunk_line = hunk:target(side)
        if hunk_line > line then
            vim.api.nvim_win_set_cursor(winid, { hunk_line, 0 })
            vim.cmd("normal! zz")
            return
        end
    end

    vim.api.nvim_win_set_cursor(winid, { hunks[1]:target(side), 0 })
    vim.cmd("normal! zz")
end

---@param bufid delta.BufId
---@return boolean proceed
local function ensure_buffer_saved_for_toggle_stage_hunk(bufid)
    if not Config.options.spotlight.autosave_before_stage then
        local choice = vim.fn.confirm("Buffer has unsaved changes. Save and continue?", "&Yes\n&No", 1)
        if choice ~= 1 then
            Notify.info("Operation cancelled")
            return false
        end
    end

    local ok, err = pcall(function()
        vim.api.nvim_buf_call(bufid, function()
            vim.cmd("silent write")
        end)
    end)
    if not ok then
        Notify.error("Failed to save file before hunk toggle: " .. tostring(err))
        return false
    end

    return true
end

--- Stage or unstage the hunk under cursor, or specific lines in visual mode.
---@param bufid? delta.BufId defaults to current buffer
---@param start_line? number visual selection start (nil for full hunk)
---@param end_line? number visual selection end (nil for full hunk)
---@param cb? fun() Runs after a successful stage/unstage completes
function M.toggle_stage_hunk(bufid, start_line, end_line, cb)
    bufid = bufid or vim.api.nvim_get_current_buf()
    local winid = vim.api.nvim_get_current_win()

    local mfile = as_managed_file(file_for_buf(bufid))
    if not mfile or mfile.path == "" then
        return
    end

    local path = mfile.path
    local is_visual_selection = start_line ~= nil and end_line ~= nil
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local range_start = start_line or cursor_line
    local range_end = end_line or cursor_line
    if range_start > range_end then
        range_start, range_end = range_end, range_start
    end

    local _, _, scratch = file_and_path_for_buf(bufid)
    if scratch then
        Notify.info(
            "Hunk toggle is not supported in scratch diff views; use the source buffer or file-level toggle instead"
        )
        return
    end

    local partial_selection = is_visual_selection
    if not partial_selection then
        range_start = cursor_line
        range_end = cursor_line
    end

    if vim.bo[bufid].modified and not ensure_buffer_saved_for_toggle_stage_hunk(bufid) then
        return
    end

    if not mutating_file_state_locks:acquire(path) then
        Notify.info("Another operation is going on on the file")
        return
    end

    local function run_toggle()
        Git.async(function()
            local ok_run, err = xpcall(function()
                local current_file = as_managed_file(files[path])
                if not current_file then
                    return
                end

                local cached_target =
                    resolve_toggle_target(current_file.action_hunks, current_file.raw_hunks, range_start, range_end)

                local source_bufid = current_file.bufs.source and current_file.bufs.source.buf or nil
                local ok_data, fresh_file_data = fetch_file_data(path, source_bufid)
                if not ok_data or not fresh_file_data then
                    Notify.info("Failed to refresh git state")
                    return
                end

                local fresh_target = resolve_toggle_target(
                    fresh_file_data.action_hunks,
                    fresh_file_data.raw_hunks,
                    range_start,
                    range_end
                )

                if not fresh_target then
                    Notify.info("No hunk at cursor")
                    return
                end

                if
                    fresh_target.action == "unstage"
                    and not partial_selection
                    and target_overlaps_hunks(fresh_target, fresh_file_data.raw_hunks.unstaged)
                then
                    local choice = vim.fn.confirm(
                        "This staged hunk overlaps unstaged changes and may unstage more than expected. Continue?",
                        "&Yes\n&No",
                        2
                    )
                    if choice ~= 1 then
                        Notify.info("Unstage cancelled")
                        return
                    end
                end

                local apply_start, apply_end = range_start, range_end
                if fresh_target.action == "unstage" and partial_selection then
                    apply_start, apply_end =
                        Git.worktree_to_index_range(range_start, range_end, fresh_file_data.raw_hunks.unstaged)
                end

                local visible_source_hunks = fresh_target.action == "unstage" and fresh_file_data.raw_hunks.staged
                    or fresh_file_data.action_hunks.unstaged
                local ok, apply_err = apply_toggle_target(
                    path,
                    fresh_target,
                    apply_start,
                    apply_end,
                    partial_selection,
                    visible_source_hunks
                )
                if not ok then
                    Notify.info(apply_err or "No hunk at cursor")
                    return
                end

                if fresh_target.action == "stage" then
                    maybe_reopen_picker_after_stage(current_file)
                end

                local registered = register_render_callback(winid, path, function(_, wid, bid)
                    if partial_selection then
                        vim.api.nvim_win_call(wid, exit_visual_mode)
                    end
                    jump_to_next_hunk_after_stage_toggle(wid, bid, current_file, cursor_line)
                    if cb then
                        cb()
                    end
                end)
                if not registered and cb then
                    cb()
                end
            end, debug.traceback)

            mutating_file_state_locks:release(path)

            if not ok_run then
                error(err)
            end
        end)
    end

    if refreshing_file_state_locks:locked(path) then
        refreshing_file_state_locks:wait(path, function()
            if not vim.api.nvim_buf_is_valid(bufid) or path_for_buf(bufid) ~= path then
                mutating_file_state_locks:release(path)
                return
            end

            run_toggle()
        end, {
            on_timeout = function()
                mutating_file_state_locks:release(path)
                Notify.error("Failed to wait for file state." .. " Path: " .. path)
            end,
        })
        return
    end

    run_toggle()
end

--- Reset the unstaged hunk under cursor, or specific lines in visual mode.
---@param bufid? delta.BufId defaults to current buffer
---@param start_line? number visual selection start (nil for full hunk)
---@param end_line? number visual selection end (nil for full hunk)
---@param cb? fun() Runs after a successful reset completes
function M.reset_hunk(bufid, start_line, end_line, cb)
    bufid = bufid or vim.api.nvim_get_current_buf()
    local winid = vim.api.nvim_get_current_win()

    local mfile = as_managed_file(file_for_buf(bufid))
    if not mfile or mfile.path == "" then
        return
    end

    local path = mfile.path
    local is_visual_selection = start_line ~= nil and end_line ~= nil
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local range_start = start_line or cursor_line
    local range_end = end_line or cursor_line
    if range_start > range_end then
        range_start, range_end = range_end, range_start
    end

    local _, _, scratch = file_and_path_for_buf(bufid)
    if scratch then
        Notify.info(
            "Hunk reset is not supported in scratch diff views; use the source buffer or file-level reset instead"
        )
        return
    end

    local partial_selection = is_visual_selection
    if not partial_selection then
        range_start = cursor_line
        range_end = cursor_line
    end

    if vim.bo[bufid].modified and not ensure_buffer_saved_for_toggle_stage_hunk(bufid) then
        return
    end

    if not mutating_file_state_locks:acquire(path) then
        Notify.info("Another operation is going on on the file")
        return
    end

    local function run_reset()
        Git.async(function()
            local ok_run, err = xpcall(function()
                local current_file = as_managed_file(files[path])
                if not current_file then
                    return
                end

                local cached_hunks = resolve_reset_hunks(current_file.action_hunks, range_start, range_end)

                local source_bufid = current_file.bufs.source and current_file.bufs.source.buf or nil
                local ok_data, fresh_file_data = fetch_file_data(path, source_bufid)
                if not ok_data or not fresh_file_data then
                    Notify.info("Failed to refresh git state")
                    return
                end

                local fresh_hunk_target = resolve_reset_hunks(fresh_file_data.action_hunks, range_start, range_end)
                if not fresh_hunk_target then
                    if
                        collect_toggle_target(fresh_file_data.action_hunks.staged, "unstage", range_start, range_end)
                    then
                        Notify.info("Reset is only supported for unstaged hunks")
                    else
                        Notify.info("No hunk at cursor")
                    end
                    return
                end

                local ok, apply_err = apply_reset_hunks(
                    bufid,
                    path,
                    fresh_hunk_target,
                    range_start,
                    range_end,
                    partial_selection,
                    fresh_file_data.action_hunks.unstaged
                )
                if not ok then
                    Notify.info(apply_err or "No hunk at cursor")
                    return
                end

                local registered = register_render_callback(winid, path, function(_, wid, bid)
                    if partial_selection then
                        vim.api.nvim_win_call(wid, exit_visual_mode)
                    end
                    jump_to_next_hunk_after_stage_toggle(wid, bid, current_file, cursor_line)
                    if cb then
                        cb()
                    end
                end)
                if not registered and cb then
                    cb()
                end
            end, debug.traceback)

            mutating_file_state_locks:release(path)

            if not ok_run then
                error(err)
            end
        end)
    end

    if refreshing_file_state_locks:locked(path) then
        refreshing_file_state_locks:wait(path, function()
            if not vim.api.nvim_buf_is_valid(bufid) or path_for_buf(bufid) ~= path then
                mutating_file_state_locks:release(path)
                return
            end

            run_reset()
        end, {
            on_timeout = function()
                mutating_file_state_locks:release(path)
                Notify.error("Failed to wait for file state." .. " Path: " .. path)
            end,
        })
        return
    end

    run_reset()
end

return M
