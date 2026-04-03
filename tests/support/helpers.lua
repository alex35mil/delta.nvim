local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local integration_root = root .. "/tests/integration"

function M.eq(left, right)
    assert(vim.deep_equal(left, right), vim.inspect(left) .. " ~= " .. vim.inspect(right))
end

function M.normalize_diff(diff)
    local lines = vim.split(diff or "", "\n", { plain = true })
    local normalized = {}

    for _, line in ipairs(lines) do
        if not line:match("^index ") then
            normalized[#normalized + 1] = line
        end
    end

    return table.concat(normalized, "\n")
end

function M.tmpdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

function M.rm_rf(path)
    if path and path ~= "" and vim.uv.fs_stat(path) then
        vim.fn.delete(path, "rf")
    end
end

function M.finally_rm(path)
    MiniTest.finally(function()
        M.rm_rf(path)
    end)
end

function M.write_file(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
end

function M.system(cmd, cwd)
    local result = vim.system(cmd, { text = true, cwd = cwd }):wait()
    if result.code ~= 0 then
        error(
            (result.stderr and result.stderr ~= "" and result.stderr) or ("command failed: " .. table.concat(cmd, " "))
        )
    end
    return result.stdout or ""
end

function M.git(cwd, ...)
    return M.system(vim.list_extend({ "git" }, { ... }), cwd)
end

function M.init_repo(files)
    local dir = M.tmpdir()

    M.git(dir, "init")
    M.git(dir, "config", "user.name", "delta-tests")
    M.git(dir, "config", "user.email", "delta-tests@nvim.com")

    for path, lines in pairs(files or {}) do
        M.write_file(dir .. "/" .. path, lines)
    end

    M.git(dir, "add", ".")
    M.git(dir, "commit", "-m", "initial")

    return dir
end

local function case_root(name)
    return integration_root .. "/" .. name .. "/fixtures"
end

function M.get_case_states(name)
    local states_dir = case_root(name) .. "/states"
    local entries = {}
    for entry_name, kind in vim.fs.dir(states_dir) do
        if kind == "file" then
            entries[#entries + 1] = entry_name
        end
    end
    table.sort(entries)
    return entries, states_dir
end

function M.case_target_name(name)
    local entries = M.get_case_states(name)
    local ext = entries[1]:match("(%.[^.]+)$") or ""
    return "test" .. ext
end

function M.init_repo_from_case(name)
    local dir = M.tmpdir()

    M.git(dir, "init")
    M.git(dir, "config", "user.name", "delta-tests")
    M.git(dir, "config", "user.email", "delta-tests@nvim.com")

    local entries, states_dir = M.get_case_states(name)
    assert(#entries >= 1, "case must have at least one state file: " .. name)

    local target_name = M.case_target_name(name)
    vim.fn.writefile(vim.fn.readfile(states_dir .. "/" .. entries[1], "b"), dir .. "/" .. target_name, "b")

    M.git(dir, "add", ".")
    M.git(dir, "commit", "-m", "initial")

    return dir
end

function M.apply_case_state(repo, name, step)
    local entries, states_dir = M.get_case_states(name)
    assert(step >= 1 and step < #entries, "invalid step: " .. tostring(step))

    local state_file = entries[step + 1]
    local target_name = M.case_target_name(name)
    vim.fn.writefile(vim.fn.readfile(states_dir .. "/" .. state_file, "b"), repo .. "/" .. target_name, "b")
end

function M.read_case_fixture(name, path)
    return table.concat(vim.fn.readfile(case_root(name) .. "/" .. path, "b"), "\n")
end

function M.write_case_actual(name, path, content)
    local target = case_root(name) .. "/result/actual/" .. path
    vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
    vim.fn.writefile(vim.split(content or "", "\n", { plain = true }), target, "b")
end

function M.new_nvim()
    local nvim = MiniTest.new_child_neovim()
    nvim.start({ "-u", root .. "/tests/nvim.lua" })
    return nvim
end

function M.nvim_set_cwd(nvim, path)
    nvim.lua_func(function(p)
        vim.fn.chdir(p)
    end, path)
end

function M.nvim_edit(nvim, path)
    nvim.lua_func(function(p)
        vim.cmd.edit(vim.fn.fnameescape(p))
    end, path)
end

function M.nvim_wait_for(nvim, expr, timeout, interval)
    local ok = nvim.lua_func(function(e, t, i)
        local chunk, err = load("return function() return " .. e .. " end")
        assert(chunk, err)
        local predicate = chunk()

        return vim.wait(t or 5000, function()
            local ok_eval, value = pcall(predicate)
            return ok_eval and value
        end, i or 20)
    end, expr, timeout, interval)

    assert(ok, "timed out waiting for nvim expression: " .. expr)
end

function M.find_upvalue(fn, target, limit)
    for i = 1, limit or 50 do
        local name, value = debug.getupvalue(fn, i)
        if not name then
            break
        end
        if name == target then
            return value
        end
    end
end

function M.nvim_wait_for_delta_file_state(nvim, predicate, timeout, interval)
    if type(predicate) == "number" then
        timeout, interval = predicate, timeout
        predicate = nil
    end

    local ok = nvim.lua_func(function(t, i, pred_src)
        local toggle = require("delta").spotlight.toggle_stage_hunk
        local file_for_buf

        for idx = 1, 20 do
            local name, value = debug.getupvalue(toggle, idx)
            if name == "file_for_buf" then
                file_for_buf = value
                break
            end
        end

        assert(type(file_for_buf) == "function", "failed to resolve file_for_buf upvalue")

        local predicate_fn = nil
        if pred_src then
            local chunk, err = load("return " .. pred_src)
            assert(chunk, err)
            predicate_fn = chunk()
            assert(type(predicate_fn) == "function", "predicate must evaluate to a function")
        end

        return vim.wait(t or 5000, function()
            local file = file_for_buf(vim.api.nvim_get_current_buf())
            if file == nil or file.path == "" or file.status == nil or file.hunks == nil then
                return false
            end

            return predicate_fn == nil or predicate_fn(file)
        end, i or 20)
    end, timeout, interval, predicate)

    assert(ok, "timed out waiting for delta file state")
end

function M.nvim_wait_for_git_diff(nvim, path, staged, should_exist, timeout, interval)
    local ok = nvim.lua_func(function(p, s, exists, t, i)
        return vim.wait(t or 5000, function()
            local args = { "git", "diff" }
            if s then
                table.insert(args, "--cached")
            end
            vim.list_extend(args, { "--", p })

            local result = vim.system(args, { text = true }):wait()
            if result.code ~= 0 then
                return false
            end

            local has_diff = (result.stdout or "") ~= ""
            return exists and has_diff or (not exists and not has_diff)
        end, i or 20)
    end, path, staged, should_exist, timeout, interval)

    local mode = staged and "staged" or "worktree"
    local want = should_exist and "non-empty" or "empty"
    assert(ok, string.format("timed out waiting for %s git diff to become %s: %s", mode, want, path))
end

function M.nvim_wait_for_git_diff_eq(nvim, path, staged, expected, timeout, interval)
    local ok = nvim.lua_func(function(p, s, wanted, t, i)
        local function normalize(diff)
            local lines = vim.split(diff or "", "\n", { plain = true })
            local normalized = {}

            for _, line in ipairs(lines) do
                if not line:match("^index ") then
                    normalized[#normalized + 1] = line
                end
            end

            return table.concat(normalized, "\n")
        end

        return vim.wait(t or 5000, function()
            local args = { "git", "diff" }
            if s then
                table.insert(args, "--cached")
            end
            vim.list_extend(args, { "--", p })

            local result = vim.system(args, { text = true }):wait()
            if result.code ~= 0 then
                return false
            end

            return normalize(result.stdout or "") == wanted
        end, i or 20)
    end, path, staged, expected, timeout, interval)

    local mode = staged and "staged" or "worktree"
    assert(ok, string.format("timed out waiting for %s git diff to equal expected output: %s", mode, path))
end

return M
