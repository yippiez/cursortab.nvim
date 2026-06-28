# TAB.md support (draft)

## Goal
Let a project pin a small doc — `TAB.md` at the workspace root — whose contents
are injected into every completion prompt as static context. This teaches the
local model project-specific conventions it cannot learn from nearby files:
custom CLIs, helper functions, naming/style rules, etc.

This is the local analogue of Cursor's project rules / AGENTS.md, but aimed at
the Tab/FIM prompt rather than a chat system prompt.

## Why
Small local models (Sweep-1.5B, Qwen-3B) reliably fail to know project-specific
APIs/CLIs from a single in-file example (see `evals/python-function-in-bash`).
Injecting the authoritative doc into context is the cheapest, most reliable fix —
no training, fully offline.

## Design
1. `tabmd.Read(workspacePath)` (`server/tabmd`) reads `<workspaceRoot>/TAB.md`,
   trims and caps it to `MaxBytes`. `workspacePath` is already on every request.
2. The prompt builders inject it as a dedicated context section, *before* the
   current-file window so it stays stable:
   - sweep provider: a `<|file_sep|>context/docs` section in `buildPrompt`
     (alongside retrieval / treesitter / diagnostics).
   - fim provider: a `<|file_sep|>TAB.md` pseudo-file in the repo-level block
     (only when repo tokens are configured).
3. Config: `provider.tab_md = true|false` (default true); optional
   `provider.tab_md_path` to override the filename/location.

## Status
- [x] `tabmd.Read` helper (this branch)
- [ ] wire into the sweep `buildPrompt`
- [ ] wire into the fim cross-file block
- [ ] config flag + lua surface
- [ ] add a `custom-cli` eval that only passes with TAB.md injected

## Open questions
- Token budget vs the ~13k context; how to trade off TAB.md against retrieval.
- Cache by mtime so we don't re-read the file on every keystroke.
