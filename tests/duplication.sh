#!/usr/bin/env bash
# "No repeated functions" as a command that fails, not a rule to remember.
#
#   tests/duplication.sh [root]
#
# Exit 0 clean · 1 duplicated blocks, listed on stdout · 2 jscpd out of reach,
# which the caller reports as a skip · 3 it ran and proved nothing, which is a
# failure: jscpd exits 0 whether it read the tree or read none of it.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
REPORT="$(mktemp -d)"
trap 'rm -rf "$REPORT"' EXIT

# Pinned for the fetch, because a threshold only means anything against one
# tokenizer. A jscpd already on PATH is the machine owner's choice and is run
# as it stands.
JSCPD=jscpd@5.0.15
# Around eight lines of shell or python. Less than that is an idiom rather than
# a paste; the fixtures in tests/run.sh pin where the floor actually falls.
MIN_TOKENS=30
MIN_LINES=5
# Code only. Repeated prose is a judgement a tokenizer cannot make, and a gate
# that fires on documentation is one people learn to ignore.
FORMATS=bash,python
# Worktrees under .claude are whole copies of the checkout, so every file in one
# duplicates its original. The globs match absolute paths, so they are anchored
# at ROOT: a floating **/.claude/** also swallows a checkout that lives under
# one, which is where an agent's worktree sits.
IGNORE="$ROOT/.claude/**,$ROOT/**/node_modules/**"

# The npx cache answers offline; a cold one fetches once. Neither is a
# dependency of the hooks, which stay stdlib-only — this runs at test time.
via=""
if command -v jscpd >/dev/null 2>&1; then
  via=path
elif command -v npx >/dev/null 2>&1; then
  if npx --offline --yes "$JSCPD" --version >/dev/null 2>&1; then
    via=cache
  elif npx --yes "$JSCPD" --version >/dev/null 2>&1; then
    via=registry
  fi
fi

case "$via" in
  path)     run=(jscpd) ;;
  cache)    run=(npx --offline --yes "$JSCPD") ;;
  registry) run=(npx --yes "$JSCPD") ;;
  *) echo "jscpd is not installed and could not be fetched: npm i -g $JSCPD"; exit 2 ;;
esac

out="$("${run[@]}" --min-tokens "$MIN_TOKENS" --min-lines "$MIN_LINES" \
  --format "$FORMATS" --ignore "$IGNORE" --threshold 0 \
  --reporters console,json --output "$REPORT" --no-colors "$ROOT" 2>&1)"
rc=$?

case "$rc" in
  0) ;;
  # jscpd signals the threshold with 1, so any other code is the tool failing.
  1) printf '%s\n' "$out"; exit 1 ;;
  *) printf 'jscpd exited %s\n%s\n' "$rc" "$out"; exit 3 ;;
esac

# A missing path, an unknown format and an ignore glob that swallowed the tree
# all exit 0 as well, having read nothing. The file count is what separates a
# gate that passed from one that never looked.
files="$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["statistics"]["total"]["sources"])
except Exception:
    print(0)' "$REPORT/jscpd-report.json" 2>/dev/null)"
case "$files" in ''|*[!0-9]*) files=0 ;; esac
if [ "$files" -eq 0 ]; then
  printf 'jscpd read no %s file under %s\n' "$FORMATS" "$ROOT"
  exit 3
fi
exit 0
