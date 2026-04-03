--- Tree data structures for delta.nvim.
--- Pure functions: no UI state, no side effects.

local M = {}

---@class delta.Node
---@field name string
---@field path string Full relative path
---@field status delta.FileStatus?
---@field section delta.picker.Section
---@field is_dir boolean
---@field depth number
---@field children delta.Node[]
---@field expanded boolean

--- Build a tree from a flat file list.
---@param files delta.FileEntry[]
---@param section delta.picker.Section
---@return delta.Node root
function M.build(files, section)
    ---@type delta.Node
    local root = {
        name = "",
        path = "",
        status = nil,
        section = section,
        is_dir = true,
        depth = 0,
        children = {},
        expanded = true,
    }

    for _, file in ipairs(files) do
        local parts = vim.split(file.path, "/")
        local node = root

        for i, part in ipairs(parts) do
            local is_last = i == #parts

            if is_last then
                table.insert(node.children, {
                    name = part,
                    path = file.path,
                    status = file.status,
                    section = section,
                    is_dir = false,
                    depth = i,
                    children = {},
                    expanded = false,
                })
            else
                -- Find or create directory.
                local found = nil
                for _, child in ipairs(node.children) do
                    if child.is_dir and child.name == part then
                        found = child
                        break
                    end
                end

                if not found then
                    found = {
                        name = part,
                        path = table.concat(parts, "/", 1, i),
                        status = nil,
                        section = section,
                        is_dir = true,
                        depth = i,
                        children = {},
                        expanded = true,
                    }
                    table.insert(node.children, found)
                end

                node = found
            end
        end
    end

    M.sort(root)
    M.collapse_single_dirs(root)

    return root
end

--- Sort tree: directories first, then alphabetical.
---@param node delta.Node
function M.sort(node)
    table.sort(node.children, function(a, b)
        if a.is_dir ~= b.is_dir then
            return a.is_dir
        end
        return a.name < b.name
    end)

    for _, child in ipairs(node.children) do
        if child.is_dir then
            M.sort(child)
        end
    end
end

--- Collapse directories that have only one child directory.
---@param node delta.Node
function M.collapse_single_dirs(node)
    for _, child in ipairs(node.children) do
        if child.is_dir then
            M.collapse_single_dirs(child)
        end
    end

    for i, child in ipairs(node.children) do
        if child.is_dir and #child.children == 1 and child.children[1].is_dir then
            local grandchild = child.children[1]
            node.children[i] = {
                name = child.name .. "/" .. grandchild.name,
                path = grandchild.path,
                status = grandchild.status,
                section = grandchild.section,
                is_dir = true,
                depth = child.depth,
                children = grandchild.children,
                expanded = child.expanded,
            }
            -- Re-collapse in case of chains.
            M.collapse_single_dirs(node)
            return
        end
    end
end

--- Apply collapsed state to a tree.
---@param node delta.Node
---@param collapsed table<string, boolean> set of collapsed directory paths
function M.apply_collapsed(node, collapsed)
    if node.is_dir and collapsed[node.path] then
        node.expanded = false
    end
    for _, child in ipairs(node.children) do
        if child.is_dir then
            M.apply_collapsed(child, collapsed)
        end
    end
end

--- Filter files by query (substring match on full path, case-insensitive).
---@param files delta.FileEntry[]
---@param query string
---@return delta.FileEntry[]
function M.filter_files(files, query)
    if query == "" then
        return files
    end

    local q = query:lower()
    local result = {}
    for _, file in ipairs(files) do
        if file.path:lower():find(q, 1, true) then
            table.insert(result, file)
        end
    end
    return result
end

return M
