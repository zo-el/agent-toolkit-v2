#!/usr/bin/env bash
# PreToolUse — the only gate. Makes CLAUDE.md's approval rules mechanical so
# they hold in auto mode and inside subagents, where no permission prompt would
# otherwise reach the user.
#
#   deny  posting publicly as the user. Never allowed, approval or not.
#   ask   anything that leaves the machine, touches the device outside the
#         workspace, destroys unrecoverable local work, or writes the Linear board.
#
# Everything else is silent — local work is free.
#
# Matching is substring-regex over the raw command, so a compound command is
# caught. A quoted mention of a gated word can trip an ask; the cost is one
# extra prompt, which is the right direction to be wrong in.
set -uo pipefail

input="$(cat)"
command -v jq >/dev/null 2>&1 || { echo "guard: jq missing — gate inactive" >&2; exit 0; }

verdict() {
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0

# ── Linear: shared team state, so a write surfaces before it lands ────────────
case "$tool" in
  mcp__linear*)
    case "$tool" in *__list_*|*__get_*|*__search_*|*__extract_*) exit 0 ;; esac
    verdict ask "Linear write ($tool) — show the change table and get approval first."
    ;;
esac

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
hit() { printf '%s' "$cmd" | grep -qE "$1"; }

# ── never: speaking publicly as the user ─────────────────────────────────────
hit '\bgh[[:space:]]+(pr|issue)[[:space:]]+comment\b' \
  && verdict deny "Never comment as the user. Draft the text and let them post it."
hit '\bgh[[:space:]]+pr[[:space:]]+review\b' \
  && verdict deny "Never submit a PR review as the user. Answer feedback with code."
hit '\bgh[[:space:]]+api\b' && hit '(comments|reviews|discussions)' \
  && hit '(--method[= ]+(POST|PUT|PATCH|DELETE)|[[:space:]]-(f|F)[[:space:]]|--(field|raw-field|input)\b)' \
  && verdict deny "Mutating a comment or review endpoint posts as the user. Never allowed."

# ── ask: anything that leaves the machine ────────────────────────────────────
hit '\bgit[[:space:]]+push\b' \
  && verdict ask "Publish gate: show the commits, a diff summary, and the exact target, then get a fresh go-ahead."
hit '\bgh[[:space:]]+pr[[:space:]]+(create|edit|merge|close|reopen|ready|lock)\b' \
  && verdict ask "Publish gate: PR actions are outward-facing. Show the plan and wait."
hit '\bgh[[:space:]]+(issue|release|gist)[[:space:]]+(create|edit|delete|close|reopen|upload)\b' \
  && verdict ask "Publish gate: outward-facing GitHub action. Needs approval for this action."
hit '\bgh[[:space:]]+repo[[:space:]]+(create|delete|edit|rename|archive|fork)\b' \
  && verdict ask "Publish gate: repository-level action. Needs approval for this action."
hit '\b(npm|yarn|pnpm|cargo)[[:space:]]+publish\b|\btwine[[:space:]]+upload\b' \
  && verdict ask "Publish gate: package publishing. Needs approval for this action."

# ── ask: the machine outside the workspace ───────────────────────────────────
hit '(^|[;&|][[:space:]]*)sudo\b' \
  && verdict ask "Touches the system outside the workspace. Needs approval for this action."
hit '\b(apt|apt-get|dnf|pacman|brew)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*install\b|\bnpm[[:space:]]+(install|i)[[:space:]][^|;&]*(-g|--global)|\bcargo[[:space:]]+install\b' \
  && verdict ask "Global install. Needs approval for this action."
hit '\bcrontab\b|\bsystemctl[[:space:]]+(--user[[:space:]]+)?(enable|disable|mask|unmask|edit)\b|\blaunchctl\b' \
  && verdict ask "Launcher, cron, or service entry. Needs approval for this action."
# Writing ~/.gitconfig, not reading it.
hit '\bgit[[:space:]]+config\b[^|;&]*--global' && ! hit '\bgit[[:space:]]+config\b[^|;&]*(--get|--list|[[:space:]]-l\b)' \
  && verdict ask "~/.gitconfig is outside the workspace. Needs approval for this action."

# Local work is free — except where git cannot get it back. The reflog covers a
# bad commit, branch, or rebase; nothing covers these. switch and checkout are
# named because --force there is reset --hard under another spelling.
hit '\bgit[[:space:]]+reset\b[^|;&]*--hard|\bgit[[:space:]]+clean\b[^|;&]*-[a-zA-Z]*f|\bgit[[:space:]]+stash[[:space:]]+(clear|drop)\b|\bgit[[:space:]]+(filter-branch|filter-repo)\b' \
  && verdict ask "Destroys uncommitted or stashed work, which the reflog cannot recover. Needs approval for this action."
hit '\bgit[[:space:]]+(switch|checkout)\b[^|;&]*[[:space:]](-f|--force|--discard-changes)([[:space:]]|$)' \
  && verdict ask "Discards uncommitted changes in the working tree. Needs approval for this action."

exit 0
