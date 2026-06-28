#!/usr/bin/env bash
# Text pipeline. Each step is a bash function that wraps a small python snippet.
# Steps are composed with shell pipes.
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib/py.sh"
source "$here/lib/text_ops.sh"

# -> add a `count_tokens` step: print the number of whitespace tokens on stdin
