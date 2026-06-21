--- Native side-by-side file diff for delta.nvim.

local M = {}

local Config = require("delta.config")
local Git = require("delta.git")
local Highlights = require("delta.diff.highlights")
local Keys = require("delta.keys")
local Mode = require("delta.spotlight.mode")
local Notify = require("delta.notify")
local Paths = require("delta.spotlight.paths")

local DEFAULT_DIFF_CONTEXT = 6

---@class delta.diff.FileOpenOpts
---@field winid? delta.WinId
---@field bufid? delta.BufId
---@field path? string
---@field mode? delta.diff.FileMode

---@class delta.diff.file.State
---@field tab delta.TabId
---@field origin_tab delta.TabId
---@field origin_win delta.WinId
---@field left_win delta.WinId
---@field right_win delta.WinId
---@field left_buf delta.BufId
---@field right_buf delta.BufId
---@field path string
---@field requested_mode delta.diff.FileMode
---@field resolved_mode "unstaged"|"staged"
---@field source_bufid? delta.BufId
---@field source_changedtick? integer
---@field used_source_buffer boolean
---@field context integer
---@field context_base integer
---@field context_step integer
---@field augroup integer
---@field keymap_hints { mode: "none"|"dialog"|"winbar", key?: delta.KeySpec, lhs?: string, collides?: boolean }
---@field hint_actions table[]
---@field closing? boolean
---@field mutating? boolean

---@type table<delta.TabId, delta.diff.file.State>
local tabs = {}

---@type string?
local owned_diffopt = nil
local diffopt_refcount = 0

local next_id = 0

---@return string[]
local function diffopt_items()
    return vim.split(vim.go.diffopt, ",", { plain = true, trimempty = true })
end

---@return integer
local function diff_context()
    for _, item in ipairs(diffopt_items()) do
        local value = item:match("^context:(%d+)$")
        if value then
            return tonumber(value) or DEFAULT_DIFF_CONTEXT
        end
    end
    return DEFAULT_DIFF_CONTEXT
end

---@param context integer
local function set_diff_context(context)
    context = math.max(0, context)

    local items = {}
    for _, item in ipairs(diffopt_items()) do
        if not item:match("^context:%d+$") then
            items[#items + 1] = item
        end
    end
    items[#items + 1] = "context:" .. context
    vim.go.diffopt = table.concat(items, ",")
end

---@param keyspecs delta.KeySpecs|nil
---@return delta.KeySpec[]
local function resolve_keyspecs(keyspecs)
    if not keyspecs then
        return {}
    end
    return Keys.resolve(keyspecs)
end

---@param lines string[]
---@return string[]
local function copy_lines(lines)
    return vim.deepcopy(lines or {})
end

---@param left string[]
---@param right string[]
---@return boolean
local function same_lines(left, right)
    if #left ~= #right then
        return false
    end
    for i, line in ipairs(left) do
        if line ~= right[i] then
            return false
        end
    end
    return true
end

---@param path string
---@param label string
---@param lines string[]
---@return delta.BufId
local function create_side_buffer(path, label, lines)
    next_id = next_id + 1
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "delta://diff/" .. next_id .. "/" .. label .. "/" .. path)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].undofile = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].readonly = true
    vim.bo[bufnr].filetype = vim.filetype.match({ filename = path }) or ""
    return bufnr
end

---@param bufnr delta.BufId
---@param lines string[]
local function set_buffer_lines(bufnr, lines)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
end

---@param winid delta.WinId
---@param bufnr delta.BufId
local function setup_window(winid, bufnr)
    local is_markdown = vim.bo[bufnr].filetype == "markdown"
    vim.wo[winid].wrap = is_markdown
    if is_markdown then
        vim.wo[winid].linebreak = true
    end
    vim.wo[winid].number = true
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].winhighlight = Highlights.FILE_WINHIGHLIGHT
end

---@param state delta.diff.file.State
local function refresh_diff_windows(state)
    for _, win in ipairs({ state.left_win, state.right_win }) do
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function()
                vim.cmd("diffupdate")
            end)
        end
    end
end

---@param state delta.diff.file.State
local function labels(state)
    local old_label = state.resolved_mode == "staged" and "HEAD" or "INDEX"
    local new_label = state.resolved_mode == "staged" and "INDEX" or "WORKTREE"
    return old_label, new_label
end

---@param keys delta.diff.FileKeysConfig
---@return table[]
local function keymap_hint_actions(keys)
    return {
        { label = "Stage/unstage file", hint = "stage", keys = resolve_keyspecs(keys.toggle_stage_file) },
        {
            label = "Stage/unstage file and close",
            hint = "stage+close",
            keys = resolve_keyspecs(keys.toggle_stage_file_and_close),
        },
        { label = "Reset file", hint = "reset", keys = resolve_keyspecs(keys.reset_file) },
        { label = "Reset file and close", hint = "reset+close", keys = resolve_keyspecs(keys.reset_file_and_close) },
        { label = "Expand context", hint = "expand", keys = resolve_keyspecs(keys.expand_context) },
        { label = "Shrink context", hint = "shrink", keys = resolve_keyspecs(keys.shrink_context) },
        { label = "Close", hint = "close", keys = resolve_keyspecs(keys.close) },
    }
end

---@param action table
---@return string[]
local function lhs_values(action)
    local values = {}
    for _, key in ipairs(action.keys or {}) do
        local lhs = Keys.lhs(key)
        if lhs ~= "" then
            values[#values + 1] = lhs
        end
    end
    return values
end

---@param lhs string
---@param actions table[]
---@return boolean
local function lhs_collides(lhs, actions)
    if lhs == "" then
        return false
    end
    local normalized = Keys.normalize_lhs(lhs)
    for _, action in ipairs(actions) do
        for _, action_lhs in ipairs(lhs_values(action)) do
            if Keys.normalize_lhs(action_lhs) == normalized then
                return true
            end
        end
    end
    return false
end

---@param file_config delta.diff.FileConfig
---@param actions table[]
---@return { mode: "none"|"dialog"|"winbar", key?: delta.KeySpec, lhs?: string, collides?: boolean }
local function resolve_keymap_hints(file_config, actions)
    local value = file_config.keymap_hints
    if value == nil then
        value = "dialog"
    end
    if value == false then
        return { mode = "none" }
    end
    if value == "winbar" then
        return { mode = "winbar" }
    end
    if value ~= true and value ~= "dialog" then
        Notify.warn("diff: unsupported diff.file.keymap_hints; falling back to dialog")
    end
    local help_key = "?"
    local help_lhs = Keys.lhs(help_key)
    return { mode = "dialog", key = help_key, lhs = help_lhs, collides = lhs_collides(help_lhs, actions) }
end

---@param state delta.diff.file.State
local function open_keymap_dialog(state)
    local lines = { "File diff keymaps", "" }
    for _, action in ipairs(state.hint_actions) do
        local values = lhs_values(action)
        local keys_text = #values > 0 and table.concat(values, ", ") or "(unbound)"
        lines[#lines + 1] = action.label .. ": " .. keys_text
    end
    local close_keys = {}
    local seen_close_keys = {}
    local function add_close_key(lhs)
        if lhs ~= "" and not seen_close_keys[lhs] then
            seen_close_keys[lhs] = true
            close_keys[#close_keys + 1] = lhs
        end
    end
    for _, action in ipairs(state.hint_actions) do
        if action.hint == "close" then
            for _, lhs in ipairs(lhs_values(action)) do
                add_close_key(lhs)
            end
        end
    end
    for _, lhs in ipairs({ "q", "<Esc>", "<CR>" }) do
        add_close_key(lhs)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Close: " .. table.concat(close_keys, ", ")

    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = math.min(math.max(width + 4, 40), math.max(vim.o.columns - 4, 20))
    local height = #lines
    local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "delta://diff/keymaps/" .. buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        border = "rounded",
        title = " Keymaps ",
        style = "minimal",
    })

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    for _, lhs in ipairs(close_keys) do
        vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, desc = "Close keymap help" })
    end
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = close,
    })
end

---@param state delta.diff.file.State
local function render_winbars(state)
    local old_label, new_label = labels(state)
    local hint_text = ""
    if state.keymap_hints.mode == "winbar" then
        local hint = {}
        for _, action in ipairs(state.hint_actions) do
            local values = lhs_values(action)
            if values[1] then
                hint[#hint + 1] = values[1] .. "=" .. action.hint
            end
        end
        hint_text = #hint > 0 and (" [" .. table.concat(hint, "  ") .. "]") or ""
    elseif state.keymap_hints.mode == "dialog" and not state.keymap_hints.collides and state.keymap_hints.lhs then
        hint_text = " [" .. state.keymap_hints.lhs .. "=keymaps]"
    end

    local base = "%#" .. Highlights.groups.file_winbar .. "#"
    local base_label = "%#" .. Highlights.groups.file_winbar_base .. "#"
    local current_label = "%#" .. Highlights.groups.file_winbar_current .. "#"
    local hint_label = "%#" .. Highlights.groups.file_winbar_hint .. "#"

    if vim.api.nvim_win_is_valid(state.left_win) then
        vim.wo[state.left_win].winbar = base .. " " .. base_label .. old_label .. ": " .. state.path .. base
    end
    if vim.api.nvim_win_is_valid(state.right_win) then
        vim.wo[state.right_win].winbar = base
            .. " "
            .. current_label
            .. new_label
            .. ": "
            .. state.path
            .. base
            .. hint_label
            .. hint_text
            .. base
    end
end

---@param state delta.diff.file.State
local function delete_buffers(state)
    if vim.api.nvim_buf_is_valid(state.left_buf) then
        pcall(vim.api.nvim_buf_delete, state.left_buf, { force = true })
    end
    if vim.api.nvim_buf_is_valid(state.right_buf) then
        pcall(vim.api.nvim_buf_delete, state.right_buf, { force = true })
    end
end

---@param state delta.diff.file.State
local function cleanup(state)
    tabs[state.tab] = nil
    if state.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    end
    for _, win in ipairs({ state.left_win, state.right_win }) do
        if vim.api.nvim_win_is_valid(win) then
            vim.wo[win].winbar = ""
        end
    end
    diffopt_refcount = math.max(diffopt_refcount - 1, 0)
    if diffopt_refcount == 0 and owned_diffopt then
        vim.go.diffopt = owned_diffopt
        owned_diffopt = nil
    end
    local diff_win = vim.api.nvim_win_is_valid(state.right_win) and state.right_win
        or (vim.api.nvim_win_is_valid(state.left_win) and state.left_win or nil)
    if diff_win then
        vim.api.nvim_win_call(diff_win, function()
            pcall(function()
                vim.cmd("diffoff!")
            end)
        end)
    end
    delete_buffers(state)
end

---@param tab? delta.TabId
function M.close(tab)
    tab = tab or vim.api.nvim_get_current_tabpage()
    local state = tabs[tab]
    if not state or state.closing then
        return
    end
    state.closing = true

    if vim.api.nvim_tabpage_is_valid(state.tab) and #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.api.nvim_set_current_tabpage, state.tab)
        pcall(function()
            vim.cmd("silent! tabclose!")
        end)
    end

    cleanup(state)

    if vim.api.nvim_tabpage_is_valid(state.origin_tab) then
        pcall(vim.api.nvim_set_current_tabpage, state.origin_tab)
        if vim.api.nvim_win_is_valid(state.origin_win) then
            pcall(vim.api.nvim_set_current_win, state.origin_win)
        end
    end
end

function M.close_all()
    local open_tabs = vim.tbl_keys(tabs)
    for _, tab in ipairs(open_tabs) do
        M.close(tab)
    end
end

---@param path string
---@return delta.BufId?
local function modified_open_buffer(path)
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(candidate) and vim.bo[candidate].modified then
            local candidate_path = select(1, Paths.normalize(vim.api.nvim_buf_get_name(candidate)))
            if candidate_path == path then
                return candidate
            end
        end
    end
end

---@param bufnr delta.BufId
---@return integer
local function changedtick(bufnr)
    return vim.api.nvim_buf_get_changedtick(bufnr)
end

---@param state delta.diff.file.State
---@return boolean
local function save_source_buffer_if_visible(state)
    if state.used_source_buffer then
        if
            not state.source_bufid
            or not vim.api.nvim_buf_is_valid(state.source_bufid)
            or state.source_changedtick ~= changedtick(state.source_bufid)
        then
            Notify.error("File has changes not shown in this diff: " .. state.path)
            return false
        end
    end

    local modified = modified_open_buffer(state.path)
    if not modified then
        return true
    end
    if state.used_source_buffer and modified == state.source_bufid then
        local ok, err = pcall(vim.api.nvim_buf_call, modified, function()
            vim.cmd("write")
        end)
        if not ok then
            Notify.error("Save failed: " .. tostring(err))
            return false
        end
        return true
    end
    Notify.error("File has unsaved changes not shown in this diff: " .. state.path)
    return false
end

---@param path string
---@param requested delta.diff.FileMode
---@param status delta.FileStatus
---@return "unstaged"|"staged"|"none"
local function resolve_file_diff_mode(path, requested, status)
    if requested == "staged" then
        return "staged"
    end
    if requested == "unstaged" then
        return "unstaged"
    end
    return status:is_untracked() and "unstaged" or Mode.resolve(path, "auto", status)
end

---@param path string
---@param requested delta.diff.FileMode
---@param current_buf_lines? string[]
---@return boolean ok
---@return "unstaged"|"staged"? resolved
---@return string[]? old_lines
---@return string[]? new_lines
---@return boolean used_source_buffer
local function load_diff_lines(path, requested, current_buf_lines)
    local ok, status, errkind = Git.file_status(path)
    if not ok or not status then
        if errkind == "no_repo" then
            Notify.info("No git repository")
        elseif errkind == "outsider" then
            Notify.info("Current file is outside a git repository")
        end
        return false, nil, nil, nil, false
    end

    local resolved = resolve_file_diff_mode(path, requested, status)
    if resolved == "none" then
        return true, nil, nil, nil, false
    end

    ---@type "unstaged"|"staged"
    local mode = resolved == "staged" and "staged" or "unstaged"

    local old_ok, old_lines, old_err
    local new_ok, new_lines, new_err
    local used_source_buffer = false
    if mode == "staged" then
        old_ok, old_lines, old_err = Git.get_head_lines(path)
        new_ok, new_lines, new_err = Git.get_index_lines(path)
    else
        old_ok, old_lines, old_err = Git.get_index_lines(path)
        if current_buf_lines then
            new_ok, new_lines = true, copy_lines(current_buf_lines)
            used_source_buffer = true
        else
            new_ok, new_lines, new_err = Git.get_worktree_lines(path)
        end
    end

    if not old_ok then
        Notify.error(old_err or "Failed to read old file contents")
        return false, nil, nil, nil, false
    end
    if not new_ok then
        Notify.error(new_err or "Failed to read new file contents")
        return false, nil, nil, nil, false
    end
    if same_lines(old_lines or {}, new_lines or {}) then
        return true, nil, nil, nil, used_source_buffer
    end

    return true, mode, old_lines or {}, new_lines or {}, used_source_buffer
end

---@param state delta.diff.file.State
---@return string[]?
---@return integer?
local function current_source_lines(state)
    if not state.source_bufid or not vim.api.nvim_buf_is_valid(state.source_bufid) then
        return nil, nil
    end
    local source_path = select(1, Paths.normalize(vim.api.nvim_buf_get_name(state.source_bufid)))
    if source_path ~= state.path then
        return nil, nil
    end
    return vim.api.nvim_buf_get_lines(state.source_bufid, 0, -1, false), changedtick(state.source_bufid)
end

---@param state delta.diff.file.State
local function refresh_state(state)
    if state.closing or not vim.api.nvim_tabpage_is_valid(state.tab) then
        return
    end
    Git.async(function()
        local source_lines, source_changedtick = current_source_lines(state)
        local ok, resolved, old_lines, new_lines, used_source_buffer =
            load_diff_lines(state.path, state.requested_mode, source_lines)
        if not ok then
            return
        end
        if not resolved then
            M.close(state.tab)
            return
        end
        state.resolved_mode = resolved
        state.used_source_buffer = used_source_buffer
        state.source_changedtick = used_source_buffer and source_changedtick or nil
        set_buffer_lines(state.left_buf, old_lines or {})
        set_buffer_lines(state.right_buf, new_lines or {})
        render_winbars(state)
        refresh_diff_windows(state)
    end)
end

---@param state delta.diff.file.State
---@param delta integer
local function update_context(state, delta)
    state.context = math.max(state.context_base, state.context + delta)
    set_diff_context(state.context)
    render_winbars(state)
    refresh_diff_windows(state)
end

---@param state delta.diff.file.State
---@param close_after boolean
local function toggle_stage_file(state, close_after)
    if state.mutating then
        Notify.info("Another operation is going on on the file")
        return
    end
    if not save_source_buffer_if_visible(state) then
        return
    end

    state.mutating = true
    Git.async(function()
        local ok, err
        if state.resolved_mode == "unstaged" then
            ok, err = Git.stage(state.path)
        else
            ok, err = Git.unstage(state.path)
        end
        state.mutating = false
        if not ok then
            Notify.error(err or "Failed to toggle file stage")
            return
        end
        if close_after then
            M.close(state.tab)
        else
            refresh_state(state)
        end
    end)
end

---@param state delta.diff.file.State
---@param close_after boolean
local function reset_file(state, close_after)
    if state.mutating then
        Notify.info("Another operation is going on on the file")
        return
    end

    state.mutating = true
    Git.async(function()
        local ok_status, status = Git.file_status(state.path)
        if not ok_status or not status then
            state.mutating = false
            return
        end

        local target = nil
        if status:is_untracked() then
            target = "delete"
        elseif state.resolved_mode == "staged" and status:has_staged() then
            target = "head"
        elseif status:has_unstaged() then
            target = "index"
        elseif status:has_staged() then
            target = "head"
        end

        if not target then
            state.mutating = false
            Notify.info("No changes to reset")
            return
        end

        if target == "index" or target == "delete" then
            if not save_source_buffer_if_visible(state) then
                state.mutating = false
                return
            end
        elseif modified_open_buffer(state.path) then
            state.mutating = false
            Notify.error("Reset aborted: file has unsaved changes: " .. state.path)
            return
        end

        if Config.options.reset.confirm then
            local baseline = target == "head" and "HEAD" or target == "index" and "index" or "deletion"
            local choice = vim.fn.confirm("Reset current file to " .. baseline .. "?\n", "&Yes\n&No", 2)
            if choice ~= 1 then
                state.mutating = false
                Notify.info("Reset cancelled")
                return
            end
        end

        local ok, undo_hint, err = Git.reset_file(state.path, target)
        state.mutating = false
        if not ok then
            Notify.error(err or ("Failed to reset file: " .. state.path))
            return
        end
        if state.source_bufid and vim.api.nvim_buf_is_valid(state.source_bufid) then
            pcall(function()
                vim.cmd("checktime " .. state.source_bufid)
            end)
        end
        if undo_hint then
            Notify.info("Reset complete. Undo hint: " .. undo_hint)
        end
        if close_after or target == "delete" then
            M.close(state.tab)
        else
            refresh_state(state)
        end
    end)
end

---@param state delta.diff.file.State
---@param keyspecs delta.KeySpecs|nil
---@param handler fun()
---@param desc string
local function bind_file_keys(state, keyspecs, handler, desc)
    for _, keyspec in ipairs(resolve_keyspecs(keyspecs)) do
        local lhs = Keys.lhs(keyspec)
        local modes = Keys.modes(keyspec, "n")
        for _, bufnr in ipairs({ state.left_buf, state.right_buf }) do
            vim.keymap.set(modes, lhs, handler, { buffer = bufnr, nowait = true, desc = desc })
        end
    end
end

---@param state delta.diff.file.State
local function setup_keymaps(state)
    local keys = (((Config.options.diff or {}).file or {}).keys or {})
    bind_file_keys(state, keys.close, function()
        M.close(state.tab)
    end, "delta.diff.file.close")
    bind_file_keys(state, keys.toggle_stage_file, function()
        toggle_stage_file(state, false)
    end, "delta.diff.file.toggle_stage_file")
    bind_file_keys(state, keys.toggle_stage_file_and_close, function()
        toggle_stage_file(state, true)
    end, "delta.diff.file.toggle_stage_file_and_close")
    bind_file_keys(state, keys.reset_file, function()
        reset_file(state, false)
    end, "delta.diff.file.reset_file")
    bind_file_keys(state, keys.reset_file_and_close, function()
        reset_file(state, true)
    end, "delta.diff.file.reset_file_and_close")
    bind_file_keys(state, keys.expand_context, function()
        update_context(state, state.context_step)
    end, "delta.diff.file.expand_context")
    bind_file_keys(state, keys.shrink_context, function()
        update_context(state, -state.context_step)
    end, "delta.diff.file.shrink_context")
    if state.keymap_hints.mode == "dialog" and state.keymap_hints.key and not state.keymap_hints.collides then
        bind_file_keys(state, state.keymap_hints.key, function()
            open_keymap_dialog(state)
        end, "delta.diff.file.keymaps")
    end
end

---@param state delta.diff.file.State
local function attach(state)
    local group = vim.api.nvim_create_augroup("DeltaDiff:" .. state.tab, { clear = true })
    state.augroup = group

    vim.api.nvim_create_autocmd("TabClosed", {
        group = group,
        callback = function()
            if state.closing or not tabs[state.tab] then
                return
            end
            if not vim.api.nvim_tabpage_is_valid(state.tab) then
                cleanup(state)
            end
        end,
    })
end

---@param path string
---@param requested_mode delta.diff.FileMode
---@param resolved_mode "unstaged"|"staged"
---@param old_lines string[]
---@param new_lines string[]
---@param origin_tab delta.TabId
---@param origin_win delta.WinId
---@param source_bufid? delta.BufId
---@param source_changedtick? integer
---@param used_source_buffer boolean
local function open_tab(
    path,
    requested_mode,
    resolved_mode,
    old_lines,
    new_lines,
    origin_tab,
    origin_win,
    source_bufid,
    source_changedtick,
    used_source_buffer
)
    local file_config = (Config.options.diff or {}).file or {}
    local context_config = file_config.context or {}
    local keys = file_config.keys or {}
    local hint_actions = keymap_hint_actions(keys)
    local keymap_hints = resolve_keymap_hints(file_config, hint_actions)
    local context_base = context_config.base or diff_context()
    local context_step = math.max(1, context_config.step or 5)
    if diffopt_refcount == 0 then
        owned_diffopt = vim.go.diffopt
    end
    diffopt_refcount = diffopt_refcount + 1
    set_diff_context(context_base)

    local old_label = resolved_mode == "staged" and "HEAD" or "index"
    local new_label = resolved_mode == "staged" and "index" or "worktree"
    local left_buf = create_side_buffer(path, old_label, old_lines)
    local right_buf = create_side_buffer(path, new_label, new_lines)

    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win, left_buf)
    setup_window(left_win, left_buf)

    vim.cmd("rightbelow vsplit")
    local right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right_win, right_buf)
    setup_window(right_win, right_buf)

    vim.api.nvim_win_call(left_win, function()
        vim.cmd("diffthis")
    end)
    vim.api.nvim_win_call(right_win, function()
        vim.cmd("diffthis")
    end)
    setup_window(left_win, left_buf)
    setup_window(right_win, right_buf)
    vim.cmd("wincmd =")

    local state = {
        tab = tab,
        origin_tab = origin_tab,
        origin_win = origin_win,
        left_win = left_win,
        right_win = right_win,
        left_buf = left_buf,
        right_buf = right_buf,
        path = path,
        requested_mode = requested_mode,
        resolved_mode = resolved_mode,
        source_bufid = source_bufid,
        source_changedtick = source_changedtick,
        used_source_buffer = used_source_buffer,
        context = context_base,
        context_base = context_base,
        context_step = context_step,
        augroup = 0,
        keymap_hints = keymap_hints,
        hint_actions = hint_actions,
    }
    tabs[tab] = state
    render_winbars(state)
    setup_keymaps(state)
    attach(state)
end

---@param opts? delta.diff.FileOpenOpts
function M.open(opts)
    opts = opts or {}
    local origin_win = opts.winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(origin_win) then
        Notify.info("Invalid window")
        return
    end

    local origin_tab = vim.api.nvim_win_get_tabpage(origin_win)
    local bufid = opts.bufid or vim.api.nvim_win_get_buf(origin_win)
    if not vim.api.nvim_buf_is_valid(bufid) then
        Notify.info("Invalid buffer")
        return
    end

    local bufname = vim.api.nvim_buf_get_name(bufid)
    local normalized, scratch = Paths.normalize(opts.path or bufname)
    if not normalized then
        Notify.info("No file path for current buffer")
        return
    end

    local current_buf_lines = nil
    local source_bufid = nil
    local source_changedtick = nil
    local current_path, current_scratch = Paths.normalize(bufname)
    if current_path == normalized and not current_scratch and not scratch then
        source_bufid = bufid
        current_buf_lines = vim.api.nvim_buf_get_lines(bufid, 0, -1, false)
        source_changedtick = changedtick(bufid)
    end

    local requested = opts.mode or "auto"
    if requested ~= "auto" and requested ~= "unstaged" and requested ~= "staged" then
        Notify.info("Invalid diff mode: " .. tostring(requested))
        return
    end

    Git.async(function()
        local ok, resolved, old_lines, new_lines, used_source_buffer =
            load_diff_lines(normalized, requested, current_buf_lines)
        if not ok then
            return
        end
        if not resolved then
            Notify.info("No changes for current file")
            return
        end

        if vim.api.nvim_win_is_valid(origin_win) then
            open_tab(
                normalized,
                requested,
                resolved,
                old_lines or {},
                new_lines or {},
                origin_tab,
                origin_win,
                source_bufid,
                used_source_buffer and source_changedtick or nil,
                used_source_buffer
            )
        end
    end)
end

return M
