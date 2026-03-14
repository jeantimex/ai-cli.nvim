---@module 'gemini_cli.terminal'
local M = {}

local logger = require("gemini_cli.logger")
local utils = require("gemini_cli.utils")

local bufnr = nil
local winid = nil
local jobid = nil

---@type table
local config = nil

function M.setup(term_config)
  config = term_config
end

local function cleanup_state()
  bufnr = nil
  winid = nil
  jobid = nil
end

local function is_valid()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    cleanup_state()
    return false
  end

  if not winid or not vim.api.nvim_win_is_valid(winid) then
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        winid = win
        return true
      end
    end
    return true
  end

  return true
end

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

local function focus_terminal()
  if is_valid() then
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  end
end

local function hide_terminal()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, false)
    winid = nil
    logger.debug("terminal", "Terminal window hidden")
  end
end

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

function M.open(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

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
  vim.bo[bufnr].bufhidden = "hide"

  if focus then
    focus_terminal()
  else
    vim.api.nvim_set_current_win(original_win)
  end
end

function M.toggle(cmd_string, env_table, effective_config)
  local has_buffer = bufnr and vim.api.nvim_buf_is_valid(bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if is_visible then
    local current_win_id = vim.api.nvim_get_current_win()
    if winid == current_win_id then
      hide_terminal()
    else
      focus_terminal()
    end
  else
    if has_buffer then
      show_hidden_terminal(effective_config, true)
    else
      M.open(cmd_string, env_table, effective_config, true)
    end
  end
end

function M.close()
  if is_valid() and winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
    cleanup_state()
  end
end

return M
