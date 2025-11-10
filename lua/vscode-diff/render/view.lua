-- Diff view creation and window management
local M = {}

local core = require('vscode-diff.render.core')
local lifecycle = require('vscode-diff.render.lifecycle')
local semantic = require('vscode-diff.render.semantic_tokens')
local virtual_file = require('vscode-diff.virtual_file')
local auto_refresh = require('vscode-diff.auto_refresh')
local config = require('vscode-diff.config')
local diff_module = require('vscode-diff.diff')

-- Helper: Check if revision is virtual (commit hash or STAGED)
-- Virtual: "STAGED" or commit hash | Real: nil or "WORKING"
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Create a buffer for virtual file (git revision) or real file
local function create_buffer(is_virtual, git_root, revision, path)
  if is_virtual then
    -- Virtual file: URL is returned, buffer created by :edit command
    local virtual_url = virtual_file.create_url(git_root, revision, path)
    return nil, virtual_url
  else
    -- Real file: reuse existing buffer or create new one
    local existing_buf = vim.fn.bufnr(path)
    if existing_buf ~= -1 then
      return existing_buf, nil
    else
      -- For real files, we should use :edit to properly load the file
      -- This ensures filetype detection, no modification flag, etc.
      return nil, path
    end
  end
end

---@class SessionConfig
---@field mode "standalone"|"explorer"
---@field git_root string?
---@field original_path string
---@field modified_path string
---@field original_revision string?
---@field modified_revision string?

---Create side-by-side diff view
---@param original_lines string[] Lines from the original version
---@param modified_lines string[] Lines from the modified version
---@param session_config SessionConfig Session configuration
---@param filetype? string Optional filetype for syntax highlighting
---@return table|nil Result containing diff metadata, or nil if deferred
function M.create(original_lines, modified_lines, session_config, filetype)
  -- Compute diff
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
  }
  local lines_diff = diff_module.compute_diff(original_lines, modified_lines, diff_options)
  if not lines_diff then
    vim.notify("Failed to compute diff", vim.log.levels.ERROR)
    return nil
  end
  -- Create new tab for standalone mode
  if session_config.mode == "standalone" then
    vim.cmd("tabnew")
  end
  
  local tabpage = vim.api.nvim_get_current_tabpage()
  
  -- Create lifecycle session with git context
  lifecycle.create_session(
    tabpage,
    session_config.mode,
    session_config.git_root,
    session_config.original_path,
    session_config.modified_path,
    session_config.original_revision,
    session_config.modified_revision
  )

  -- Determine if buffers are virtual based on revisions
  local original_is_virtual = is_virtual_revision(session_config.original_revision)
  local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

  -- Create buffers based on revisions
  local original_buf, original_url = create_buffer(
    original_is_virtual,
    session_config.git_root,
    session_config.original_revision,
    session_config.original_path
  )
  local modified_buf, modified_url = create_buffer(
    modified_is_virtual,
    session_config.git_root,
    session_config.modified_revision,
    session_config.modified_path
  )

  -- Determine if we need to use :edit command (for virtual files or new real files)
  local original_needs_edit = (original_url ~= nil)
  local modified_needs_edit = (modified_url ~= nil)

  -- Determine if we need to wait for virtual file content to load
  local has_virtual_buffer = original_is_virtual or modified_is_virtual

  -- Create side-by-side windows in CURRENT tab (caller should have created new tab if needed)
  local initial_buf = vim.api.nvim_get_current_buf()
  local original_win = vim.api.nvim_get_current_win()

  -- Set original buffer/window
  if original_needs_edit then
    vim.cmd("edit " .. vim.fn.fnameescape(original_url))
    original_buf = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(original_win, original_buf)
  end

  vim.cmd("vsplit")
  local modified_win = vim.api.nvim_get_current_win()

  -- Set modified buffer/window
  if modified_needs_edit then
    vim.cmd("edit " .. vim.fn.fnameescape(modified_url))
    modified_buf = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(modified_win, modified_buf)
  end

  -- Clean up initial buffer
  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= original_buf and initial_buf ~= modified_buf then
    pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
  end

  -- Reset both cursors to line 1 BEFORE enabling scrollbind
  vim.api.nvim_win_set_cursor(original_win, {1, 0})
  vim.api.nvim_win_set_cursor(modified_win, {1, 0})

  -- Window options
  local win_opts = {
    number = true,
    relativenumber = false,
    cursorline = true,
    scrollbind = true,
    wrap = false,
    winbar = "",  -- Disable winbar to ensure alignment between windows
  }

  for opt, val in pairs(win_opts) do
    vim.wo[original_win][opt] = val
    vim.wo[modified_win][opt] = val
  end

  -- Note: Filetype is automatically detected when using :edit for real files
  -- For virtual files, filetype is set in the virtual_file module

  -- Complete lifecycle session with buffer/window info
  -- Session metadata was already created by commands.lua
  lifecycle.complete_session(tabpage, original_buf, modified_buf, original_win, modified_win, lines_diff)

  -- Set up rendering after buffers are ready
  -- For virtual files, we wait for VscodeDiffVirtualFileLoaded event
  -- Unified rendering function - executes everything once buffers are ready
  local render_everything = function()
    -- Render diff highlights (content must already be in buffers)
    core.render_diff(original_buf, modified_buf, original_lines, modified_lines, lines_diff)

    -- Apply semantic tokens for virtual buffers
    if original_is_virtual then
      semantic.apply_semantic_tokens(original_buf, modified_buf)
    end
    if modified_is_virtual then
      semantic.apply_semantic_tokens(modified_buf, original_buf)
    end

    -- Auto-scroll to first change
    if #lines_diff.changes > 0 then
      local first_change = lines_diff.changes[1]
      local target_line = first_change.original.start_line

      pcall(vim.api.nvim_win_set_cursor, original_win, {target_line, 0})
      pcall(vim.api.nvim_win_set_cursor, modified_win, {target_line, 0})

      if vim.api.nvim_win_is_valid(modified_win) then
        vim.api.nvim_set_current_win(modified_win)
        vim.cmd("normal! zz")
      end
    end

    -- Enable auto-refresh for real file buffers only
    if not original_is_virtual then
      auto_refresh.enable(original_buf)
    end
    
    if not modified_is_virtual then
      auto_refresh.enable(modified_buf)
    end
  end

  -- Choose timing based on buffer types
  if has_virtual_buffer then
    -- Virtual file(s): Wait for BufReadCmd to load content
    local trigger_buf = original_is_virtual and original_buf or modified_buf
    local group = vim.api.nvim_create_augroup('VscodeDiffVirtualFileHighlight_' .. trigger_buf, { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if event.data and event.data.buf == trigger_buf then
          vim.schedule(render_everything)
          vim.api.nvim_del_augroup_by_id(group)
        end
      end,
    })
  else
    -- Real files only: Defer until :edit completes
    vim.schedule(render_everything)
  end

  return {
    original_buf = original_buf,
    modified_buf = modified_buf,
    original_win = original_win,
    modified_win = modified_win,
  }
end

return M
