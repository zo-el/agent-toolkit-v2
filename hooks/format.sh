#!/usr/bin/env bash
# PostToolUse[Write|Edit], async — format the file that was just written, so
# formatting never depends on the model remembering to run it.
#
# Only formatters that are installed run. Prettier additionally requires a
# project config, so a repo that never opted in is not reformatted on someone
# else's defaults.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
fp="$(cat | jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[ -n "$fp" ] && [ -f "$fp" ] || exit 0

prettier_config() {
  local dir="$1"
  while [ "$dir" != "/" ]; do
    for c in .prettierrc .prettierrc.json .prettierrc.yaml .prettierrc.yml \
             .prettierrc.js prettier.config.js prettier.config.mjs; do
      [ -f "$dir/$c" ] && { printf '%s' "$dir"; return 0; }
    done
    [ -f "$dir/package.json" ] && grep -q '"prettier"' "$dir/package.json" 2>/dev/null \
      && { printf '%s' "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

case "$fp" in
  *.rs)
    command -v rustfmt >/dev/null 2>&1 && rustfmt --edition 2021 "$fp" 2>/dev/null
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.json|*.css|*.scss|*.html|*.vue|*.svelte)
    if root="$(prettier_config "$(dirname "$fp")")"; then
      bin="$root/node_modules/.bin/prettier"
      [ -x "$bin" ] || bin="$(command -v prettier || true)"
      [ -n "$bin" ] && "$bin" --write "$fp" >/dev/null 2>&1
    fi
    ;;
  *.py)
    command -v ruff >/dev/null 2>&1 && ruff format -q "$fp" 2>/dev/null \
      || { command -v black >/dev/null 2>&1 && black -q "$fp" 2>/dev/null; }
    ;;
esac
exit 0
