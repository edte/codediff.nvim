-- Git status explorer using nui.nvim
local M = {}

local Tree = require("nui.tree")
local NuiLine = require("nui.line")
local Split = require("nui.split")

-- Status symbols and colors
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "DiagnosticWarn" },
  A = { symbol = "A", color = "DiagnosticOk" },
  D = { symbol = "D", color = "DiagnosticError" },
  ["??"] = { symbol = "??", color = "DiagnosticInfo" },
}

-- File icons (basic fallback)
local function get_file_icon(path)
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    local icon, color = devicons.get_icon(path, nil, { default = true })
    return icon or "", color
  end
  return "", nil
end

-- Create tree nodes for file list
local function create_file_nodes(files, git_root)
  local nodes = {}
  for _, file in ipairs(files) do
    local icon, icon_color = get_file_icon(file.path)
    local status_info = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }

    nodes[#nodes + 1] = Tree.Node({
      text = file.path,
      data = {
        path = file.path,
        status = file.status,
        icon = icon,
        icon_color = icon_color,
        status_symbol = status_info.symbol,
        status_color = status_info.color,
        git_root = git_root,
      }
    })
  end
  return nodes
end

-- Create explorer tree structure
local function create_tree_data(status_result, git_root)
  local unstaged_nodes = create_file_nodes(status_result.unstaged, git_root)
  local staged_nodes = create_file_nodes(status_result.staged, git_root)

  return {
    Tree.Node({
      text = string.format("Changes (%d)", #status_result.unstaged),
      data = { type = "group", name = "unstaged" },
    }, unstaged_nodes),
    Tree.Node({
      text = string.format("Staged Changes (%d)", #status_result.staged),
      data = { type = "group", name = "staged" },
    }, staged_nodes),
  }
end

-- Render tree node
local function prepare_node(node)
  local line = NuiLine()
  local data = node.data or {}

  if data.type == "group" then
    -- Group header
    local icon = node:is_expanded() and "" or ""
    line:append(icon .. " ", "Directory")
    line:append(node.text, "Directory")
  else
    -- File entry
    local indent = string.rep("  ", node:get_depth() - 1)
    line:append(indent)
    
    if data.icon then
      line:append(data.icon .. " ", data.icon_color or "Normal")
    end
    
    -- File path (truncate if too long)
    local display_path = data.path or node.text
    if #display_path > 40 then
      display_path = "..." .. display_path:sub(-37)
    end
    line:append(display_path, "Normal")
    
    -- Add status symbol at the end
    local padding = string.rep(" ", math.max(1, 45 - #display_path))
    line:append(padding)
    line:append(data.status_symbol or "", data.status_color or "Normal")
  end

  return line
end

-- Create and show explorer
function M.create(status_result, git_root, tabpage, width)
  -- Use provided width or default to 30 columns
  local explorer_width = width or 30
  
  -- File selection callback - manages its own lifecycle
  local function on_file_select(file_data)
    local git = require('vscode-diff.git')
    local view = require('vscode-diff.render.view')
    local lifecycle = require('vscode-diff.render.lifecycle')
    
    local file_path = file_data.path
    local abs_path = git_root .. "/" .. file_path

    -- Check if this file is already being displayed
    local session = lifecycle.get_session(tabpage)
    if session then
      -- Compare paths (modified_path is the full path, original_path is relative)
      if session.modified_path == abs_path or 
         (session.git_root and session.original_path == file_path) then
        -- Already showing this file, skip update
        return
      end
    end

    -- Resolve HEAD to commit hash first
    git.resolve_revision("HEAD", git_root, function(err_resolve, commit_hash)
      if err_resolve then
        vim.schedule(function()
          vim.notify(err_resolve, vim.log.levels.ERROR)
        end)
        return
      end

      -- Get file content from HEAD commit and working directory
      git.get_file_content(commit_hash, git_root, file_path, function(err_head, lines_git)
        vim.schedule(function()
          -- If file doesn't exist in HEAD (new file), use empty content
          if err_head then
            lines_git = {}
          end

          -- Read current file content
          local lines_current
          if vim.fn.filereadable(abs_path) == 1 then
            lines_current = vim.fn.readfile(abs_path)
          else
            lines_current = {}
          end

          -- Update diff view with auto-scroll to first hunk
          ---@type SessionConfig
          local session_config = {
            mode = "explorer",
            git_root = git_root,
            original_path = file_path,
            modified_path = abs_path,
            original_revision = commit_hash,
            modified_revision = nil,
          }
          view.update(tabpage, lines_git, lines_current, session_config, true)
        end)
      end)
    end)
  end
  
  -- Create split window for explorer
  local split = Split({
    relative = "editor",
    position = "left",
    size = explorer_width,
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "vscode-diff-explorer",
    },
    win_options = {
      number = false,
      relativenumber = false,
      cursorline = true,
      wrap = false,
    },
  })

  -- Mount split first to get bufnr
  split:mount()

  -- Create tree with buffer number
  local tree_data = create_tree_data(status_result, git_root)
  local tree = Tree({
    bufnr = split.bufnr,
    nodes = tree_data,
    prepare_node = prepare_node,
  })

  -- Expand all groups by default before first render
  for _, node in ipairs(tree_data) do
    if node.data and node.data.type == "group" then
      node:expand()
    end
  end

  -- Render tree
  tree:render()

  -- Keymaps
  local map_options = { noremap = true, silent = true, nowait = true }

  -- Toggle expand/collapse
  vim.keymap.set("n", "<CR>", function()
    local node = tree:get_node()
    if not node then return end

    if node.data and node.data.type == "group" then
      -- Toggle group
      if node:is_expanded() then
        node:collapse()
      else
        node:expand()
      end
      tree:render()
    else
      -- File selected
      if node.data then
        on_file_select(node.data)
      end
    end
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))

  -- Double click also works for files
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local node = tree:get_node()
    if not node or not node.data or node.data.type == "group" then return end
    on_file_select(node.data)
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))

  -- Close explorer
  vim.keymap.set("n", "q", function()
    split:unmount()
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr }))

  -- Select first file by default
  local first_file = nil
  if #status_result.unstaged > 0 then
    first_file = status_result.unstaged[1]
  elseif #status_result.staged > 0 then
    first_file = status_result.staged[1]
  end

  if first_file then
    -- Defer to allow explorer to be fully set up
    vim.defer_fn(function()
      on_file_select({
        path = first_file.path,
        status = first_file.status,
        git_root = git_root,
      })
    end, 100)
  end

  return {
    split = split,
    tree = tree,
    bufnr = split.bufnr,
    winid = split.winid,
  }
end

return M
