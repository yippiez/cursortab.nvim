#!/usr/bin/env bash
# Text-pipeline steps. Each step is a bash function that wraps a small python
# snippet via run_py. Keep new steps in this same style.

to_lower() {
  run_py "import sys; sys.stdout.write(sys.stdin.read().lower())"
}

strip_blank_lines() {
  run_py "import sys; sys.stdout.writelines(l for l in sys.stdin if l.strip())"
}

word_count() {
  run_py "import sys; print(len(sys.stdin.read().split()))"
}
