---@module 'gemini_cli.terminal'
--- Manages the Gemini CLI terminal buffer and window.
--- This module handles creating the terminal split, managing its visibility,
--- and tracking the terminal process lifecycle.
local M = {}

local logger = require("gemini_cli.logger")
local utils = require("gemini_cli.utils")

-- Buffer number of the terminal
local bufnr = nil
-- Window ID where the terminal is currently displayed
local winid = nil
-- Job ID of the terminal process (returned by termopen)
local jobid = nil

---@type table|nil Active terminal configuration
local config = nil
-- Callback function triggered when there is terminal activity (output)
local activity_handler = nil
-- Autocmd group ID for terminal-related events
local terminal_group = nil

---Sets the base configuration for terminal management.
---@param term_config table The configuration table
function M.setup(term_config)
  config = term_config
end

---Sets the handler to be called when activity is detected in the terminal.
---@param handler function The callback function
function M.set_activity_handler(handler)
  activity_handler = handler
end

---Notifies the activity handler that something happened in the terminal.
---Used to trigger UI updates or notifications.
local function notify_activity()
  if not activity_handler then
    return
  end

  local ok, err = pcall(activity_handler)
  if not ok then
    logger.warn("terminal", "Activity handler failed:", err)
  end
end

---Formats a numeric color value into a hex string (e.g., #RRGGBB).
---@param color number|nil The color as an integer
---@return string|nil The formatted hex string or nil if input is invalid
local function format_hex_color(color)
  if type(color) ~= "number" then
    return nil
  end

  return string.format("#%06x", color)
end

---Retrieves the background color of the 'Normal' highlight group.
---@return string|nil The hex color string or nil if not found
local function get_normal_background()
  local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if not ok or not normal then
    return nil
  end

  return format_hex_color(normal.bg)
end

---Applies consistent window styling to the terminal window.
---Sets 'winhighlight' to ensure the terminal looks integrated.
---@param target_win number The window ID to style
local function apply_terminal_window_style(target_win)
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return
  end

  vim.wo[target_win].winhighlight = "Normal:Normal,NormalNC:Normal,EndOfBuffer:Normal,SignColumn:Normal"
end

---Synchronizes terminal color palette with the editor's background.
---Sets terminal_color_0 and terminal_color_8 to match the 'Normal' bg.
---@param target_buf number The buffer ID to apply colors to
local function apply_terminal_palette(target_buf)
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    return
  end

  local background = get_normal_background()
  if not background then
    return
  end

  vim.api.nvim_buf_set_var(target_buf, "terminal_color_0", background)
  vim.api.nvim_buf_set_var(target_buf, "terminal_color_8", background)
end

---Configures buffer-local options for the terminal.
---Sets name, filetype, and hides it from the buffer list.
---@param target_buf number The buffer ID to configure
local function configure_terminal_buffer(target_buf)
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    return
  end

  pcall(vim.api.nvim_buf_set_name, target_buf, "gemini://cli")
  vim.bo[target_buf].buflisted = false
  vim.bo[target_buf].bufhidden = "hide"
  vim.bo[target_buf].filetype = "gemini-cli"
  vim.bo[target_buf].swapfile = false
end

---Resets internal state variables and cleans up autocommands.
local function cleanup_state()
  if terminal_group then
    pcall(vim.api.nvim_del_augroup_by_id, terminal_group)
    terminal_group = nil
  end
  bufnr = nil
  winid = nil
  jobid = nil
end

---Searches for all windows displaying the terminal buffer.
---@param current_tab_only boolean If true, only look in the current tabpage
---@return number[] A list of window IDs
local function find_terminal_windows(current_tab_only)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local wins = current_tab_only and vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage()) or vim.api.nvim_list_wins()
  local matches = {}

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      table.insert(matches, win)
    end
  end

  return matches
end

---Ensures only one terminal window exists and updates the tracked winid.
---Closes redundant windows and applies styling to the remaining one.
---@param preferred_win number|nil A window ID that should be kept if possible
---@return number|nil The ID of the window that was kept
local function normalize_terminal_windows(preferred_win)
  local wins = find_terminal_windows(true)
  if #wins == 0 then
    return nil
  end

  local keep = nil
  if preferred_win and vim.api.nvim_win_is_valid(preferred_win) and vim.api.nvim_win_get_buf(preferred_win) == bufnr then
    keep = preferred_win
  elseif winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    keep = winid
  else
    keep = wins[1]
  end

  for _, win in ipairs(wins) do
    if win ~= keep and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end

  winid = keep
  apply_terminal_window_style(keep)
  return keep
end

---Checks if the terminal buffer is still valid and optionally updates the window ID.
---@return boolean true if the terminal buffer exists and is valid
local function is_valid()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    cleanup_state()
    return false
  end

  if not winid or not vim.api.nvim_win_is_valid(winid) then
    -- Try to find if the buffer is visible in any window
    for _, win in ipairs(find_terminal_windows(false)) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        winid = win
        return true
      end
    end
    -- Buffer exists but is hidden
    return true
  end

  return true
end

---Checks if the terminal window is currently visible in the current tab.
---@return boolean visible
local function is_terminal_visible()
  return normalize_terminal_windows() ~= nil
end

---Moves focus to the terminal window and enters insert mode.
local function focus_terminal()
  if is_valid() then
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  end
end

---Hides the terminal window if it's currently open.
local function hide_terminal()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, false)
    winid = nil
    logger.debug("terminal", "Terminal window hidden")
  end
end

---Re-opens a hidden terminal buffer in a new split.
---@param effective_config table Configuration for split side and width
---@param focus boolean Whether to focus the window after opening
---@return boolean success
local function show_hidden_terminal(effective_config, focus)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if is_terminal_visible() then
    if focus then
      focus_terminal()
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local placement_modifier = effective_config.split_side == "left" and "topleft " or "botright "

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_winid, bufnr)
  winid = new_winid
  apply_terminal_window_style(new_winid)

  if focus then
    focus_terminal()
  else
    vim.api.nvim_set_current_win(original_win)
  end

  return true
end

---Opens the Gemini terminal. Creates a new process if none is running.
---@param cmd_string string The command to run (e.g., "gemini")
---@param env_table table Environment variables for the process
---@param effective_config table Window layout configuration
---@param focus boolean Whether to focus the terminal immediately
function M.open(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  -- If terminal already exists, just ensure it's visible
  if is_valid() then
    if not is_terminal_visible() then
      show_hidden_terminal(effective_config, focus)
    else
      if focus then
        focus_terminal()
      end
    end
    return
  end

  local original_win = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local placement_modifier = effective_config.split_side == "left" and "topleft " or "botright "

  -- Create the split and a new empty buffer
  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.cmd("enew")
  local new_bufnr = vim.api.nvim_get_current_buf()
  apply_terminal_window_style(new_winid)
  apply_terminal_palette(new_bufnr)

  local term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = true })

  local term_opts = {
    on_stdout = function()
      -- Notify about terminal activity on standard output
      vim.schedule(notify_activity)
    end,
    on_stderr = function()
      -- Notify about terminal activity on standard error
      vim.schedule(notify_activity)
    end,
    on_exit = function(job_id, _, _)
      -- Handle terminal process termination
      vim.schedule(function()
        if job_id == jobid then
          logger.debug("terminal", "Terminal process exited")
          local current_winid = winid
          local current_bufnr = bufnr
          cleanup_state()

          -- Optionally close the window when the process finishes if auto_close is enabled
          if effective_config.auto_close and current_winid and vim.api.nvim_win_is_valid(current_winid) then
            if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
              if vim.api.nvim_win_get_buf(current_winid) == current_bufnr then
                vim.api.nvim_win_close(current_winid, true)
              end
            else
              vim.api.nvim_win_close(current_winid, true)
            end
          end
        end
      end)
    end,
  }

  if env_table and next(env_table) then
    term_opts.env = env_table
  end

  -- Start the terminal process
  jobid = vim.fn.termopen(term_cmd_arg, term_opts)

  if not jobid or jobid <= 0 then
    vim.notify("Failed to open Gemini terminal.", vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    cleanup_state()
    return
  end

  winid = new_winid
  bufnr = new_bufnr
  configure_terminal_buffer(bufnr)

  terminal_group = vim.api.nvim_create_augroup("GeminiTerminalWindow", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "TabEnter", "WinEnter" }, {
    group = terminal_group,
    callback = function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        normalize_terminal_windows(vim.api.nvim_get_current_win())
      end
    end,
  })

  if focus then
    focus_terminal()
  else
    vim.api.nvim_set_current_win(original_win)
  end
end

---Toggles the visibility of the Gemini terminal.
---@param cmd_string string Command to run
---@param env_table table Environment variables
---@param effective_config table Layout configuration
function M.toggle(cmd_string, env_table, effective_config)
  local has_buffer = bufnr and vim.api.nvim_buf_is_valid(bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if is_visible then
    local current_win_id = vim.api.nvim_get_current_win()
    if winid == current_win_id then
      -- If already focused, hide it
      hide_terminal()
    else
      -- If visible but not focused, focus it
      focus_terminal()
    end
  else
    if has_buffer then
      -- Show the existing buffer
      show_hidden_terminal(effective_config, true)
    else
      -- Start a new terminal process
      M.open(cmd_string, env_table, effective_config, true)
    end
  end
end

---Closes the terminal window and resets state.
function M.close()
  if is_valid() and winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
    cleanup_state()
  end
end

return M
