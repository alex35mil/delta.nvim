--- Picker UI for delta.nvim.
--- Manages floating windows, rendering, keymaps, and cursor.

local M = {}

local Config = require("delta.config")
local Git = require("delta.git")
local Highlights = require("delta.picker.highlights")
local Layout = require("delta.picker.layout")
local Notify = require("delta.notify")
local Preview = require("delta.picker.preview")
local Tree = require("delta.picker.tree")
local Spotlight = require("delta.spotlight")
local Paths = require("delta.spotlight.paths")

local hl = Highlights.groups

--- Git status code → { icon, hl } mapping, built from config icons + highlight groups.
local status_map = {
    M = { hl = hl.status_modified, key = "modified" },
    A = { hl = hl.status_added, key = "added" },
    D = { hl = hl.status_deleted, key = "deleted" },
    R = { hl = hl.status_renamed, key = "renamed" },
    ["?"] = { hl = hl.status_untracked, key = "untracked" },
    U = { hl = hl.status_unmerged, key = "unmerged" },
}

---@alias delta.picker.Section "staged"|"unstaged"

local sections = {
    unstaged = { title = "Unstaged" },
    staged = { title = "Staged" },
}

---@class delta.picker.RenderSectionOpts
---@field section delta.picker.Section
---@field files delta.FileEntry[]
---@field query string
---@field nodes (delta.Node|false)[]
---@field lines string[]
---@field highlights { line: number, col: number, end_col: number, hl: string }[]
---@field parent_map table<number, number>
---@field section_lines table<number, boolean>

---@class delta.PickerState
---@field input_buf delta.BufId
---@field input_win delta.WinId
---@field tree_buf delta.BufId
---@field tree_win delta.WinId
---@field nodes (delta.Node|false)[] flat visible list (false for section headers/spacers)
---@field unstaged delta.FileEntry[]
---@field staged delta.FileEntry[]
---@field parent_map table<number, number> flat index → parent flat index
---@field section_lines table<number, boolean>
---@field staged_start number index in nodes where staged section begins (0 if no staged)
---@field cursor_idx number 1-indexed selected line in tree
---@field collapsed table<string, boolean> set of collapsed directory paths
---@field origin_win delta.WinId window that was active when picker opened
---@field sources (delta.SourceConfig|delta.SourceDef)[] ordered list of sources to cycle through
---@field source_keys (string|false)[] source key for each entry (false for inline sources)
---@field source_idx number current index in sources list
---@field preselect_path? string requested file path to preselect
---@field preview_visible? boolean whether preview pane is showing
---@field layout? { row: number, col: number, width: number, height: number } picker layout dimensions

---@type delta.PickerState|nil
local state = nil

--- Get the current source from state.
---@return delta.SourceConfig|delta.SourceDef|nil
local function current_source()
    return state and state.sources[state.source_idx]
end

---@return string|false|nil
local function current_source_key()
    return state and state.source_keys[state.source_idx]
end

---@return string[]
local function collect_unstaged_paths()
    if not state then
        return {}
    end

    local paths = {}
    local index = 0
    for _, file in ipairs(state.unstaged) do
        index = index + 1
        paths[index] = file.path
    end
    return paths
end

---@param path string
---@param section? delta.picker.Section
---@return integer?
local function find_node_index(path, section)
    if not state then
        return
    end

    for i, node in ipairs(state.nodes) do
        if node and not node.is_dir and node.path == path and (not section or node.section == section) then
            return i
        end
    end
end

---@param path string
---@return delta.FileEntry?
local function find_file_entry(path)
    if not state then
        return
    end

    for _, file in ipairs(state.unstaged) do
        if file.path == path then
            return file
        end
    end

    for _, file in ipairs(state.staged) do
        if file.path == path then
            return file
        end
    end
end

---@param paths string[]
---@return string[]
local function find_modified_open_paths(paths)
    local wanted = {}
    for _, path in ipairs(paths) do
        wanted[path] = true
    end

    local modified = {}
    for _, bufid in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufid) and vim.bo[bufid].modified then
            local path = Paths.normalize(vim.api.nvim_buf_get_name(bufid))
            if path and wanted[path] then
                modified[#modified + 1] = path
            end
        end
    end

    table.sort(modified)
    return modified
end

---@param node delta.Node
---@param section delta.picker.Section
---@return { path: string, target: delta.ResetTarget }[]
local function collect_reset_targets(node, section)
    if not state then
        return {}
    end

    local source = section == "staged" and state.staged or state.unstaged
    local targets = {}
    local prefix = node.is_dir and (node.path .. "/") or nil

    for _, file in ipairs(source) do
        if file.path == node.path or (prefix and vim.startswith(file.path, prefix)) then
            local target = section == "staged" and "head" or (file.status:is_untracked() and "delete" or "index")
            targets[#targets + 1] = { path = file.path, target = target }
        end
    end

    table.sort(targets, function(a, b)
        return a.path < b.path
    end)
    return targets
end

---@param section delta.picker.Section
---@param targets { path: string, target: delta.ResetTarget }[]
---@return string
local function reset_confirm_message(section, targets)
    local count = #targets
    local deletes = 0
    for _, item in ipairs(targets) do
        if item.target == "delete" then
            deletes = deletes + 1
        end
    end

    local baseline = section == "staged" and "HEAD" or "index"
    local subject = count == 1 and "this entry" or (count .. " entries")
    local suffix = deletes > 0 and ("\nThis will delete " .. deletes .. " untracked file(s).") or ""
    return "Reset " .. subject .. " to " .. baseline .. "?" .. suffix
end

---@param bufid delta.BufId
---@return string? path
---@return delta.picker.Section? section
local function current_buffer_preselect_target(bufid)
    local bufname = vim.api.nvim_buf_get_name(bufid)
    local path, scratch = Paths.normalize(bufname)

    if not path then
        return nil, nil
    end

    if scratch == "staged" then
        return path, "staged"
    end

    if scratch == "deleted" then
        local ctx = Spotlight.context(bufid)
        if ctx.is_active then
            if ctx.resolved_mode == "staged" then
                return path, "staged"
            end
            if ctx.resolved_mode == "unstaged" then
                return path, "unstaged"
            end
        end

        local file = find_file_entry(path)
        if file then
            if file.status:has_unstaged_deletion() and not file.status:has_staged_deletion() then
                return path, "unstaged"
            end
            if file.status:has_staged_deletion() and not file.status:has_unstaged_deletion() then
                return path, "staged"
            end
        end
    end

    return path, nil
end

--- Resolve a source from ShowOpts: string key → config lookup, table → inline, nil → git.
---@param raw? string|delta.SourceDef
---@return delta.SourceConfig|delta.SourceDef
local function resolve_source(raw)
    if raw == nil or raw == "git" then
        return Config.options.picker.sources.git
    end
    if type(raw) == "string" then
        local source = Config.options.picker.sources[raw]
        if not source then
            Notify.error("Unknown source: " .. raw)
            return Config.options.picker.sources.git
        end
        if not source.files then
            Notify.error("Source '" .. raw .. "' has no files")
            return Config.options.picker.sources.git
        end
        return source
    end
    -- Inline source table.
    if not raw.files then
        Notify.error("Source has no files")
        return Config.options.picker.sources.git
    end
    return raw
end

--- Resolve a title value (static or function).
---@param title delta.WinTitle|fun(...): delta.WinTitle
---@param ... any arguments passed to function titles
---@return delta.WinTitle
local function resolve_title(title, ...)
    if type(title) == "function" then
        return title(...)
    end
    return title
end

local function build_title()
    local source = current_source()
    local label = source and source.label or Config.options.picker.sources.git.label or "Git"
    return resolve_title(Config.options.picker.layout.main.title, label)
end

--- Update the input window title.
local function update_title()
    if state and vim.api.nvim_win_is_valid(state.input_win) then
        vim.api.nvim_win_set_config(state.input_win, { title = build_title(), title_pos = "center" })
    end
end

--- Resolve files from a source's files field.
---@param files string[]|fun(): string[]
---@return table<string, boolean>
local function resolve_files(files)
    if type(files) == "function" then
        files = files()
    end
    local cwd = vim.fn.getcwd() .. "/"
    local set = {}
    for _, f in ipairs(files) do
        -- Normalize absolute paths to relative (git status uses relative paths).
        -- Skip files outside the current working directory.
        if f:sub(1, #cwd) == cwd then
            set[f:sub(#cwd + 1)] = true
        elseif not vim.startswith(f, "/") then
            set[f] = true
        end
    end
    return set
end

--- Fetch files for the current source.
--- Must be called inside Git.async().
---@return boolean ok
local function refresh_files()
    if not state then
        return false
    end

    local ok, result = Git.get_changed_files()
    if not ok then
        return false
    end

    local unstaged = result.unstaged
    local staged = result.staged

    local source = current_source()
    if source and source.files then
        local path_set = resolve_files(source.files)
        unstaged = Git.filter_by_paths(unstaged, path_set)
        staged = Git.filter_by_paths(staged, path_set)
    end

    state.unstaged = unstaged
    state.staged = staged
    return true
end

---@return string
local function get_query()
    if not state then
        return ""
    end
    local raw = vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ""
    local prompt = vim.fn.prompt_getprompt(state.input_buf) or ""
    local text
    if prompt ~= "" and raw:sub(1, #prompt) == prompt then
        text = raw:sub(#prompt + 1)
    else
        text = raw
    end
    return text
end

--- Flatten a tree node into visible node list, lines, and highlights.
---@param node delta.Node
---@param prefix_parts string[]
---@param is_last boolean
---@param result (delta.Node|false)[]
---@param lines string[]
---@param highlights { line: number, col: number, end_col: number, hl: string }[]
---@param parent_map table<number, number>
---@param parent_idx number|nil
local function flatten(node, prefix_parts, is_last, result, lines, highlights, parent_map, parent_idx)
    local icons = Config.options.picker.layout.main.icons
    local line_nr = #lines

    local prefix = table.concat(prefix_parts)

    local connector = ""
    if node.depth > 1 then
        connector = is_last and icons.tree_last or icons.tree_mid
    elseif node.depth == 1 then
        connector = " "
    end

    local icon
    if node.is_dir then
        icon = node.expanded and icons.dir_open or icons.dir_closed
    else
        icon = icons.file
    end

    local status_suffix = ""
    local status_code = nil
    if not node.is_dir and node.status then
        status_code = node.section == "staged" and node.status.index or node.status.worktree
    end
    local status_entry = status_code and status_map[status_code] or nil
    if status_entry and not node.is_dir then
        local status_icons = Config.options.git and Config.options.git.status or {}
        local status_icon = status_icons[status_entry.key] or ""
        status_suffix = "  " .. status_icon
    end

    local line = prefix .. connector .. icon .. node.name .. status_suffix
    table.insert(lines, line)
    table.insert(result, node)

    local my_idx = #result
    if parent_idx then
        parent_map[my_idx] = parent_idx
    end

    -- Highlight tree connectors (prefix + connector) with highest priority.
    local connector_len = #prefix + #connector
    if connector_len > 0 then
        table.insert(highlights, {
            line = line_nr,
            col = 0,
            end_col = connector_len,
            hl = hl.tree_connector,
            priority = 300,
        })
    end

    -- Highlight status icon.
    if status_entry and not node.is_dir then
        local status_start = #line - #status_suffix + 2
        table.insert(highlights, {
            line = line_nr,
            col = status_start,
            end_col = #line,
            hl = status_entry.hl,
        })
    end

    -- Highlight directory names.
    local name_start = #prefix + #connector + #icon
    if node.is_dir and node.depth > 0 then
        table.insert(highlights, {
            line = line_nr,
            col = name_start,
            end_col = name_start + #node.name,
            hl = hl.directory,
        })
    elseif not node.is_dir then
        table.insert(highlights, {
            line = line_nr,
            col = name_start,
            end_col = name_start + #node.name,
            hl = hl.file,
        })
    end

    -- Recurse into children if expanded.
    if node.is_dir and node.expanded then
        local child_prefix = {}
        for _, p in ipairs(prefix_parts) do
            table.insert(child_prefix, p)
        end
        if node.depth > 1 then
            table.insert(child_prefix, is_last and icons.tree_blank or icons.tree_vert)
        elseif node.depth == 1 then
            table.insert(child_prefix, " ")
        end

        for i, child in ipairs(node.children) do
            local child_is_last = i == #node.children
            flatten(child, child_prefix, child_is_last, result, lines, highlights, parent_map, my_idx)
        end
    end
end

--- Render a section (tree of files) into the output arrays.
---@param opts delta.picker.RenderSectionOpts
---@return number count of nodes added
local function render_section(opts)
    if not state then
        return 0
    end

    local filtered = Tree.filter_files(opts.files, opts.query)
    if #filtered == 0 then
        return 0
    end

    -- Spacing before section if not the first.
    if #opts.lines > 0 then
        table.insert(opts.lines, "")
        table.insert(opts.nodes, false)
        opts.section_lines[#opts.lines] = true
    end

    -- Section header.
    local header = " " .. sections[opts.section].title .. " (" .. #filtered .. ")"
    table.insert(opts.lines, header)
    table.insert(opts.nodes, false)
    opts.section_lines[#opts.lines] = true
    table.insert(opts.highlights, {
        line = #opts.lines - 1,
        col = 0,
        end_col = #header,
        hl = hl.section_header,
    })

    local tree = Tree.build(filtered, opts.section)
    Tree.apply_collapsed(tree, state.collapsed)

    local count = 0
    for i, child in ipairs(tree.children) do
        local before = #opts.nodes
        flatten(child, {}, i == #tree.children, opts.nodes, opts.lines, opts.highlights, opts.parent_map, nil)
        count = count + (#opts.nodes - before)
    end

    return count
end

--- Update preview pane to show the file under cursor.
local function update_preview()
    if not state or not state.preview_visible then
        return
    end
    local node = state.nodes[state.cursor_idx]
    if not node or node.is_dir then
        Preview.clear()
        return
    end
    Preview.update(node.path)
end

--- Show the preview pane. Tree width stays the same, total block widens and recenters.
local function show_preview()
    if not state or state.preview_visible then
        return
    end

    local layout = state.layout

    if not layout then
        return
    end

    local preview_cfg = Config.options.picker.layout.preview
    local tree_width = layout.width -- keep original width
    local gap = 2
    local preview_width
    if preview_cfg.width < 1 then
        preview_width = Layout.resolve_size(preview_cfg.width, vim.o.columns)
    else
        preview_width = math.floor(preview_cfg.width)
    end

    local total_width = tree_width + gap + preview_width
    local _, new_col = Layout.centered_box(total_width, layout.height, vim.o.columns, vim.o.lines)

    -- Move input and tree windows to new left position.
    vim.api.nvim_win_set_config(state.input_win, { relative = "editor", row = layout.row, col = new_col })
    vim.api.nvim_win_set_config(state.tree_win, { relative = "editor", row = layout.row + 3, col = new_col })

    -- Create preview window to the right of the tree (full height = input + tree).
    local preview_col = new_col + tree_width + gap
    local preview_row = layout.row
    local preview_height = layout.height

    Preview.show(preview_row, preview_col, preview_width, preview_height)
    state.preview_visible = true
    update_preview()
end

--- Hide the preview pane and recenter the picker.
local function hide_preview()
    if not state or not state.preview_visible then
        return
    end

    Preview.hide()
    state.preview_visible = false

    -- Recenter input and tree to original position.
    local layout = state.layout

    if not layout then
        return
    end

    vim.api.nvim_win_set_config(state.input_win, { relative = "editor", row = layout.row, col = layout.col })
    vim.api.nvim_win_set_config(state.tree_win, { relative = "editor", row = layout.row + 3, col = layout.col })
end

--- Count visible nodes in a tree (expanded dirs + files).
---@param node delta.Node
---@return number
local function count_nodes(node)
    local n = 0
    for _, child in ipairs(node.children) do
        n = n + 1
        if child.is_dir and child.expanded then
            n = n + count_nodes(child)
        end
    end
    return n
end

--- Compute the ideal height based on content and config.
---@return number
local function compute_height()
    if not state then
        return 0
    end

    local layout_height = Config.options.picker.layout.height

    if type(layout_height) ~= "table" then
        return Layout.resolve_size(layout_height, vim.o.lines)
    end

    local min_h = Layout.resolve_size(layout_height[1], vim.o.lines)
    local max_h = Layout.resolve_size(layout_height[2], vim.o.lines)

    local content = 0
    if #state.unstaged > 0 then
        content = content + 1
        content = content + count_nodes(Tree.build(state.unstaged, "unstaged"))
    end
    if #state.staged > 0 then
        content = content + 2
        content = content + count_nodes(Tree.build(state.staged, "staged"))
    end
    -- Overhead: input (2 content) + top border (1) + bottom border (1) = 4
    local ideal = content + 4
    return math.max(min_h, math.min(max_h, ideal))
end

--- Resize the picker windows to match current content height.
local function resize_layout()
    if not state then
        return
    end
    local layout = Config.options.picker.layout
    if type(layout.height) ~= "table" then
        return
    end

    local height = compute_height()
    if height == state.layout.height then
        return
    end

    state.layout.height = height
    local row = Layout.centered_box(state.layout.width, height, vim.o.columns, vim.o.lines)
    state.layout.row = row

    local tree_height = height - 4
    if tree_height < 3 then
        tree_height = 3
    end

    vim.api.nvim_win_set_config(state.input_win, {
        relative = "editor",
        row = row,
        col = state.layout.col,
        height = 2,
    })
    vim.api.nvim_win_set_config(state.tree_win, {
        relative = "editor",
        row = row + 3,
        col = state.layout.col,
        height = tree_height,
    })

    if state.preview_visible then
        -- Re-show preview at new position.
        Preview.hide()
        state.preview_visible = false
        show_preview()
    end
end

--- Update the visual cursor line in the tree window.
local function update_cursor_highlight()
    if not state or #state.nodes == 0 then
        return
    end

    local ns = vim.api.nvim_create_namespace("delta-cursor")
    vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, 0, -1)

    local idx = state.cursor_idx
    if idx >= 1 and idx <= #state.nodes and state.nodes[idx] then
        vim.api.nvim_buf_set_extmark(state.tree_buf, ns, idx - 1, 0, {
            end_row = idx,
            hl_group = hl.cursor_line,
            hl_eol = true,
            priority = 200,
        })
        if vim.api.nvim_win_is_valid(state.tree_win) then
            vim.api.nvim_win_set_cursor(state.tree_win, { idx, 0 })
        end
    end

    update_preview()
end

--- Highlight the active branch path in the tree.
local function highlight_branch()
    if not state or not vim.api.nvim_win_is_valid(state.tree_win) then
        return
    end

    local ns = vim.api.nvim_create_namespace("delta-branch")
    vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, 0, -1)

    local idx = state.cursor_idx

    -- Collect ancestor indices (including self).
    local active = {}
    local cur = idx
    while cur do
        active[cur] = true
        cur = state.parent_map[cur]
    end

    for i = 1, #state.nodes do
        if active[i] and i ~= idx then
            vim.api.nvim_buf_set_extmark(
                state.tree_buf,
                ns,
                i - 1,
                0,
                { end_row = i, hl_group = hl.active_branch, priority = 100 }
            )
        elseif not active[i] and i ~= idx then
            vim.api.nvim_buf_set_extmark(
                state.tree_buf,
                ns,
                i - 1,
                0,
                { end_row = i, hl_group = hl.inactive_branch, priority = 100 }
            )
        end
    end
end

---@param path string
---@param section? delta.picker.Section
local function preselect_path(path, section)
    if not state or path == "" then
        return false
    end

    local idx = find_node_index(path, section)
    if not idx and section then
        idx = find_node_index(path)
    end
    if not idx then
        return false
    end

    state.cursor_idx = idx
    update_cursor_highlight()
    highlight_branch()
    return true
end

--- Render the tree into the buffer.
local function render()
    if not state then
        return
    end

    local query = get_query()

    local nodes = {}
    local lines = {}
    local highlights = {}
    local parent_map = {}
    local section_lines = {}

    local unstaged_count = render_section({
        section = "unstaged",
        files = state.unstaged,
        query = query,
        nodes = nodes,
        lines = lines,
        highlights = highlights,
        parent_map = parent_map,
        section_lines = section_lines,
    })
    local staged_start = #nodes + 1
    local staged_count = render_section({
        section = "staged",
        files = state.staged,
        query = query,
        nodes = nodes,
        lines = lines,
        highlights = highlights,
        parent_map = parent_map,
        section_lines = section_lines,
    })

    if unstaged_count + staged_count == 0 then
        state.nodes = {}
        state.parent_map = {}
        state.section_lines = {}
        state.staged_start = 0
        state.cursor_idx = 0
        Preview.clear()
        vim.bo[state.tree_buf].modifiable = true
        vim.api.nvim_buf_set_lines(state.tree_buf, 0, -1, false, { "  No matches" })
        vim.bo[state.tree_buf].modifiable = false
        local ns = vim.api.nvim_create_namespace("delta")
        vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(state.tree_buf, ns, 0, 0, { end_row = 1, hl_group = hl.empty })
        vim.api.nvim_buf_clear_namespace(state.tree_buf, vim.api.nvim_create_namespace("delta-branch"), 0, -1)
        vim.api.nvim_buf_clear_namespace(state.tree_buf, vim.api.nvim_create_namespace("delta-cursor"), 0, -1)
        return
    end

    state.nodes = nodes
    state.parent_map = parent_map
    state.section_lines = section_lines
    state.staged_start = staged_start

    -- Clamp cursor, skip non-node lines.
    if state.cursor_idx < 1 then
        state.cursor_idx = 1
    end
    if state.cursor_idx > #nodes then
        state.cursor_idx = #nodes
    end
    while state.cursor_idx <= #nodes and not state.nodes[state.cursor_idx] do
        state.cursor_idx = state.cursor_idx + 1
    end
    if state.cursor_idx > #nodes then
        state.cursor_idx = #nodes
    end

    vim.bo[state.tree_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.tree_buf, 0, -1, false, lines)
    vim.bo[state.tree_buf].modifiable = false

    local ns = vim.api.nvim_create_namespace("delta")
    vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, 0, -1)

    for _, h in ipairs(highlights) do
        local mark_opts = { end_col = h.end_col, hl_group = h.hl }
        if h.priority then
            mark_opts.priority = h.priority
        end
        vim.api.nvim_buf_set_extmark(state.tree_buf, ns, h.line, h.col, mark_opts)
    end

    update_cursor_highlight()
    highlight_branch()
end

--- Find the index of the first file (non-directory) node, or first real node.
---@param nodes (delta.Node|false)[]
---@return number
local function first_file_idx(nodes)
    for i, node in ipairs(nodes) do
        if node and not node.is_dir then
            return i
        end
    end
    for i, node in ipairs(nodes) do
        if node then
            return i
        end
    end
    return 1
end

--- Move cursor in tree by delta.
---@param delta number
local function move_cursor(delta)
    if not state or #state.nodes == 0 then
        return
    end

    local new_idx = state.cursor_idx + delta
    local step = delta > 0 and 1 or -1

    -- Skip non-node lines (section headers, spacers).
    while new_idx >= 1 and new_idx <= #state.nodes and not state.nodes[new_idx] do
        new_idx = new_idx + step
    end

    if new_idx < 1 or new_idx > #state.nodes then
        return
    end

    state.cursor_idx = new_idx
    update_cursor_highlight()
    highlight_branch()
end

--- Find the best window to open a file in.
---@param origin_win? delta.WinId Prefer this window as the original picker source.
---@return delta.WinId
local function find_target_win(origin_win)
    local current = vim.api.nvim_get_current_win()
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    local origin = origin_win or (state and state.origin_win or 0)

    local all = vim.api.nvim_tabpage_list_wins(0)
    table.sort(all, function(a, b)
        local ba = vim.api.nvim_win_get_buf(a)
        local bb = vim.api.nvim_win_get_buf(b)
        local la = (vim.fn.getbufinfo(ba)[1] or {}).lastused or 0
        local lb = (vim.fn.getbufinfo(bb)[1] or {}).lastused or 0
        return la > lb
    end)

    local candidates = { origin, current, prev }
    vim.list_extend(candidates, all)

    local non_float = 0
    for _, win in ipairs(candidates) do
        if win ~= 0 and vim.api.nvim_win_is_valid(win) then
            local config = vim.api.nvim_win_get_config(win)
            local is_float = config.relative ~= ""
            if not is_float then
                non_float = win
                local buf = vim.api.nvim_win_get_buf(win)
                if vim.bo[buf].buftype == "" then
                    return win
                end
            end
        end
    end

    if non_float ~= 0 then
        return non_float
    end
    vim.cmd("new")
    return vim.api.nvim_get_current_win()
end

--- Build the action context passed to action handlers.
---@return delta.picker.ActionContext
local function make_context()
    local node = state and state.nodes[state.cursor_idx]
    -- Normalize false (section header placeholder) to nil.
    if not node then
        node = nil
    end

    local origin_win = state and state.origin_win or nil
    local source_key = current_source_key()
    local unstaged_paths = collect_unstaged_paths()

    return {
        node = node,
        move = function(step)
            move_cursor(step)
        end,
        move_to_top = function()
            if not state or #state.nodes == 0 then
                return
            end
            -- Find first real node.
            for i, n in ipairs(state.nodes) do
                if n then
                    state.cursor_idx = i
                    update_cursor_highlight()
                    highlight_branch()
                    return
                end
            end
        end,
        move_to_bottom = function()
            if not state or #state.nodes == 0 then
                return
            end
            -- Find last real node.
            for i = #state.nodes, 1, -1 do
                if state.nodes[i] then
                    state.cursor_idx = i
                    update_cursor_highlight()
                    highlight_branch()
                    return
                end
            end
        end,
        expand = function()
            if not state or #state.nodes == 0 then
                return
            end
            local n = state.nodes[state.cursor_idx]
            if not n or not n.is_dir then
                return
            end
            if state.collapsed[n.path] then
                state.collapsed[n.path] = nil
                render()
            end
        end,
        collapse = function()
            if not state or #state.nodes == 0 then
                return
            end
            local n = state.nodes[state.cursor_idx]
            if not n or not n.is_dir then
                return
            end
            if not state.collapsed[n.path] then
                state.collapsed[n.path] = true
                render()
            end
        end,
        cycle_source = function()
            if not state or #state.sources <= 1 then
                return
            end
            state.source_idx = state.source_idx % #state.sources + 1
            local prompt = vim.fn.prompt_getprompt(state.input_buf) or ""
            vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { prompt })
            Git.async(function()
                if not refresh_files() then
                    return
                end
                state.collapsed = {}
                state.cursor_idx = 1
                resize_layout()
                render()
                update_title()
            end)
        end,
        cycle_source_back = function()
            if not state or #state.sources <= 1 then
                return
            end
            state.source_idx = (state.source_idx - 2) % #state.sources + 1
            local prompt = vim.fn.prompt_getprompt(state.input_buf) or ""
            vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { prompt })
            Git.async(function()
                if not refresh_files() then
                    return
                end
                state.collapsed = {}
                state.cursor_idx = 1
                resize_layout()
                render()
                update_title()
            end)
        end,
        toggle_stage = function(cb)
            if not state or not node then
                return false
            end

            local is_staged = state.staged_start > 0 and state.cursor_idx >= state.staged_start

            local function do_toggle()
                Git.async(function()
                    local ok
                    if is_staged then
                        ok = Git.unstage(node.path)
                    else
                        ok = Git.stage(node.path)
                    end
                    if ok then
                        if not refresh_files() then
                            return
                        end
                        render()
                        if cb then
                            cb()
                        end
                    end
                end)
            end

            if node.is_dir then
                local verb = is_staged and "Unstage" or "Stage"
                local choice = vim.fn.confirm(verb .. " all files in " .. node.path .. "/?", "&Yes\n&No", 2)
                if choice == 1 then
                    do_toggle()
                end
                return
            end

            do_toggle()
        end,
        reset_file = function(cb)
            if not state or not node then
                return false
            end

            local targets = collect_reset_targets(node, node.section)
            if #targets == 0 then
                Notify.info("No changes to reset")
                return false
            end

            local modified = find_modified_open_paths(vim.tbl_map(function(item)
                return item.path
            end, targets))
            if #modified > 0 then
                Notify.error("Reset aborted: file has unsaved changes: " .. modified[1])
                return false
            end

            if Config.options.reset.confirm then
                local choice = vim.fn.confirm(reset_confirm_message(node.section, targets), "&Yes\n&No", 2)
                if choice ~= 1 then
                    Notify.info("Reset cancelled")
                    return false
                end
            end

            Git.async(function()
                local undo_hints = {}
                for _, item in ipairs(targets) do
                    local ok, undo_hint, err = Git.reset_file(item.path, item.target)
                    if not ok then
                        Notify.error(err or ("Failed to reset file: " .. item.path))
                        return
                    end
                    if undo_hint then
                        undo_hints[#undo_hints + 1] = item.path .. ": " .. undo_hint
                    end
                end

                if not refresh_files() then
                    return
                end

                render()

                if #undo_hints > 0 then
                    local msg = "Reset complete. Undo hints:\n" .. table.concat(undo_hints, "\n")
                    Notify.info(msg)
                end

                if cb then
                    cb()
                end
            end)

            return true
        end,
        toggle_preview = function()
            if not state then
                return
            end
            if state.preview_visible then
                hide_preview()
            else
                show_preview()
            end
        end,
        scroll_preview = function(step)
            Preview.scroll(step)
        end,
        open = function(opts)
            if not node or node.is_dir then
                return false
            end

            opts = opts or { cmd = "edit", spotlight = false }
            local winid = find_target_win(origin_win)
            local nav = nil

            for i, path in ipairs(unstaged_paths) do
                if path == node.path then
                    nav = {
                        source_key = source_key,
                        opened_path = node.path,
                        unstaged_paths = unstaged_paths,
                        opened_index = i,
                    }
                    break
                end
            end

            local opened_winid, enable_spotlight = Spotlight.open_picker_entry(winid, node.path, {
                section = node.section,
                status = node.status,
                cmd = opts.cmd,
                spotlight = opts.spotlight,
                nav = nav,
            })

            M.close()
            vim.api.nvim_set_current_win(opened_winid)

            if enable_spotlight then
                Spotlight.ensure()
            end

            return true
        end,
        close = function()
            M.close()
        end,
    }
end

--- Actions

--- Execute an action handler.
---@param handler delta.picker.ActionHandler
local function execute_action(handler)
    if not state then
        return
    end
    handler(make_context())
end

--- Create the floating windows (input + tree) and set up keymaps.
---@return delta.BufId input_buf
---@return delta.WinId input_win
---@return delta.BufId tree_buf
---@return delta.WinId tree_win
---@return { row: number, col: number, width: number, height: number } layout
local function create_float()
    local opts = Config.options.picker
    local layout = opts.layout
    local main = layout.main

    local width = Layout.resolve_size(main.width, vim.o.columns)
    local height = compute_height()
    local row, col = Layout.centered_box(width, height, vim.o.columns, vim.o.lines)

    local border = Layout.resolve_border(main.border)
    -- Split border: input gets top+sides (no bottom), tree gets sides+bottom (no top).
    local input_border, tree_border = Layout.split_stacked_border(border)

    -- Input buffer (1 line, prompt type).
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].bufhidden = "wipe"
    vim.bo[input_buf].buftype = "prompt"
    vim.bo[input_buf].filetype = "delta-input"

    local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = "editor",
        width = width,
        height = 2,
        row = row,
        col = col,
        style = "minimal",
        border = input_border,
        title = build_title(),
        title_pos = "center",
    })

    vim.fn.prompt_setprompt(input_buf, main.icons.prompt)
    vim.wo[input_win].winhighlight = "NormalFloat:"
        .. hl.prompt
        .. ",FloatBorder:"
        .. hl.border
        .. ",FloatTitle:"
        .. hl.title

    -- Tree buffer.
    -- height minus input (1 top border + 2 content) minus tree bottom border (1)
    local tree_height = height - 4
    if tree_height < 3 then
        tree_height = 3
    end

    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].bufhidden = "wipe"
    vim.bo[tree_buf].filetype = "delta-filetree"

    local tree_win = vim.api.nvim_open_win(tree_buf, false, {
        relative = "editor",
        width = width,
        height = tree_height,
        row = row + 3,
        col = col,
        style = "minimal",
        border = tree_border,
    })

    vim.wo[tree_win].cursorline = false
    vim.wo[tree_win].winhighlight = "NormalFloat:" .. hl.dialog .. ",FloatBorder:" .. hl.border

    -- Keymaps: bind all actions + arrow key aliases.
    local map_opts = { buffer = input_buf, nowait = true, silent = true }
    local default_modes = { "n", "i" }

    local Keys = require("delta.keys")

    for _, action in pairs(opts.actions) do
        if action then
            local keyspecs = Keys.resolve(action[1])
            local handler = action[2]
            for _, keyspec in ipairs(keyspecs) do
                local lhs, modes
                if type(keyspec) == "table" then
                    lhs = keyspec[1]
                    modes = keyspec.modes or default_modes
                else
                    lhs = keyspec
                    modes = default_modes
                end
                vim.keymap.set(modes, lhs, function()
                    execute_action(handler)
                end, map_opts)
            end
        end
    end

    -- Arrow key aliases for cursor movement (always bound).
    local Actions = require("delta.picker.actions")
    vim.keymap.set(default_modes, "<Up>", function()
        execute_action(Actions.move(-1))
    end, map_opts)
    vim.keymap.set(default_modes, "<Down>", function()
        execute_action(Actions.move(1))
    end, map_opts)

    -- Re-render on input change.
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = input_buf,
        callback = function()
            if state then
                render()
                if get_query() ~= "" then
                    state.cursor_idx = first_file_idx(state.nodes)
                    update_cursor_highlight()
                    highlight_branch()
                end
            end
        end,
    })

    return input_buf, input_win, tree_buf, tree_win, { row = row, col = col, width = width, height = height }
end

--- Public API

--- Show the picker.
---@param opts? delta.ShowOpts
function M.show(opts)
    if state then
        return
    end

    Highlights.setup()

    local source = resolve_source(opts and opts.source)
    local origin_win = vim.api.nvim_get_current_win()

    -- Build ordered source list: git first, then other config sources, then inline (if any).
    local sources = {}
    local source_keys = {}
    local source_idx = 1

    -- Git always first.
    local git_source = Config.options.picker.sources.git
    table.insert(sources, git_source)
    table.insert(source_keys, "git")

    -- Other config sources in sorted order.
    local keys = vim.tbl_keys(Config.options.picker.sources)
    table.sort(keys)
    for _, key in ipairs(keys) do
        if key ~= "git" then
            table.insert(sources, Config.options.picker.sources[key])
            table.insert(source_keys, key)
        end
    end

    -- If opened with an inline source (not from config), append it.
    local is_inline = true
    for _, s in ipairs(sources) do
        if s == source then
            is_inline = false
            break
        end
    end
    if is_inline and source ~= git_source then
        table.insert(sources, source)
        table.insert(source_keys, false)
    end

    -- Find the index of the requested source.
    for i, s in ipairs(sources) do
        if s == source then
            source_idx = i
            break
        end
    end

    -- Initialize state early so refresh_files can use it.
    state = {
        input_buf = 0,
        input_win = 0,
        tree_buf = 0,
        tree_win = 0,
        origin_win = origin_win,
        nodes = {},
        unstaged = {},
        staged = {},
        parent_map = {},
        section_lines = {},
        staged_start = 0,
        collapsed = {},
        cursor_idx = 1,
        sources = sources,
        source_keys = source_keys,
        source_idx = source_idx,
        preselect_path = opts and opts.preselect_path or nil,
    }

    Git.async(function()
        if not refresh_files() then
            state = nil
            return
        end

        local input_buf, input_win, tree_buf, tree_win, layout = create_float()

        state.input_buf = input_buf
        state.input_win = input_win
        state.tree_buf = tree_buf
        state.tree_win = tree_win
        state.layout = layout
        state.preview_visible = false

        render()

        -- Show preview if enabled by default.
        if Config.options.picker.layout.preview.enabled then
            show_preview()
        end

        -- Preselect requested path first, otherwise current buffer's file if it's in the list.
        local did_preselect = false
        if state.preselect_path then
            did_preselect = preselect_path(state.preselect_path)
        end

        if not did_preselect then
            local current_buf = vim.api.nvim_win_get_buf(origin_win)
            local current_path, current_section = current_buffer_preselect_target(current_buf)
            if current_path then
                preselect_path(current_path, current_section)
            end
        end

        if Config.options.picker.initial_mode == "i" then
            vim.schedule(function()
                vim.cmd("startinsert")
            end)
        end

        -- Close when leaving to a non-picker window.
        vim.api.nvim_create_autocmd("WinLeave", {
            buffer = input_buf,
            callback = function()
                vim.schedule(function()
                    if not state then
                        return
                    end
                    local cur_win = vim.api.nvim_get_current_win()
                    -- Stay open if focus moved to tree or preview window.
                    if cur_win == state.tree_win then
                        return
                    end
                    local preview_win = Preview.get_win()
                    if preview_win and cur_win == preview_win then
                        return
                    end
                    M.close()
                end)
            end,
        })

        -- Sync selection when cursor moves in tree window (e.g. via flash).
        vim.api.nvim_create_autocmd("CursorMoved", {
            buffer = tree_buf,
            callback = function()
                if not state then
                    return
                end
                local cursor = vim.api.nvim_win_get_cursor(state.tree_win)
                local idx = cursor[1]
                if idx >= 1 and idx <= #state.nodes and state.nodes[idx] and idx ~= state.cursor_idx then
                    state.cursor_idx = idx
                    update_cursor_highlight()
                    highlight_branch()
                end
                -- Return focus to input.
                vim.schedule(function()
                    if state and vim.api.nvim_win_is_valid(state.input_win) then
                        vim.api.nvim_set_current_win(state.input_win)
                    end
                end)
            end,
        })
    end)
end

--- Close the picker.
function M.close()
    if state then
        local s = state
        state = nil
        Preview.hide()
        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(s.tree_win) then
            vim.api.nvim_win_close(s.tree_win, true)
        end
        if vim.api.nvim_win_is_valid(s.input_win) then
            vim.api.nvim_win_close(s.input_win, true)
        end
    end
end

--- Toggle the picker.
---@param opts? delta.ShowOpts
function M.toggle(opts)
    if state then
        M.close()
    else
        M.show(opts)
    end
end

--- Check if the picker is currently open.
---@return boolean
function M.is_open()
    return state ~= nil
end

return M
