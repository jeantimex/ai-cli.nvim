---@brief Centralized logger for Gemini CLI Neovim integration.
--- This module provides level-based logging with support for different display modes.
--- - ERROR and WARN use vim.notify() for persistent alerts.
--- - INFO, DEBUG, and TRACE use nvim_echo() for less intrusive logging.
---@module 'gemini_cli.logger'
local M = {}

--- Available log levels and their numeric values.
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

-- Minimum level required for a message to be logged
local current_log_level_value = M.levels.INFO

---Initializes the logger with a specific log level from the plugin configuration.
---@param plugin_config table The configuration table (expects .log_level)
function M.setup(plugin_config)
  local conf = plugin_config

  if conf and conf.log_level and level_values[conf.log_level] then
    current_log_level_value = level_values[conf.log_level]
  else
    current_log_level_value = M.levels.INFO
  end
end

---Internal log implementation that formats and displays the message.
---@param level number Numeric log level
---@param component string|nil The module or component name for the log prefix
---@param message_parts any[] List of arguments to log (can be tables/primitives)
local function log(level, component, message_parts)
  -- Filter based on the global log level
  if level > current_log_level_value then
    return
  end

  local prefix = "[GeminiCLI]"
  if component then
    prefix = prefix .. " [" .. component .. "]"
  end

  -- Find the name of the log level for the prefix
  local level_name = "UNKNOWN"
  for name, val in pairs(M.levels) do
    if val == level then
      level_name = name
      break
    end
  end
  prefix = prefix .. " [" .. level_name .. "]"

  -- Format the message by concatenating parts and inspecting tables
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

  -- Schedule the UI update on the main thread
  vim.schedule(function()
    if level == M.levels.ERROR then
      vim.notify(prefix .. " " .. message, vim.log.levels.ERROR, { title = "GeminiCLI Error" })
    elseif level == M.levels.WARN then
      vim.notify(prefix .. " " .. message, vim.log.levels.WARN, { title = "GeminiCLI Warning" })
    else
      -- Non-critical logs are echoed to the command line to minimize disruption
      vim.api.nvim_echo({ { prefix .. " " .. message, "Normal" } }, true, {})
    end
  end)
end

---Logs an error message.
---@param component string Component name
---@param ... any Log parts
function M.error(component, ...)
  if type(component) ~= "string" then
    log(M.levels.ERROR, nil, { component, ... })
  else
    log(M.levels.ERROR, component, { ... })
  end
end

---Logs a warning message.
---@param component string Component name
---@param ... any Log parts
function M.warn(component, ...)
  if type(component) ~= "string" then
    log(M.levels.WARN, nil, { component, ... })
  else
    log(M.levels.WARN, component, { ... })
  end
end

---Logs an info message.
---@param component string Component name
---@param ... any Log parts
function M.info(component, ...)
  if type(component) ~= "string" then
    log(M.levels.INFO, nil, { component, ... })
  else
    log(M.levels.INFO, component, { ... })
  end
end

---Logs a debug message.
---@param component string Component name
---@param ... any Log parts
function M.debug(component, ...)
  if type(component) ~= "string" then
    log(M.levels.DEBUG, nil, { component, ... })
  else
    log(M.levels.DEBUG, component, { ... })
  end
end

---Logs a trace message.
---@param component string Component name
---@param ... any Log parts
function M.trace(component, ...)
  if type(component) ~= "string" then
    log(M.levels.TRACE, nil, { component, ... })
  else
    log(M.levels.TRACE, component, { ... })
  end
end

return M
