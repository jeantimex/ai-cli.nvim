---@module 'ai-cli.providers.claude'
--- Claude-specific provider adapter.
--- This first pass focuses on terminal integration and command selection.
--- Claude can share the core terminal and diff UI, but automatic IDE bridge
--- wiring should only be added once its MCP contract is wired explicitly.

local M = {
  name = "claude",
}

local function read_json_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()
  if not content or content == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  return decoded
end

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

---@param _config table
---@param ctx table
---@return boolean success
---@return string|nil error
function M.prepare_workspace(_config, ctx)
  if not ctx.bridge_port or not ctx.auth_token then
    return false, "Claude MCP setup requires a running local bridge"
  end

  local root = vim.uv.cwd() or vim.fn.getcwd()
  local path = vim.fs.joinpath(root, ".mcp.json")
  local config = read_json_file(path) or {}
  config.mcpServers = config.mcpServers or {}
  config.mcpServers["ai-cli"] = {
    type = "http",
    url = string.format("http://127.0.0.1:%d/mcp", ctx.bridge_port),
    headers = {
      Authorization = "Bearer " .. ctx.auth_token,
    },
  }

  local file, err = io.open(path, "w")
  if not file then
    return false, err or "Failed to write Claude MCP config"
  end

  file:write(vim.json.encode(config))
  file:close()
  return true
end

return M
