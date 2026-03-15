---@module 'gemini_cli.server'
--- Implements a Model Context Protocol (MCP) bridge server.
--- This server runs inside Neovim and listens on a random local port.
--- It provides an HTTP interface for gemini-cli to call Neovim-specific tools
--- like 'openDiff' and 'closeDiff', and uses SSE (Server-Sent Events) to
--- notify the CLI about user actions in the editor.
local M = {}
local logger = require("gemini_cli.logger")
local lockfile = require("gemini_cli.lockfile")
local diff = require("gemini_cli.diff")

-- The main TCP server handle from libuv (vim.uv)
local server_handle = nil

-- The ephemeral TCP port Neovim is currently listening on
local port = nil

-- A random token required in the 'Authorization: Bearer <token>' header for all requests.
-- This ensures that only the gemini-cli that started Neovim (or has access to the lockfile)
-- can call these tools.
local auth_token = nil

-- List of active SSE (Server-Sent Events) clients.
-- Each entry is a table: { client = <uv_tcp_t> }
local sse_clients = {}

-- Current version of the Model Context Protocol supported by this server.
local MCP_PROTOCOL_VERSION = "2024-11-05"

---Generates a cryptographically-insecure but sufficient random token for local auth.
---Uses high-resolution time and a random number to minimize collisions.
---@return string token The generated token
local function make_token()
  return tostring(vim.uv.hrtime()) .. "-" .. tostring(math.random(100000, 999999))
end

---Gracefully closes a TCP client connection.
---Stops reading, performs a shutdown (FIN), and then closes the handle.
---@param client any The libuv TCP client handle
local function close_client(client)
  if not client or client:is_closing() then
    return
  end

  -- Stop reading from the socket to prevent further callbacks
  pcall(client.read_stop, client)

  -- Initiate a graceful shutdown
  client:shutdown(function()
    if not client:is_closing() then
      client:close()
    end
  end)
end

---Removes a client from the active SSE broadcast list.
---Used when a client disconnects or an error occurs during broadcast.
---@param client any The libuv TCP client handle to remove
local function remove_sse_client(client)
  for index, entry in ipairs(sse_clients) do
    if entry.client == client then
      table.remove(sse_clients, index)
      break
    end
  end
end

---Writes a raw HTTP response to a client.
---Automatically sets Content-Length and Connection: close.
---@param client any The libuv TCP client
---@param status string HTTP status line (e.g., "200 OK")
---@param body string Response body
---@param headers table|nil Optional additional headers
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

  -- Write the full response and close the client once finished
  client:write(table.concat(lines, "\r\n"), function()
    close_client(client)
  end)
end

---Writes a JSON-encoded HTTP response.
---Convenience wrapper for write_http.
---@param client any The libuv TCP client
---@param status string HTTP status line
---@param payload table The Lua table to encode as JSON
local function write_json(client, status, payload)
  write_http(client, status, vim.json.encode(payload))
end

---Sends a message to an SSE client using the 'message' event type.
---Follows the SSE wire format: 'event: <type>\ndata: <json>\n\n'.
---@param client any The libuv TCP client handle
---@param payload table The data to send
---@return boolean success Whether the write was successfully initiated
local function write_sse(client, payload)
  if not client or client:is_closing() then
    return false
  end

  local encoded = vim.json.encode(payload)
  local message = table.concat({
    "event: message",
    "data: " .. encoded,
    "", -- Double \r\n to end the SSE block
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

---Initializes an SSE stream on a client connection.
---Sends the initial HTTP response with text/event-stream content type.
---@param client any The libuv TCP client handle
local function open_sse_stream(client)
  local lines = {
    "HTTP/1.1 200 OK",
    "Content-Type: text/event-stream",
    "Cache-Control: no-cache",
    "Connection: keep-alive", -- SSE requires a persistent connection
    "",
    ": connected", -- Initial SSE comment to confirm connection
    "",
  }

  client:write(table.concat(lines, "\r\n"))
  table.insert(sse_clients, { client = client })
end

---Responds with a 401 Unauthorized JSON-RPC error.
---Used when the Authorization header is missing or invalid.
---@param client any The libuv TCP client handle
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

---Constructs a standard JSON-RPC 2.0 result object.
---@param id number|string|nil Request identifier
---@param result any The result payload
---@return table response The JSON-RPC response object
local function jsonrpc_result(id, result)
  return {
    jsonrpc = "2.0",
    id = id,
    result = result,
  }
end

---Constructs a standard JSON-RPC 2.0 error object.
---@param id number|string|nil Request identifier
---@param code number Error code
---@param message string Error message
---@return table response The JSON-RPC error object
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

---Basic HTTP request parser for the bridge server.
---Supports simple GET and POST requests.
---Note: Does NOT support chunked encoding or multi-part bodies.
---@param raw string The raw data from the socket
---@return table|nil request The parsed request object, or nil if incomplete
---@return string|nil error Error message if parsing failed or data is incomplete
local function parse_http(raw)
  -- Split headers from body (double newline)
  local header_text, body = raw:match("^(.-)\r\n\r\n(.*)$")
  if not header_text then
    return nil, "Incomplete HTTP request"
  end

  local lines = vim.split(header_text, "\r\n", { plain = true })
  local request_line = table.remove(lines, 1)
  -- Parse Method (e.g., POST) and Path (e.g., /mcp)
  local method, path = request_line:match("^(%S+)%s+(%S+)")
  if not method or not path then
    return nil, "Invalid request line"
  end

  -- Simple header extraction
  local headers = {}
  for _, line in ipairs(lines) do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end

  -- Validate that we have the full body based on Content-Length
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

---Normalizes argument names between different MCP client implementations.
---@param args table Raw arguments from the MCP request
---@return table normalized Normalized arguments
local function normalize_open_diff_args(args)
  return {
    old_file_path = args.filePath or args.old_file_path or args.path,
    new_file_contents = args.newContent or args.new_file_contents or args.newText or "",
    tab_name = args.tabName or args.tab_name or args.filePath or args.path,
  }
end

---Returns the list of tools available via this MCP server.
---@return table tools The tools list in MCP format
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

---Dispatches an MCP 'tools/call' request to the appropriate Neovim function.
---@param request table The JSON-RPC request object
---@return table response The JSON-RPC response object
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

---Main entry point for handling MCP JSON-RPC requests.
---@param request table The decoded JSON-RPC request
---@return table|nil response The JSON-RPC response, or nil for notifications
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

---Starts the MCP bridge server.
---@return boolean success Whether the server started
---@return number|string result The port number or error message
---@return string|nil token The authentication token
function M.start()
  if server_handle then
    return true, port, auth_token
  end

  math.randomseed(os.time())
  auth_token = make_token()

  local tcp = vim.uv.new_tcp()
  local success, err = tcp:bind("127.0.0.1", 0) -- Bind to random port
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

      -- If we've already responded to this request (e.g., it was a POST), ignore further data
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
          -- Wait for more data if the request is incomplete
          if parse_err == "Incomplete HTTP request" or parse_err == "Incomplete body" then
            return
          end

          handled = true
          write_json(client, "400 Bad Request", jsonrpc_error(nil, -32700, parse_err))
          return
        end

        handled = true

        -- All MCP requests should go to /mcp
        if http_request.path ~= "/mcp" then
          write_http(client, "404 Not Found", "")
          return
        end

        -- Verify authentication token
        local auth_header = http_request.headers.authorization or ""
        local expected = "Bearer " .. auth_token
        if auth_header ~= expected then
          unauthorized(client)
          return
        end

        -- GET requests initiate the SSE event stream
        if http_request.method == "GET" then
          open_sse_stream(client)
          return
        end

        -- POST requests carry JSON-RPC MCP calls
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
          -- For notifications that don't return a response
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
  -- Write port/token to a lockfile so external tools can find us
  lockfile.create(port, auth_token)
  logger.info("server", "Gemini MCP bridge started on port " .. port)
  return true, port, auth_token
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

---Stops the bridge server and cleans up resources.
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

---Returns the port the server is listening on.
---@return number|nil port The TCP port or nil if not running
function M.get_port()
  return port
end

return M
