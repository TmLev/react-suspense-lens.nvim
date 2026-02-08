# Contributing

## Development Quickstart

- Neovim 0.10+
- `nvim-treesitter` with the `tsx` parser
- A TypeScript LSP (`ts_ls`, `vtsls`, etc.)

## Local Testing

- Load the plugin and run:
  - `:ReactSuspenseLensInspect`
  - `:ReactSuspenseLensStats`
  - `:ReactSuspenseLensDebug on` and `:ReactSuspenseLensShowLog`

## Code Style

- Keep the plugin dependency-free (runtime).
- Prefer small, explicit helpers over clever abstractions.
- Avoid expensive background work: the plugin should only do meaningful work for visible buffers.

