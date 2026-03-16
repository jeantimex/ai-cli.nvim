local M = {}

---Normalize focus argument
---@param focus boolean|nil
---@return boolean
function M.normalize_focus(focus)
  if focus == nil then
    return true
  end
  return focus
end

return M
