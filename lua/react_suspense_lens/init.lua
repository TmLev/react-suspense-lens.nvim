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

---@class react_suspense_lens.State
---@field enabled boolean
---@field bufs table<integer, react_suspense_lens.BufState>
---@field def_cache table<string, integer>
---@field queries table<string, vim.treesitter.Query>

---@class react_suspense_lens.Opts
---@field enabled boolean
---@field filetypes string[]
---@field hl_group string
---@field hl_link string|nil
---@field define_hl boolean
---@field debounce_ms integer
---@field max_tags integer
---@field lsp_methods string[]
---@field prefer_client_names string[]
---@field suspense_callee_names string[]
---@field suspense_callee_suffixes string[]
---@field suspense_member_suffixes string[]
---@field priority integer

---@class react_suspense_lens.Module
---@field setup fun(user_opts?: react_suspense_lens.Opts)

---@type react_suspense_lens.Module
local M = {}

local ns = vim.api.nvim_create_namespace('react_suspense_lens')

---@type react_suspense_lens.State
local state = {
  enabled = true,
  bufs = {}, -- bufnr -> { timer = uv_timer, gen = int }
  def_cache = {}, -- def_key -> bitmask (1=async, 2=suspense-hook)
  queries = {}, -- lang -> parsed query
}

---@type react_suspense_lens.Opts
local defaults = {
  enabled = true,
  filetypes = { 'typescriptreact', 'javascriptreact' },
  hl_group = 'ReactSuspenseLensAsyncComponent',
  hl_link = 'DiagnosticUnderlineWarn',
  define_hl = true,
  debounce_ms = 200,
  max_tags = 200,
  lsp_methods = { 'textDocument/definition', 'textDocument/typeDefinition' },
  -- Prefer TS LSP clients so we don't accidentally hit e.g. tailwindcss for definition requests.
  prefer_client_names = { 'ts_ls', 'vtsls', 'tsserver', 'typescript-tools' },
  -- Heuristic: treat components that call these as "needs a Suspense boundary".
  suspense_callee_names = { 'useSuspenseQuery', 'useSuspenseQueries', 'useSuspenseInfiniteQuery', 'useSuspenseInfiniteQueries' },
  -- Heuristic: also match custom hooks that end with these suffixes, e.g. "useProjectSuspenseQuery".
  suspense_callee_suffixes = { 'SuspenseQuery', 'SuspenseQueries', 'SuspenseInfiniteQuery', 'SuspenseInfiniteQueries' },
  -- Heuristic: also match member calls that end with ".<suffix>", e.g. "trpc.foo.useSuspenseQuery".
  suspense_member_suffixes = { 'useSuspenseQuery', 'useSuspenseQueries', 'useSuspenseInfiniteQuery', 'useSuspenseInfiniteQueries' },
  priority = 10000,
}

---@param node react_suspense_lens.TSNode
---@param bufnr integer
---@return string
local function get_node_text(node, bufnr)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
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
          return client
        end
      end
    end
  end

  for _, client in ipairs(clients) do
    if client.supports_method and client:supports_method(method) then
      return client
    end
  end
  return nil
end

---@class react_suspense_lens.LocationLike
---@field uri string
---@field range lsp.Range

---@param result any
---@return react_suspense_lens.LocationLike|nil
local function normalize_location(result)
  if not result then
    return nil
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

  if vim.islist(result) then
    local first = nil
    for _, item in ipairs(result) do
      local loc = one(item)
      if loc and not first then
        first = loc
      end
      if loc then
        local fname = vim.uri_to_fname(loc.uri)
        if fname ~= '' and not fname:match('%.d%.ts$') then
          return loc
        end
      end
    end
    return first
  end

  return one(result)
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

---@param t table
---@return integer
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
---@param bufnr integer
---@return string|nil
local function get_call_function_text(call_node, bufnr)
  local fn = (call_node:field('function') or {})[1]
  if fn then
    local txt = get_node_text(fn, bufnr)
    if txt ~= '' then
      return txt
    end
  end
  -- Fallback: many grammars put the callee as the first named child.
  local ok, named_child = pcall(function()
    return call_node:named_child(0)
  end)
  if ok and named_child then
    local txt = get_node_text(named_child, bufnr)
    if txt ~= '' then
      return txt
    end
  end
  return nil
end

---@param fn_node react_suspense_lens.TSNode
---@param def_bufnr integer
---@param opts react_suspense_lens.Opts
---@return boolean
local function function_uses_suspense_hook(fn_node, def_bufnr, opts)
  if not has_suspense_hook_opts(opts) then
    return false
  end

  for node in iter_descendants(fn_node) do
    local t = node:type()
    if t == 'call_expression' or t == 'optional_call_expression' then
      local func_txt = get_call_function_text(node, def_bufnr)
      if func_txt and matches_suspense_hook(func_txt, opts) then
        return true
      end
    end
  end
  return false
end

---@param def_bufnr integer
---@param row integer
---@param col integer
---@return react_suspense_lens.TSNode|nil
local function find_definition_function_node(def_bufnr, row, col)
  local node = ts_get_node_at_pos(def_bufnr, row, col)
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

---@param def_bufnr integer
---@param row integer
---@param col integer
---@return boolean
local function is_async_definition_at(def_bufnr, row, col)
  local fn = find_definition_function_node(def_bufnr, row, col)
  return node_has_async_kw(fn)
end

---@param loc react_suspense_lens.LocationLike
---@param opts react_suspense_lens.Opts
---@return boolean
local function is_async_or_hook_via_location(loc, opts)
  local fname = vim.uri_to_fname(loc.uri)
  if fname == '' then
    return false
  end
  if fname:match('%.d%.ts$') then
    return false
  end

  local def_key = string.format('%s:%d:%d', loc.uri, loc.range.start.line, loc.range.start.character)
  local cached = state.def_cache[def_key]
  if cached ~= nil then
    return cached ~= 0
  end

  local def_bufnr = vim.fn.bufadd(fname)
  pcall(vim.fn.bufload, def_bufnr)

  -- Ensure TS parses with a sensible language.
  local lang = get_lang_for_buf(def_bufnr)
  if not lang then
    lang = get_lang_for_path(fname)
  end
  if not lang then
    state.def_cache[def_key] = false
    return false
  end

  local ok = pcall(vim.treesitter.get_parser, def_bufnr, lang)
  if not ok then
    state.def_cache[def_key] = 0
    return false
  end

  local mask = 0

  if is_async_definition_at(def_bufnr, loc.range.start.line, loc.range.start.character) then
    mask = mask + 1
  end

  local fn = find_definition_function_node(def_bufnr, loc.range.start.line, loc.range.start.character)
  if fn and function_uses_suspense_hook(fn, def_bufnr, opts) then
    mask = mask + 2
  end

  state.def_cache[def_key] = mask
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
local function clear_marks(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

---@param bufnr integer
---@param opts react_suspense_lens.Opts
local function refresh(bufnr, opts)
  if not state.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].buftype ~= '' then
    return
  end

  local tags = gather_jsx_tag_nodes(bufnr, opts)
  clear_marks(bufnr)

  ---@type react_suspense_lens.BufState
  local bstate = state.bufs[bufnr] or {}
  bstate.gen = (bstate.gen or 0) + 1
  local gen = bstate.gen
  bstate.last = bstate.last or {}
  bstate.last.tags = #tags
  bstate.last.highlighted = 0
  bstate.last.method = nil
  bstate.last.client = nil
  state.bufs[bufnr] = bstate

  local method
  local client
  for _, m in ipairs(opts.lsp_methods) do
    client = pick_lsp_client(bufnr, m, opts.prefer_client_names)
    if client then
      method = m
      break
    end
  end
  if not client or not method then
    return
  end
  bstate.last.method = method
  bstate.last.client = client.name

  for _, item in ipairs(tags) do
    local sr, sc, er, ec = item.node:range()
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = sr, character = sc },
    }

    -- NOTE: In Neovim 0.10+, client.request is a wrapped function (already bound to the client),
    -- so it must be called with dot syntax, not colon syntax.
    client.request(method, params, function(_, result)
      local cur_state = state.bufs[bufnr]
      if not cur_state or cur_state.gen ~= gen then
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      local loc = normalize_location(result)
      if not loc then
        return
      end

      if is_async_or_hook_via_location(loc, opts) then
        -- Treesitter node ranges are byte-based; extmarks expect byte columns as well.
        vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
          end_row = er,
          end_col = ec,
          hl_group = opts.hl_group,
          priority = opts.priority,
        })
        local st = state.bufs[bufnr]
        if st and st.gen == gen and st.last then
          st.last.highlighted = (st.last.highlighted or 0) + 1
        end
      end
    end, bufnr)
  end
end

---@param bufnr integer
---@param opts react_suspense_lens.Opts
local function debounce_refresh(bufnr, opts)
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
    debounce_refresh(bufnr, opts)
    return
  end
  state.bufs[bufnr] = state.bufs[bufnr] or {}
  state.bufs[bufnr].attached = true

  local group = vim.api.nvim_create_augroup('ReactSuspenseLensBuf' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'TextChangedI', 'InsertLeave', 'BufWritePost' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      debounce_refresh(bufnr, opts)
    end,
  })

  debounce_refresh(bufnr, opts)
end

---@param user_opts react_suspense_lens.Opts|nil
function M.setup(user_opts)
  local opts = vim.tbl_deep_extend('force', {}, defaults, user_opts or {})
  state.enabled = opts.enabled ~= false

  local function apply_hl()
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

  apply_hl()

  vim.api.nvim_create_user_command('ReactSuspenseLensEnable', function()
    state.enabled = true
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        attach(bufnr, opts)
      end
    end
  end, {})

  vim.api.nvim_create_user_command('ReactSuspenseLensDisable', function()
    state.enabled = false
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      clear_marks(bufnr)
    end
  end, {})

  vim.api.nvim_create_user_command('ReactSuspenseLensRefresh', function()
    local bufnr = vim.api.nvim_get_current_buf()
    refresh(bufnr, opts)
  end, {})

  vim.api.nvim_create_user_command('ReactSuspenseLensInspect', function()
    local bufnr = vim.api.nvim_get_current_buf()
    local ft = vim.bo[bufnr].filetype
    local lang = get_lang_for_buf(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
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
        ' last_client=%s last_method=%s last_tags=%s last_highlighted=%s',
        tostring(last.client),
        tostring(last.method),
        tostring(last.tags),
        tostring(last.highlighted)
      )
    end
    vim.notify(
      string.format(
        'react-suspense-lens: enabled=%s ft=%s lang=%s extmarks=%d lsp_clients=%s%s',
        tostring(state.enabled),
        ft,
        tostring(lang),
        #marks,
        table.concat(names, ','),
        last_s
      ),
      vim.log.levels.INFO
    )
  end, {})

  local group = vim.api.nvim_create_augroup('ReactSuspenseLens', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(args)
      if state.enabled and ft_allowed(opts, args.match) then
        attach(args.buf, opts)
      end
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      apply_hl()
    end,
  })

  -- Attach to already-open buffers.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach(bufnr, opts)
    end
  end
end

return M
