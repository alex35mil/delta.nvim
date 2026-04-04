--- Git operations for delta.nvim.
--- All shell commands are async via vim.system + coroutines.
--- Functions that call git must be invoked inside delta.git.async().

local M = {}

local Notify = require("delta.notify")

---@class delta.FileEntry
---@field path string
---@field status delta.FileStatus

---@class delta.HunkNode
---@field start number First line in this side of the diff hunk.
---@field count number Number of lines on this side; may be 0 for zero-line hunks.
---@field lines string[] Changed lines for this side, without diff prefixes.
---@field no_nl_at_eof? boolean True when the selected hunk side has no trailing newline.

---@alias delta.HunkSide "added"|"removed"
---@alias delta.HunkType "add"|"change"|"delete"

---@class delta.Hunk
---@field type delta.HunkType
---@field header string Original @@ header line.
---@field added delta.HunkNode New/index/worktree side of the diff.
---@field removed delta.HunkNode Old/HEAD/index side of the diff.
---@field vend number Last visible line on the added side.
---@field lines fun(self: delta.Hunk, side?: delta.HunkSide): number Effective span on the chosen side; returns at least 1.
---@field target fun(self: delta.Hunk, side?: delta.HunkSide): number Preferred cursor/jump line on the chosen side.
---@field start_line fun(self: delta.Hunk, side?: delta.HunkSide): number First visible line on the chosen side.
---@field end_line fun(self: delta.Hunk, side?: delta.HunkSide): number Last visible line on the chosen side.
---@field clone fun(self: delta.Hunk): delta.Hunk Deep copy preserving the hunk metatable.
local Hunk = {}
Hunk.__index = Hunk

M.Hunk = Hunk

---@param old_start number
---@param old_count number
---@param new_start number
---@param new_count number
---@return delta.Hunk
function Hunk.new(old_start, old_count, new_start, new_count)
    return setmetatable({
        type = new_count == 0 and "delete" or old_count == 0 and "add" or "change",
        header = string.format("@@ -%d,%d +%d,%d @@", old_start, old_count, new_start, new_count),
        added = { start = new_start, count = new_count, lines = {} },
        removed = { start = old_start, count = old_count, lines = {} },
        vend = new_start + math.max(new_count - 1, 0),
    }, Hunk)
end

---@param side? delta.HunkSide
---@return delta.HunkNode
function Hunk:node(side)
    return side == "removed" and self.removed or self.added
end

---@param side? delta.HunkSide
---@return number
function Hunk:lines(side)
    local node = self:node(side)
    return math.max(node.count, 1)
end

---@param side? delta.HunkSide
---@return number
function Hunk:target(side)
    local node = self:node(side)
    if node.count == 0 then
        return math.max(node.start, 1)
    end
    return node.start
end

---@param side? delta.HunkSide
---@return number
function Hunk:start_line(side)
    return self:target(side)
end

---@param side? delta.HunkSide
---@return number
function Hunk:end_line(side)
    return self:target(side) + self:lines(side) - 1
end

---@return delta.Hunk
function Hunk:clone()
    local clone = setmetatable({}, getmetatable(self))
    for k, v in pairs(self) do
        clone[k] = type(v) == "table" and vim.deepcopy(v) or v
    end
    return clone
end

---@class delta.ChangedFiles
---@field unstaged delta.FileEntry[]
---@field staged delta.FileEntry[]

---@alias delta.GitStatusCode " "|"M"|"A"|"D"|"R"|"C"|"U"|"?"|"!"

---@class delta.FileStatus
---@field index delta.GitStatusCode
---@field worktree delta.GitStatusCode
local FileStatus = {}
FileStatus.__index = FileStatus

---@param index delta.GitStatusCode
---@param worktree delta.GitStatusCode
---@return delta.FileStatus
function FileStatus.new(index, worktree)
    return setmetatable({
        index = index,
        worktree = worktree,
    }, FileStatus)
end

---@return boolean
function FileStatus:has_staged()
    return self.index ~= " " and self.index ~= "?" and self.index ~= "!"
end

---@return boolean
function FileStatus:has_unstaged()
    return self.worktree ~= " " and self.worktree ~= "!"
end

---@return boolean
function FileStatus:is_untracked()
    return self.index == "?" and self.worktree == "?"
end

---@return boolean
function FileStatus:is_ignored()
    return self.index == "!" and self.worktree == "!"
end

---@return boolean
function FileStatus:has_staged_deletion()
    return self.index == "D"
end

---@return boolean
function FileStatus:has_unstaged_deletion()
    return self.worktree == "D"
end

---@return boolean
function FileStatus:is_deleted()
    return self:has_staged_deletion() or self:has_unstaged_deletion()
end

---@return boolean
function FileStatus:is_conflicted()
    return self.index == "U"
        or self.worktree == "U"
        or (self.index == "A" and self.worktree == "A")
        or (self.index == "D" and self.worktree == "D")
end

---@return string
function FileStatus:key()
    return self.index .. self.worktree
end

--- Async infrastructure

--- Per-coroutine step functions for error-safe resume.
---@type table<thread, fun(...: any)>
local step_fns = {}

--- Run a git command asynchronously. Must be called from a coroutine (via M.async).
---@param args string[] command arguments (without "git" prefix)
---@param opts? { stdin?: string } optional stdin input
---@return vim.SystemCompleted
local function run(args, opts)
    local co = coroutine.running()
    assert(co, "git.run must be called inside git.async()")

    local step = step_fns[co]
    assert(step, "git.run: no step function for coroutine")

    local cmd = vim.list_extend({ "git" }, args)
    local sys_opts = { text = true }
    if opts and opts.stdin then
        sys_opts.stdin = opts.stdin
    end

    vim.system(cmd, sys_opts, function(result)
        vim.schedule(function()
            step(result)
        end)
    end)

    return coroutine.yield()
end

--- Run an async function in a coroutine. Errors are reported via Notify.
---@param fn fun()
function M.async(fn)
    local co = coroutine.create(fn)

    local function step(...)
        local ok, err = coroutine.resume(co, ...)
        if not ok then
            Notify.error(tostring(err))
        end
        if coroutine.status(co) == "dead" then
            step_fns[co] = nil
        end
    end

    step_fns[co] = step
    step()
end

--- File listing

---@alias delta.GitContextErrorKind "no_repo"|"outsider"

---@param stderr string?
---@return delta.GitContextErrorKind?
local function classify_context_error(stderr)
    local err = stderr or ""
    if err:find("outside repository", 1, true) then
        return "outsider"
    end
    if err:find("not a git repository", 1, true) then
        return "no_repo"
    end
end

--- Get the .git directory path for the current repo.
--- Must be called inside M.async().
---@return boolean ok
---@return string? gitdir
---@return delta.GitContextErrorKind? errkind
function M.git_dir()
    local result = run({ "rev-parse", "--absolute-git-dir" })
    if result.code ~= 0 then
        local errkind = classify_context_error(result.stderr)
        if errkind then
            return false, nil, errkind
        end
        Notify.error("git rev-parse: " .. (result.stderr or "failed"))
        return false, nil, nil
    end
    return true, vim.trim(result.stdout or ""), nil
end

--- Parse `git status --porcelain -z` output.
---@param output string
---@return { x: string, y: string, path: string }[]
local function parse_porcelain_z(output)
    local entries = {}
    local records = vim.split(output or "", "\0", { plain = true, trimempty = true })

    local i = 1
    while i <= #records do
        local record = records[i]
        local x = record:sub(1, 1)
        local y = record:sub(2, 2)
        local path = record:sub(4)

        -- Renames/copies in -z mode are emitted as: "XY oldpath\0newpath\0".
        if x == "R" or x == "C" then
            path = records[i + 1] or path
            i = i + 1
        end

        entries[#entries + 1] = { x = x, y = y, path = path }
        i = i + 1
    end

    return entries
end

--- Collect changed files from git, split into staged and unstaged.
--- Must be called inside M.async().
---@return boolean ok
---@return delta.ChangedFiles result
function M.get_changed_files()
    local result = run({ "status", "--porcelain", "-z", "-u" })
    if result.code ~= 0 then
        Notify.error("git status: " .. (result.stderr or "unknown error"))
        return false, { unstaged = {}, staged = {} }
    end

    local unstaged = {}
    local staged = {}

    for _, entry in ipairs(parse_porcelain_z(result.stdout or "")) do
        local x = entry.x
        local y = entry.y
        local path = entry.path

        local status = FileStatus.new(x, y)

        if y ~= " " and y ~= "!" then
            table.insert(unstaged, { path = path, status = status })
        end

        if x ~= " " and x ~= "?" and x ~= "!" then
            table.insert(staged, { path = path, status = status })
        end
    end

    return true, { unstaged = unstaged, staged = staged }
end

--- Filter file entries to only include paths in the given set.
---@param files delta.FileEntry[]
---@param path_set table<string, boolean>
---@return delta.FileEntry[]
function M.filter_by_paths(files, path_set)
    local result = {}
    for _, file in ipairs(files) do
        if path_set[file.path] then
            table.insert(result, file)
        end
    end
    return result
end

--- Get the git status of a file.
--- Must be called inside M.async().
---@param path string
---@return boolean ok
---@return delta.FileStatus|nil status
---@return delta.GitContextErrorKind? errkind
function M.file_status(path)
    local result = run({ "status", "--porcelain", "-z", "--", path })
    if result.code ~= 0 then
        local errkind = classify_context_error(result.stderr)
        if errkind then
            return false, nil, errkind
        end
        Notify.error("git status: " .. (result.stderr or "failed"))
        return false, nil, nil
    end

    local entries = parse_porcelain_z(result.stdout or "")
    local entry = entries[1]
    if not entry then
        return true, FileStatus.new(" ", " "), nil
    end

    return true, FileStatus.new(entry.x, entry.y), nil
end

--- Staging

--- Stage a file. Must be called inside M.async().
---@param path string
---@return boolean success
---@return string? error
function M.stage(path)
    local result = run({ "add", "--", path })
    if result.code ~= 0 then
        return false, result.stderr
    end
    return true
end

--- Unstage a file. Must be called inside M.async().
---@param path string
---@return boolean success
---@return string? error
function M.unstage(path)
    local result = run({ "reset", "HEAD", "--", path })
    if result.code ~= 0 then
        return false, result.stderr
    end
    return true
end

---@alias delta.ResetTarget "index"|"head"|"delete"

--- Store the current worktree file contents as a blob for best-effort undo hints.
--- Must be called inside M.async(). Missing files simply return nil.
---@param path string
---@return boolean ok
---@return string? blob
---@return string? error
function M.snapshot_worktree_blob(path)
    if vim.fn.filereadable(path) == 0 then
        return true, nil, nil
    end

    local result = run({ "hash-object", "-w", "--", path })
    if result.code ~= 0 then
        return false, nil, result.stderr
    end

    return true, vim.trim(result.stdout or ""), nil
end

---@param path string
---@param blob string
---@return string
function M.undo_hint_for_blob(path, blob)
    return "git show " .. blob .. " > " .. vim.fn.shellescape(path)
end

--- Reset a file to the requested baseline.
--- Must be called inside M.async().
---@param path string
---@param target delta.ResetTarget
---@return boolean success
---@return string? undo_hint
---@return string? error
function M.reset_file(path, target)
    local ok_blob, blob, blob_err = M.snapshot_worktree_blob(path)
    if not ok_blob then
        return false, nil, blob_err
    end

    local result
    if target == "index" then
        result = run({ "restore", "--worktree", "--", path })
    elseif target == "head" then
        result = run({ "restore", "--source=HEAD", "--staged", "--worktree", "--", path })
    elseif target == "delete" then
        result = run({ "clean", "-f", "--", path })
    else
        return false, nil, "invalid reset target"
    end

    if result.code ~= 0 then
        return false, nil, result.stderr
    end

    local undo_hint = blob and M.undo_hint_for_blob(path, blob) or nil
    return true, undo_hint, nil
end

-- Diff / hunks

---@alias delta.Hunks {staged: delta.Hunk[], unstaged: delta.Hunk[]}

---@param text string
---@return string[]
local function split_text_lines(text)
    local lines = vim.split(text or "", "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

---@param path string
---@param staged boolean
---@return string[]
local function diff_args(path, staged)
    local args = { "diff", "-U0" }
    if staged then
        table.insert(args, "--cached")
    end
    table.insert(args, "--")
    table.insert(args, path)
    return args
end

---@param node delta.HunkNode
---@return number
local function node_end(node)
    if node.count == 0 then
        return node.start
    end
    return node.start + node.count - 1
end

--- Parse diff output into file header and hunks.
---@param diff_lines string[]
---@return string[] file_header
---@return delta.Hunk[] hunks
function M.parse_diff(diff_lines)
    local file_header = {}
    local hunks = {}
    local current = nil
    local last_prefix = nil

    for i, line in ipairs(diff_lines) do
        if i == #diff_lines and line == "" then
            break
        end

        if line:match("^@@ ") then
            if current then
                table.insert(hunks, current)
            end

            local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
            local old_start = tonumber(os)
            local new_start = tonumber(ns)
            if not old_start or not new_start then
                error("failed to parse hunk header: " .. line)
            end
            current = Hunk.new(old_start, tonumber(oc) or 1, new_start, tonumber(nc) or 1)
            current.header = line
            last_prefix = nil
        elseif current then
            if line == "\\ No newline at end of file" then
                local node = last_prefix == "+" and current.added or (last_prefix == "-" and current.removed or nil)
                if node then
                    node.no_nl_at_eof = true
                end
            else
                local prefix = line:sub(1, 1)
                if prefix == "+" then
                    current.added.lines[#current.added.lines + 1] = line:sub(2)
                elseif prefix == "-" then
                    current.removed.lines[#current.removed.lines + 1] = line:sub(2)
                end
                last_prefix = prefix
            end
        else
            table.insert(file_header, line)
        end
    end

    if current then
        table.insert(hunks, current)
    end

    return file_header, hunks
end

--- Parse hunks from git diff output.
---@param output string
---@return delta.Hunk[]
function M.parse_hunks(output)
    local _, hunks = M.parse_diff(vim.split(output or "", "\n", { plain = true }))
    return hunks
end

---@class delta.VisibleDiffLine
---@field kind "context"|"add"|"remove"
---@field text string
---@field old_line integer?
---@field new_line integer?

---@class delta.VisibleDiffBlock
---@field header string
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field lines delta.VisibleDiffLine[]
---@field old_lines string[]
---@field new_lines string[]
---@field old_map integer[]
---@field new_map integer[]
---@field old_no_nl_at_eof? boolean
---@field new_no_nl_at_eof? boolean

--- Parse merged diff blocks from git diff output while preserving full
--- old/new line mapping, including inter-hunk context lines.
---@param diff_lines string[]
---@return string[] file_header
---@return delta.VisibleDiffBlock[] blocks
function M.parse_visible_diff(diff_lines)
    local file_header = {}
    local blocks = {}
    local current = nil
    local old_line = nil
    local new_line = nil
    local last_prefix = nil

    for i, line in ipairs(diff_lines) do
        if i == #diff_lines and line == "" then
            break
        end

        if line:match("^@@ ") then
            if current then
                table.insert(blocks, current)
            end

            local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
            local old_start = tonumber(os)
            local new_start = tonumber(ns)
            if not old_start or not new_start then
                error("failed to parse hunk header: " .. line)
            end

            current = {
                header = line,
                old_start = old_start,
                old_count = tonumber(oc) or 1,
                new_start = new_start,
                new_count = tonumber(nc) or 1,
                lines = {},
                old_lines = {},
                new_lines = {},
                old_map = {},
                new_map = {},
            }
            old_line = old_start
            new_line = new_start
            last_prefix = nil
        elseif current then
            if line == "\\ No newline at end of file" then
                if last_prefix == "+" then
                    current.new_no_nl_at_eof = true
                elseif last_prefix == "-" then
                    current.old_no_nl_at_eof = true
                end
            else
                local prefix = line:sub(1, 1)
                local text = line:sub(2)

                if prefix == " " then
                    current.lines[#current.lines + 1] = {
                        kind = "context",
                        text = text,
                        old_line = old_line,
                        new_line = new_line,
                    }
                    current.old_lines[#current.old_lines + 1] = text
                    current.old_map[#current.old_map + 1] = old_line
                    current.new_lines[#current.new_lines + 1] = text
                    current.new_map[#current.new_map + 1] = new_line
                    old_line = old_line + 1
                    new_line = new_line + 1
                elseif prefix == "+" then
                    current.lines[#current.lines + 1] = {
                        kind = "add",
                        text = text,
                        new_line = new_line,
                    }
                    current.new_lines[#current.new_lines + 1] = text
                    current.new_map[#current.new_map + 1] = new_line
                    new_line = new_line + 1
                elseif prefix == "-" then
                    current.lines[#current.lines + 1] = {
                        kind = "remove",
                        text = text,
                        old_line = old_line,
                    }
                    current.old_lines[#current.old_lines + 1] = text
                    current.old_map[#current.old_map + 1] = old_line
                    old_line = old_line + 1
                end

                last_prefix = prefix
            end
        else
            table.insert(file_header, line)
        end
    end

    if current then
        table.insert(blocks, current)
    end

    return file_header, blocks
end

--- Parse merged visible diff blocks from git diff output.
---@param output string
---@return delta.VisibleDiffBlock[]
function M.parse_visible_diff_blocks(output)
    local _, blocks = M.parse_visible_diff(vim.split(output or "", "\n", { plain = true }))
    return blocks
end

--- Normalize diff file headers for partial patch application.
--- Converts new/deleted-file headers into regular file headers so git apply
--- can stage/unstage partial hunks within added/deleted files.
---@param file_header string[]
---@param path string
---@return string[]
function M.normalize_file_header(file_header, path)
    local normalized = {}
    for _, line in ipairs(file_header) do
        if line:match("^new file mode ") or line:match("^deleted file mode ") then
            -- Skip mode-only lines for partial patch application.
        elseif line == "--- /dev/null" then
            normalized[#normalized + 1] = "--- a/" .. path
        elseif line == "+++ /dev/null" then
            normalized[#normalized + 1] = "+++ b/" .. path
        else
            normalized[#normalized + 1] = line
        end
    end
    return normalized
end

--- Get diff file header + structured hunks for a file.
--- Must be called inside M.async().
---@param path string
---@param staged boolean
---@return boolean ok
---@return string[] file_header
---@return delta.Hunk[] hunks
---@return string? error
function M.get_patch_data(path, staged)
    local result = run(diff_args(path, staged))
    if result.code ~= 0 then
        return false, {}, {}, result.stderr
    end

    local file_header, hunks = M.parse_diff(vim.split(result.stdout or "", "\n", { plain = true }))
    file_header = M.normalize_file_header(file_header, path)

    table.sort(hunks, function(a, b)
        if a.added.start == b.added.start then
            return a.removed.start < b.removed.start
        end
        return a.added.start < b.added.start
    end)

    return true, file_header, hunks
end

--- Get diff hunks for a file. Must be called inside M.async().
---@param path string
---@return boolean ok
---@return delta.Hunks hunks
function M.get_diff_hunks(path)
    local sok, _, staged, serr = M.get_patch_data(path, true)
    if not sok then
        Notify.error("git diff --cached: " .. (serr or "failed"))
        return false, { staged = {}, unstaged = {} }
    end

    local uok, _, unstaged, uerr = M.get_patch_data(path, false)
    if not uok then
        Notify.error("git diff: " .. (uerr or "failed"))
        return false, { staged = {}, unstaged = {} }
    end

    return true, { staged = staged, unstaged = unstaged }
end

--- Get staged file contents from the git index.
--- Must be called inside M.async().
---@param path string
---@return boolean ok
---@return string? text
function M.get_staged_file(path)
    local result = run({ "show", ":" .. path })
    if result.code ~= 0 then
        Notify.error("git show :" .. path .. ": " .. (result.stderr or "failed"))
        return false, nil
    end

    return true, result.stdout or ""
end

--- Get committed file contents from HEAD.
--- Must be called inside M.async().
---@param path string
---@return boolean ok
---@return string? text
function M.get_head_file(path)
    local result = run({ "show", "HEAD:" .. path })
    if result.code ~= 0 then
        Notify.error("git show HEAD:" .. path .. ": " .. (result.stderr or "failed"))
        return false, nil
    end

    return true, result.stdout or ""
end

---@param _ string[] args
---@param stderr string
---@return boolean
local function is_missing_blob(_, stderr)
    if stderr == "" then
        return false
    end

    return stderr:match("does not exist in") ~= nil
        or stderr:match("exists on disk, but not in") ~= nil
        or stderr:match("not in the index") ~= nil
        or stderr:match("invalid object name 'HEAD'") ~= nil
        or stderr:match("bad revision 'HEAD'") ~= nil
end

---@param args string[]
---@return boolean ok
---@return string[]? lines
---@return string? error
local function get_show_lines(args)
    local result = run(args)
    if result.code == 0 then
        return true, split_text_lines(result.stdout or "")
    end

    local stderr = result.stderr or ""
    if is_missing_blob(args, stderr) then
        return true, {}
    end

    return false, nil, stderr
end

--- Get file contents from the index as lines. Missing files resolve to an empty list.
--- Must be called inside M.async().
---@param path string
---@return boolean ok
---@return string[]? lines
---@return string? error
function M.get_index_lines(path)
    return get_show_lines({ "show", ":" .. path })
end

--- Get file contents from HEAD as lines. Missing files resolve to an empty list.
--- Must be called inside M.async().
---@param path string
---@return boolean ok
---@return string[]? lines
---@return string? error
function M.get_head_lines(path)
    return get_show_lines({ "show", "HEAD:" .. path })
end

--- Get worktree file contents as lines. Missing files resolve to an empty list.
---@param path string
---@return boolean ok
---@return string[]? lines
---@return string? error
function M.get_worktree_lines(path)
    if vim.fn.filereadable(path) == 0 then
        return true, {}
    end

    local ok, lines = pcall(vim.fn.readfile, path, "b")
    if not ok then
        return false, nil, tostring(lines)
    end

    return true, lines
end

--- Find the diff hunk containing a visible line.
---@param hunks delta.Hunk[]
---@param line number
---@param side? delta.HunkSide
---@return delta.Hunk|nil
function M.find_hunk(hunks, line, side)
    side = side or "added"

    local best_match = nil
    local best_starts_here = false
    local best_has_lines = false
    local best_span = math.huge

    for _, hunk in ipairs(hunks or {}) do
        local node = side == "removed" and hunk.removed or hunk.added
        local matches = false
        local starts_here = false
        local has_lines = node.count > 0
        local span = 1

        if has_lines then
            matches = hunk:start_line(side) <= line and hunk:end_line(side) >= line
            starts_here = hunk:start_line(side) == line
            span = hunk:lines(side)
        else
            matches = line == node.start or line == node.start + 1
            starts_here = line == node.start
        end

        if matches then
            if
                not best_match
                or (has_lines and not best_has_lines)
                or (has_lines == best_has_lines and starts_here and not best_starts_here)
                or (has_lines == best_has_lines and starts_here == best_starts_here and span < best_span)
            then
                best_match = hunk
                best_starts_here = starts_here
                best_has_lines = has_lines
                best_span = span
            end
        end
    end

    return best_match
end

---@param line number
---@param unstaged_hunks delta.Hunk[]
---@return number
function M.worktree_to_index_line(line, unstaged_hunks)
    local mapped = line
    for _, hunk in ipairs(unstaged_hunks) do
        if line > hunk.vend then
            mapped = mapped - (hunk.added.count - hunk.removed.count)
        end
    end
    return mapped
end

---@param start_line number
---@param end_line number
---@param unstaged_hunks delta.Hunk[]
---@return number, number
function M.worktree_to_index_range(start_line, end_line, unstaged_hunks)
    return M.worktree_to_index_line(start_line, unstaged_hunks), M.worktree_to_index_line(end_line, unstaged_hunks)
end

--- Build a partial hunk from one or more hunks on the added side.
---@param hunks delta.Hunk[]
---@param top integer
---@param bot integer
---@return delta.Hunk|nil
function M.create_partial_hunk(hunks, top, bot)
    local pretop, precount = top, bot - top + 1
    local unused = 0

    for _, h in ipairs(hunks) do
        local added_in_hunk = h.added.count - h.removed.count
        local added_in_range = 0

        if h.added.start >= top and h.vend <= bot then
            added_in_range = added_in_hunk
        else
            local added_above_bot = math.max(0, bot + 1 - (h.added.start + h.removed.count))
            local added_above_top = math.max(0, top - (h.added.start + h.removed.count))

            if h.added.start >= top and h.added.start <= bot then
                added_in_range = added_above_bot
            elseif h.vend >= top and h.vend <= bot then
                added_in_range = added_in_hunk - added_above_top
                pretop = pretop - added_above_top
            elseif h.added.start <= top and h.vend >= bot then
                added_in_range = added_above_bot - added_above_top
                pretop = pretop - added_above_top
            else
                unused = unused + 1
            end

            if top > h.vend then
                pretop = pretop - added_in_hunk
            end
        end

        precount = precount - added_in_range
    end

    if unused == #hunks then
        return nil
    end

    if precount == 0 then
        pretop = pretop - 1
    end

    return Hunk.new(pretop, precount, top, bot - top + 1)
end

--- Select specific added-side lines inside a hunk.
---@param hunk delta.Hunk
---@param start_line number
---@param end_line number
---@return delta.Hunk|nil
function M.select_hunk_lines(hunk, start_line, end_line)
    if start_line > end_line then
        start_line, end_line = end_line, start_line
    end

    -- Clamp the visual selection to the visible added-side span of this hunk.
    local top = math.max(start_line, hunk:start_line("added"))
    local bot = math.min(end_line, hunk:end_line("added"))
    if top > bot then
        return nil
    end

    if hunk.type == "add" then
        -- Pure added hunks have no removed-side lines to recompute against.
        -- Keep the original insertion anchor from the source hunk and only
        -- narrow the added-side range, otherwise partial staging can shift the
        -- selected lines down into the following context.
        return Hunk.new(hunk.removed.start, 0, top, bot - top + 1)
    elseif hunk.type == "delete" then
        -- In the source/worktree view, pure delete hunks expose only a single
        -- visible anchor line on the added side. A visual selection touching
        -- that anchor cannot meaningfully select a subset of the deleted lines,
        -- so treat it as selecting the whole delete hunk.
        return hunk
    end

    local added_removed_delta = hunk.added.start - hunk.removed.start
    if added_removed_delta == 0 then
        return M.create_partial_hunk({ hunk }, top, bot)
    end

    -- For change/delete hunks, partial selection math is easier if both sides
    -- share the same origin. Normalize the hunk into removed-side coordinates,
    -- slice there, then shift the added-side start back to buffer coordinates.
    local normalized = Hunk.new(hunk.removed.start, hunk.removed.count, hunk.removed.start, hunk.added.count)
    local shape = M.create_partial_hunk({ normalized }, top - added_removed_delta, bot - added_removed_delta)
    if not shape then
        return nil
    end

    shape.added.start = shape.added.start + added_removed_delta
    shape.vend = shape.added.start + math.max(shape.added.count - 1, 0)
    return shape
end

---@param lines string[]
---@param start number
---@param count number
---@return string[]
local function slice_lines(lines, start, count)
    if count <= 0 then
        return {}
    end
    return vim.list_slice(lines, start, start + count - 1)
end

--- Populate a hunk shape with actual file lines from the old/new texts.
---@param shape delta.Hunk
---@param base_lines string[] old side (HEAD or index)
---@param current_lines string[] new side (index or worktree)
---@param source_hunk? delta.Hunk original source hunk for metadata such as no-eol markers
---@return delta.Hunk
function M.populate_hunk_lines(shape, base_lines, current_lines, source_hunk)
    source_hunk = source_hunk or shape

    local populated = Hunk.new(shape.removed.start, shape.removed.count, shape.added.start, shape.added.count)
    populated.added.lines = slice_lines(current_lines, populated.added.start, populated.added.count)
    populated.removed.lines = slice_lines(base_lines, populated.removed.start, populated.removed.count)

    if
        source_hunk.added.no_nl_at_eof
        and populated.added.count > 0
        and node_end(populated.added) == node_end(source_hunk.added)
    then
        populated.added.no_nl_at_eof = true
    end

    if
        source_hunk.removed.no_nl_at_eof
        and populated.removed.count > 0
        and node_end(populated.removed) == node_end(source_hunk.removed)
    then
        populated.removed.no_nl_at_eof = true
    end

    return populated
end

--- Build a patch string from file header and one or more hunks.
---@param file_header string[]
---@param hunks delta.Hunk[]
---@return string
function M.build_patch(file_header, hunks)
    local lines = {}
    local offset = 0
    vim.list_extend(lines, file_header)

    for _, hunk in ipairs(hunks) do
        local old_start = hunk.removed.start
        local old_count = hunk.removed.count
        local new_start = hunk.added.start
        local new_count = hunk.added.count

        if hunk.type == "add" then
            old_start = old_start + 1
            new_start = old_start
        end

        lines[#lines + 1] = string.format("@@ -%d,%d +%d,%d @@", old_start, old_count, new_start + offset, new_count)

        for _, line in ipairs(hunk.removed.lines) do
            lines[#lines + 1] = "-" .. line
        end
        if hunk.removed.no_nl_at_eof then
            lines[#lines + 1] = "\\ No newline at end of file"
        end

        for _, line in ipairs(hunk.added.lines) do
            lines[#lines + 1] = "+" .. line
        end
        if hunk.added.no_nl_at_eof then
            lines[#lines + 1] = "\\ No newline at end of file"
        end

        offset = offset + (new_count - old_count)
    end

    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

--- Build a patch string from file header and a single hunk.
---@param file_header string[]
---@param hunk delta.Hunk
---@return string
function M.build_hunk_patch(file_header, hunk)
    return M.build_patch(file_header, { hunk })
end

---@class delta.ApplyPatchOpts
---@field reverse? boolean
---@field cached? boolean defaults to true (apply to index)

--- Apply a patch string. Must be called inside M.async().
---@param patch string
---@param opts? delta.ApplyPatchOpts
---@return boolean success
---@return string? error
function M.apply_patch(patch, opts)
    opts = opts or {}

    local args = { "apply", "--unidiff-zero" }
    if opts.cached ~= false then
        table.insert(args, "--cached")
    end
    if opts.reverse then
        table.insert(args, "--reverse")
    end
    local result = run(args, { stdin = patch })
    if result.code ~= 0 then
        return false, result.stderr
    end
    return true
end

return M
