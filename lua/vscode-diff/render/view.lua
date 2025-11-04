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
--   - git_revision string: If provided (e.g., "HEAD"), creates a virtual file URL for LSP
--   - git_root string: Required if git_revision is provided
function M.create(original_lines, modified_lines, lines_diff, opts)
  opts = opts or {}
  
  -- Create left buffer - use virtual file URL if this is a git diff
  local left_buf
  local is_virtual_file = opts.git_revision and opts.git_root and opts.right_file
  local virtual_url = nil
  
  if is_virtual_file then
    -- Create a virtual file URL that LSP can attach to
    local virtual_file = require('vscode-diff.virtual_file')
    local relative_path = opts.right_file:gsub('^' .. vim.pesc(opts.git_root .. '/'), '')
    virtual_url = virtual_file.create_url(opts.git_root, opts.git_revision, relative_path)
    
    -- Don't create buffer here - let :edit create it and trigger BufReadCmd
    left_buf = nil
  else
    -- Fallback to scratch buffer
    left_buf = vim.api.nvim_create_buf(false, true)
    
    -- Set buffer options for scratch buffer
    vim.bo[left_buf].modifiable = false
    vim.bo[left_buf].buftype = "nofile"
    vim.bo[left_buf].bufhidden = "wipe"
  end
  
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

  -- For virtual file URLs, buffer options are set by BufReadCmd
  -- For scratch buffers, we set them here
  if not (opts.git_revision and opts.git_root) then
    vim.bo[left_buf].modifiable = false
    vim.bo[left_buf].buftype = "nofile"
    vim.bo[left_buf].bufhidden = "wipe"
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
  if not is_virtual_file then
    vim.bo[left_buf].modifiable = true
  end
  vim.bo[right_buf].modifiable = true

  -- For non-virtual files, render diff now
  -- For virtual files, we'll render after content loads
  local result
  if not is_virtual_file then
    result = core.render_diff(left_buf, right_buf, original_lines, modified_lines, lines_diff, opts.right_file ~= nil, false)
    
    -- Make left buffer read-only again
    vim.bo[left_buf].modifiable = false
  end
  
  -- Make right buffer read-only only if it's not a real file
  if not opts.right_file then
    vim.bo[right_buf].modifiable = false
  end

  -- Create side-by-side windows
  vim.cmd("tabnew")
  local initial_buf = vim.api.nvim_get_current_buf()  -- The unnamed buffer created by tabnew
  local left_win = vim.api.nvim_get_current_win()
  
  -- For virtual files, use :edit to trigger BufReadCmd
  if is_virtual_file then
    -- :edit will create the buffer and trigger BufReadCmd autocmd
    vim.cmd("edit " .. vim.fn.fnameescape(virtual_url))
    left_buf = vim.api.nvim_get_current_buf()  -- Get the buffer created by :edit
  else
    vim.api.nvim_win_set_buf(left_win, left_buf)
  end

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
  -- For virtual files, don't rename (they already have the vscodediff:// URL)
  if not is_virtual_file then
    if not opts.right_file then
      local unique_id = math.random(1000000, 9999999)
      pcall(vim.api.nvim_buf_set_name, left_buf, string.format("Original_%d", unique_id))
      pcall(vim.api.nvim_buf_set_name, right_buf, string.format("Modified_%d", unique_id))
    else
      local unique_id = math.random(1000000, 9999999)
      pcall(vim.api.nvim_buf_set_name, left_buf, string.format("Original_%d", unique_id))
    end
  end
  
  -- Enable syntax highlighting on left buffer (for non-virtual files only)
  -- Virtual files get filetype set in BufReadCmd
  if not is_virtual_file and opts.right_file then
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
  end

  -- Register this diff view for lifecycle management
  local current_tab = vim.api.nvim_get_current_tabpage()
  lifecycle.register(current_tab, left_buf, right_buf, left_win, right_win)
  
  -- For virtual files, set up autocmd to apply diff highlights after content loads
  if is_virtual_file then
    local group = vim.api.nvim_create_augroup('VscodeDiffVirtualFileHighlight_' .. left_buf, { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if event.data and event.data.buf == left_buf then
          vim.schedule(function()
            -- Now apply diff highlights
            result = core.render_diff(left_buf, right_buf, original_lines, modified_lines, lines_diff, opts.right_file ~= nil, true)
            
            -- Request semantic tokens from right buffer's LSP for left buffer
            vim.schedule(function()
              local semantic = require('vscode-diff.render.semantic')
              semantic.apply_semantic_tokens(left_buf, right_buf)
            end)
            
            -- Auto-scroll to first hunk
            if #lines_diff.changes > 0 then
              local first_change = lines_diff.changes[1]
              local target_line = first_change.original.start_line
              
              pcall(vim.api.nvim_win_set_cursor, left_win, {target_line, 0})
              pcall(vim.api.nvim_win_set_cursor, right_win, {target_line, 0})
              
              if vim.api.nvim_win_is_valid(right_win) then
                vim.api.nvim_set_current_win(right_win)
                vim.cmd("normal! zz")
              end
            end
            
            -- Clean up the autocmd
            vim.api.nvim_del_augroup_by_id(group)
          end)
        end
      end,
    })
  end

  -- Auto-scroll to center the first hunk
  -- For virtual files, skip for now (will be done after content loads)
  if #lines_diff.changes > 0 and not is_virtual_file then
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
