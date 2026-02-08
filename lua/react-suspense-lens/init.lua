-- LuaLS/EmmyLua type annotations (kept inline so they stay close to the code).
-- These comments do not affect runtime.

---@class react_suspense_lens.TSNode
---@field type fun(self: react_suspense_lens.TSNode): string
---@field range fun(self: react_suspense_lens.TSNode): integer, integer, integer, integer
---@field parent fun(self: react_suspense_lens.TSNode): react_suspense_lens.TSNode|nil
---@field iter_children fun(self: react_suspense_lens.TSNode): fun(): react_suspense_lens.TSNode
---@field field fun(self: react_suspense_lens.TSNode, name: string): react_suspense_lens.TSNode[]

---@class react_suspense_lens.TagItem
---@field node react_suspense_lens.TSNode
---@field text string

---@class react_suspense_lens.BufLast
---@field tags integer
---@field highlighted integer
---@field method string|nil
---@field client string|nil

---@class react_suspense_lens.BufState
---@field timer uv_timer_t|nil
---@field gen integer|nil
---@field attached boolean|nil
---@field last react_suspense_lens.BufLast|nil
---@field no_client_retries integer|nil
---@field warmup_scheduled boolean|nil
---@field ns_idx integer|nil
---@field pending_ns_idx integer|nil

---@class react_suspense_lens.State
---@field enabled boolean
---@field bufs table<integer, react_suspense_lens.BufState>
---@field def_cache table<string, react_suspense_lens.DefCacheEntry>
---@field file_cache table<string, react_suspense_lens.FileCacheEntry>
---@field queries table<string, vim.treesitter.Query>
---@field logs string[]
---@field debug boolean
---@field opts react_suspense_lens.Opts|nil
---@field runtime_inited boolean
---@field stats react_suspense_lens.Stats
---@field pending table<string, integer> -- key -> start_hrtime_ns

---@class react_suspense_lens.Opts
---@field enabled boolean
---@field filetypes string[]
---@field hl_group string
---@field hl_link string|nil
---@field define_hl boolean
---@field debounce_ms integer
---@field max_tags integer
---@field max_concurrent_lsp integer
---@field max_file_bytes integer
---@field lsp_methods string[]
---@field prefer_client_names string[]
---@field suspense_callee_names string[]
---@field suspense_callee_suffixes string[]
---@field suspense_member_suffixes string[]
---@field priority integer
---@field debug boolean
---@field no_client_retry_ms integer
---@field no_client_max_retries integer
---@field only_visible boolean

---@class react_suspense_lens.Stats
---@field refresh_count integer
---@field refresh_total_ms number
---@field refresh_max_ms number
---@field refresh_last_ms number
---@field refresh_last_buf integer
---@field refresh_last_tags integer
---@field lsp_requests integer
---@field lsp_responses integer
---@field lsp_rtt_total_ms number
---@field lsp_rtt_max_ms number
---@field cache_hits integer
---@field cache_misses integer
---@field def_analyze_calls integer
---@field def_analyze_total_ms number
---@field highlights_set integer

---@class react_suspense_lens.DefCacheEntry
---@field mask integer
---@field stamp integer
---@field stamp_kind 'changedtick'|'mtime'

---@class react_suspense_lens.FileCacheEntry
---@field stamp integer
---@field text string
---@field lines string[]
---@field lang string|nil
---@field root react_suspense_lens.TSNode|nil
---@field parser any|nil

---@class react_suspense_lens.Module
---@field setup fun(user_opts?: react_suspense_lens.Opts)

---@type react_suspense_lens.Module
local M = {}

-- We keep two namespaces to "double buffer" extmarks.
-- Refresh resolves many LSP requests asynchronously; swapping namespaces after the new set is ready
-- avoids flicker (clearing old marks before the new set has been fully computed).
local ns = {
  vim.api.nvim_create_namespace('react_suspense_lens_a'),
  vim.api.nvim_create_namespace('react_suspense_lens_b'),
}

---@type react_suspense_lens.State
local state = {
  enabled = true,
  bufs = {}, -- bufnr -> { timer = uv_timer, gen = int }
  def_cache = {}, -- def_key -> { mask, stamp, stamp_kind }
  file_cache = {}, -- fname -> { stamp, text, lines }
  queries = {}, -- lang -> parsed query
  logs = {},
  debug = false,
  ---@type react_suspense_lens.Opts|nil
  opts = nil,
  runtime_inited = false,
  stats = {
    refresh_count = 0,
    refresh_total_ms = 0,
    refresh_max_ms = 0,
    refresh_last_ms = 0,
    refresh_last_buf = 0,
    refresh_last_tags = 0,
    lsp_requests = 0,
    lsp_responses = 0,
    lsp_rtt_total_ms = 0,
    lsp_rtt_max_ms = 0,
    cache_hits = 0,
    cache_misses = 0,
    def_analyze_calls = 0,
    def_analyze_total_ms = 0,
    highlights_set = 0,
  },
  pending = {},
}

---@type react_suspense_lens.Opts
local defaults = {
  enabled = true,
  filetypes = { 'typescriptreact', 'javascriptreact' },
  hl_group = 'ReactSuspenseLensAsyncComponent',
  hl_link = 'DiagnosticUnderlineWarn',
  define_hl = true,
  -- Performance: only refresh buffers that are visible in a window (prevents lots of background work
  -- when plugins/loaders briefly load many TSX buffers).
  only_visible = true,
  debounce_ms = 200,
  max_tags = 200,
  -- Limit concurrent LSP requests per refresh to avoid spiking tsserver/vtsls at startup.
  -- Note: work is also reduced by de-duping tag resolution per unique component name.
  max_concurrent_lsp = 10,
  -- When a definition file isn't loaded in Neovim, we parse it from disk text.
  -- Cap file size to avoid huge blocking reads.
  max_file_bytes = 2 * 1024 * 1024,
  -- We'll try these in order per-tag until we can resolve an implementation that matches our heuristics.
  lsp_methods = { 'textDocument/definition', 'textDocument/implementation', 'textDocument/typeDefinition', 'textDocument/declaration' },
  -- Prefer TS LSP clients so we don't accidentally hit e.g. tailwindcss for definition requests.
  prefer_client_names = { 'ts_ls', 'vtsls', 'tsserver', 'typescript-tools' },
  -- Heuristic: treat components that call these as "needs a Suspense boundary".
  suspense_callee_names = { 'useSuspenseQuery', 'useSuspenseQueries', 'useSuspenseInfiniteQuery', 'useSuspenseInfiniteQueries' },
  -- Heuristic: also match custom hooks that end with these suffixes, e.g. "useProjectSuspenseQuery".
  suspense_callee_suffixes = { 'SuspenseQuery', 'SuspenseQueries', 'SuspenseInfiniteQuery', 'SuspenseInfiniteQueries' },
  -- Heuristic: also match member calls that end with ".<suffix>", e.g. "trpc.foo.useSuspenseQuery".
  suspense_member_suffixes = { 'useSuspenseQuery', 'useSuspenseQueries', 'useSuspenseInfiniteQuery', 'useSuspenseInfiniteQueries' },
  priority = 10000,
  debug = false,
  -- Startup race: first buffer can refresh before ts_ls fully attaches/initializes.
  -- Retry a few times before giving up.
  no_client_retry_ms = 250,
  no_client_max_retries = 8,
}

---@return react_suspense_lens.Opts
local function get_opts()
  return state.opts or defaults
end

---@return integer
local function hrtime_ns()
  return vim.uv.hrtime()
end

---@param ns integer
---@return number
local function ns_to_ms(ns)
  return ns / 1e6
end

---@param msg string
local function log(msg)
  if not state.debug then
    return
  end
  local ts = os.date('%H:%M:%S')
  local line = string.format('[%s] %s', ts, msg)
  table.insert(state.logs, line)
  if #state.logs > 200 then
    table.remove(state.logs, 1)
  end
end

---@param bufnr integer
---@return string
local function buf_label(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return string.format('buf=%d (no name)', bufnr)
  end
  return string.format('buf=%d %s', bufnr, vim.fn.fnamemodify(name, ':t'))
end

---@param bufnr integer
---@param row integer
---@return boolean
local function line_is_importish(bufnr, row)
  local ok, line = pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
  if not ok or not line or not line[1] then
    return false
  end
  local s = line[1]
  return s:match('^%s*import%s') ~= nil or s:match('^%s*export%s') ~= nil
end

---@param line string
---@param index integer|nil
---@param encoding string|nil
---@return integer
local function str_utfindex_enc(line, index, encoding)
  local util = vim.lsp and vim.lsp.util or nil
  if util and util._str_utfindex_enc then
    return util._str_utfindex_enc(line, index, encoding)
  end

  local len32, len16 = vim.str_utfindex(line)
  encoding = encoding or 'utf-16'

  if encoding == 'utf-8' then
    return index or #line
  elseif encoding == 'utf-16' then
    if not index or index > len16 then
      return len16
    end
    local _, col16 = vim.str_utfindex(line, index)
    return col16
  elseif encoding == 'utf-32' then
    if not index or index > len32 then
      return len32
    end
    local col32, _ = vim.str_utfindex(line, index)
    return col32
  end

  error('Invalid encoding: ' .. vim.inspect(encoding))
end

---@param line string
---@param index integer
---@param encoding string|nil
---@return integer
local function str_byteindex_enc(line, index, encoding)
  local util = vim.lsp and vim.lsp.util or nil
  if util and util._str_byteindex_enc then
    return util._str_byteindex_enc(line, index, encoding)
  end

  local len8 = #line
  encoding = encoding or 'utf-16'
  if encoding == 'utf-8' then
    return (index and index <= len8) and index or len8
  end

  local len32, len16 = vim.str_utfindex(line)
  if encoding == 'utf-16' then
    return index <= len16 and vim.str_byteindex(line, index, true) or len8
  elseif encoding == 'utf-32' then
    return index <= len32 and vim.str_byteindex(line, index) or len8
  end

  error('Invalid encoding: ' .. vim.inspect(encoding))
end

---@param bufnr integer
---@param row integer
---@param byte_col integer
---@param offset_encoding string|nil
---@return lsp.Position
local function position_from_bytecol(bufnr, row, byte_col, offset_encoding)
  if byte_col <= 0 then
    return { line = row, character = 0 }
  end
  local ok, line = pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
  local s = (ok and line and line[1]) and line[1] or ''
  local char = str_utfindex_enc(s, byte_col, offset_encoding or 'utf-16')
  return { line = row, character = char }
end

---@param bufnr integer
---@param row integer
---@param character integer
---@param offset_encoding string|nil
---@return integer
local function bytecol_from_position(bufnr, row, character, offset_encoding)
  if character <= 0 then
    return 0
  end
  local ok, line = pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
  local s = (ok and line and line[1]) and line[1] or ''
  return str_byteindex_enc(s, character, offset_encoding or 'utf-16')
end

---@param line string
---@param character integer
---@param offset_encoding string|nil
---@return integer
local function bytecol_from_line(line, character, offset_encoding)
  if character <= 0 then
    return 0
  end
  return str_byteindex_enc(line or '', character, offset_encoding or 'utf-16')
end

---@type fun(bufnr: integer, opts: react_suspense_lens.Opts)
local debounce_refresh

---@param opts react_suspense_lens.Opts
---@param client_name string
---@return boolean
local function is_preferred_ts_client(opts, client_name)
  for _, n in ipairs(opts.prefer_client_names or {}) do
    if n == client_name then
      return true
    end
  end
  return false
end

---@param bufnr integer
---@param opts react_suspense_lens.Opts
local function schedule_warmup_refreshes(bufnr, opts)
  local bstate = state.bufs[bufnr] or {}
  if bstate.warmup_scheduled then
    return
  end
  bstate.warmup_scheduled = true
  state.bufs[bufnr] = bstate

  -- Some TS LSP servers will answer definition requests with incomplete results
  -- in the first moments after attach (startup/indexing). Force a couple retries.
  local delays = { 250, 800, 1800, 3500, 7000 }
  for _, delay in ipairs(delays) do
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) and state.enabled and (opts.only_visible == false or #vim.fn.win_findbuf(bufnr) > 0) then
        log(string.format('warmup: refresh delay=%dms %s', delay, buf_label(bufnr)))
        debounce_refresh(bufnr, opts)
      end
    end, delay)
  end
end

---@param node react_suspense_lens.TSNode
---@param source integer|string
---@return string
local function get_node_text(node, source)
  local ok, text = pcall(vim.treesitter.get_node_text, node, source)
  if ok then
    return text
  end
  return ''
end

---@param bufnr integer
---@return string|nil
local function get_lang_for_buf(bufnr)
  local ft = vim.bo[bufnr].filetype
  local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
  if ok and lang then
    return lang
  end
  -- Reasonable fallback for TSX/JSX buffers.
  if ft == 'typescriptreact' or ft == 'javascriptreact' then
    return 'tsx'
  end
  return nil
end

---@param path string
---@return string|nil
local function get_lang_for_path(path)
  if path:match('%.tsx$') or path:match('%.jsx$') then
    return 'tsx'
  end
  if path:match('%.ts$') or path:match('%.mts$') or path:match('%.cts$') then
    return 'typescript'
  end
  if path:match('%.js$') or path:match('%.mjs$') or path:match('%.cjs$') then
    return 'javascript'
  end
  return nil
end

---@param lang string
---@return vim.treesitter.Query|nil
local function get_query(lang)
  if state.queries[lang] then
    return state.queries[lang]
  end

  -- Capture the "name" field, which can be an identifier or member expression (e.g. React.Suspense).
  local ok, q = pcall(vim.treesitter.query.parse, lang, [[
    (jsx_opening_element name: (_) @name)
    (jsx_self_closing_element name: (_) @name)
  ]])
  if not ok then
    return nil
  end
  state.queries[lang] = q
  return q
end

---@param text string
---@return boolean
local function is_suspense_name(text)
  return text == 'Suspense' or text:match('%.Suspense$') ~= nil
end

---@param text string
---@return boolean
local function starts_with_lowercase(text)
  local c = text:sub(1, 1)
  return c:match('%l') ~= nil
end

---@param bufnr integer
---@param method string
---@param prefer_names string[]|nil
---@return vim.lsp.Client|nil
local function pick_lsp_client(bufnr, method, prefer_names)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })

  if prefer_names and #prefer_names > 0 then
    for _, name in ipairs(prefer_names) do
      for _, client in ipairs(clients) do
        if client.name == name and client.supports_method and client:supports_method(method) then
          log(string.format('pick_lsp_client: picked preferred client=%s method=%s %s', client.name, method, buf_label(bufnr)))
          return client
        end
      end
    end
  end

  for _, client in ipairs(clients) do
    if client.supports_method and client:supports_method(method) then
      log(string.format('pick_lsp_client: picked client=%s method=%s %s', client.name, method, buf_label(bufnr)))
      return client
    end
  end
  log(string.format('pick_lsp_client: no client for method=%s %s', method, buf_label(bufnr)))
  return nil
end

---@class react_suspense_lens.LocationLike
---@field uri string
---@field range lsp.Range

---@param result any
---@return react_suspense_lens.LocationLike[]
local function normalize_locations(result)
  if not result then
    return {}
  end

  local function one(loc)
    if not loc then
      return nil
    end
    -- LocationLink
    if loc.targetUri and loc.targetRange then
      return {
        uri = loc.targetUri,
        range = loc.targetRange,
      }
    end
    -- Location
    if loc.uri and loc.range then
      return {
        uri = loc.uri,
        range = loc.range,
      }
    end
    return nil
  end

  local out = {}
  if vim.islist(result) then
    for _, item in ipairs(result) do
      local loc = one(item)
      if loc then
        table.insert(out, loc)
      end
    end
  else
    local loc = one(result)
    if loc then
      table.insert(out, loc)
    end
  end

  -- Prefer non-.d.ts locations first, but keep .d.ts as last-resort.
  table.sort(out, function(a, b)
    local fa = vim.uri_to_fname(a.uri)
    local fb = vim.uri_to_fname(b.uri)
    local ada = fa:match('%.d%.ts$') ~= nil
    local bda = fb:match('%.d%.ts$') ~= nil
    if ada ~= bda then
      return not ada
    end
    return fa < fb
  end)

  return out
end

---@param client vim.lsp.Client
---@return string|nil
local function pick_source_def_command(client)
  local cap = client.server_capabilities or {}
  local prov = cap.executeCommandProvider or {}
  local cmds = prov.commands or {}
  if not vim.islist(cmds) then
    cmds = {}
  end

  local candidates = { 'typescript.goToSourceDefinition', '_typescript.goToSourceDefinition' }

  for _, want in ipairs(candidates) do
    for _, have in ipairs(cmds) do
      if have == want then
        return want
      end
    end
  end

  -- Fall back to the common name even if it isn't advertised.
  return candidates[1]
end

---@param client vim.lsp.Client
---@param bufnr integer
---@param pos lsp.Position
---@param cb fun(locs: react_suspense_lens.LocationLike[])
local function request_source_definition(client, bufnr, pos, cb)
  local cmd = pick_source_def_command(client)
  if not cmd then
    return cb({})
  end
  if not (client.supports_method and client:supports_method('workspace/executeCommand')) then
    return cb({})
  end

  local uri = vim.uri_from_bufnr(bufnr)

  ---@type table[]
  local arg_variants = {
    { { textDocument = { uri = uri }, position = pos } },
    { { uri = uri, position = pos } },
    { uri, pos },
    { vim.uri_to_fname(uri), pos },
  }

  local function try_args(i)
    local args = arg_variants[i]
    if not args then
      return cb({})
    end
    client.request('workspace/executeCommand', { command = cmd, arguments = args }, function(err, result)
      if err then
        if state.debug then
          log(string.format('exec: cmd=%s err=%s', cmd, err.message or vim.inspect(err)))
        end
        return try_args(i + 1)
      end
      local locs = normalize_locations(result)
      if state.debug then
        local sample = {}
        for j = 1, math.min(#locs, 3) do
          table.insert(sample, vim.fn.fnamemodify(vim.uri_to_fname(locs[j].uri), ':t'))
        end
        log(string.format('exec: cmd=%s locs=%d [%s]', cmd, #locs, table.concat(sample, ',')))
      end
      if #locs > 0 then
        return cb(locs)
      end
      return try_args(i + 1)
    end, bufnr)
  end

  return try_args(1)
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return react_suspense_lens.TSNode|nil
local function ts_get_node_at_pos(bufnr, row, col)
  if vim.treesitter.get_node then
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
    if ok then
      return node
    end
  end
  if vim.treesitter.get_node_at_pos then
    local ok, node = pcall(vim.treesitter.get_node_at_pos, bufnr, row, col, true)
    if ok then
      return node
    end
  end
  return nil
end

---@param node react_suspense_lens.TSNode|nil
---@return boolean
local function node_has_async_kw(node)
  if not node then
    return false
  end
  for child in node:iter_children() do
    if child:type() == 'async' then
      return true
    end
    if child:type() == 'modifiers' then
      for m in child:iter_children() do
        if m:type() == 'async' then
          return true
        end
      end
    end
  end
  return false
end

---@param root react_suspense_lens.TSNode
---@return fun(): react_suspense_lens.TSNode|nil
local function iter_descendants(root)
  ---@type react_suspense_lens.TSNode[]
  local stack = { root }
  return function()
    local node = table.remove(stack)
    if not node then
      return nil
    end
    local children = {}
    for child in node:iter_children() do
      table.insert(children, child)
    end
    for i = #children, 1, -1 do
      table.insert(stack, children[i])
    end
    return node
  end
end

---@param opts react_suspense_lens.Opts
---@return boolean
local function has_suspense_hook_opts(opts)
  return (opts.suspense_callee_names and #opts.suspense_callee_names > 0)
    or (opts.suspense_callee_suffixes and #opts.suspense_callee_suffixes > 0)
    or (opts.suspense_member_suffixes and #opts.suspense_member_suffixes > 0)
end

---@param text string
---@param suffix string
---@return boolean
local function ends_with(text, suffix)
  return suffix ~= '' and #text >= #suffix and text:sub(-#suffix) == suffix
end

---@param text string
---@param suffix string
---@return boolean
local function ends_with_member_suffix(text, suffix)
  local want = '.' .. suffix
  return #text > #want and text:sub(-#want) == want
end

---@param func_txt string
---@param opts react_suspense_lens.Opts
---@return boolean
local function matches_suspense_hook(func_txt, opts)
  for _, name in ipairs(opts.suspense_callee_names or {}) do
    if func_txt == name then
      return true
    end
  end
  for _, suffix in ipairs(opts.suspense_member_suffixes or {}) do
    if ends_with_member_suffix(func_txt, suffix) then
      return true
    end
  end
  for _, suffix in ipairs(opts.suspense_callee_suffixes or {}) do
    if ends_with(func_txt, suffix) then
      return true
    end
  end
  return false
end

---@param call_node react_suspense_lens.TSNode
---@param source integer|string
---@return string|nil
local function get_call_function_text(call_node, source)
  local fn = (call_node:field('function') or {})[1]
  if fn then
    local txt = get_node_text(fn, source)
    if txt ~= '' then
      return txt
    end
  end
  -- Fallback: many grammars put the callee as the first named child.
  local ok, named_child = pcall(function()
    return call_node:named_child(0)
  end)
  if ok and named_child then
    local txt = get_node_text(named_child, source)
    if txt ~= '' then
      return txt
    end
  end
  return nil
end

---@param fn_node react_suspense_lens.TSNode
---@param source integer|string
---@param opts react_suspense_lens.Opts
---@return boolean
local function function_uses_suspense_hook(fn_node, source, opts)
  if not has_suspense_hook_opts(opts) then
    return false
  end

  for node in iter_descendants(fn_node) do
    local t = node:type()
    if t == 'call_expression' or t == 'optional_call_expression' then
      local func_txt = get_call_function_text(node, source)
      if func_txt and matches_suspense_hook(func_txt, opts) then
        return true
      end
    end
  end
  return false
end

---@type fun(node: react_suspense_lens.TSNode|nil): react_suspense_lens.TSNode|nil
local find_definition_function_node_from_node

---@param def_bufnr integer
---@param row integer
---@param col integer
---@return react_suspense_lens.TSNode|nil
local function find_definition_function_node(def_bufnr, row, col)
  local node = ts_get_node_at_pos(def_bufnr, row, col)
  return find_definition_function_node_from_node(node)
end

---@param node react_suspense_lens.TSNode|nil
---@return react_suspense_lens.TSNode|nil
find_definition_function_node_from_node = function(node)
  if not node then
    return nil
  end
  local cur = node
  while cur do
    local t = cur:type()
    if t == 'function_declaration' or t == 'method_definition' or t == 'arrow_function' or t == 'function' then
      return cur
    end
    if t == 'variable_declarator' then
      local value = (cur:field('value') or {})[1]
      if value and (value:type() == 'arrow_function' or value:type() == 'function') then
        return value
      end
    end
    if t == 'export_statement' then
      for child in cur:iter_children() do
        local ct = child:type()
        if ct == 'function_declaration' or ct == 'arrow_function' or ct == 'function' then
          return child
        end
        if ct == 'lexical_declaration' or ct == 'variable_declaration' then
          for n in iter_descendants(child) do
            if n:type() == 'arrow_function' or n:type() == 'function' then
              return n
            end
          end
        end
      end
    end
    cur = cur:parent()
  end
  return nil
end

---@param fname string
---@param def_bufnr integer
---@return integer stamp, 'changedtick'|'mtime' kind
local function get_def_stamp(fname, def_bufnr)
  if vim.api.nvim_buf_is_valid(def_bufnr) and vim.api.nvim_buf_is_loaded(def_bufnr) then
    return vim.api.nvim_buf_get_changedtick(def_bufnr), 'changedtick'
  end
  local st = vim.uv.fs_stat(fname)
  if st and st.mtime and st.mtime.sec then
    -- Use seconds + nanoseconds to avoid "same-second" cache staleness.
    local nsec = tonumber(st.mtime.nsec or 0) or 0
    -- Keep this representable as an integer in a Lua number (double): use milliseconds.
    return (st.mtime.sec * 1000) + math.floor(nsec / 1000000), 'mtime'
  end
  return 0, 'mtime'
end

---@param fname string
---@return integer|nil
local function loaded_bufnr_for_fname(fname)
  local ok, b = pcall(vim.fn.bufnr, fname, false)
  if not ok or type(b) ~= 'number' or b < 0 then
    return nil
  end
  if vim.api.nvim_buf_is_loaded(b) then
    return b
  end
  return nil
end

---@param fname string
---@param max_bytes integer
---@return string|nil
local function read_file_text(fname, max_bytes)
  local fd = vim.uv.fs_open(fname, 'r', 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local size = stat and stat.size or 0
  if type(size) ~= 'number' or size <= 0 then
    vim.uv.fs_close(fd)
    return ''
  end
  if type(max_bytes) == 'number' and max_bytes > 0 and size > max_bytes then
    vim.uv.fs_close(fd)
    return nil
  end
  local data = vim.uv.fs_read(fd, size, 0)
  vim.uv.fs_close(fd)
  if type(data) ~= 'string' then
    return nil
  end
  return (data:gsub('\r\n?', '\n'))
end

---@param fname string
---@param stamp integer
---@param lang string
---@param max_bytes integer
---@return react_suspense_lens.FileCacheEntry|nil
local function get_file_cache_entry(fname, stamp, lang, max_bytes)
  local entry = state.file_cache[fname]
  if entry and entry.stamp == stamp and entry.lang == lang and entry.text and entry.lines and entry.root and entry.parser then
    return entry
  end
  if entry and entry.stamp == stamp and entry.lang == lang and entry.text and entry.lines and (entry.root == nil or entry.parser == nil) then
    -- fallthrough: attempt parse again
  end
  if not (entry and entry.stamp == stamp and entry.text and entry.lines) then
    local text = read_file_text(fname, max_bytes)
    if text == nil then
      return nil
    end
    local lines = vim.split(text, '\n', { plain = true, trimempty = false })
    entry = { stamp = stamp, text = text, lines = lines, lang = lang, root = nil, parser = nil }
    state.file_cache[fname] = entry
  end

  local okp, parser = pcall(vim.treesitter.get_string_parser, entry.text, lang)
  if not okp or not parser then
    entry.lang = lang
    entry.root = nil
    entry.parser = nil
    return entry
  end
  local trees = parser:parse()
  local tree = trees and trees[1] or nil
  if not tree then
    entry.lang = lang
    entry.root = nil
    entry.parser = nil
    return entry
  end
  entry.lang = lang
  entry.parser = parser
  entry.root = tree:root()
  return entry
end

---@param fname string
---@return boolean
local function is_dts_file(fname)
  return fname:match('%.d%.ts$') ~= nil or fname:match('%.d%.mts$') ~= nil or fname:match('%.d%.cts$') ~= nil
end

---@param loc react_suspense_lens.LocationLike
---@param opts react_suspense_lens.Opts
---@param offset_encoding string|nil
---@return boolean
local function is_async_or_hook_via_location(loc, opts, offset_encoding)
  state.stats.def_analyze_calls = state.stats.def_analyze_calls + 1
  local t0 = hrtime_ns()

  local fname = vim.uri_to_fname(loc.uri)
  if fname == '' then
    state.stats.def_analyze_total_ms = state.stats.def_analyze_total_ms + ns_to_ms(hrtime_ns() - t0)
    return false
  end
  if is_dts_file(fname) then
    state.stats.def_analyze_total_ms = state.stats.def_analyze_total_ms + ns_to_ms(hrtime_ns() - t0)
    return false
  end

  local enc = offset_encoding or 'utf-16'
  local def_key = string.format('%s:%d:%d:%s', loc.uri, loc.range.start.line, loc.range.start.character, enc)
  local def_bufnr = loaded_bufnr_for_fname(fname)

  local stamp, stamp_kind = get_def_stamp(fname, def_bufnr or -1)
  local cached = state.def_cache[def_key]
  if cached ~= nil and cached.stamp == stamp and cached.stamp_kind == stamp_kind then
    state.stats.cache_hits = state.stats.cache_hits + 1
    state.stats.def_analyze_total_ms = state.stats.def_analyze_total_ms + ns_to_ms(hrtime_ns() - t0)
    return cached.mask ~= 0
  end
  state.stats.cache_misses = state.stats.cache_misses + 1

  local lang = def_bufnr and get_lang_for_buf(def_bufnr) or nil
  if not lang then
    lang = get_lang_for_path(fname)
  end
  if not lang then
    state.def_cache[def_key] = { mask = 0, stamp = stamp, stamp_kind = stamp_kind }
    state.stats.def_analyze_total_ms = state.stats.def_analyze_total_ms + ns_to_ms(hrtime_ns() - t0)
    return false
  end

  local mask = 0
  local row = loc.range.start.line
  if def_bufnr ~= nil then
    local ok = pcall(vim.treesitter.get_parser, def_bufnr, lang)
    if not ok then
      state.def_cache[def_key] = { mask = 0, stamp = stamp, stamp_kind = stamp_kind }
      state.stats.def_analyze_total_ms = state.stats.def_analyze_total_ms + ns_to_ms(hrtime_ns() - t0)
      return false
    end

    local col = bytecol_from_position(def_bufnr, row, loc.range.start.character, enc)
    local fn = find_definition_function_node(def_bufnr, row, col)
    if node_has_async_kw(fn) then
      mask = mask + 1
    end
    if fn and function_uses_suspense_hook(fn, def_bufnr, opts) then
      mask = mask + 2
    end
  else
    -- Avoid bufadd/bufload: parse from file text so we don't trigger autocommands or load user plugins.
    local entry = get_file_cache_entry(fname, stamp, lang, opts.max_file_bytes or defaults.max_file_bytes)
    if not entry or not entry.root then
      state.def_cache[def_key] = { mask = 0, stamp = stamp, stamp_kind = stamp_kind }
      state.stats.def_analyze_total_ms = state.stats.def_analyze_total_ms + ns_to_ms(hrtime_ns() - t0)
      return false
    end

    local line = (entry.lines and entry.lines[row + 1]) or ''
    local col = bytecol_from_line(line, loc.range.start.character, enc)

    local node = nil
    local okn, n = pcall(function()
      if entry.root.named_descendant_for_range then
        return entry.root:named_descendant_for_range(row, col, row, col + 1)
      end
      return entry.root:descendant_for_range(row, col, row, col + 1)
    end)
    if okn then
      node = n
    end

    local fn = find_definition_function_node_from_node(node)
    if node_has_async_kw(fn) then
      mask = mask + 1
    end
    if fn and function_uses_suspense_hook(fn, entry.text, opts) then
      mask = mask + 2
    end
  end

  state.def_cache[def_key] = { mask = mask, stamp = stamp, stamp_kind = stamp_kind }
  state.stats.def_analyze_total_ms = state.stats.def_analyze_total_ms + ns_to_ms(hrtime_ns() - t0)
  return mask ~= 0
end

---@param bufnr integer
---@param opts react_suspense_lens.Opts
---@return react_suspense_lens.TagItem[]
local function gather_jsx_tag_nodes(bufnr, opts)
  local lang = get_lang_for_buf(bufnr)
  if not lang then
    return {}
  end

  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not parser_ok or not parser then
    return {}
  end

  local q = get_query(lang)
  if not q then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local root = tree:root()
  local out = {}
  for _, node in q:iter_captures(root, bufnr, 0, -1) do
    if #out >= opts.max_tags then
      break
    end
    local text = get_node_text(node, bufnr)
    if text ~= '' and not starts_with_lowercase(text) and not is_suspense_name(text) then
      table.insert(out, { node = node, text = text })
    end
  end

  return out
end

---@param bufnr integer
---@param ns_id integer
local function clear_marks(bufnr, ns_id)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

---@param bufnr integer
---@return boolean
local function buf_is_visible(bufnr)
  return #vim.fn.win_findbuf(bufnr) > 0
end

---@param bufnr integer
---@param opts react_suspense_lens.Opts
local function refresh(bufnr, opts)
  local r0 = hrtime_ns()
  if not state.enabled then
    log('refresh: disabled')
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    log('refresh: invalid buffer')
    return
  end
  if vim.bo[bufnr].buftype ~= '' then
    log(string.format('refresh: skip buftype=%s %s', vim.bo[bufnr].buftype, buf_label(bufnr)))
    return
  end
  if opts.only_visible ~= false and not buf_is_visible(bufnr) then
    log(string.format('refresh: skip not visible %s', buf_label(bufnr)))
    return
  end

  ---@type react_suspense_lens.BufState
  local bstate = state.bufs[bufnr] or {}
  bstate.no_client_retries = bstate.no_client_retries or 0
  bstate.ns_idx = bstate.ns_idx or 1
  bstate.gen = (bstate.gen or 0) + 1
  local gen = bstate.gen
  bstate.last = bstate.last or {}
  bstate.last.tags = 0
  bstate.last.highlighted = 0
  bstate.last.method = nil
  bstate.last.client = nil
  state.bufs[bufnr] = bstate

  local primary_method = nil
  local client = nil
  for _, m in ipairs(opts.lsp_methods) do
    client = pick_lsp_client(bufnr, m, opts.prefer_client_names)
    if client then
      primary_method = m
      break
    end
  end
  if not client or not primary_method then
    log(string.format('refresh: no client/method %s', buf_label(bufnr)))
    if bstate.no_client_retries < (opts.no_client_max_retries or 0) then
      bstate.no_client_retries = bstate.no_client_retries + 1
      local delay = (opts.no_client_retry_ms or 250) * bstate.no_client_retries
      log(string.format('refresh: scheduling retry=%d delay=%dms %s', bstate.no_client_retries, delay, buf_label(bufnr)))
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) and state.enabled then
          debounce_refresh(bufnr, opts)
        end
      end, delay)
    end
    return
  end
  bstate.no_client_retries = 0
  bstate.last.method = primary_method
  bstate.last.client = client.name
  log(string.format('refresh: using client=%s primary_method=%s %s', client.name, primary_method, buf_label(bufnr)))

  local tags = gather_jsx_tag_nodes(bufnr, opts)
  log(string.format('refresh: tags=%d %s', #tags, buf_label(bufnr)))
  state.stats.refresh_last_buf = bufnr
  state.stats.refresh_last_tags = #tags
  bstate.last.tags = #tags

  -- If there are no JSX component tags, clear marks and stop.
  if #tags == 0 then
    clear_marks(bufnr, ns[1])
    clear_marks(bufnr, ns[2])
    local dt = ns_to_ms(hrtime_ns() - r0)
    state.stats.refresh_count = state.stats.refresh_count + 1
    state.stats.refresh_last_ms = dt
    state.stats.refresh_total_ms = state.stats.refresh_total_ms + dt
    if dt > state.stats.refresh_max_ms then
      state.stats.refresh_max_ms = dt
    end
    return
  end

  ---@type table<string, react_suspense_lens.TagItem[]>
  local by_name = {}
  ---@type string[]
  local names = {}
  for _, item in ipairs(tags) do
    local k = item.text
    local lst = by_name[k]
    if not lst then
      lst = {}
      by_name[k] = lst
      table.insert(names, k)
    end
    table.insert(lst, item)
  end

  local active_idx = bstate.ns_idx or 1
  local target_idx = 3 - active_idx
  bstate.pending_ns_idx = target_idx
  clear_marks(bufnr, ns[target_idx])

  local function refresh_still_current()
    local st = state.bufs[bufnr]
    if not st or st.gen ~= gen then
      return false
    end
    if not state.enabled then
      return false
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    if opts.only_visible ~= false and not buf_is_visible(bufnr) then
      return false
    end
    return true
  end

  local pending_names = #names
  local function finish_one()
    pending_names = pending_names - 1
    if pending_names > 0 then
      return
    end
    local st = state.bufs[bufnr]
    if not st or st.gen ~= gen or st.pending_ns_idx ~= target_idx then
      return
    end
    if not state.enabled then
      return
    end
    -- Swap namespaces: keep old marks until the new set is ready to avoid flicker.
    clear_marks(bufnr, ns[active_idx])
    st.ns_idx = target_idx
    st.pending_ns_idx = nil

    local dt = ns_to_ms(hrtime_ns() - r0)
    state.stats.refresh_count = state.stats.refresh_count + 1
    state.stats.refresh_last_ms = dt
    state.stats.refresh_total_ms = state.stats.refresh_total_ms + dt
    if dt > state.stats.refresh_max_ms then
      state.stats.refresh_max_ms = dt
    end
  end

  local function locs_all_importish_in_current_buf(locs)
    if #locs == 0 then
      return false
    end
    local cur_uri = vim.uri_from_bufnr(bufnr)
    for _, loc in ipairs(locs) do
      if loc.uri ~= cur_uri then
        return false
      end
      if not line_is_importish(bufnr, loc.range.start.line) then
        return false
      end
    end
    return true
  end

  local in_flight = 0
  local next_i = 1
  local max_conc = tonumber(opts.max_concurrent_lsp or 0) or 0
  if max_conc <= 0 then
    max_conc = 10
  end

  local function kick()
    if not refresh_still_current() then
      return
    end
    while in_flight < max_conc and next_i <= #names do
      if not refresh_still_current() then
        return
      end
      local tag_text = names[next_i]
      next_i = next_i + 1
      local items = by_name[tag_text] or {}
      local item = items[1]
      if not item then
        finish_one()
      else
        in_flight = in_flight + 1

        local sr, sc = item.node:range()
        local params = {
          textDocument = vim.lsp.util.make_text_document_params(bufnr),
          position = position_from_bytecol(bufnr, sr, sc, client.offset_encoding),
        }

        -- NOTE: In Neovim 0.10+, client.request is a wrapped function (already bound to the client),
        -- so it must be called with dot syntax, not colon syntax.
        local function set_marks_for_all()
          if not refresh_still_current() then
            return
          end
          for _, it in ipairs(items) do
            local sr2, sc2, er2, ec2 = it.node:range()
            vim.api.nvim_buf_set_extmark(bufnr, ns[target_idx], sr2, sc2, {
              end_row = er2,
              end_col = ec2,
              hl_group = opts.hl_group,
              priority = opts.priority,
            })
            state.stats.highlights_set = state.stats.highlights_set + 1
          end
          local st = state.bufs[bufnr]
          if st and st.gen == gen and st.last then
            st.last.highlighted = (st.last.highlighted or 0) + #items
          end
        end

        local function still_current()
          return refresh_still_current()
        end

        local function done()
          in_flight = in_flight - 1
          finish_one()
          if refresh_still_current() then
            vim.schedule(kick)
          end
        end

        local function try_source_definition()
          request_source_definition(client, bufnr, params.position, function(src_locs)
            if not still_current() then
              return done()
            end
            for i2 = 1, math.min(#src_locs, 10) do
              if is_async_or_hook_via_location(src_locs[i2], opts, client.offset_encoding) then
                set_marks_for_all()
                break
              end
            end
            return done()
          end)
        end

        local function try_method(idx)
          local m = opts.lsp_methods[idx]
          if not m then
            return try_source_definition()
          end
          if not client.supports_method or not client:supports_method(m) then
            return try_method(idx + 1)
          end

          state.stats.lsp_requests = state.stats.lsp_requests + 1
          local pending_key = nil
          local ok, req_id = client.request(m, params, function(_, result)
            state.stats.lsp_responses = state.stats.lsp_responses + 1
            if pending_key then
              local start = state.pending[pending_key]
              if start then
                local rtt = ns_to_ms(hrtime_ns() - start)
                state.stats.lsp_rtt_total_ms = state.stats.lsp_rtt_total_ms + rtt
                if rtt > state.stats.lsp_rtt_max_ms then
                  state.stats.lsp_rtt_max_ms = rtt
                end
                state.pending[pending_key] = nil
              end
            end

            if not still_current() then
              return done()
            end

            local locs = normalize_locations(result)
            if state.debug then
              local sample = {}
              for i = 1, math.min(#locs, 3) do
                table.insert(sample, vim.fn.fnamemodify(vim.uri_to_fname(locs[i].uri), ':t'))
              end
              log(string.format('lsp: tag=%s method=%s locs=%d [%s] %s', tag_text, m, #locs, table.concat(sample, ','), buf_label(bufnr)))
            end

            for i = 1, math.min(#locs, 10) do
              if is_async_or_hook_via_location(locs[i], opts, client.offset_encoding) then
                set_marks_for_all()
                return done()
              end
            end

            -- If definition points at the import/export in the current file, jump straight to source-definition.
            if locs_all_importish_in_current_buf(locs) then
              return try_source_definition()
            end

            -- If we got a non-.d.ts file and it doesn't match our heuristics, treat that as authoritative and stop.
            if #locs > 0 then
              local fname = vim.uri_to_fname(locs[1].uri)
              if fname ~= '' and not is_dts_file(fname) then
                return done()
              end
            end

            -- No match; try the next method (implementation/typeDefinition/etc).
            return try_method(idx + 1)
          end, bufnr)

          if not ok then
            if state.debug then
              log(string.format('lsp: request failed tag=%s method=%s %s', tag_text, m, buf_label(bufnr)))
            end
            return try_method(idx + 1)
          end
          if ok and req_id then
            pending_key = string.format('%d:%d', client.id, req_id)
            state.pending[pending_key] = hrtime_ns()
          end
        end

        try_method(1)
      end
    end
  end

  kick()

  -- NOTE: stats are finalized in finish_one() when the namespace swap occurs (after async LSP completes).
  if pending_names <= 0 then
    finish_one()
  end
end

---@param bufnr integer
---@param opts react_suspense_lens.Opts
debounce_refresh = function(bufnr, opts)
  if not state.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if opts.only_visible ~= false and not buf_is_visible(bufnr) then
    -- Avoid scheduling timers/LSP work for background buffers. We'll refresh on BufEnter/BufWinEnter.
    return
  end

  local bstate = state.bufs[bufnr]
  if not bstate then
    bstate = {}
    state.bufs[bufnr] = bstate
  end

  if bstate.timer then
    pcall(bstate.timer.stop, bstate.timer)
    pcall(bstate.timer.close, bstate.timer)
    bstate.timer = nil
  end

  local timer = vim.uv.new_timer()
  bstate.timer = timer
  timer:start(opts.debounce_ms, 0, function()
    vim.schedule(function()
      if state.bufs[bufnr] and state.bufs[bufnr].timer == timer then
        state.bufs[bufnr].timer = nil
      end
      refresh(bufnr, opts)
    end)
  end)
end

---@param opts react_suspense_lens.Opts
---@param ft string
---@return boolean
local function ft_allowed(opts, ft)
  for _, v in ipairs(opts.filetypes) do
    if v == ft then
      return true
    end
  end
  return false
end

---@param bufnr integer
---@param opts react_suspense_lens.Opts
local function attach(bufnr, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if not ft_allowed(opts, ft) then
    return
  end

  local bstate = state.bufs[bufnr]
  if bstate and bstate.attached then
    if not state.enabled then
      return
    end
    if opts.only_visible == false or buf_is_visible(bufnr) then
      debounce_refresh(bufnr, opts)
    end
    return
  end

  -- Performance: for non-visible buffers, don't register the heavy per-buffer autocmds yet.
  -- We'll finalize attach when the buffer is actually shown in a window.
  if opts.only_visible ~= false and not buf_is_visible(bufnr) then
    state.bufs[bufnr] = state.bufs[bufnr] or {}
    local group = vim.api.nvim_create_augroup('ReactSuspenseLensBufWait' .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd('BufWinEnter', {
      group = group,
      buffer = bufnr,
      once = true,
      callback = function()
        attach(bufnr, get_opts())
      end,
    })
    return
  end

  state.bufs[bufnr] = state.bufs[bufnr] or {}
  state.bufs[bufnr].attached = true

  local group = vim.api.nvim_create_augroup('ReactSuspenseLensBuf' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'TextChangedI', 'InsertLeave', 'BufWritePost' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if not state.enabled then
        return
      end
      debounce_refresh(bufnr, get_opts())
    end,
  })

  if state.enabled and (opts.only_visible == false or buf_is_visible(bufnr)) then
    debounce_refresh(bufnr, opts)
  end
end

local function apply_hl()
  local opts = get_opts()
  if not opts.define_hl then
    return
  end
  -- If the user points hl_group at a Treesitter capture (e.g. "@text.warning"),
  -- don't try to define it here.
  if type(opts.hl_group) == 'string' and opts.hl_group:sub(1, 1) == '@' then
    return
  end
  if opts.hl_link and opts.hl_group and opts.hl_group ~= opts.hl_link then
    -- Theme-controlled: link our group to a standard highlight group.
    vim.api.nvim_set_hl(0, opts.hl_group, { link = opts.hl_link, default = true })
  end
end

local function ensure_runtime()
  if state.runtime_inited then
    return
  end
  state.runtime_inited = true

  local function attach_loaded_buffers()
    local opts = get_opts()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        attach(bufnr, opts)
      end
    end
  end

  vim.api.nvim_create_user_command('ReactSuspenseLensEnable', function()
    state.enabled = true
    log('cmd: enable')
    attach_loaded_buffers()
  end, { force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensDisable', function()
    state.enabled = false
    log('cmd: disable')
    for _, st in pairs(state.bufs) do
      if st.timer then
        pcall(st.timer.stop, st.timer)
        pcall(st.timer.close, st.timer)
        st.timer = nil
      end
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      clear_marks(bufnr, ns[1])
      clear_marks(bufnr, ns[2])
    end
  end, { force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensRefresh', function()
    local bufnr = vim.api.nvim_get_current_buf()
    log(string.format('cmd: refresh %s', buf_label(bufnr)))
    state.def_cache = {}
    state.file_cache = {}
    refresh(bufnr, get_opts())
  end, { force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensClearCache', function()
    state.def_cache = {}
    state.file_cache = {}
    vim.notify('react-suspense-lens: cleared cache', vim.log.levels.INFO)
  end, { force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensStats', function()
    local s = state.stats
    local avg = (s.refresh_count > 0) and (s.refresh_total_ms / s.refresh_count) or 0
    local hit_total = s.cache_hits + s.cache_misses
    local hit_rate = (hit_total > 0) and (100 * s.cache_hits / hit_total) or 0
    vim.notify(
      string.format(
        table.concat({
          'react-suspense-lens stats:',
          'refresh: last=%.2fms avg=%.2fms max=%.2fms count=%d (last_tags=%d)',
          'lsp: requests=%d responses=%d (avg_rtt=%.2fms max_rtt=%.2fms)',
          'cache: def_entries=%d file_entries=%d hits=%d misses=%d (hit_rate=%.1f%%)',
          'def: calls=%d total=%.2fms',
          'highlights_set=%d',
        }, '\n'),
        s.refresh_last_ms,
        avg,
        s.refresh_max_ms,
        s.refresh_count,
        s.refresh_last_tags,
        s.lsp_requests,
        s.lsp_responses,
        (s.lsp_responses > 0) and (s.lsp_rtt_total_ms / s.lsp_responses) or 0,
        s.lsp_rtt_max_ms,
        vim.tbl_count(state.def_cache),
        vim.tbl_count(state.file_cache),
        s.cache_hits,
        s.cache_misses,
        hit_rate,
        s.def_analyze_calls,
        s.def_analyze_total_ms,
        s.highlights_set
      ),
      vim.log.levels.INFO
    )
  end, { force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensResetStats', function()
    state.stats = {
      refresh_count = 0,
      refresh_total_ms = 0,
      refresh_max_ms = 0,
      refresh_last_ms = 0,
      refresh_last_buf = 0,
      refresh_last_tags = 0,
      lsp_requests = 0,
      lsp_responses = 0,
      lsp_rtt_total_ms = 0,
      lsp_rtt_max_ms = 0,
      cache_hits = 0,
      cache_misses = 0,
      def_analyze_calls = 0,
      def_analyze_total_ms = 0,
      highlights_set = 0,
    }
    vim.notify('react-suspense-lens: reset stats', vim.log.levels.INFO)
  end, { force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensDebug', function(cmd)
    local arg = (cmd.args or ''):lower()
    if arg == 'on' then
      state.debug = true
    elseif arg == 'off' then
      state.debug = false
    else
      state.debug = not state.debug
    end
    vim.notify(string.format('react-suspense-lens: debug=%s', tostring(state.debug)), vim.log.levels.INFO)
  end, { nargs = '?', force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensShowLog', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'react-suspense-lens://log')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, state.logs)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'log'
    vim.cmd('botright split')
    vim.api.nvim_win_set_buf(0, buf)
  end, { force = true })

  vim.api.nvim_create_user_command('ReactSuspenseLensInspect', function()
    local bufnr = vim.api.nvim_get_current_buf()
    local ft = vim.bo[bufnr].filetype
    local lang = get_lang_for_buf(bufnr)
    local marks_a = vim.api.nvim_buf_get_extmarks(bufnr, ns[1], 0, -1, {})
    local marks_b = vim.api.nvim_buf_get_extmarks(bufnr, ns[2], 0, -1, {})
    local marks_n = #marks_a + #marks_b
    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    local names = {}
    for _, c in ipairs(clients) do
      table.insert(names, c.name)
    end
    local bstate = state.bufs[bufnr]
    local last = bstate and bstate.last or nil
    local last_s = ''
    if last then
      last_s = string.format(
        ' last_client=%s last_method=%s last_tags=%s last_highlighted=%s ns=%s',
        tostring(last.client),
        tostring(last.method),
        tostring(last.tags),
        tostring(last.highlighted),
        tostring(bstate and bstate.ns_idx or '?')
      )
    end
    vim.notify(
      string.format(
        'react-suspense-lens: enabled=%s ft=%s lang=%s extmarks=%d def_cache=%d file_cache=%d lsp_clients=%s%s',
        tostring(state.enabled),
        ft,
        tostring(lang),
        marks_n,
        vim.tbl_count(state.def_cache),
        vim.tbl_count(state.file_cache),
        table.concat(names, ','),
        last_s
      ),
      vim.log.levels.INFO
    )
  end, { force = true })

  local group = vim.api.nvim_create_augroup('ReactSuspenseLens', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(args)
      local opts = get_opts()
      if state.enabled and ft_allowed(opts, args.match) then
        attach(args.buf, opts)
      end
    end,
  })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      -- On initial open, our first refresh can run before ts_ls attaches.
      -- When an LSP attaches, kick a refresh so highlights appear without manual go-to-definition.
      if not state.enabled then
        return
      end
      if not vim.api.nvim_buf_is_valid(args.buf) then
        return
      end
      local opts = get_opts()
      if not ft_allowed(opts, vim.bo[args.buf].filetype) then
        return
      end
      local client_id = args.data and args.data.client_id or nil
      local cname = client_id and (vim.lsp.get_client_by_id(client_id) or {}).name or '?'
      log(string.format('LspAttach: client=%s %s', tostring(cname), buf_label(args.buf)))
      attach(args.buf, opts)
      vim.defer_fn(function()
        debounce_refresh(args.buf, get_opts())
      end, 150)
      if is_preferred_ts_client(opts, tostring(cname)) and (opts.only_visible == false or buf_is_visible(args.buf)) then
        schedule_warmup_refreshes(args.buf, opts)
      end
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      apply_hl()
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = { '*.ts', '*.tsx', '*.js', '*.jsx', '*.mts', '*.cts', '*.mjs', '*.cjs' },
    callback = function()
      -- Definitions can change in other buffers; simplest invalidation is to clear the cache.
      state.def_cache = {}
      state.file_cache = {}
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = group,
    callback = function(args)
      local bstate = state.bufs[args.buf]
      if bstate and bstate.timer then
        pcall(bstate.timer.stop, bstate.timer)
        pcall(bstate.timer.close, bstate.timer)
      end
      state.bufs[args.buf] = nil
    end,
  })
end

---@param user_opts react_suspense_lens.Opts|nil
function M.setup(user_opts)
  local opts = vim.tbl_deep_extend('force', {}, defaults, user_opts or {})
  state.opts = opts
  state.enabled = opts.enabled ~= false
  state.debug = opts.debug == true

  apply_hl()
  ensure_runtime()

  -- Attach to already-open buffers.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach(bufnr, opts)
    end
  end
end

return M
