---@module 'ai-cli.providers.gemini'
--- Gemini-specific provider adapter.
--- This module owns the parts of setup that are tied to Gemini's IDE contract:
--- environment variables, the system-defaults file, and the default CLI command.

local M = {
  name = "gemini",
}

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

local function extend_env(env, ctx)
  local merged = vim.deepcopy(env or {})

  if ctx.bridge_port then
    merged.GEMINI_CLI_IDE_SERVER_PORT = tostring(ctx.bridge_port)
  end
  if ctx.pid then
    merged.GEMINI_CLI_IDE_PID = tostring(ctx.pid)
  end
  if ctx.defaults_path then
    merged.GEMINI_CLI_SYSTEM_DEFAULTS_PATH = ctx.defaults_path
  end

  return merged
end

---@param config table
---@return string
function M.build_command(config)
  return config.terminal_cmd or "gemini"
end

---@param config table
---@return string[]
function M.build_argv(config)
  return { M.build_command(config) }
end

---@param config table
---@param ctx AiCliProviderLaunchContext
---@return AiCliPreparedLaunch
function M.prepare_launch(config, ctx)
  local defaults_path, defaults_error = write_system_defaults()
  return {
    env = extend_env((config or {}).env, {
      bridge_port = ctx.bridge_port,
      auth_token = ctx.auth_token,
      defaults_path = defaults_path,
      pid = ctx.pid,
    }),
    defaults_path = defaults_path,
    defaults_error = defaults_error,
    bridge_url = nil,
    instructions_path = nil,
  }
end

return M
