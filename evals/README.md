# evals/

Offline evaluation harness for cursortab's **local** completion quality.

Each eval is a **self-contained folder** under `evals/`:

```
evals/<eval-name>/
  README.md     # what this eval probes + success criteria (human-readable)
  eval.json     # machine spec: target file, cursor, context files, expectations
  repo/         # a small made-up codebase that provides the context
```

The harness (`run.py`) loads an eval, assembles the prompt under one or more
**context conditions**, sends it to a running `llama-server`, and checks the
completion against the eval's `expect` rules.

## Why
Measure, reproducibly, whether feeding more/better *local* context (sibling
files, LSP-style signatures, retrieved chunks) actually improves completions —
separating "the model can't" from "we didn't give it the context".

## Run
```bash
# against a running server (sweep-server / qwen-server on :8000)
python3 evals/run.py evals/python-function-in-bash --provider fim
python3 evals/run.py --all --provider sweep --url http://localhost:8000
```

`--provider`:
- `fim`   — Qwen2.5-Coder-style FIM (`<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`, repo tokens for cross-file context)
- `sweep` — Sweep next-edit format (`<|file_sep|>` current/original/updated + `<|cursor|>`)

## Conditions
- `baseline`     — current file only
- `files-around` — current file + the eval's `context_files`

(Further conditions — LSP signatures, BM25 chunks — to be added; see the
[Tab Analysis experiment log] for the manual versions these formalize.)

## eval.json schema
```json
{
  "name": "...",
  "target": "repo/pipeline.sh",
  "cursor": "eof",
  "context_files": ["repo/lib/text_ops.sh"],
  "expect": {
    "must_contain":     ["..."],
    "should_contain":   ["..."],
    "must_not_contain": ["..."]
  }
}
```

> Status: WIP (first eval + harness). `cursor` currently supports `eof`; marker
> and line/col positions are TODO.
