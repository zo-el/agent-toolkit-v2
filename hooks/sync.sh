#!/usr/bin/env bash
# PostToolUse[Write|Edit]: re-apply the toolkit when one of its own skills or
# agents is edited, so the change is live in this session instead of the next
# one. Path-gated: an edit anywhere else does nothing.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v jq >/dev/null 2>&1 || exit 0
fields="$(jq -r '[.hook_event_name // "PostToolUse", .tool_input.file_path // ""] | @json' 2>/dev/null)" || exit 0
fp="$(jq -r '.[1]' <<<"$fields")"
[ -n "$fp" ] || exit 0

# install.sh shapes its report for the event, so the event goes on with it. The
# rest of the payload stays here: a Write carries the whole file.
case "$(realpath -m -- "$fp" 2>/dev/null || printf '%s' "$fp")" in
  "$root"/skills/* | "$root"/agents/*)
    exec "$root/install.sh" --sync <<<"$(jq -c '{hook_event_name: .[0]}' <<<"$fields")"
    ;;
esac
exit 0
