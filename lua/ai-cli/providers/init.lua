---@module 'ai-cli.providers'
--- Lightweight provider registry.
--- For now only Gemini exists, but this indirection lets the core editor UX
--- stay stable while future providers are added on separate modules.

local M = {}

---@param name string|nil
---@return table
function M.get(name)
  local provider_name = name or "gemini"
  return require("ai-cli.providers." .. provider_name)
end

return M
