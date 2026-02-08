# Changelog

## Unreleased

- TBD

## 0.1.0 - 2026-02-08

- Highlight JSX component tags that likely require a Suspense boundary.
- Detect async components and components that call Suspense hooks (including custom `*SuspenseQuery*` hooks).
- Tree-sitter driven JSX tag scanning + TypeScript LSP resolution.
- Module name: `react-suspense-lens` (kebab-case). Backwards-compatible alias: `react_suspense_lens`.
- Performance controls: `only_visible`, per-name de-duping, `max_concurrent_lsp`, `max_file_bytes`.
- Debugging/profiling commands: `Inspect`, `Stats`, `ShowLog`.
