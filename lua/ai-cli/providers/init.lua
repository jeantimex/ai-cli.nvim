---@module 'ai-cli.providers'
--- Lightweight provider registry.
--- Shared editor UX should depend on this normalized provider contract rather than
--- on provider-specific implementation details.

local M = {}

---@class AiCliProviderLaunchContext
---@field bridge_port number|nil
---@field auth_token string|nil
---@field pid number

---@class AiCliPreparedLaunch
---@field env table
---@field defaults_path string|nil
---@field defaults_error string|nil
---@field bridge_url string|nil
---@field instructions_path string|nil

local function default_prepare_launch(provider, config, ctx)
  local defaults_path, defaults_error = nil, nil
  if type(provider.write_system_defaults) == "function" then
    defaults_path, defaults_error = provider.write_system_defaults()
  end

  local env = vim.deepcopy((config or {}).env or {})
  if type(provider.extend_env) == "function" then
    env = provider.extend_env(env, {
      bridge_port = ctx.bridge_port,
      auth_token = ctx.auth_token,
      defaults_path = defaults_path,
      pid = ctx.pid,
    })
  end

  return {
    env = env,
    defaults_path = defaults_path,
    defaults_error = defaults_error,
    bridge_url = nil,
    instructions_path = nil,
  }
end

local function default_build_argv(provider, config, _prepared_launch)
  return { provider.build_command(config) }
end

---@param name string|nil
---@return table
function M.get(name)
  local provider_name = name or "gemini"
  local provider = require("ai-cli.providers." .. provider_name)

  assert(type(provider) == "table", "Provider module must return a table")
  assert(type(provider.name) == "string" and provider.name ~= "", "Provider must define a non-empty name")

  if type(provider.build_command) ~= "function" then
    provider.build_command = function(config)
      return config.terminal_cmd or provider.name
    end
  end

  if type(provider.prepare_launch) ~= "function" then
    provider.prepare_launch = function(config, ctx)
      return default_prepare_launch(provider, config, ctx)
    end
  end

  if type(provider.build_argv) ~= "function" then
    provider.build_argv = function(config, prepared_launch)
      return default_build_argv(provider, config, prepared_launch)
    end
  end

  return provider
end

return M
