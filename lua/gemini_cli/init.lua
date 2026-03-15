---@module 'gemini_cli'
local M = {}

local logger = require("gemini_cli.logger")
local config_module = require("gemini_cli.config")
local terminal = require("gemini_cli.terminal")

local server = require("gemini_cli.server")
local diff = require("gemini_cli.diff")

local defaults_path = nil

local function write_system_defaults()
  local path = vim.fs.joinpath(vim.uv.os_tmpdir(), "gemini-cli.nvim-system-defaults.json")
  local file = io.open(path, "w")
  if not file then
    return nil, "Failed to create Gemini system-defaults file"
  end

  file:write(vim.json.encode({
    ide = {
      enabled = true,
    },
  }))
  file:close()
  return path
end

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
  diff.setup(M.state.config)

  -- Start the bridge server for code edits
  local ok, bridge_port = server.start()
  if ok and bridge_port then
    M.state.config.env.GEMINI_CLI_IDE_SERVER_PORT = tostring(bridge_port)
    M.state.config.env.GEMINI_CLI_IDE_PID = tostring(vim.fn.getpid())
    M.state.config.env.TERM_PROGRAM = "vscode"
    diff.set_event_handler(server.notify)
  else
    logger.warn("init", "Gemini IDE bridge failed to start:", bridge_port)
  end

  defaults_path = defaults_path or write_system_defaults()
  if defaults_path then
    M.state.config.env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH = defaults_path
  else
    logger.warn("init", "Gemini IDE defaults file could not be created.")
  end

  -- Set environment variables to let gemini_cli know it's in Neovim
  M.state.config.env.NVIM = vim.v.servername
  M.state.config.env.EDITOR = "nvim"

  -- Auto-reload files changed by Gemini CLI
  vim.o.autoread = true
  vim.api.nvim_create_autocmd({ "BufEnter", "CursorHold", "CursorHoldI", "FocusGained" }, {
    group = vim.api.nvim_create_augroup("GeminiAutoread", { clear = true }),
    callback = function()
      if vim.fn.mode() ~= "c" then
        vim.cmd("checktime")
      end
    end,
  })

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

---Add current file to Gemini context
function M.add_current_file()
  local file_path = vim.fn.expand("%:p")
  if file_path == "" then
    logger.error("command", "No file in current buffer")
    return
  end

  logger.info("command", "To add this file, type: /add " .. file_path .. " in the Gemini terminal")
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
    GeminiAdd = {
      fn = function()
        M.add_current_file()
      end,
      opts = {
        desc = "Add current file to Gemini context",
      },
    },
    GeminiRefresh = {
      fn = function()
        vim.cmd("checktime")
        logger.info("command", "Buffer reloaded from disk.")
      end,
      opts = {
        desc = "Manually refresh the current buffer from disk.",
      },
    },
  }

  for name, cmd in pairs(commands) do
    vim.api.nvim_create_user_command(name, cmd.fn, cmd.opts)
  end
end

return M
