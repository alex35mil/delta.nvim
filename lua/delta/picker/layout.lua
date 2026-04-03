--- Layout helpers for delta.picker.
--- Pure geometry/border calculations.

local M = {}

---@param value number fraction (<1) or absolute (>=1)
---@param screen number screen dimension
---@return number
function M.resolve_size(value, screen)
    if value < 1 then
        return math.floor(screen * value)
    end
    return math.min(math.floor(value), screen - 4)
end

---@param width number
---@param height number
---@param columns number
---@param lines number
---@return number row
---@return number col
function M.centered_box(width, height, columns, lines)
    local row = math.floor((lines - height) / 2)
    local col = math.floor((columns - width) / 2)
    return row, col
end

---@param border? string|string[]
---@param fallback? string
---@return string[]|nil
function M.resolve_border(border, fallback)
    local border_names = {
        none = { "", "", "", "", "", "", "", "" },
        single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
        double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
        rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
        solid = { "▛", "▀", "▜", "▐", "▟", "▄", "▙", "▌" },
        shadow = { "", "", " ", " ", " ", " ", " ", "" },
    }

    if type(border) == "string" then
        return border_names[border] or border_names[fallback or "rounded"]
    end

    return border
end

---@param border? string[]
---@return string[] input_border
---@return string[] tree_border
function M.split_stacked_border(border)
    if border then
        local input_border = { border[1], border[2], border[3], border[4], "", "", "", border[8] }
        local tree_border = { "", "", "", border[4], border[5], border[6], border[7], border[8] }
        return input_border, tree_border
    end

    return { " ", " ", " ", " ", " ", " ", " ", " " }, { "", "", "", " ", " ", " ", " ", " " }
end

---@param border? string[]
---@return number top_rows
---@return number bottom_rows
function M.border_rows(border)
    if not border then
        return 0, 0
    end

    local top_rows = border[2] ~= "" and 1 or 0
    local bottom_rows = border[6] ~= "" and 1 or 0
    return top_rows, bottom_rows
end

return M
