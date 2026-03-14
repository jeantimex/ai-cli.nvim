---@module 'gemini_cli'
local M = {}

local logger = require("gemini_cli.logger")
local config_module = require("gemini_cli.config")
local terminal = require("gemini_cli.terminal")

-- Module state
M.state = {
  config = config_module.defaults,
  initialized = false,
}

---Initialize the plugin
---@param user_config table|nil User configuration
function M.setup(user_config)
  M.state.config = config_module.apply(user_config)
  logger.setup(M.state.config)
  terminal.setup(M.state.config.terminal)

  M._create_commands()
  M.state.initialized = true

  logger.debug("init", "Gemini CLI initialized")
end

---Open the Gemini terminal
---@param args string|nil Optional arguments for gemini_cli
function M.open(args)
  if not M.state.initialized then
    M.setup()
  end

  local cmd = M.state.config.terminal_cmd
  if args and args ~= "" then
    cmd = cmd .. " " .. args
  end

  terminal.open(cmd, M.state.config.env, M.state.config.terminal, true)
end

---Toggle the Gemini terminal
---@param args string|nil Optional arguments for gemini_cli
function M.toggle(args)
  if not M.state.initialized then
    M.setup()
  end

  local cmd = M.state.config.terminal_cmd
  if args and args ~= "" then
    cmd = cmd .. " " .. args
  end

  terminal.toggle(cmd, M.state.config.env, M.state.config.terminal)
end

---Close the Gemini terminal
function M.close()
  terminal.close()
end

---Create user commands
function M._create_commands()
  local commands = {
    Gemini = {
      fn = function(opts)
        M.toggle(opts.args)
      end,
      opts = {
        nargs = "*",
        desc = "Toggle Gemini CLI terminal",
      },
    },
    GeminiOpen = {
      fn = function(opts)
        M.open(opts.args)
      end,
      opts = {
        nargs = "*",
        desc = "Open Gemini CLI terminal",
      },
    },
    GeminiClose = {
      fn = function()
        M.close()
      end,
      opts = {
        desc = "Close Gemini CLI terminal",
      },
    },
  }

  for name, cmd in pairs(commands) do
    vim.api.nvim_create_user_command(name, cmd.fn, cmd.opts)
  end
end

return M
