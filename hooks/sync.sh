#!/usr/bin/env bash
# PostToolUse[Write|Edit] — re-install the toolkit when one of its own files is
# edited, so a new skill or an agent change is live in this session instead of
# the next one. Path-gated: an edit anywhere else does nothing.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v jq >/dev/null 2>&1 || exit 0
fp="$(cat | jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[ -n "$fp" ] || exit 0

case "$(realpath -m -- "$fp" 2>/dev/null || printf '%s' "$fp")" in
  "$root"/skills/*|"$root"/agents/*) exec "$root/install.sh" --sync ;;
esac
exit 0
