local T = MiniTest.new_set()

local H = require("tests.support.helpers")

-- Builds a tab of three scratch windows (left | top-right / bottom-right), like a
-- start screen next to a side layout. `layout` maps window names to options:
-- `winfixbuf` sets 'winfixbuf', `file` shows that repo file instead of a scratch buffer.
-- `focus` names the window that is current when the picker opens (its origin).
local function start(layout, focus)
    local repo = H.init_repo({ ["a.txt"] = { "old a" }, ["b.txt"] = { "old b" } })
    H.finally_rm(repo)
    H.write_file(repo .. "/a.txt", { "new a" })

    local nvim = H.new_nvim()
    MiniTest.finally(nvim.stop)
    H.nvim_set_cwd(nvim, repo)
    nvim.lua_func(function(spec, focus_name)
        _G.errors = {}
        vim.notify = function(msg, level)
            if level == vim.log.levels.ERROR then
                errors[#errors + 1] = msg
            end
        end
        vim.o.hidden = true

        vim.cmd("vsplit")
        vim.cmd("wincmd l")
        vim.cmd("split")
        _G.wins = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local row, col = unpack(vim.api.nvim_win_get_position(win))
            if col == 0 then
                wins.left = win
            elseif row == 0 then
                wins.right_top = win
            else
                wins.right_bottom = win
            end
        end
        assert(wins.left and wins.right_top and wins.right_bottom, "unexpected layout")

        _G.bufs = {}
        for name, win in pairs(wins) do
            local opts = spec[name] or {}
            if opts.file then
                vim.api.nvim_win_call(win, function()
                    vim.cmd.edit(vim.fn.fnameescape(opts.file))
                end)
            else
                -- Named like a start screen, so :edit can't reuse it as an empty buffer.
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_name(buf, "scratch://" .. name)
                vim.api.nvim_win_set_buf(win, buf)
            end
            bufs[name] = vim.api.nvim_win_get_buf(win)
            vim.wo[win].winfixbuf = opts.winfixbuf == true
        end
        assert(#vim.api.nvim_tabpage_list_wins(0) == 3)
        vim.api.nvim_set_current_win(wins[focus_name])

        require("delta").setup({ picker = { initial_mode = "n" } })
        require("delta.picker").show({ source = "git", preselect_path = "a.txt" })
    end, layout, focus)

    H.nvim_wait_for(
        nvim,
        "(function() for _, w in ipairs(vim.api.nvim_list_wins()) do"
            .. " if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'delta-filetree' then return true end"
            .. " end end)()"
    )
    return nvim, repo
end

-- Presses <CR> (the default open action) in the picker and returns where the file opened.
local function open_entry(nvim)
    return nvim.lua_func(function()
        local done = false
        vim.schedule(function()
            vim.schedule(function()
                done = true
            end)
        end)
        assert(vim.wait(5000, function()
            return done
        end, 10))

        local input
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "delta-input" then
                input = vim.api.nvim_win_get_buf(win)
            end
        end
        assert(input, "picker input missing")
        local callback
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(input, "n")) do
            if map.lhs == "<CR>" then
                callback = map.callback
            end
        end
        assert(callback, "<CR> mapping missing")
        callback()

        assert(not require("delta.picker").is_open(), "picker still open")
        assert(#errors == 0, vim.inspect(errors))

        local win = vim.api.nvim_get_current_win()
        local unchanged = {}
        for name, w in pairs(wins) do
            unchanged[name] = vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufs[name]
        end
        local named
        for name, w in pairs(wins) do
            if w == win then
                named = name
            end
        end
        return {
            name = named,
            path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
            winfixbuf = vim.wo[win].winfixbuf,
            float = vim.api.nvim_win_get_config(win).relative ~= "",
            count = #vim.api.nvim_tabpage_list_wins(0),
            unchanged = unchanged,
            pos = vim.api.nvim_win_get_position(win),
            width = vim.api.nvim_win_get_width(win),
            height = vim.api.nvim_win_get_height(win),
        }
    end)
end

local function win_geometry(nvim, name)
    return nvim.lua_func(function(n)
        return { pos = vim.api.nvim_win_get_position(wins[n]), width = vim.api.nvim_win_get_width(wins[n]) }
    end, name)
end

local scratch_fallback = {
    left = {},
    right_top = { winfixbuf = true },
    right_bottom = { winfixbuf = true },
}

T["scratch window without winfixbuf is chosen over winfixbuf windows"] = function()
    local nvim = start(scratch_fallback, "left")
    local opened = open_entry(nvim)
    H.eq(opened.name, "left")
    H.eq(opened.path, "a.txt")
    H.eq(opened.count, 3)
    H.eq(opened.unchanged, { left = false, right_top = true, right_bottom = true })
end

T["focus in a winfixbuf window still opens in the scratch window"] = function()
    local nvim = start(scratch_fallback, "right_top")
    local opened = open_entry(nvim)
    H.eq(opened.name, "left")
    H.eq(opened.path, "a.txt")
    H.eq(opened.count, 3)
    H.eq(opened.unchanged, { left = false, right_top = true, right_bottom = true })
end

local all_winfixbuf = {
    left = { winfixbuf = true },
    right_top = { winfixbuf = true },
    right_bottom = { winfixbuf = true },
}

for _, focus in ipairs({ "left", "right_bottom" }) do
    T["all winfixbuf windows open a new split of the origin: " .. focus] = function()
        local nvim = start(all_winfixbuf, focus)
        local origin_before = win_geometry(nvim, focus)
        local opened = open_entry(nvim)
        local origin = win_geometry(nvim, focus)

        H.eq(opened.name, nil)
        H.eq(opened.path, "a.txt")
        H.eq(opened.winfixbuf, false)
        H.eq(opened.float, false)
        H.eq(opened.count, 4)
        H.eq(opened.unchanged, { left = true, right_top = true, right_bottom = true })
        -- :new with the default 'nosplitbelow' puts the split directly above its source,
        -- in the source's column ('equalalways' may resize the column afterwards).
        H.eq(opened.pos[2], origin_before.pos[2])
        H.eq(opened.width, origin_before.width)
        H.eq(origin.pos[2], origin_before.pos[2])
        H.eq(opened.pos[1] + opened.height + 1, origin.pos[1])
    end
end

T["normal file window is preferred alongside winfixbuf and scratch windows"] = function()
    local nvim = start({
        left = { winfixbuf = true },
        right_top = {},
        right_bottom = { file = "b.txt" },
    }, "left")
    local opened = open_entry(nvim)
    H.eq(opened.name, "right_bottom")
    H.eq(opened.path, "a.txt")
    H.eq(opened.count, 3)
    H.eq(opened.unchanged, { left = true, right_top = true, right_bottom = false })
end

return T
