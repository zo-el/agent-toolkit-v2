#!/usr/bin/env bash
# Launcher for any long-lived background process — a dev server, a watcher, a
# tail. Registers it against the Claude CLI that owns this shell so reap.sh can
# clean it up if it is ever left behind.
#
#   bg.sh [--log FILE] -- cmd args...
#
# A raw `nohup cmd &` reparents to init and outlives everything; nothing ever
# cleans it up.
#
# Ownership is the owning CLI's pid plus its kernel start time, not the session
# id: subagents inherit the session id from their parent, and /clear or /resume
# rotates it while the process lives. A pid+start-time pair is stable across
# both, and it is the thing that actually dies when the session is over.
set -uo pipefail

reg="$HOME/.claude/bg-procs"
mkdir -p "$reg"

log=/dev/null
[ "${1:-}" = "--log" ] && { log="$2"; shift 2; }
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "usage: bg.sh [--log FILE] -- cmd args..." >&2; exit 2; }

# comm can contain spaces and parentheses, so cut past the last ')' first.
start_of() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
ppid_of()  { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }

owner=""
p="$$"
while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
  [ -f "$HOME/.claude/sessions/$p.json" ] && { owner="$p"; break; }
  p="$(ppid_of "$p")"
done

setsid "$@" >"$log" 2>&1 </dev/null &
pid=$!

# Built with jq so a command containing quotes or newlines cannot corrupt the
# entry — a malformed entry reads back as an empty pid and gets pruned, which
# orphans the process for good.
if command -v jq >/dev/null 2>&1; then
  jq -n --argjson pid "$pid" --arg start "$(start_of "$pid")" \
        --arg owner "$owner" --arg owner_start "${owner:+$(start_of "$owner")}" \
        --arg session "${CLAUDE_CODE_SESSION_ID:-unknown}" --args \
        '{pid:$pid, start:$start, owner:$owner, owner_start:$owner_start,
          session:$session, cmd:$ARGS.positional}' "$@" > "$reg/.$pid.json.tmp"
else
  printf '{"pid":%d,"start":"%s","owner":"%s","owner_start":"%s"}\n' \
    "$pid" "$(start_of "$pid")" "$owner" "${owner:+$(start_of "$owner")}" > "$reg/.$pid.json.tmp"
fi
# Renamed into place, so the reaper never reads an entry half written.
mv -f "$reg/.$pid.json.tmp" "$reg/$pid.json"

echo "background pid $pid (owner CLI ${owner:-unknown}, log $log)"
