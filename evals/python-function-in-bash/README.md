# python-function-in-bash

**Probe:** can the model define a new bash function that wraps a Python snippet,
following a convention it can only learn from *neighbouring files*?

## The repo (`repo/`)
A tiny text-processing pipeline where every step is a bash function that wraps a
one-line Python snippet via a `run_py` helper:

- `repo/lib/py.sh`        — defines `run_py`
- `repo/lib/text_ops.sh`  — example steps `to_lower`, `strip_blank_lines`, `word_count` (all use `run_py "..."`)
- `repo/pipeline.sh`      — the file being edited; ends with a comment asking for a new `count_tokens` step

## Task
At the end of `pipeline.sh` (the cursor position) complete a `count_tokens`
bash function that prints the number of whitespace tokens on stdin — in the same
`run_py "..."` style as the sibling functions.

## Success criteria (`eval.json`)
- **must contain** `run_py`          → picked up the repo convention
- **should contain** `count_tokens`  → wrote the requested function
- **must NOT contain** `pip install` → the generic-boilerplate failure mode

## Why it mirrors a real problem (but isn't it)
Same *shape* as "define python-functions-in-bash using sibling examples", but
made-up content (a text pipeline, not a compute/augmentation CLI) — so it tests
the mechanism, not one specific codebase.
