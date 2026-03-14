if vim.fn.has("nvim-0.8.0") ~= 1 then
  vim.api.nvim_err_writeln("Gemini CLI requires Neovim >= 0.8.0")
  return
end

if vim.g.loaded_gemini_cli then
  return
end
vim.g.loaded_gemini_cli = 1

--- Example: In your `init.lua`, you can set `vim.g.gemini_cli_auto_setup = { auto_start = true }`
--- to automatically start Gemini CLI when Neovim loads.
if vim.g.gemini_cli_auto_setup then
  vim.defer_fn(function()
    require("gemini_cli").setup(vim.g.gemini_cli_auto_setup)
  end, 0)
end

local main_module_ok, gemini_cli = pcall(require, "gemini_cli")
if not main_module_ok then
  vim.notify("Gemini CLI: Failed to load main module. Plugin may not function correctly.", vim.log.levels.ERROR)
else
  -- Automatically call setup if it hasn't been called yet
  -- This ensures commands are registered.
  if not gemini_cli.state.initialized then
    gemini_cli.setup()
  end
end
