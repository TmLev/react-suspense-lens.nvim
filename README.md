# react-suspense-lens.nvim

Highlights React components that likely require a Suspense boundary:

- `async function Component()` (async server components)
- Heuristic: component body calls `useSuspenseQuery(...)` (or member calls like `trpc.foo.useSuspenseQuery(...)`)
- Heuristic: component body calls a custom hook that ends in `SuspenseQuery`/`SuspenseQueries` (e.g. `useProjectSuspenseQuery(...)`)

## Requirements

- Neovim 0.10+
- `nvim-treesitter` with `tsx` and `typescript` parsers installed
- A TypeScript LSP attached to the buffer (e.g. `ts_ls`, `vtsls`, `tsserver`)
  - Note: the plugin refreshes on `LspAttach`, so initial highlights may appear a moment after opening a file.
  - If the TS server is still warming up, the plugin schedules a couple refresh retries automatically.

## Setup (lazy.nvim)

```lua
{
  'TmLev/react-suspense-lens.nvim',
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
  main = 'react-suspense-lens',
  opts = {},
}
```

## Commands

- `:ReactSuspenseLensEnable`: enable highlighting (and attach to open buffers).
- `:ReactSuspenseLensDisable`: disable highlighting and clear marks from open buffers.
- `:ReactSuspenseLensRefresh`: recompute highlights for the current buffer (clears the analysis cache first).
- `:ReactSuspenseLensInspect`: prints a short status line (enabled, filetype/lang, extmarks count, cache size, LSP clients, last picked client/method).
- `:ReactSuspenseLensClearCache`: clear the definition-analysis cache.
- `:ReactSuspenseLensStats`: show profiling stats (refresh timing, cache hit-rate, LSP request counts).
- `:ReactSuspenseLensResetStats`: reset profiling stats.
- `:ReactSuspenseLensDebug [on|off]`: toggle debug logging.
- `:ReactSuspenseLensShowLog`: open the in-memory debug log buffer.

Help: `:help react-suspense-lens`

If you installed via a plugin manager, helptags are usually generated automatically.
Otherwise run `:helptags ALL`.

## Health Check

- `:checkhealth react-suspense-lens`

## Configuration

```lua
require('react-suspense-lens').setup({
  -- Highlight group used for JSX tag extmarks.
  -- Default: "ReactSuspenseLensAsyncComponent"
  hl_group = 'ReactSuspenseLensAsyncComponent',

  -- Link hl_group to a standard group so your colorscheme controls the look.
  -- Default: "DiagnosticUnderlineWarn"
  hl_link = 'DiagnosticUnderlineWarn',

  -- Heuristics for "needs Suspense" hooks.
  suspense_callee_names = { 'useSuspenseQuery' },
  suspense_callee_suffixes = { 'SuspenseQuery', 'SuspenseQueries' },
  suspense_member_suffixes = { 'useSuspenseQuery' },

  -- Performance: only refresh buffers that are visible in a window.
  -- only_visible = true,

  -- Performance: cap concurrent LSP requests per refresh (also reduces startup spikes).
  -- max_concurrent_lsp = 10,

  -- Performance/safety: cap size of definition files that are parsed from disk text (unloaded buffers).
  -- max_file_bytes = 2 * 1024 * 1024,

  -- Startup race handling:
  -- If the first refresh runs before ts_ls attaches, the plugin retries a few times.
  -- no_client_retry_ms = 250,
  -- no_client_max_retries = 8,
})
```

## Performance Notes

- The plugin avoids work for background buffers by default (`only_visible = true`).
- If you see your TS LSP stall on first open in a large file, try lowering `max_concurrent_lsp`.

## Highlighting

By default `ReactSuspenseLensAsyncComponent` links to `DiagnosticUnderlineWarn` so your colorscheme controls the look.

Implementation note: the plugin uses two internal extmark namespaces and swaps between them after a refresh completes to avoid flicker while LSP requests resolve.
