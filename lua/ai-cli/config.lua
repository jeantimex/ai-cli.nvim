---@brief Manages configuration for the Gemini CLI Neovim integration.
--- This module handles the default settings, validation of user overrides,
--- and merging user configuration into the active state.
---@module 'ai-cli.config'

local M = {}

---@class GeminiConfig
---@field provider string Provider adapter name. Defaults to "gemini".
---@field auto_start boolean Whether to automatically start the bridge server (currently unused in init)
---@field terminal_cmd string The shell command used to launch the Gemini CLI
---@field env table Environment variables to inject into the Gemini terminal process
---@field log_level "trace"|"debug"|"info"|"warn"|"error" Minimum level for logging
---@field terminal GeminiTerminalConfig Terminal window settings
---@field diff GeminiDiffConfig Diff review settings

---@class GeminiTerminalConfig
---@field split_side "left"|"right" Which side of the screen to open the terminal on
---@field split_width_percentage number Width of the terminal split (0.0 to 1.0)
---@field auto_close boolean Whether to close the terminal window when the process exits

---@class GeminiDiffConfig
---@field accept_key string Keybinding to apply changes in diff view
---@field reject_key string Keybinding to reject changes in diff view

--- Default configuration values
---@type GeminiConfig
M.defaults = {
  provider = "gemini",
  auto_start = true,
  terminal_cmd = "gemini",
  env = {},
  log_level = "info",
  terminal = {
    split_side = "right",
    split_width_percentage = 0.4,
    auto_close = true,
  },
  diff = {
    accept_key = "ga",
    reject_key = "gr",
  },
}

---Validates the provided configuration table against the expected schema.
---Throws an error if any required field is missing or has an invalid type.
---@param config table The configuration table to validate.
---@return boolean true if the configuration is valid.
function M.validate(config)
  assert(type(config.provider) == "string" and config.provider ~= "", "provider must be a non-empty string")
  assert(type(config.auto_start) == "boolean", "auto_start must be a boolean")
  assert(type(config.terminal_cmd) == "string", "terminal_cmd must be a string")
  assert(type(config.env) == "table", "env must be a table")

  local valid_log_levels = { "trace", "debug", "info", "warn", "error" }
  local is_valid_log_level = false
  for _, level in ipairs(valid_log_levels) do
    if config.log_level == level then
      is_valid_log_level = true
      break
    end
  end
  assert(is_valid_log_level, "log_level must be one of: " .. table.concat(valid_log_levels, ", "))

  assert(type(config.terminal) == "table", "terminal must be a table")
  assert(
    config.terminal.split_side == "left" or config.terminal.split_side == "right",
    "terminal.split_side must be 'left' or 'right'"
  )
  assert(
    type(config.terminal.split_width_percentage) == "number"
      and config.terminal.split_width_percentage > 0
      and config.terminal.split_width_percentage < 1,
    "terminal.split_width_percentage must be a number between 0 and 1"
  )
  assert(type(config.terminal.auto_close) == "boolean", "terminal.auto_close must be a boolean")

  assert(type(config.diff) == "table", "diff must be a table")
  assert(type(config.diff.accept_key) == "string", "diff.accept_key must be a string")
  assert(type(config.diff.reject_key) == "string", "diff.reject_key must be a string")

  return true
end

---Applies user configuration on top of default settings.
---Uses a deep merge to ensure nested tables like `terminal` are correctly updated.
---@param user_config table|nil The user-provided configuration table.
---@return table config The final, validated configuration table.
function M.apply(user_config)
  local config = vim.deepcopy(M.defaults)

  if user_config then
    config = vim.tbl_deep_extend("force", config, user_config)
  end

  M.validate(config)

  return config
end

return M
