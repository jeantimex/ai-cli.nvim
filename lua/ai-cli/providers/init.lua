---@module 'ai-cli.providers'
--- Lightweight provider registry.
--- Gemini and Claude are supported initially, and this indirection lets the core editor UX
--- stay stable while future providers are added on separate modules.

local M = {}

---@param name string|nil
---@return table
function M.get(name)
  local provider_name = name or "gemini"
  return require("ai-cli.providers." .. provider_name)
end

return M
