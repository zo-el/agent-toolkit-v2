#!/bin/sh
# Every command the toolkit writes into settings.json runs through the copy of
# this file at ~/.claude/agent-toolkit-run, which lives outside every version
# directory so a toolkit that moved or broke still answers.
#
#   agent-toolkit-run <caller> <entry point> [args...]
#
# caller is the event the command is wired to, statusline for the status line,
# or async for a handler nobody waits on. It decides how the command fails.
# POSIX sh, so it runs where nothing else the toolkit needs is installed.

caller=${1-}
entry=${2-}
if [ $# -ge 2 ]; then shift 2; else set --; fi
link="$HOME/.claude/agent-toolkit"

lead="agent-toolkit is unreachable, so its gate cannot judge this call"
if [ -n "$entry" ] && [ -f "$link/$entry" ] && [ -x "$link/$entry" ]; then
  [ "$caller" = PreToolUse ] || exec "$link/$entry" "$@"
  # Claude Code lets the call through on any exit but 0 and 2, which is what a
  # guard that cannot start, or crashes, exits with. Its output is held until
  # then, so half a verdict never reaches Claude Code ahead of the ask.
  out=$("$link/$entry" "$@")
  status=$?
  if [ "$status" -eq 0 ] || [ "$status" -eq 2 ]; then
    [ -z "$out" ] || printf '%s\n' "$out"
    exit "$status"
  fi
  lead="agent-toolkit's gate gave no verdict on this call"
  problem="$entry exited $status"
else
  target=$(readlink "$link" 2>/dev/null)
  if [ -z "$target" ]; then
    problem="~/.claude/agent-toolkit is not a link to a toolkit"
  elif [ ! -e "$link" ]; then
    problem="~/.claude/agent-toolkit points at $target, which is gone"
  else
    problem="${entry:-the entry point} is missing or not executable in $target"
  fi
fi
fix="cd <toolkit directory> && ./install.sh"

esc() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

case "$caller" in
  PreToolUse)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
      "$(esc "$lead: $problem. Fix: $fix")"
    ;;
  SessionStart)
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"agent-toolkit doctor:\\n%s"}}\n' \
      "agent-toolkit: 1 problem. Ask Claude to fix it, or run ./install.sh from the toolkit's current location" \
      "$(esc "✗ $problem. Fix (user): $fix")"
    ;;
  statusline)
    printf '⬡ agent-toolkit unreachable: run ./install.sh from its current location\n'
    ;;
esac
exit 0
