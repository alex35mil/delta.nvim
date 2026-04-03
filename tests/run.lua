local function find_files()
    if vim.env.FILE and vim.env.FILE ~= "" then
        return { vim.env.FILE }
    end

    local files = {}

    local unit = vim.fn.globpath("tests/unit", "**/test*.lua", true, true)
    local integration = vim.fn.globpath("tests/integration", "**/test*.lua", true, true)
    vim.list_extend(files, unit)
    vim.list_extend(files, integration)

    return files
end

local cases = MiniTest.collect({
    emulate_busted = true,
    find_files = find_files,
    filter_cases = function(_)
        return true
    end,
})

MiniTest.execute(cases, {
    reporter = MiniTest.gen_reporter.stdout({ quit_on_finish = false }),
    stop_on_error = false,
})

local finished = vim.wait(30000, function()
    return not MiniTest.is_executing()
end, 20)

if not finished then
    vim.api.nvim_echo({ { "mini.test timed out before finishing", "ErrorMsg" } }, true, {})
    io.write("\n")
    io.flush()
    vim.cmd("cquit 2")
end

for _, case in ipairs(cases) do
    if case.exec == nil or (case.exec.fails and #case.exec.fails > 0) then
        io.write("\n")
        io.flush()
        vim.cmd("cquit 1")
    end
end

io.write("\n")
io.flush()
vim.cmd("qa!")
