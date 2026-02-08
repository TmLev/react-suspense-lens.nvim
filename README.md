# react-suspense-lens.nvim

Highlights React components that likely require a Suspense boundary:

- `async function Component()` (async server components)
- Heuristic: component body calls `useSuspenseQuery(...)` (or member calls like `trpc.foo.useSuspenseQuery(...)`)
- Heuristic: component body calls a custom hook that ends in `SuspenseQuery`/`SuspenseQueries` (e.g. `useProjectSuspenseQuery(...)`)

## Requirements

- Neovim 0.10+
- `nvim-treesitter` with `tsx` parser installed
- A TypeScript LSP attached to the buffer (e.g. `ts_ls`, `vtsls`, `tsserver`)

## Setup (lazy.nvim)

```lua
{
  'TmLev/react-suspense-lens.nvim',
  event = { 'BufReadPre', 'BufNewFile' },
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
  opts = {},
}
```

## Commands

- `:ReactSuspenseLensEnable`
- `:ReactSuspenseLensDisable`
- `:ReactSuspenseLensRefresh`
- `:ReactSuspenseLensInspect`

## Highlighting

By default `ReactSuspenseLensAsyncComponent` links to `DiagnosticUnderlineWarn` so your colorscheme controls the look.
