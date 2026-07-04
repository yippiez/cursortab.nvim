# AGENTS.md

@CONTRIBUTING.md

## Code Style

### No Legacy Code or Backward Compatibility

When refactoring or modifying code, completely remove old implementations. DO
NOT:

- Keep deprecated functions or methods
- Add backward-compatible shims or wrappers
- Leave commented-out old code
- Add comments explaining what changed from the old version
- Rename unused parameters with underscore prefixes

Treat the new code as if it was always the correct implementation.

## Bug Investigation

When working on bugs, follow this process:

1. **Trace logs with code** - If logs are provided, go line by line through the
   code path that produced them
2. **Find the root cause** - Don't stop at symptoms; understand why the bug
   occurs
3. **Write tests first** - Before fixing, write tests that validate your
   hypothesis about the root cause
4. **Fix and verify** - Apply the fix and confirm tests pass

## Testing

This is a pure-Lua plugin. Syntax-check modules with `luajit -bl`, and load the
plugin in an isolated Neovim via `scripts/init.lua` to exercise the visuals
(`:CursortabDemo`). See CONTRIBUTING.md.
