local M = {}

local Git = require("delta.git")
local Config = require("delta.config")
local Notify = require("delta.notify")
local Paths = require("delta.spotlight.paths")
local Keys = require("delta.spotlight.keys")
local Highlights = require("delta.spotlight.highlights")

local ns = vim.api.nvim_create_namespace("delta.spotlight.diff")

---@class delta.spotlight.diff.Keymaps
---@field scroll_up? delta.KeySpec|delta.KeySpec[]
---@field scroll_down? delta.KeySpec|delta.KeySpec[]
---@field focus_left? delta.KeySpec|delta.KeySpec[]
---@field focus_right? delta.KeySpec|delta.KeySpec[]
---@field close? delta.KeySpec|delta.KeySpec[]

---@class delta.spotlight.diff.LayoutOpts
---@field mode delta.spotlight.DiffMode
---@field border string
---@field max_width integer
---@field max_height integer
---@field zindex integer
---@field focusable boolean
---@field follow_scroll boolean
---@field min_side_by_side_width integer
---@field scroll_step integer

---@class delta.spotlight.diff.IntralineRange
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@class delta.spotlight.diff.SideContent
---@field width integer
---@field lines string[]
---@field prefixes string[]
---@field line_hls string[]
---@field intraline_hls (delta.spotlight.diff.IntralineRange[]?)[]

---@class delta.spotlight.diff.Content
---@field title string
---@field format "inline"|"side-by-side"
---@field path? string
---@field height integer
---@field width integer
---@field lines string[]
---@field prefixes string[]
---@field line_hls string[]
---@field intraline_hls (delta.spotlight.diff.IntralineRange[]?)[]
---@field left? delta.spotlight.diff.SideContent
---@field right? delta.spotlight.diff.SideContent

---@class delta.spotlight.diff.State
---@field winid delta.WinId
---@field bufnr delta.BufId
---@field parent_winid delta.WinId
---@field parent_bufnr delta.BufId
---@field side_winid? delta.WinId
---@field side_bufnr? delta.BufId
---@field augroup integer
---@field anchor { line: integer, col: integer }
---@field side? delta.HunkSide
---@field layout delta.spotlight.diff.LayoutOpts
---@field content delta.spotlight.diff.Content
---@field hunk delta.Hunk
---@field keymaps? delta.spotlight.diff.Keymaps

---@class delta.spotlight.diff.OpenHunkOpts
---@field winid? delta.WinId
---@field bufid? delta.BufId
---@field hunk delta.Hunk
---@field hunks? delta.Hunk[]
---@field side? delta.HunkSide
---@field path? string
---@field title? string
---@field anchor? { line: integer, col?: integer }
---@field border? string
---@field max_width? integer
---@field max_height? integer
---@field zindex? integer
---@field focusable? boolean
---@field follow_scroll? boolean
---@field mode? delta.spotlight.DiffMode
---@field min_side_by_side_width? integer
---@field scroll_step? integer
---@field keymaps? delta.spotlight.diff.Keymaps

---@class delta.spotlight.diff.OpenOpts
---@field winid? delta.WinId
---@field bufid? delta.BufId
---@field hunk? delta.Hunk
---@field hunks? delta.Hunk[]
---@field side? delta.HunkSide
---@field path? string
---@field title? string
---@field border? string
---@field max_width? integer
---@field max_height? integer
---@field zindex? integer
---@field focusable? boolean
---@field follow_scroll? boolean
---@field mode? delta.spotlight.DiffMode
---@field min_side_by_side_width? integer
---@field scroll_step? integer
---@field keymaps? delta.spotlight.diff.Keymaps

---@type table<delta.WinId, delta.spotlight.diff.State>
local popups = {}

local hl_groups = {
    popup = Highlights.groups.popup,
    border = Highlights.groups.popup_border,
    title = Highlights.groups.popup_title,
    added = Highlights.groups.popup_added,
    removed = Highlights.groups.popup_removed,
    added_text = Highlights.groups.popup_added_text,
    removed_text = Highlights.groups.popup_removed_text,
    neutral = Highlights.groups.popup_neutral,
    line_nr = Highlights.groups.popup_line_nr,
}

---@return integer
local function default_max_width()
    return math.max(40, math.floor(vim.o.columns * 0.9))
end

---@return integer
local function default_max_height()
    return math.max(6, math.floor((vim.o.lines - vim.o.cmdheight) * 0.6))
end

---@param line string
---@return integer
local function display_width(line)
    return vim.fn.strdisplaywidth(line)
end

---@param winid delta.WinId
---@return delta.WinId?, delta.spotlight.diff.State?
local function resolve_popup(winid)
    if popups[winid] then
        return winid, popups[winid]
    end

    for parent_winid, state in pairs(popups) do
        if state.winid == winid or state.side_winid == winid then
            return parent_winid, state
        end
    end

    return nil, nil
end

---@param keyspecs delta.KeySpec|delta.KeySpec[]|nil
---@return delta.KeySpec[]
local function resolve_keyspecs(keyspecs)
    if not keyspecs then
        return {}
    end
    return require("delta.keys").resolve(keyspecs)
end

---@return delta.KeySpec[]
local function resolve_open_keyspecs()
    local entry = Config.options.spotlight.actions.open_diff
    if not entry then
        return {}
    end
    return resolve_keyspecs(entry[1])
end

---@param keymaps? delta.spotlight.diff.Keymaps
---@return delta.spotlight.diff.Keymaps
local function resolve_popup_keymaps(keymaps)
    local diff_keys = (Config.options.spotlight.diff or {}).keys or {}
    return {
        close = keymaps and keymaps.close or diff_keys.close,
        scroll_up = keymaps and keymaps.scroll_up or diff_keys.scroll_up,
        scroll_down = keymaps and keymaps.scroll_down or diff_keys.scroll_down,
        focus_left = keymaps and keymaps.focus_left or diff_keys.focus_left,
        focus_right = keymaps and keymaps.focus_right or diff_keys.focus_right,
    }
end

---@param path string?
local function set_code_filetype(bufnr, path)
    local ft = path and vim.filetype.match({ filename = path }) or nil
    vim.bo[bufnr].filetype = ft or "text"
end

---@param title string
---@return integer
local function title_min_width(title)
    return display_width(title) + 20
end

---@param hunk delta.Hunk
---@param visible_side? delta.HunkSide
---@return integer, integer
local function resolve_display_starts(hunk, visible_side)
    local removed_start = hunk.removed.start
    local added_start = hunk.added.start

    if visible_side == "added" then
        if hunk.removed.count > 0 then
            removed_start = added_start
        end
    elseif visible_side == "removed" then
        if hunk.added.count > 0 then
            added_start = removed_start
        end
    end

    return removed_start, added_start
end

---@param text string
---@return integer
local function char_count(text)
    return vim.fn.strchars(text)
end

---@param text string
---@param char_idx integer
---@return string
local function char_at(text, char_idx)
    return vim.fn.strcharpart(text, char_idx, 1)
end

---@param text string
---@param char_idx integer
---@return integer
local function byte_col(text, char_idx)
    return vim.str_byteindex(text, char_idx)
end

---@param left string
---@param right string
---@return integer
local function common_prefix_len(left, right)
    local left_chars = char_count(left)
    local right_chars = char_count(right)
    local prefix = 0
    local shared = math.min(left_chars, right_chars)

    while prefix < shared and char_at(left, prefix) == char_at(right, prefix) do
        prefix = prefix + 1
    end

    return prefix
end

---@param left string
---@param right string
---@param prefix integer
---@return integer
local function common_suffix_len(left, right, prefix)
    local left_chars = char_count(left)
    local right_chars = char_count(right)
    local left_suffix = left_chars
    local right_suffix = right_chars

    while left_suffix > prefix and right_suffix > prefix do
        if char_at(left, left_suffix - 1) ~= char_at(right, right_suffix - 1) then
            break
        end
        left_suffix = left_suffix - 1
        right_suffix = right_suffix - 1
    end

    return left_chars - left_suffix
end

---@param left string
---@param right string
---@return integer
local function longest_common_substring_len(left, right)
    local left_chars = char_count(left)
    local right_chars = char_count(right)
    if left_chars == 0 or right_chars == 0 then
        return 0
    end

    local prev, best = {}, 0
    for i = 1, left_chars do
        local cur = {}
        local left_char = char_at(left, i - 1)
        for j = 1, right_chars do
            if left_char == char_at(right, j - 1) then
                cur[j] = (prev[j - 1] or 0) + 1
                best = math.max(best, cur[j])
            else
                cur[j] = 0
            end
        end
        prev = cur
    end

    return best
end

---@param removed_line string
---@param added_line string
---@return number
local function line_similarity(removed_line, added_line)
    if removed_line == added_line then
        return 1e6
    end

    local prefix = common_prefix_len(removed_line, added_line)
    local suffix = common_suffix_len(removed_line, added_line, prefix)
    local substring = longest_common_substring_len(removed_line, added_line)
    local removed_chars = char_count(removed_line)
    local added_chars = char_count(added_line)
    local removed_trim = vim.trim(removed_line)
    local added_trim = vim.trim(added_line)
    local contains_bonus = 0

    if removed_trim ~= "" and added_trim ~= "" then
        if added_trim:find(removed_trim, 1, true) or removed_trim:find(added_trim, 1, true) then
            contains_bonus = math.min(char_count(removed_trim), char_count(added_trim)) * 4
        end
    end

    return prefix * 3 + suffix * 3 + substring * 2 + contains_bonus - math.floor(math.abs(removed_chars - added_chars) / 2)
end

---@param removed_lines string[]
---@param added_lines string[]
---@return { removed_idx: integer, added_idx: integer }[]
local function match_changed_lines(removed_lines, added_lines)
    local m = #removed_lines
    local n = #added_lines
    if m == 0 or n == 0 then
        return {}
    end

    local scores = {}
    for i = 1, m do
        scores[i] = {}
        for j = 1, n do
            scores[i][j] = line_similarity(removed_lines[i], added_lines[j])
        end
    end

    local dp, choice = {}, {}
    for i = 0, m do
        dp[i] = {}
        choice[i] = {}
        for j = 0, n do
            dp[i][j] = 0
        end
    end

    for i = 1, m do
        for j = 1, n do
            local best = dp[i - 1][j]
            local best_choice = "up"
            if dp[i][j - 1] > best then
                best = dp[i][j - 1]
                best_choice = "left"
            end
            local pair_score = scores[i][j]
            if pair_score > 0 and dp[i - 1][j - 1] + pair_score > best then
                best = dp[i - 1][j - 1] + pair_score
                best_choice = "diag"
            end
            dp[i][j] = best
            choice[i][j] = best_choice
        end
    end

    local pairs = {}
    local i, j = m, n
    while i > 0 and j > 0 do
        local step = choice[i][j]
        if step == "diag" then
            pairs[#pairs + 1] = { removed_idx = i, added_idx = j }
            i = i - 1
            j = j - 1
        elseif step == "left" then
            j = j - 1
        else
            i = i - 1
        end
    end

    table.sort(pairs, function(a, b)
        return a.removed_idx < b.removed_idx
    end)
    return pairs
end

---@param removed_line string
---@param added_line string
---@return delta.spotlight.diff.IntralineRange[]?, delta.spotlight.diff.IntralineRange[]?
local function intraline_ranges(removed_line, added_line)
    if removed_line == added_line then
        return nil, nil
    end

    local removed_chars = char_count(removed_line)
    local added_chars = char_count(added_line)
    local prefix = common_prefix_len(removed_line, added_line)
    local suffix = common_suffix_len(removed_line, added_line, prefix)
    local removed_suffix = removed_chars - suffix
    local added_suffix = added_chars - suffix

    local removed_ranges = nil
    if removed_suffix > prefix then
        removed_ranges = {
            {
                start_col = byte_col(removed_line, prefix),
                end_col = byte_col(removed_line, removed_suffix),
                hl_group = hl_groups.removed_text,
            },
        }
    end

    local added_ranges = nil
    if added_suffix > prefix then
        added_ranges = {
            {
                start_col = byte_col(added_line, prefix),
                end_col = byte_col(added_line, added_suffix),
                hl_group = hl_groups.added_text,
            },
        }
    end

    return removed_ranges, added_ranges
end

---@param title string
---@param lines string[]
---@param prefixes string[]
---@param line_hls string[]
---@param intraline_hls (delta.spotlight.diff.IntralineRange[]?)[]
---@return delta.spotlight.diff.Content
local function make_inline_content(title, lines, prefixes, line_hls, intraline_hls)
    local width = title_min_width(title)
    for i, line in ipairs(lines) do
        width = math.max(width, display_width((prefixes[i] or "") .. line))
    end
    return {
        title = title,
        format = "inline",
        lines = lines,
        prefixes = prefixes,
        line_hls = line_hls,
        intraline_hls = intraline_hls,
        width = width,
        height = math.max(#lines, 1),
    }
end

---@param hunk delta.Hunk
---@param title string
---@param visible_side? delta.HunkSide
---@return delta.spotlight.diff.Content
local function build_inline_content(hunk, title, visible_side)
    local lines, prefixes, line_hls, intraline_hls = {}, {}, {}, {}
    local removed_line_idxs, added_line_idxs = {}, {}
    local old_ln, new_ln = resolve_display_starts(hunk, visible_side)

    for _, line in ipairs(hunk.removed.lines) do
        lines[#lines + 1] = line
        prefixes[#prefixes + 1] = string.format("%4d - ", old_ln)
        line_hls[#line_hls + 1] = hl_groups.removed
        intraline_hls[#intraline_hls + 1] = nil
        removed_line_idxs[#removed_line_idxs + 1] = #lines
        old_ln = old_ln + 1
    end

    if hunk.removed.no_nl_at_eof then
        lines[#lines + 1] = "\\ No newline at end of file"
        prefixes[#prefixes + 1] = ""
        line_hls[#line_hls + 1] = hl_groups.removed
        intraline_hls[#intraline_hls + 1] = nil
    end

    for _, line in ipairs(hunk.added.lines) do
        lines[#lines + 1] = line
        prefixes[#prefixes + 1] = string.format("%4d + ", new_ln)
        line_hls[#line_hls + 1] = hl_groups.added
        intraline_hls[#intraline_hls + 1] = nil
        added_line_idxs[#added_line_idxs + 1] = #lines
        new_ln = new_ln + 1
    end

    if hunk.added.no_nl_at_eof then
        lines[#lines + 1] = "\\ No newline at end of file"
        prefixes[#prefixes + 1] = ""
        line_hls[#line_hls + 1] = hl_groups.added
        intraline_hls[#intraline_hls + 1] = nil
    end

    for _, pair in ipairs(match_changed_lines(hunk.removed.lines, hunk.added.lines)) do
        local removed_ranges, added_ranges = intraline_ranges(
            hunk.removed.lines[pair.removed_idx],
            hunk.added.lines[pair.added_idx]
        )
        intraline_hls[removed_line_idxs[pair.removed_idx]] = removed_ranges
        intraline_hls[added_line_idxs[pair.added_idx]] = added_ranges
    end

    if #lines == 0 then
        lines[1] = "(empty hunk)"
        prefixes[1] = ""
        line_hls[1] = hl_groups.neutral
        intraline_hls[1] = nil
    end

    return make_inline_content(title, lines, prefixes, line_hls, intraline_hls)
end

---@param title string
---@param left? delta.spotlight.diff.SideContent
---@param right? delta.spotlight.diff.SideContent
---@return delta.spotlight.diff.Content
local function make_side_content(title, left, right)
    local width = 1
    local height = 1

    if left and right then
        local pane_width = math.max(left.width, right.width, title_min_width(title .. " [-]"), title_min_width("[+]"))
        left.width = pane_width
        right.width = pane_width
        width = pane_width * 2 + 3
        height = math.max(#left.lines, #right.lines, 1)
    elseif left then
        left.width = math.max(left.width, title_min_width(title .. " [-]"))
        width = left.width
        height = math.max(#left.lines, 1)
    elseif right then
        right.width = math.max(right.width, title_min_width(title .. " [+]"))
        width = right.width
        height = math.max(#right.lines, 1)
    end

    return {
        title = title,
        format = "side-by-side",
        lines = {},
        prefixes = {},
        line_hls = {},
        intraline_hls = {},
        left = left,
        right = right,
        width = width,
        height = height,
    }
end

---@param hunk delta.Hunk
---@param title string
---@param visible_side? delta.HunkSide
---@return delta.spotlight.diff.Content
local function build_side_by_side_content(hunk, title, visible_side)
    local left_lines, left_prefixes, left_hls, left_intraline_hls = {}, {}, {}, {}
    local right_lines, right_prefixes, right_hls, right_intraline_hls = {}, {}, {}, {}
    local left_width, right_width = 1, 1
    local removed_start, added_start = resolve_display_starts(hunk, visible_side)

    for i, line in ipairs(hunk.removed.lines) do
        left_lines[#left_lines + 1] = line
        left_prefixes[#left_prefixes + 1] = string.format("%4d - ", removed_start + i - 1)
        left_hls[#left_hls + 1] = hl_groups.removed
        left_intraline_hls[#left_intraline_hls + 1] = nil
        left_width = math.max(left_width, display_width(left_prefixes[#left_prefixes] .. line))
    end
    if hunk.removed.no_nl_at_eof then
        left_lines[#left_lines + 1] = "\\ No newline at end of file"
        left_prefixes[#left_prefixes + 1] = ""
        left_hls[#left_hls + 1] = hl_groups.removed
        left_intraline_hls[#left_intraline_hls + 1] = nil
        left_width = math.max(left_width, display_width(left_lines[#left_lines]))
    end

    for i, line in ipairs(hunk.added.lines) do
        right_lines[#right_lines + 1] = line
        right_prefixes[#right_prefixes + 1] = string.format("%4d + ", added_start + i - 1)
        right_hls[#right_hls + 1] = hl_groups.added
        right_intraline_hls[#right_intraline_hls + 1] = nil
        right_width = math.max(right_width, display_width(right_prefixes[#right_prefixes] .. line))
    end
    if hunk.added.no_nl_at_eof then
        right_lines[#right_lines + 1] = "\\ No newline at end of file"
        right_prefixes[#right_prefixes + 1] = ""
        right_hls[#right_hls + 1] = hl_groups.added
        right_intraline_hls[#right_intraline_hls + 1] = nil
        right_width = math.max(right_width, display_width(right_lines[#right_lines]))
    end

    for _, pair in ipairs(match_changed_lines(hunk.removed.lines, hunk.added.lines)) do
        local removed_ranges, added_ranges = intraline_ranges(
            hunk.removed.lines[pair.removed_idx],
            hunk.added.lines[pair.added_idx]
        )
        left_intraline_hls[pair.removed_idx] = removed_ranges
        right_intraline_hls[pair.added_idx] = added_ranges
    end

    return make_side_content(title, #left_lines > 0 and {
        lines = left_lines,
        prefixes = left_prefixes,
        line_hls = left_hls,
        intraline_hls = left_intraline_hls,
        width = left_width,
    } or nil, #right_lines > 0 and {
        lines = right_lines,
        prefixes = right_prefixes,
        line_hls = right_hls,
        intraline_hls = right_intraline_hls,
        width = right_width,
    } or nil)
end

---@param hunk delta.Hunk
---@param layout delta.spotlight.diff.LayoutOpts
---@param title string
---@param visible_side? delta.HunkSide
---@return delta.spotlight.diff.Content
local function build_content(hunk, layout, title, visible_side)
    local inline = build_inline_content(hunk, title, visible_side)
    local side = build_side_by_side_content(hunk, title, visible_side)
    if layout.mode == "inline" then
        return inline
    end
    if layout.mode == "side-by-side" then
        return side
    end
    local can_side = vim.o.columns >= layout.min_side_by_side_width and side.width <= layout.max_width
    return can_side and side or inline
end

---@param parent_winid delta.WinId
---@param anchor { line: integer, col: integer }
---@param width integer
---@param height integer
---@param opts delta.spotlight.diff.LayoutOpts
---@param title string
---@return vim.api.keyset.win_config?
local function resolve_single_layout(parent_winid, anchor, width, height, opts, title)
    local pos = vim.fn.screenpos(parent_winid, anchor.line, math.max(anchor.col + 1, 1))
    if not pos or pos.row <= 0 or pos.col <= 0 then
        return nil
    end

    local editor_height = vim.o.lines - vim.o.cmdheight
    local editor_width = vim.o.columns
    width = math.max(1, math.min(width, opts.max_width, math.max(editor_width - 4, 1)))

    local space_above = pos.row - 1
    local space_below = editor_height - pos.row
    local inner_above = math.max(space_above - 2, 1)
    local inner_below = math.max(space_below - 2, 1)
    local place_below = inner_below >= inner_above
    local height_cap = place_below and inner_below or inner_above
    height = math.max(1, math.min(height, opts.max_height, height_cap))

    local total_width = width + 2
    local total_height = height + 2
    local row = place_below and pos.row or (pos.row - total_height - 1)
    if place_below and row + total_height > editor_height then
        row = math.max(editor_height - total_height, 0)
    end
    if not place_below and row < 0 then
        row = 0
    end

    local col = pos.col - 1
    if col + total_width > editor_width then
        col = math.max(editor_width - total_width, 0)
    end

    return {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = opts.border,
        focusable = opts.focusable,
        zindex = opts.zindex,
        title = title ~= "" and (" " .. title .. " ") or nil,
        title_pos = "left",
        noautocmd = true,
    }
end

---@param parent_winid delta.WinId
---@param anchor { line: integer, col: integer }
---@param content delta.spotlight.diff.Content
---@param opts delta.spotlight.diff.LayoutOpts
---@return vim.api.keyset.win_config?, vim.api.keyset.win_config?
local function resolve_layouts(parent_winid, anchor, content, opts)
    if content.format == "inline" then
        return resolve_single_layout(parent_winid, anchor, content.width, content.height, opts, content.title), nil
    end

    if content.left and not content.right then
        return resolve_single_layout(
            parent_winid,
            anchor,
            content.left.width,
            content.height,
            opts,
            content.title .. " [-]"
        ),
            nil
    end

    if content.right and not content.left then
        return resolve_single_layout(
            parent_winid,
            anchor,
            content.right.width,
            content.height,
            opts,
            content.title .. " [+]"
        ),
            nil
    end

    local pane_cap = math.max(1, math.floor((opts.max_width - 3) / 2))
    local pane_width = math.max(1, math.min(math.max(content.left.width, content.right.width), pane_cap))
    local total_width = pane_width * 2 + 3
    local base = resolve_single_layout(parent_winid, anchor, total_width, content.height, opts, content.title)
    if not base then
        return nil, nil
    end

    local left = vim.deepcopy(base)
    left.width = pane_width
    left.title = " " .. content.title .. " [-] "

    local right = vim.deepcopy(base)
    right.col = base.col + pane_width + 3
    right.width = pane_width
    right.title = " [+] "

    return left, right
end

---@param bufnr delta.BufId
---@param lines string[]
---@param prefixes string[]
---@param line_hls string[]
---@param intraline_hls (delta.spotlight.diff.IntralineRange[]?)[]?
local function render_buffer(bufnr, lines, prefixes, line_hls, intraline_hls, target_width)
    local padded_lines = {}
    local max_width = target_width or 1

    for i, line in ipairs(lines) do
        local prefix = prefixes[i] or ""
        max_width = math.max(max_width, display_width(prefix .. line))
    end

    for i, line in ipairs(lines) do
        local prefix = prefixes[i] or ""
        local text_width = display_width(prefix .. line)
        local pad = math.max(max_width - text_width, 0)
        padded_lines[i] = line .. string.rep(" ", pad)
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, padded_lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    for i, line in ipairs(lines) do
        local padded_line = padded_lines[i]
        local hl = line_hls[i] or hl_groups.neutral
        local prefix = prefixes[i] or ""
        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
            end_row = i - 1,
            end_col = #padded_line,
            hl_group = hl,
            priority = 4000,
        })
        if prefix ~= "" then
            vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
                virt_text = { { prefix, hl_groups.line_nr } },
                virt_text_pos = "inline",
                priority = 300,
            })
        end
        for _, range in ipairs(intraline_hls and intraline_hls[i] or {}) do
            vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, range.start_col, {
                end_col = range.end_col,
                hl_group = range.hl_group,
                priority = 5000,
            })
        end
        if line == "" and prefix == "" then
            vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
                virt_text = { { " ", hl_groups.neutral } },
                virt_text_pos = "inline",
            })
        end
    end

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
end

---@param winid delta.WinId
local function setup_window(winid)
    vim.wo[winid].wrap = false
    vim.wo[winid].cursorline = false
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].spell = false
    vim.wo[winid].winhl = "NormalFloat:"
        .. hl_groups.popup
        .. ",FloatBorder:"
        .. hl_groups.border
        .. ",FloatTitle:"
        .. hl_groups.title
end

---@param state delta.spotlight.diff.State
local function render(state)
    if state.content.format == "inline" then
        render_buffer(
            state.bufnr,
            state.content.lines,
            state.content.prefixes,
            state.content.line_hls,
            state.content.intraline_hls,
            state.content.width
        )
        set_code_filetype(state.bufnr, state.content.path)
        return
    end

    if state.content.left and state.content.right and state.side_bufnr then
        render_buffer(
            state.bufnr,
            state.content.left.lines,
            state.content.left.prefixes,
            state.content.left.line_hls,
            state.content.left.intraline_hls,
            state.content.left.width
        )
        render_buffer(
            state.side_bufnr,
            state.content.right.lines,
            state.content.right.prefixes,
            state.content.right.line_hls,
            state.content.right.intraline_hls,
            state.content.right.width
        )
        set_code_filetype(state.bufnr, state.content.path)
        set_code_filetype(state.side_bufnr, state.content.path)
        return
    end

    local pane = state.content.left or state.content.right
    if not pane then
        return
    end
    render_buffer(state.bufnr, pane.lines, pane.prefixes, pane.line_hls, pane.intraline_hls, pane.width)
    set_code_filetype(state.bufnr, state.content.path)
end

---@param state delta.spotlight.diff.State
local function clear_keymaps(state)
    local open_keys = resolve_open_keyspecs()
    local popup_keys = resolve_popup_keymaps(state.keymaps)

    for _, keyspec in ipairs(open_keys) do
        Keys.unbind(state.parent_bufnr, keyspec, "nv")
    end
    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.close)) do
        Keys.unbind(state.parent_bufnr, keyspec, "nv")
        Keys.unbind(state.bufnr, keyspec, "nv")
        if state.side_bufnr then
            Keys.unbind(state.side_bufnr, keyspec, "nv")
        end
    end
    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.scroll_up)) do
        Keys.unbind(state.parent_bufnr, keyspec, "nv")
        Keys.unbind(state.bufnr, keyspec, "nv")
        if state.side_bufnr then
            Keys.unbind(state.side_bufnr, keyspec, "nv")
        end
    end
    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.scroll_down)) do
        Keys.unbind(state.parent_bufnr, keyspec, "nv")
        Keys.unbind(state.bufnr, keyspec, "nv")
        if state.side_bufnr then
            Keys.unbind(state.side_bufnr, keyspec, "nv")
        end
    end
    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.focus_left)) do
        Keys.unbind(state.bufnr, keyspec, "nv")
        if state.side_bufnr then
            Keys.unbind(state.side_bufnr, keyspec, "nv")
        end
    end
    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.focus_right)) do
        Keys.unbind(state.bufnr, keyspec, "nv")
        if state.side_bufnr then
            Keys.unbind(state.side_bufnr, keyspec, "nv")
        end
    end
end

---@param parent_winid delta.WinId
local function clear(parent_winid)
    local state = popups[parent_winid]
    if not state then
        return
    end

    popups[parent_winid] = nil
    clear_keymaps(state)

    if state.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    end
    if state.side_winid and vim.api.nvim_win_is_valid(state.side_winid) then
        pcall(vim.api.nvim_win_close, state.side_winid, true)
    end
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        pcall(vim.api.nvim_win_close, state.winid, true)
    end
    if state.side_bufnr and vim.api.nvim_buf_is_valid(state.side_bufnr) then
        pcall(vim.api.nvim_buf_delete, state.side_bufnr, { force = true })
    end
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
        pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
    end
end

---@param parent_winid delta.WinId
local function refresh_layout(parent_winid)
    local state = popups[parent_winid]
    if not state then
        return
    end
    if not vim.api.nvim_win_is_valid(parent_winid) or not vim.api.nvim_win_is_valid(state.winid) then
        clear(parent_winid)
        return
    end
    if state.side_winid and not vim.api.nvim_win_is_valid(state.side_winid) then
        clear(parent_winid)
        return
    end

    local rebuilt = build_content(state.hunk, state.layout, state.content.title, state.side)
    rebuilt.path = state.content.path
    state.content = rebuilt

    local config, side_config = resolve_layouts(parent_winid, state.anchor, state.content, state.layout)
    if not config then
        clear(parent_winid)
        return
    end

    config.noautocmd = nil
    vim.api.nvim_win_set_config(state.winid, config)
    if state.side_winid and side_config then
        side_config.noautocmd = nil
        vim.api.nvim_win_set_config(state.side_winid, side_config)
    end
    render(state)
end

function M.focus(winid)
    local _, state = resolve_popup(winid or vim.api.nvim_get_current_win())
    if not state or not vim.api.nvim_win_is_valid(state.winid) then
        return false
    end
    vim.api.nvim_set_current_win(state.winid)
    return true
end

---@param side "left"|"right"
---@param winid? delta.WinId
---@return boolean
function M.focus_side(side, winid)
    local _, state = resolve_popup(winid or vim.api.nvim_get_current_win())
    if not state then
        return false
    end

    local target = side == "right" and state.side_winid or state.winid
    if not target or not vim.api.nvim_win_is_valid(target) then
        return false
    end

    vim.api.nvim_set_current_win(target)
    return true
end

---@param direction "up"|"down"
---@param winid? delta.WinId
---@return boolean
function M.scroll(direction, winid)
    local _, state = resolve_popup(winid or vim.api.nvim_get_current_win())
    if not state or not vim.api.nvim_win_is_valid(state.winid) then
        return false
    end

    local step = state.layout.scroll_step
    local delta = direction == "up" and -step or direction == "down" and step or nil
    if not delta then
        return false
    end

    local function scroll_win(target)
        if not target or not vim.api.nvim_win_is_valid(target) then
            return
        end
        vim.api.nvim_win_call(target, function()
            local key = delta < 0 and "<C-y>" or "<C-e>"
            local keys = vim.api.nvim_replace_termcodes(tostring(math.abs(delta)) .. key, true, false, true)
            vim.api.nvim_feedkeys(keys, "n", false)
        end)
    end

    scroll_win(state.winid)
    scroll_win(state.side_winid)
    return true
end

---@param state delta.spotlight.diff.State
local function setup_keymaps(state)
    local open_keys = resolve_open_keyspecs()
    local popup_keys = resolve_popup_keymaps(state.keymaps)

    for _, keyspec in ipairs(open_keys) do
        Keys.bind(state.parent_bufnr, keyspec, function()
            M.focus(state.parent_winid)
        end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.focus" })
    end

    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.close)) do
        Keys.bind(state.parent_bufnr, keyspec, function()
            M.hide(state.parent_winid)
        end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.close" })
        Keys.bind(state.bufnr, keyspec, function()
            M.hide(state.parent_winid)
        end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.close" })
        if state.side_bufnr then
            Keys.bind(state.side_bufnr, keyspec, function()
                M.hide(state.parent_winid)
            end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.close" })
        end
    end

    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.scroll_up)) do
        Keys.bind(state.parent_bufnr, keyspec, function()
            M.scroll("up", state.parent_winid)
        end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.scroll_up" })
        Keys.bind(state.bufnr, keyspec, function()
            M.scroll("up", state.parent_winid)
        end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.scroll_up" })
        if state.side_bufnr then
            Keys.bind(state.side_bufnr, keyspec, function()
                M.scroll("up", state.parent_winid)
            end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.scroll_up" })
        end
    end

    for _, keyspec in ipairs(resolve_keyspecs(popup_keys.scroll_down)) do
        Keys.bind(state.parent_bufnr, keyspec, function()
            M.scroll("down", state.parent_winid)
        end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.scroll_down" })
        Keys.bind(state.bufnr, keyspec, function()
            M.scroll("down", state.parent_winid)
        end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.scroll_down" })
        if state.side_bufnr then
            Keys.bind(state.side_bufnr, keyspec, function()
                M.scroll("down", state.parent_winid)
            end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.scroll_down" })
        end
    end

    if state.side_bufnr then
        for _, keyspec in ipairs(resolve_keyspecs(popup_keys.focus_left)) do
            Keys.bind(state.side_bufnr, keyspec, function()
                M.focus_side("left", state.parent_winid)
            end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.focus_left" })
        end
        for _, keyspec in ipairs(resolve_keyspecs(popup_keys.focus_right)) do
            Keys.bind(state.bufnr, keyspec, function()
                M.focus_side("right", state.parent_winid)
            end, { modes = "nv", nowait = true, desc = "delta.spotlight.diff.focus_right" })
        end
    end
end

---@param parent_winid delta.WinId
---@param state delta.spotlight.diff.State
local function attach(parent_winid, state)
    local group = vim.api.nvim_create_augroup("DeltaSpotlightDiff:" .. parent_winid, { clear = true })
    state.augroup = group

    vim.api.nvim_create_autocmd({ "WinClosed" }, {
        group = group,
        pattern = tostring(parent_winid),
        callback = function()
            clear(parent_winid)
        end,
        once = true,
    })

    vim.api.nvim_create_autocmd({ "WinClosed" }, {
        group = group,
        pattern = tostring(state.winid),
        callback = function()
            clear(parent_winid)
        end,
        once = true,
    })

    if state.side_winid then
        vim.api.nvim_create_autocmd({ "WinClosed" }, {
            group = group,
            pattern = tostring(state.side_winid),
            callback = function()
                clear(parent_winid)
            end,
            once = true,
        })
    end

    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
        group = group,
        buffer = state.bufnr,
        callback = function()
            clear(parent_winid)
        end,
        once = true,
    })
    if state.side_bufnr then
        vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
            group = group,
            buffer = state.side_bufnr,
            callback = function()
                clear(parent_winid)
            end,
            once = true,
        })
    end

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = function()
            if vim.api.nvim_get_current_win() == parent_winid then
                clear(parent_winid)
            end
        end,
    })

    if state.layout.follow_scroll then
        vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized" }, {
            group = group,
            callback = function()
                if popups[parent_winid] then
                    refresh_layout(parent_winid)
                end
            end,
        })
    end
end

---@param hunk delta.Hunk
---@param hunks? delta.Hunk[]
---@return integer?, integer?
local function resolve_hunk_index(hunk, hunks)
    if not hunks then
        return nil, nil
    end
    for i, candidate in ipairs(hunks) do
        if candidate == hunk or candidate.header == hunk.header then
            return i, #hunks
        end
    end
    return nil, #hunks
end

---@param winid? delta.WinId
function M.hide(winid)
    local parent_winid = select(1, resolve_popup(winid or vim.api.nvim_get_current_win()))
    if parent_winid then
        clear(parent_winid)
    end
end

---@param opts delta.spotlight.diff.OpenHunkOpts
---@return delta.WinId?
local function open_hunk(opts)
    local parent_winid = opts.winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(parent_winid) then
        return nil
    end
    local parent_bufnr = opts.bufid or vim.api.nvim_win_get_buf(parent_winid)
    if not vim.api.nvim_buf_is_valid(parent_bufnr) then
        return nil
    end

    clear(parent_winid)

    local index, total = resolve_hunk_index(opts.hunk, opts.hunks)
    local title = opts.title or (index and total and ("Hunk " .. index .. " of " .. total) or "Hunk preview")
    local raw_anchor = opts.anchor or { line = opts.hunk:target(opts.side or "added"), col = 0 }
    local anchor = { line = raw_anchor.line, col = raw_anchor.col or 0 }

    local diff_config = Config.options.spotlight.diff or {}
    local layout_defaults = diff_config.layout
    local layout = {
        border = opts.border or layout_defaults.border,
        max_width = opts.max_width or layout_defaults.max_width or default_max_width(),
        max_height = opts.max_height or layout_defaults.max_height or default_max_height(),
        zindex = opts.zindex or layout_defaults.zindex,
        focusable = opts.focusable == nil and layout_defaults.focusable or opts.focusable,
        follow_scroll = opts.follow_scroll == nil and layout_defaults.follow_scroll or opts.follow_scroll,
        mode = opts.mode or diff_config.mode or "auto",
        min_side_by_side_width = opts.min_side_by_side_width or layout_defaults.min_side_by_side_width,
        scroll_step = opts.scroll_step or layout_defaults.scroll_step,
    }

    local content = build_content(opts.hunk, layout, title, opts.side)
    content.path = opts.path
    local config, side_config = resolve_layouts(parent_winid, anchor, content, layout)
    if not config then
        Notify.info("Failed to place hunk popup")
        return nil
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false

    local winid = vim.api.nvim_open_win(bufnr, false, config)
    setup_window(winid)

    local state = {
        parent_winid = parent_winid,
        parent_bufnr = parent_bufnr,
        winid = winid,
        bufnr = bufnr,
        anchor = anchor,
        side = opts.side,
        layout = layout,
        content = content,
        keymaps = opts.keymaps,
        hunk = opts.hunk,
    }

    if side_config and content.left and content.right then
        local side_bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[side_bufnr].buftype = "nofile"
        vim.bo[side_bufnr].bufhidden = "wipe"
        vim.bo[side_bufnr].swapfile = false
        vim.bo[side_bufnr].modifiable = false
        local side_winid = vim.api.nvim_open_win(side_bufnr, false, side_config)
        setup_window(side_winid)
        state.side_bufnr = side_bufnr
        state.side_winid = side_winid
    end

    popups[parent_winid] = state
    render(state)
    setup_keymaps(state)
    attach(parent_winid, state)
    return state.winid
end

---@param hunks delta.Hunk[]
---@param line number
---@param side delta.HunkSide
---@return delta.Hunk[]
local function overlapping_hunks(hunks, line, side)
    local matches = {}

    for _, hunk in ipairs(hunks or {}) do
        local node = side == "removed" and hunk.removed or hunk.added
        if node.count == 0 then
            if line == node.start or line == node.start + 1 then
                matches[#matches + 1] = hunk
            end
        elseif hunk:start_line(side) <= line and hunk:end_line(side) >= line then
            matches[#matches + 1] = hunk
        end
    end

    return matches
end

---@param visible_hunks delta.Hunk[]
---@param file? delta.spotlight.FileState
---@param line number
---@param side delta.HunkSide
---@param scratch? delta.spotlight.ScratchBufContentType
---@return delta.Hunk|nil
local function resolve_visible_hunk(visible_hunks, file, line, side, scratch)
    if scratch or not file or file.kind ~= "managed" then
        return Git.find_hunk(visible_hunks or {}, line, side)
    end

    local matches = overlapping_hunks(visible_hunks or {}, line, side)
    if #matches == 0 then
        return nil
    end

    local unstaged_lookup = {}
    for _, hunk in ipairs((file.visible_hunks and file.visible_hunks.unstaged) or file.raw_hunks.unstaged or {}) do
        unstaged_lookup[hunk] = true
    end

    local preferred = {}
    for _, hunk in ipairs(matches) do
        if unstaged_lookup[hunk] then
            preferred[#preferred + 1] = hunk
        end
    end

    return Git.find_hunk(#preferred > 0 and preferred or matches, line, side)
end

---@param opts? delta.spotlight.diff.OpenOpts
---@return delta.spotlight.diff.OpenHunkOpts?
---@return string?
local function resolve_current_hunk_opts(opts)
    local winid = opts and opts.winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(winid) then
        return nil, "Invalid window"
    end
    local bufid = opts and opts.bufid or vim.api.nvim_win_get_buf(winid)
    if not vim.api.nvim_buf_is_valid(bufid) then
        return nil, "Invalid buffer"
    end

    local bufname = vim.api.nvim_buf_get_name(bufid)
    local path = opts and opts.path or select(1, Paths.normalize(bufname))
    if not path then
        return nil, "No file path for current buffer"
    end

    local Spotlight = require("delta.spotlight.core")

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local default_hunks, default_side, file = Spotlight.hunks_for_buf(bufid)
    local side = opts and opts.side or default_side or Paths.visible_side(bufname)
    local hunks = opts and opts.hunks or default_hunks
    local _, scratch = Paths.normalize(bufname)
    local hunk = opts and opts.hunk or resolve_visible_hunk(hunks or {}, file, cursor[1], side, scratch)
    if not hunk then
        return nil, "No hunk at cursor"
    end

    return {
        winid = winid,
        bufid = bufid,
        hunk = hunk,
        hunks = hunks,
        side = side,
        path = path,
        title = opts and opts.title or nil,
        border = opts and opts.border or nil,
        max_width = opts and opts.max_width or nil,
        max_height = opts and opts.max_height or nil,
        zindex = opts and opts.zindex or nil,
        focusable = opts and opts.focusable or nil,
        follow_scroll = opts and opts.follow_scroll or nil,
        mode = opts and opts.mode or nil,
        min_side_by_side_width = opts and opts.min_side_by_side_width or nil,
        scroll_step = opts and opts.scroll_step or nil,
        keymaps = opts and opts.keymaps or nil,
        anchor = { line = hunk:target(side), col = cursor[2] },
    },
        nil
end

---@param opts? delta.spotlight.diff.OpenOpts
---@return delta.WinId?
function M.open(opts)
    local winid = opts and opts.winid or vim.api.nvim_get_current_win()
    local parent_winid = select(1, resolve_popup(winid))
    if parent_winid then
        M.focus(parent_winid)
        return popups[parent_winid].winid
    end

    local resolved, err = resolve_current_hunk_opts(opts)
    if not resolved then
        Notify.info(err or "No hunk at cursor")
        return nil
    end
    return open_hunk(resolved)
end

return M
