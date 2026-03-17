---@module 'ai-cli.providers.claude'
--- Claude-specific provider adapter.
--- This first pass focuses on terminal integration and command selection.
--- Claude can share the core terminal and diff UI, but automatic IDE bridge
--- wiring should only be added once its MCP contract is wired explicitly.

local M = {
  name = "claude",
}

---@return nil
function M.write_system_defaults()
  return nil
end

---@param config table
---@return string
function M.build_command(config)
  return config.terminal_cmd or "claude"
end

---@param env table
---@return table
function M.extend_env(env)
  return vim.deepcopy(env or {})
end

return M
