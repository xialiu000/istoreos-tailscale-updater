#!/bin/sh
# Run gh-submit.py with the token read from a file.
# The token never appears on the command line, in the chat, or in any log.
#
# Usage:
#   sh submit/run-submit.sh [/path/to/token-file]     (default: ~/.gh_token)
#
set -eu

f="${1:-$HOME/.gh_token}"
[ -s "$f" ] || { echo "token file missing or empty: $f" >&2; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

GH_TOKEN="$(cat "$f")"
export GH_TOKEN

exec python3 "$here/gh-submit.py"
