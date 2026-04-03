--- User command registration for delta.nvim.

local M = {}

function M.setup()
    vim.api.nvim_create_user_command("DeltaPicker", function(cmd)
        local source = cmd.args ~= "" and cmd.args or nil
        require("delta.picker").toggle({ source = source })
    end, {
        nargs = "?",
        complete = function()
            local sources = require("delta.config").options.picker.sources
            return vim.tbl_keys(sources)
        end,
        desc = "Toggle delta file picker",
    })

    vim.api.nvim_create_user_command("DeltaSpotlight", function(cmd)
        local mode = cmd.args ~= "" and cmd.args or nil
        require("delta.spotlight").toggle(mode)
    end, {
        nargs = "?",
        complete = function()
            return { "auto", "unstaged", "staged", "all" }
        end,
        desc = "Toggle delta spotlight on the current buffer",
    })

    vim.api.nvim_create_user_command("DeltaSpotlightDisableAll", function()
        require("delta.spotlight").disable_all()
    end, { desc = "Disable delta spotlight on all buffers" })
end

return M
