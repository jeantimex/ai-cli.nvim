-- Check if the Neovim version is supported (>= 0.8.0).
if vim.fn.has("nvim-0.8.0") ~= 1 then
  vim.notify("AI CLI requires Neovim >= 0.8.0", vim.log.levels.ERROR)
  return
end

-- Prevent the plugin from being loaded more than once.
if vim.g.loaded_ai_cli then
  return
end
vim.g.loaded_ai_cli = 1

--- Handle automatic setup if requested by the user.
--- Example: In your `init.lua`, you can set `vim.g.ai_cli_auto_setup = { auto_start = true }`
--- to automatically start the active CLI when Neovim loads.
if vim.g.ai_cli_auto_setup then
  vim.defer_fn(function()
    require("ai-cli").setup(vim.g.ai_cli_auto_setup)
  end, 0)
end

-- Safely load the main module.
local main_module_ok, ai_cli = pcall(require, "ai-cli")
if not main_module_ok then
  vim.notify("AI CLI: Failed to load main module. Plugin may not function correctly.", vim.log.levels.ERROR)
else
  -- Automatically call setup if it hasn't been called yet.
  -- This ensures commands are registered and the plugin is ready to use.
  if not ai_cli.state.initialized then
    ai_cli.setup()
  end
end
