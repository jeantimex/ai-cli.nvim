---@module 'ai-cli.providers.gemini'
--- Gemini-specific provider adapter.
--- This module owns the parts of setup that are tied to Gemini's IDE contract:
--- environment variables, the system-defaults file, and the default CLI command.

local M = {
  name = "gemini",
}

---Write Gemini's IDE-mode defaults file.
---@return string|nil path
---@return string|nil error
function M.write_system_defaults()
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

---@param config table
---@return string
function M.build_command(config)
  return config.terminal_cmd or "gemini"
end

---@param env table
---@param ctx table
---@return table
function M.extend_env(env, ctx)
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

return M
