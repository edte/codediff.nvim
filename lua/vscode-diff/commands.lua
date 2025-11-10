-- Command implementations for vscode-diff
local M = {}

local git = require("vscode-diff.git")

--- Handles diffing the current buffer against a given git revision.
-- @param revision string: The git revision (e.g., "HEAD", commit hash, branch name) to compare the current file against.
-- This function chains async git operations to get git root, resolve revision to hash, and get file content.
local function handle_git_diff(revision)
  local current_file = vim.api.nvim_buf_get_name(0)

  if current_file == "" then
    vim.notify("Current buffer is not a file", vim.log.levels.ERROR)
    return
  end

  -- Determine filetype from current buffer (sync operation, no git involved)
  local filetype = vim.bo[0].filetype
  if not filetype or filetype == "" then
    filetype = vim.filetype.match({ filename = current_file }) or ""
  end

  -- Async chain: get_git_root -> resolve_revision -> get_file_content -> render_diff
  git.get_git_root(current_file, function(err_root, git_root)
    if err_root then
      vim.schedule(function()
        vim.notify(err_root, vim.log.levels.ERROR)
      end)
      return
    end

    local relative_path = git.get_relative_path(current_file, git_root)

    git.resolve_revision(revision, git_root, function(err_resolve, commit_hash)
      if err_resolve then
        vim.schedule(function()
          vim.notify(err_resolve, vim.log.levels.ERROR)
        end)
        return
      end

      git.get_file_content(commit_hash, git_root, relative_path, function(err, lines_git)
        vim.schedule(function()
          if err then
            vim.notify(err, vim.log.levels.ERROR)
            return
          end

          -- Read fresh buffer content right before creating diff view
          local lines_current = vim.api.nvim_buf_get_lines(0, 0, -1, false)

          -- Create diff view
          local view = require('vscode-diff.render.view')
          ---@type SessionConfig
          local session_config = {
            mode = "standalone",
            git_root = git_root,
            original_path = relative_path,
            modified_path = relative_path,
            original_revision = commit_hash,
            modified_revision = "WORKING",
          }
          view.create(lines_git, lines_current, session_config, filetype)
        end)
      end)
    end)
  end)
end

local function handle_file_diff(file_a, file_b)
  local lines_a = vim.fn.readfile(file_a)
  local lines_b = vim.fn.readfile(file_b)

  -- Determine filetype from first file
  local filetype = vim.filetype.match({ filename = file_a }) or ""

  -- Create diff view
  local view = require('vscode-diff.render.view')
  ---@type SessionConfig
  local session_config = {
    mode = "standalone",
    git_root = nil,
    original_path = file_a,
    modified_path = file_b,
    original_revision = nil,
    modified_revision = nil,
  }
  view.create(lines_a, lines_b, session_config, filetype)
end

function M.vscode_diff(opts)
  local args = opts.fargs

  if #args == 0 then
    vim.notify("TODO: File explorer not implemented yet. Usage: :CodeDiff file <revision> OR :CodeDiff file <file_a> <file_b>", vim.log.levels.WARN)
    return
  end

  local subcommand = args[1]

  if subcommand == "file" then
    if #args == 2 then
      -- :CodeDiff file HEAD
      handle_git_diff(args[2])
    elseif #args == 3 then
      -- :CodeDiff file file_a.txt file_b.txt
      handle_file_diff(args[2], args[3])
    else
      vim.notify("Usage: :CodeDiff file <revision> OR :CodeDiff file <file_a> <file_b>", vim.log.levels.ERROR)
    end
  elseif subcommand == "install" or subcommand == "install!" then
    -- :CodeDiff install or :CodeDiff install!
    -- Handle both :CodeDiff! install and :CodeDiff install!
    local force = opts.bang or subcommand == "install!"
    local installer = require("vscode-diff.installer")
    
    if force then
      vim.notify("Reinstalling libvscode-diff...", vim.log.levels.INFO)
    end
    
    local success, err = installer.install({ force = force, silent = false })
    
    if success then
      vim.notify("libvscode-diff installation successful!", vim.log.levels.INFO)
    else
      vim.notify("Installation failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    end
  else
    -- :CodeDiff without "file" is reserved for explorer mode (not implemented yet)
    vim.notify("TODO: Explorer mode not implemented. Use :CodeDiff file <revision> for now", vim.log.levels.WARN)
  end
end

return M
