#!/usr/bin/env bash
# run_py CODE — run a one-line python snippet with stdin/stdout passthrough.
# Every pipeline step is a thin bash wrapper over run_py (see lib/text_ops.sh).
run_py() {
  python3 -c "$1"
}
