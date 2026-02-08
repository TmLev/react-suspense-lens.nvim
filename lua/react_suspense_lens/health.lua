local health = vim.health

local M = {}

---@return string[]
local function ts_parsers()
  local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
  if not ok or not parsers then
    return {}
  end
  local langs = parsers.available_parsers() or {}
  table.sort(langs)
  return langs
end

local function has_parser(lang)
  for _, p in ipairs(ts_parsers()) do
    if p == lang then
      return true
    end
  end
  return false
end

function M.check()
  health.start('react-suspense-lens.nvim')

  local v = vim.version()
  if v.major > 0 or v.minor >= 10 then
    health.ok(string.format('Neovim %d.%d.%d', v.major, v.minor, v.patch))
  else
    health.error(string.format('Neovim %d.%d.%d is too old (need 0.10+)', v.major, v.minor, v.patch))
  end

  local ok_ts = pcall(function()
    return vim.treesitter.language.get_lang('typescriptreact')
  end)
  if ok_ts then
    health.ok('vim.treesitter is available')
  else
    health.error('vim.treesitter is not available')
  end

  local ok_parsers = pcall(require, 'nvim-treesitter.parsers')
  if ok_parsers then
    health.ok('nvim-treesitter is installed')
  else
    health.warn('nvim-treesitter is not installed (recommended)')
  end

  if has_parser('tsx') then
    health.ok('treesitter parser: tsx')
  else
    health.warn('treesitter parser: tsx not installed', 'Install with :TSInstall tsx')
  end

  if has_parser('typescript') then
    health.ok('treesitter parser: typescript')
  else
    health.warn('treesitter parser: typescript not installed', 'Install with :TSInstall typescript')
  end

  health.info('To validate highlighting in a TSX buffer, run :ReactSuspenseLensInspect')
end

return M
