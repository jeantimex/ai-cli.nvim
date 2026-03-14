---@brief Centralized logger for Gemini CLI Neovim integration.
-- Provides level-based logging.
---@module 'gemini_cli.logger'
local M = {}

M.levels = {
  ERROR = 1,
  WARN = 2,
  INFO = 3,
  DEBUG = 4,
  TRACE = 5,
}

local level_values = {
  error = M.levels.ERROR,
  warn = M.levels.WARN,
  info = M.levels.INFO,
  debug = M.levels.DEBUG,
  trace = M.levels.TRACE,
}

local current_log_level_value = M.levels.INFO

---Setup the logger module
---@param plugin_config table The configuration table.
function M.setup(plugin_config)
  local conf = plugin_config

  if conf and conf.log_level and level_values[conf.log_level] then
    current_log_level_value = level_values[conf.log_level]
  else
    current_log_level_value = M.levels.INFO
  end
end

local function log(level, component, message_parts)
  if level > current_log_level_value then
    return
  end

  local prefix = "[GeminiCLI]"
  if component then
    prefix = prefix .. " [" .. component .. "]"
  end

  local level_name = "UNKNOWN"
  for name, val in pairs(M.levels) do
    if val == level then
      level_name = name
      break
    end
  end
  prefix = prefix .. " [" .. level_name .. "]"

  local message = ""
  for i, part in ipairs(message_parts) do
    if i > 1 then
      message = message .. " "
    end
    if type(part) == "table" or type(part) == "boolean" then
      message = message .. vim.inspect(part)
    else
      message = message .. tostring(part)
    end
  end

  vim.schedule(function()
    if level == M.levels.ERROR then
      vim.notify(prefix .. " " .. message, vim.log.levels.ERROR, { title = "GeminiCLI Error" })
    elseif level == M.levels.WARN then
      vim.notify(prefix .. " " .. message, vim.log.levels.WARN, { title = "GeminiCLI Warning" })
    else
      -- For INFO, DEBUG, TRACE, use nvim_echo to avoid flooding notifications
      vim.api.nvim_echo({ { prefix .. " " .. message, "Normal" } }, true, {})
    end
  end)
end

function M.error(component, ...)
  if type(component) ~= "string" then
    log(M.levels.ERROR, nil, { component, ... })
  else
    log(M.levels.ERROR, component, { ... })
  end
end

function M.warn(component, ...)
  if type(component) ~= "string" then
    log(M.levels.WARN, nil, { component, ... })
  else
    log(M.levels.WARN, component, { ... })
  end
end

function M.info(component, ...)
  if type(component) ~= "string" then
    log(M.levels.INFO, nil, { component, ... })
  else
    log(M.levels.INFO, component, { ... })
  end
end

function M.debug(component, ...)
  if type(component) ~= "string" then
    log(M.levels.DEBUG, nil, { component, ... })
  else
    log(M.levels.DEBUG, component, { ... })
  end
end

function M.trace(component, ...)
  if type(component) ~= "string" then
    log(M.levels.TRACE, nil, { component, ... })
  else
    log(M.levels.TRACE, component, { ... })
  end
end

return M
