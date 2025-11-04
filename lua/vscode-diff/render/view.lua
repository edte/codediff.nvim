-- Diff view creation and window management
local M = {}

local core = require('vscode-diff.render.core')
local lifecycle = require('vscode-diff.render.lifecycle')

-- Create side-by-side diff view
-- @param original_lines table: Lines from the original version
-- @param modified_lines table: Lines from the modified version
-- @param lines_diff table: Diff result from compute_diff
-- @param opts table: Optional settings
--   - right_file string: If provided, the right buffer will be linked to this file and made editable
function M.create(original_lines, modified_lines, lines_diff, opts)
  opts = opts or {}
  
  -- Create buffers
  local left_buf = vim.api.nvim_create_buf(false, true)
  local right_buf
  
  -- If right_file is provided, reuse existing buffer or create a real file buffer
  if opts.right_file then
    local existing_buf = vim.fn.bufnr(opts.right_file)
    if existing_buf ~= -1 then
      right_buf = existing_buf
    else
      right_buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(right_buf, opts.right_file)
      vim.bo[right_buf].buftype = ""
      vim.fn.bufload(right_buf)
    end
  else
    right_buf = vim.api.nvim_create_buf(false, true)
  end

  -- Set buffer options for left buffer (always read-only)
  local left_buf_opts = {
    modifiable = false,
    buftype = "nofile",
    bufhidden = "wipe",
  }

  for opt, val in pairs(left_buf_opts) do
    vim.bo[left_buf][opt] = val
  end
  
  -- Set buffer options for right buffer
  if not opts.right_file then
    local right_buf_opts = {
      modifiable = false,
      buftype = "nofile",
      bufhidden = "wipe",
    }
    for opt, val in pairs(right_buf_opts) do
      vim.bo[right_buf][opt] = val
    end
  end

  -- Temporarily make buffers modifiable for content and filler insertion
  vim.bo[left_buf].modifiable = true
  vim.bo[right_buf].modifiable = true

  -- Render diff
  local result = core.render_diff(left_buf, right_buf, original_lines, modified_lines, lines_diff, opts.right_file ~= nil)

  -- Make left buffer read-only again
  vim.bo[left_buf].modifiable = false
  
  -- Make right buffer read-only only if it's not a real file
  if not opts.right_file then
    vim.bo[right_buf].modifiable = false
  end

  -- Create side-by-side windows
  vim.cmd("tabnew")
  local initial_buf = vim.api.nvim_get_current_buf()  -- The unnamed buffer created by tabnew
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, right_buf)
  
  -- Delete the initial unnamed buffer that was created by tabnew
  -- It's not needed since we replaced it with our diff buffers
  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= left_buf and initial_buf ~= right_buf then
    pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
  end

  -- Reset both cursors to line 1 BEFORE enabling scrollbind
  vim.api.nvim_win_set_cursor(left_win, {1, 0})
  vim.api.nvim_win_set_cursor(right_win, {1, 0})

  -- Window options
  local win_opts = {
    number = true,
    relativenumber = false,
    cursorline = true,
    scrollbind = true,
    wrap = false,
  }

  for opt, val in pairs(win_opts) do
    vim.wo[left_win][opt] = val
    vim.wo[right_win][opt] = val
  end

  -- Set buffer names
  if not opts.right_file then
    local unique_id = math.random(1000000, 9999999)
    pcall(vim.api.nvim_buf_set_name, left_buf, string.format("Original_%d", unique_id))
    pcall(vim.api.nvim_buf_set_name, right_buf, string.format("Modified_%d", unique_id))
  else
    local unique_id = math.random(1000000, 9999999)
    pcall(vim.api.nvim_buf_set_name, left_buf, string.format("Original_%d", unique_id))
  end
  
  -- Enable syntax highlighting on left buffer
  -- Detect filetype from the right buffer (the actual file)
  if opts.right_file then
    -- Get filetype from right buffer (the actual file)
    local filetype = vim.bo[right_buf].filetype
    if filetype and filetype ~= "" then
      vim.bo[left_buf].filetype = filetype
    else
      -- Fallback: detect from filename
      local ft = vim.filetype.match({ filename = opts.right_file })
      if ft then
        vim.bo[left_buf].filetype = ft
      end
    end
    
    -- Apply LSP semantic tokens (async, non-blocking)
    vim.schedule(function()
      local semantic = require('vscode-diff.render.semantic')
      semantic.apply_semantic_tokens(left_buf, right_buf)
    end)
  end

  -- Register this diff view for lifecycle management
  local current_tab = vim.api.nvim_get_current_tabpage()
  lifecycle.register(current_tab, left_buf, right_buf, left_win, right_win)

  -- Auto-scroll to center the first hunk
  if #lines_diff.changes > 0 then
    local first_change = lines_diff.changes[1]
    local target_line = first_change.original.start_line
    
    vim.api.nvim_win_set_cursor(left_win, {target_line, 0})
    vim.api.nvim_win_set_cursor(right_win, {target_line, 0})
    
    vim.api.nvim_set_current_win(right_win)
    vim.cmd("normal! zz")
  end

  return {
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
    result = result,
  }
end

return M
