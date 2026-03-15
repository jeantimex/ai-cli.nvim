local M = {}
local logger = require("gemini_cli.logger")
local lockfile = require("gemini_cli.lockfile")
local diff = require("gemini_cli.diff")

local server_handle = nil
local port = nil
local auth_token = nil
local sse_clients = {}

local MCP_PROTOCOL_VERSION = "2024-11-05"

local function make_token()
  return tostring(vim.uv.hrtime()) .. "-" .. tostring(math.random(100000, 999999))
end

local function close_client(client)
  if not client or client:is_closing() then
    return
  end

  pcall(client.read_stop, client)
  client:shutdown(function()
    if not client:is_closing() then
      client:close()
    end
  end)
end

local function remove_sse_client(client)
  for index, entry in ipairs(sse_clients) do
    if entry.client == client then
      table.remove(sse_clients, index)
      break
    end
  end
end

local function write_http(client, status, body, headers)
  headers = headers or {}
  headers["Content-Type"] = headers["Content-Type"] or "application/json"
  headers["Content-Length"] = tostring(#body)
  headers.Connection = "close"

  local lines = { string.format("HTTP/1.1 %s", status) }
  for name, value in pairs(headers) do
    table.insert(lines, string.format("%s: %s", name, value))
  end
  table.insert(lines, "")
  table.insert(lines, body)

  client:write(table.concat(lines, "\r\n"), function()
    close_client(client)
  end)
end

local function write_json(client, status, payload)
  write_http(client, status, vim.json.encode(payload))
end

local function write_sse(client, payload)
  if not client or client:is_closing() then
    return false
  end

  local encoded = vim.json.encode(payload)
  local message = table.concat({
    "event: message",
    "data: " .. encoded,
    "",
    "",
  }, "\r\n")

  local ok = pcall(client.write, client, message)
  if not ok then
    remove_sse_client(client)
    close_client(client)
    return false
  end

  return true
end

local function open_sse_stream(client)
  local lines = {
    "HTTP/1.1 200 OK",
    "Content-Type: text/event-stream",
    "Cache-Control: no-cache",
    "Connection: keep-alive",
    "",
    ": connected",
    "",
  }

  client:write(table.concat(lines, "\r\n"))
  table.insert(sse_clients, { client = client })
end

local function unauthorized(client)
  write_json(client, "401 Unauthorized", {
    jsonrpc = "2.0",
    id = nil,
    error = {
      code = -32001,
      message = "Unauthorized",
    },
  })
end

local function jsonrpc_result(id, result)
  return {
    jsonrpc = "2.0",
    id = id,
    result = result,
  }
end

local function jsonrpc_error(id, code, message)
  return {
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code,
      message = message,
    },
  }
end

local function parse_http(raw)
  local header_text, body = raw:match("^(.-)\r\n\r\n(.*)$")
  if not header_text then
    return nil, "Incomplete HTTP request"
  end

  local lines = vim.split(header_text, "\r\n", { plain = true })
  local request_line = table.remove(lines, 1)
  local method, path = request_line:match("^(%S+)%s+(%S+)")
  if not method or not path then
    return nil, "Invalid request line"
  end

  local headers = {}
  for _, line in ipairs(lines) do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end

  local content_length = tonumber(headers["content-length"] or "0") or 0
  if #body < content_length then
    return nil, "Incomplete body"
  end

  return {
    method = method,
    path = path,
    headers = headers,
    body = body:sub(1, content_length),
  }
end

local function normalize_open_diff_args(args)
  return {
    old_file_path = args.filePath or args.old_file_path or args.path,
    new_file_contents = args.newContent or args.new_file_contents or args.newText or "",
    tab_name = args.tabName or args.tab_name or args.filePath or args.path,
  }
end

local function list_tools()
  return {
    tools = {
      {
        name = "openDiff",
        description = "Open a diff preview for a file in Neovim.",
        inputSchema = {
          type = "object",
          properties = {
            filePath = { type = "string", description = "Absolute path to the file being edited." },
            newContent = { type = "string", description = "Proposed file contents." },
          },
          required = { "filePath", "newContent" },
        },
      },
      {
        name = "closeDiff",
        description = "Close an open diff preview and return the latest proposed content.",
        inputSchema = {
          type = "object",
          properties = {
            filePath = { type = "string", description = "Absolute path to the file being edited." },
          },
          required = { "filePath" },
        },
      },
    },
  }
end

local function handle_tool_call(request)
  local params = request.params or {}
  local name = params.name
  local arguments = params.arguments or {}

  if name == "openDiff" then
    local normalized = normalize_open_diff_args(arguments)
    local ok, result = pcall(diff.open_diff, normalized)
    if not ok then
      return jsonrpc_error(request.id, -32000, result)
    end

    return jsonrpc_result(request.id, {
      content = {
        {
          type = "text",
          text = string.format("Opened diff for %s", normalized.old_file_path or "unknown file"),
        },
      },
      structuredContent = result or {},
    })
  end

  if name == "closeDiff" then
    local ok, result = pcall(diff.close_diff, arguments.filePath or arguments.path)
    if not ok then
      return jsonrpc_error(request.id, -32000, result)
    end

    local content = nil
    if result and result.acceptedInEditor == true then
      content = result.finalContent
    end

    return jsonrpc_result(request.id, {
      content = {
        {
          type = "text",
          text = vim.json.encode({
            content = content,
          }),
        },
      },
      structuredContent = result or {},
    })
  end

  return jsonrpc_error(request.id, -32601, "Unknown tool: " .. tostring(name))
end

local function handle_request(request)
  if type(request) ~= "table" then
    return jsonrpc_error(nil, -32600, "Invalid Request")
  end

  local method = request.method
  if method == "initialize" then
    return jsonrpc_result(request.id, {
      protocolVersion = request.params and request.params.protocolVersion or MCP_PROTOCOL_VERSION,
      capabilities = {
        tools = { listChanged = false },
      },
      serverInfo = {
        name = "gemini_cli.nvim",
        version = "0.1.0",
      },
    })
  end

  if method == "notifications/initialized" then
    return nil
  end

  if method == "ping" then
    return jsonrpc_result(request.id, {})
  end

  if method == "tools/list" then
    return jsonrpc_result(request.id, list_tools())
  end

  if method == "tools/call" then
    return handle_tool_call(request)
  end

  return jsonrpc_error(request.id, -32601, "Method not found: " .. tostring(method))
end

function M.start()
  if server_handle then
    return true, port, auth_token
  end

  math.randomseed(os.time())
  auth_token = make_token()

  local tcp = vim.uv.new_tcp()
  local success, err = tcp:bind("127.0.0.1", 0)
  if not success then
    return false, "Bind failed: " .. err
  end

  port = tcp:getsockname().port

  tcp:listen(128, function(listen_err)
    if listen_err then
      logger.error("server", "Listen error:", listen_err)
      return
    end

    local client = vim.uv.new_tcp()
    tcp:accept(client)
    local chunks = {}
    local handled = false

    client:read_start(function(read_err, data)
      if read_err then
        logger.error("server", "Read error:", read_err)
        remove_sse_client(client)
        close_client(client)
        return
      end

      if handled then
        if not data then
          remove_sse_client(client)
          close_client(client)
        end
        return
      end

      if data then
        table.insert(chunks, data)
        local raw = table.concat(chunks, "")
        local http_request, parse_err = parse_http(raw)
        if not http_request then
          if parse_err == "Incomplete HTTP request" or parse_err == "Incomplete body" then
            return
          end

          handled = true
          write_json(client, "400 Bad Request", jsonrpc_error(nil, -32700, parse_err))
          return
        end

        handled = true

        if http_request.path ~= "/mcp" then
          write_http(client, "404 Not Found", "")
          return
        end

        local auth_header = http_request.headers.authorization or ""
        local expected = "Bearer " .. auth_token
        if auth_header ~= expected then
          unauthorized(client)
          return
        end

        if http_request.method == "GET" then
          open_sse_stream(client)
          return
        end

        if http_request.method ~= "POST" then
          write_http(client, "405 Method Not Allowed", "")
          return
        end

        local ok, request = pcall(vim.json.decode, http_request.body)
        if not ok then
          write_json(client, "400 Bad Request", jsonrpc_error(nil, -32700, "Invalid JSON body"))
          return
        end

        local response = handle_request(request)
        if response == nil then
          write_http(client, "202 Accepted", "")
          return
        end

        write_json(client, "200 OK", response)
        return
      end

      handled = true
      write_json(client, "400 Bad Request", jsonrpc_error(nil, -32700, "Connection closed before request completed"))
    end)
  end)

  server_handle = tcp
  lockfile.create(port, auth_token)
  logger.info("server", "Gemini MCP bridge started on port " .. port)
  return true, port, auth_token
end

function M.notify(method, params)
  local payload = {
    jsonrpc = "2.0",
    method = method,
    params = params,
  }

  for index = #sse_clients, 1, -1 do
    local client = sse_clients[index].client
    if client:is_closing() or not write_sse(client, payload) then
      table.remove(sse_clients, index)
    end
  end
end

function M.stop()
  if server_handle then
    lockfile.remove(port)
    for _, entry in ipairs(sse_clients) do
      close_client(entry.client)
    end
    sse_clients = {}
    server_handle:close()
    server_handle = nil
    port = nil
    auth_token = nil
  end
end

function M.get_port()
  return port
end

return M
