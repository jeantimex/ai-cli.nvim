---@module 'ai-cli.diff'
--- Manages the lifecycle of code diffs proposed by the active provider.
--- This includes rendering unified diffs in a temporary buffer,
--- handling user acceptance/rejection, and auto-applying changes to disk.
local M = {}
local logger = require("ai-cli.logger")

-- Compat shim: vim.diff was renamed to vim.text.diff in Neovim 0.12
local vim_diff = (vim.text and vim.text.diff) or vim.diff

-- Tracks diffs that are currently being reviewed in a window.
-- Keyed by normalized absolute file path.
local active_diffs = {}

-- Tracks diffs that have been proposed but haven't been opened yet
-- (e.g., because the target file isn't loaded in a buffer).
-- This queue is intentionally editor-centric and should remain reusable even if
-- the source of suggestions changes from Gemini to another CLI provider.
local pending_diffs = {}
local pending_open_paths = {}

-- Stores the final outcome of diffs (accepted/rejected) to report back to the CLI.
local resolved_diffs = {}

-- Callback used to send notifications (SSE) back to the bridge server.
local event_handler = nil

-- Filetypes that should be ignored when searching for a window to show a diff.
local ignored_filetypes = {
  ["NvimTree"] = true,
  ["neo-tree"] = true,
  ["oil"] = true,
  ["minifiles"] = true,
  ["snacks_picker_input"] = true,
  ["snacks_picker_list"] = true,
  ["snacks_picker_preview"] = true,
}

---Schedules a function to run on the main Neovim event loop.
---Required when handling RPC requests from the bridge server (which may run in a fast event).
local function schedule_ui(fn)
  vim.schedule(function()
    local ok, err = pcall(fn)
    if not ok then
      logger.error("diff", err)
    end
  end)
end

---Normalizes a file path for consistent indexing.
local function normalize_path(path)
  if not path or path == "" then
    return nil
  end

  return vim.fs.normalize(path)
end

---Reads the entire content of a file from disk.
local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 420) -- 0644
  if not fd then
    return ""
  end

  local stat = vim.uv.fs_fstat(fd)
  if not stat or stat.size == 0 then
    vim.uv.fs_close(fd)
    return ""
  end

  local data = vim.uv.fs_read(fd, stat.size, 0) or ""
  vim.uv.fs_close(fd)
  return data
end

---Writes content to a file, creating parent directories if necessary.
local function write_file(path, content)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end

  local fd, err = vim.uv.fs_open(path, "w", 420) -- 0644
  if not fd then
    return false, err
  end

  local ok, write_err = vim.uv.fs_write(fd, content, 0)
  vim.uv.fs_close(fd)
  if not ok then
    return false, write_err
  end

  return true
end

---Splits a string into a table of lines.
local function split_lines(content)
  if content == "" then
    return { "" }
  end

  return vim.split(content, "\n", { plain = true })
end

---Ensures a string ends with exactly one newline.
local function ensure_trailing_newline(content)
  if content == "" or content:sub(-1) == "\n" then
    return content
  end

  return content .. "\n"
end

local function content_matches(lhs, rhs)
  return ensure_trailing_newline(lhs or "") == ensure_trailing_newline(rhs or "")
end

---Generates a unified diff between two strings using Neovim's internal diff engine.
---@return string[] lines A table of lines representing the unified diff
local function build_unified_diff(original_content, new_content)
  local diff = vim_diff(ensure_trailing_newline(original_content), ensure_trailing_newline(new_content), {
    result_type = "unified",
    ctxlen = 3,
    algorithm = "myers",
  })

  if not diff or diff == "" then
    diff = "@@ no changes @@\n"
  end

  return vim.split(diff, "\n", { plain = true })
end

---Synchronizes any loaded buffers for a given file with new content.
---Only updates buffers that haven't been manually modified to avoid data loss.
local function sync_loaded_buffers(path, content)
  local normalized = normalize_path(path)
  local lines = split_lines(content)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
      local buf_name = normalize_path(vim.api.nvim_buf_get_name(buf))
      if buf_name == normalized and not vim.bo[buf].modified then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        -- Reset modified flag since we've just synced with the disk
        vim.bo[buf].modified = false
      end
    end
  end
end

---Checks if a file is currently loaded in any buffer.
local function find_loaded_buffer(path)
  local normalized = normalize_path(path)
  if not normalized then
    return nil
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local buf_name = normalize_path(vim.api.nvim_buf_get_name(buf))
      if buf_name == normalized then
        return buf
      end
    end
  end

  return nil
end

local function find_window_for_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end

  return nil
end

local function find_window_for_path(path)
  local target_buf = find_loaded_buffer(path)
  if not target_buf then
    return nil
  end

  return find_window_for_buffer(target_buf)
end

---Heuristic to find the best window for displaying a diff review.
---Prefers the largest window that isn't a sidebar or special buffer.
local function choose_review_window()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(current_tab)
  local best_win = nil
  local best_score = -1

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local buftype = vim.bo[buf].buftype
      local filetype = vim.bo[buf].filetype
      if buftype == "" and not ignored_filetypes[filetype] then
        local width = vim.api.nvim_win_get_width(win)
        local height = vim.api.nvim_win_get_height(win)
        local score = width * height
        if score > best_score then
          best_score = score
          best_win = win
        end
      end
    end
  end

  return best_win or vim.api.nvim_get_current_win()
end

---Creates a scratch buffer to hold the diff text.
local function make_review_buffer(path, diff_lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "AI CLI Diff: " .. path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "diff"
  return buf
end

---Renders a floating help line at the top of the diff buffer.
local function render_help(buf, state)
  vim.api.nvim_buf_clear_namespace(buf, state.help_ns, 0, 1)
  vim.api.nvim_buf_set_extmark(buf, state.help_ns, 0, 0, {
    virt_text = {
      { " " .. state.accept_key .. " apply ", "DiffAdd" },
      { " " .. state.reject_key .. " reject ", "DiffDelete" },
      { " q close ", "Comment" },
    },
    virt_text_pos = "overlay",
    virt_text_win_col = 0,
    hl_mode = "combine",
  })
end

---Cleans up UI elements and restores window state when a diff review is closed.
local function cleanup_state(state)
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
  end

  if state.review_win and vim.api.nvim_win_is_valid(state.review_win) then
    -- If the review was replacing an existing buffer, restore it
    if state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
      vim.api.nvim_win_set_buf(state.review_win, state.original_buf)
      if state.original_cursor then
        pcall(vim.api.nvim_win_set_cursor, state.review_win, state.original_cursor)
      end
    elseif state.review_buf and vim.api.nvim_buf_is_valid(state.review_buf) then
      pcall(vim.api.nvim_buf_delete, state.review_buf, { force = true })
    end
  elseif state.review_buf and vim.api.nvim_buf_is_valid(state.review_buf) then
    pcall(vim.api.nvim_buf_delete, state.review_buf, { force = true })
  end
end

---Removes a diff from active tracking and cleans up its UI.
local function close_state(file_path)
  local key = normalize_path(file_path)
  local state = key and active_diffs[key] or nil
  if not state then
    return nil
  end

  active_diffs[key] = nil
  cleanup_state(state)
  return state
end

---Removes a diff from the pending queue.
local function clear_pending(file_path)
  local key = normalize_path(file_path)
  if key then
    pending_diffs[key] = nil
  end
end

---Moves an active diff back to the pending queue (e.g., if its buffer is wiped).
local function stash_pending_state(state)
  if not state or not state.old_file then
    return
  end

  -- Strip UI-specific state before stashing
  state.group = nil
  state.help_ns = nil
  state.original_buf = nil
  state.original_content = nil
  state.original_cursor = nil
  state.review_buf = nil
  state.review_win = nil
  pending_diffs[state.old_file] = state
end

---Records the outcome of a diff to be reported back to the bridge server.
local function remember_result(file_path, result)
  local key = normalize_path(file_path)
  if not key then
    return
  end

  result.filePath = key
  result.resolvedAt = vim.uv.hrtime()
  resolved_diffs[key] = result
end

---Sends an asynchronous event back to the bridge server.
local function emit_event(method, params)
  if not event_handler then
    return
  end

  local ok, err = pcall(event_handler, method, params)
  if not ok then
    logger.warn("diff", "Failed to notify bridge:", err)
  end
end

---Retrieves the current active state for a file.
local function get_state(file_path)
  local key = normalize_path(file_path)
  if not key then
    return nil, "No file path provided"
  end

  local state = active_diffs[key]
  if not state then
    return nil, "No active diff for " .. key
  end

  return state
end

---Retrieves a pending diff for a file.
local function get_pending(file_path)
  local key = normalize_path(file_path)
  if not key then
    return nil
  end

  return pending_diffs[key]
end

---Handles the final decision (Accept/Reject) for a diff in the Neovim UI.
---If accepted, writes the new content to disk and syncs all open buffers.
---@param file_path string Path to the file being edited
---@param accepted boolean Whether the user accepted the changes
local function finalize_in_editor(file_path, accepted)
  local state, err = get_state(file_path)
  if not state then
    return false, err
  end

  state.accepted = accepted == true
  state.resolved = true
  state.final_content = state.new_content

  local result = {
    acceptedInEditor = state.accepted,
    finalContent = state.accepted and state.new_content or nil,
    status = state.accepted and "accepted" or "rejected",
  }

  clear_pending(file_path)

  if accepted then
    local ok, write_err = write_file(state.old_file, state.new_content)
    if not ok then
      state.accepted = false
      state.resolved = false
      return false, write_err
    end

    sync_loaded_buffers(state.old_file, state.new_content)
    remember_result(state.old_file, result)
    emit_event("ide/diffAccepted", {
      filePath = state.old_file,
      content = state.new_content,
    })
    logger.info("diff", "Changes applied in editor for " .. vim.fn.fnamemodify(state.old_file, ":."))
  else
    remember_result(state.old_file, result)
    emit_event("ide/diffRejected", {
      filePath = state.old_file,
    })
    logger.info("diff", "Changes rejected in editor for " .. vim.fn.fnamemodify(state.old_file, ":."))
  end

  close_state(file_path)
  return true
end

local function resolve_external_accept(state)
  if not state or not state.old_file then
    return
  end

  local result = {
    acceptedInEditor = true,
    finalContent = state.new_content,
    status = "accepted",
  }

  remember_result(state.old_file, result)
  close_state(state.old_file)
  clear_pending(state.old_file)
  logger.info("diff", "Detected external apply for " .. vim.fn.fnamemodify(state.old_file, ":."))
end

---Configures buffer-local keymaps for the diff review buffer.
local function set_keymaps(buf, state)
  local opts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", state.accept_key, function()
    local ok, err = finalize_in_editor(state.old_file, true)
    if not ok then
      logger.error("diff", "Failed to apply changes:", err or "unknown error")
    end
  end, vim.tbl_extend("force", opts, { desc = "Apply AI CLI changes" }))

  vim.keymap.set("n", state.reject_key, function()
    finalize_in_editor(state.old_file, false)
  end, vim.tbl_extend("force", opts, { desc = "Reject AI CLI changes" }))

  vim.keymap.set("n", "q", function()
    finalize_in_editor(state.old_file, false)
  end, vim.tbl_extend("force", opts, { desc = "Close AI CLI diff" }))
end

function M.setup(config)
  M.config = config or {}
end

function M.set_event_handler(handler)
  event_handler = handler
end

---Internal helper to open the diff review UI.
local function open_review(state, review_win)
  local previous_win = vim.api.nvim_get_current_win()
  local previous_buf = vim.api.nvim_win_is_valid(previous_win) and vim.api.nvim_win_get_buf(previous_win) or nil
  local previous_buftype = previous_buf and vim.bo[previous_buf].buftype or ""
  local original_buf = vim.api.nvim_win_get_buf(review_win)
  local original_cursor = vim.api.nvim_win_get_cursor(review_win)
  local original_content = read_file(state.old_file)
  local review_buf = make_review_buffer(state.old_file, build_unified_diff(original_content, state.new_content))
  local unique_id = tostring(vim.uv.hrtime())

  state.accepted = false
  state.final_content = nil
  state.group = vim.api.nvim_create_augroup("AiCliDiff" .. unique_id, { clear = true })
  state.help_ns = vim.api.nvim_create_namespace("AiCliDiffHelp" .. unique_id)
  state.original_buf = original_buf
  state.original_content = original_content
  state.original_cursor = original_cursor
  state.resolved = false
  state.review_buf = review_buf
  state.review_win = review_win

  active_diffs[state.old_file] = state
  clear_pending(state.old_file)

  vim.api.nvim_win_set_buf(review_win, review_buf)
  vim.wo[review_win].wrap = false
  vim.wo[review_win].number = false
  vim.wo[review_win].relativenumber = false
  vim.wo[review_win].cursorline = true
  vim.wo[review_win].signcolumn = "no"

  set_keymaps(review_buf, state)
  render_help(review_buf, state)

  -- If the user closes the diff buffer without deciding, stash it as pending
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.group,
    buffer = review_buf,
    callback = function()
      if active_diffs[state.old_file] and not active_diffs[state.old_file].resolved then
        local stashed = active_diffs[state.old_file]
        active_diffs[state.old_file] = nil
        stash_pending_state(stashed)
        logger.info("diff", "Deferred diff for " .. vim.fn.fnamemodify(state.old_file, ":."))
      end
    end,
  })

  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
    if previous_buftype == "terminal" then
      vim.cmd("startinsert")
    end
  end
  logger.info("diff", "Opened diff for " .. vim.fn.fnamemodify(state.old_file, ":."))
end

local function schedule_pending_open(path)
  if not path or pending_open_paths[path] then
    return
  end

  pending_open_paths[path] = true
  vim.defer_fn(function()
    pending_open_paths[path] = nil

    if active_diffs[path] then
      return
    end

    local latest_pending = get_pending(path)
    if not latest_pending then
      return
    end

    local target_win = find_window_for_path(path)
    if target_win then
      open_review(latest_pending, target_win)
    end
  end, 20)
end

---Entry point for opening a diff (called via MCP).
---If the file is already visible, starts the review immediately.
---Otherwise, queues the diff as pending.
---The diff UI does not need to know which provider produced the suggestion; it
---only requires a target file path and the proposed file contents.
function M.open_diff(params)
  if vim.in_fast_event() then
    schedule_ui(function()
      M.open_diff(params)
    end)

    return {
      filePath = normalize_path(params.old_file_path or params.filePath or params.path),
      status = "scheduled",
    }
  end

  local old_file = normalize_path(params.old_file_path or params.filePath or params.path)
  local new_content = params.new_file_contents or params.newContent or params.newText or ""
  local accept_key = ((M.config or {}).diff or {}).accept_key or "ga"
  local reject_key = ((M.config or {}).diff or {}).reject_key or "gr"

  if not old_file then
    error("No target file path provided for diff request.")
  end

  close_state(old_file)
  local state = {
    accept_key = accept_key,
    new_content = new_content,
    old_file = old_file,
    reject_key = reject_key,
  }

  local target_buf = find_loaded_buffer(old_file)
  local target_win = target_buf and find_window_for_buffer(target_buf) or nil
  if not target_win then
    pending_diffs[old_file] = state
    logger.info("diff", "Queued diff for " .. vim.fn.fnamemodify(old_file, ":."))
    return {
      filePath = old_file,
      status = "pending",
    }
  end

  open_review(state, target_win)

  return {
    filePath = old_file,
    status = "opened",
  }
end

---Checks the status of a diff for a given file.
---Returns whether it's active, pending, or recently resolved.
function M.close_diff(file_path)
  local key = normalize_path(file_path)
  if vim.in_fast_event() then
    local resolved = key and resolved_diffs[key] or nil
    if resolved then
      return {
        filePath = resolved.filePath,
        acceptedInEditor = resolved.acceptedInEditor == true,
        status = resolved.status,
        finalContent = resolved.finalContent,
      }
    end

    local state = key and active_diffs[key] or nil
    if state then
      schedule_ui(function()
        M.close_diff(file_path)
      end)

      return {
        filePath = key,
        status = "scheduled",
        finalContent = state.new_content,
      }
    end

    local pending = key and pending_diffs[key] or nil
    if pending then
      return {
        filePath = key,
        status = "pending",
        finalContent = pending.new_content,
      }
    end
  end

  local state, err = get_state(file_path)
  if not state then
    local pending = key and pending_diffs[key] or nil
    if pending then
      return {
        filePath = key,
        status = "pending",
        finalContent = pending.new_content,
      }
    end

    local resolved = key and resolved_diffs[key] or nil
    if resolved then
      return {
        filePath = resolved.filePath,
        acceptedInEditor = resolved.acceptedInEditor == true,
        status = resolved.status,
        finalContent = resolved.finalContent,
      }
    end

    return {
      filePath = key,
      status = "not_found",
      error = err,
    }
  end

  local result = {
    filePath = state.old_file,
    acceptedInEditor = state.accepted == true,
    status = state.accepted and "accepted" or "closed",
    finalContent = state.new_content,
  }

  close_state(file_path)
  remember_result(state.old_file, result)
  return result
end

function M.get_diff_status(file_path)
  local key = normalize_path(file_path)
  if not key then
    return {
      filePath = nil,
      status = "not_found",
      error = "No file path provided",
    }
  end

  local state = active_diffs[key]
  if state then
    return {
      filePath = key,
      acceptedInEditor = state.accepted == true,
      status = "opened",
      finalContent = state.new_content,
    }
  end

  local pending = pending_diffs[key]
  if pending then
    return {
      filePath = key,
      status = "pending",
      finalContent = pending.new_content,
    }
  end

  local resolved = resolved_diffs[key]
  if resolved then
    return {
      filePath = resolved.filePath,
      acceptedInEditor = resolved.acceptedInEditor == true,
      status = resolved.status,
      finalContent = resolved.finalContent,
    }
  end

  return {
    filePath = key,
    status = "not_found",
    error = "No active diff for " .. key,
  }
end

function M.sync_external_resolution()
  if vim.in_fast_event() then
    schedule_ui(M.sync_external_resolution)
    return
  end

  for _, state in pairs(active_diffs) do
    if content_matches(read_file(state.old_file), state.new_content) then
      resolve_external_accept(state)
    end
  end

  for path, state in pairs(pending_diffs) do
    if content_matches(read_file(path), state.new_content) then
      clear_pending(path)
      remember_result(path, {
        acceptedInEditor = true,
        finalContent = state.new_content,
        status = "accepted",
      })
      logger.info("diff", "Resolved pending diff from disk for " .. vim.fn.fnamemodify(path, ":."))
    end
  end
end

function M.maybe_open_pending()
  if vim.in_fast_event() then
    schedule_ui(M.maybe_open_pending)
    return
  end

  for path, _ in pairs(pending_diffs) do
    if find_window_for_path(path) then
      schedule_pending_open(path)
    end
  end
end

---Checks if there is a pending diff for a buffer being opened.
---If so, opens the diff in the window displaying that buffer.
function M.maybe_open_pending_for_buffer(bufnr)
  if vim.in_fast_event() then
    schedule_ui(function()
      M.maybe_open_pending_for_buffer(bufnr)
    end)
    return
  end

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  if not path or active_diffs[path] then
    return
  end

  local pending = get_pending(path)
  if not pending then
    return
  end

  schedule_pending_open(path)
end

return M
