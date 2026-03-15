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

---@type table active terminal configuration
local config = nil

---Sets the base configuration for terminal management.
function M.setup(term_config)
  config = term_config
end

---Resets internal state variables.
local function cleanup_state()
  bufnr = nil
  winid = nil
  jobid = nil
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
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
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
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local windows = vim.api.nvim_list_wins()
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      winid = win
      return true
    end
  end

  winid = nil
  return false
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
    if not winid or not vim.api.nvim_win_is_valid(winid) then
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

  local term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = true })

  local term_opts = {
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        if job_id == jobid then
          logger.debug("terminal", "Terminal process exited")
          local current_winid = winid
          local current_bufnr = bufnr
          cleanup_state()

          -- Optionally close the window when the process finishes
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
  bufnr = vim.api.nvim_get_current_buf()
  -- Prevent the buffer from being deleted when the window is closed
  vim.bo[bufnr].bufhidden = "hide"

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
