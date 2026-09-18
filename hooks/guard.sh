#!/usr/bin/env bash
# PreToolUse — the only gate. Makes CLAUDE.md's approval rules mechanical so
# they hold in auto mode and inside subagents, where no permission prompt would
# otherwise reach the user.
#
#   deny  posting publicly as the user, and AI attribution in a commit or a
#         pull request. Never allowed, approval or not.
#   ask   anything that leaves the machine, touches the device outside the
#         workspace, destroys unrecoverable local work, or writes the Linear board.
#
# Everything else is silent, because local work is free.
#
# Matching is substring-regex over the raw command, so a compound command is
# caught. A quoted mention of a gated word can trip a verdict; the cost is one
# extra prompt, or for attribution one command split in two, which is the right
# direction to be wrong in.
set -uo pipefail

input="$(cat)"

# A call the gate cannot read is a call it cannot clear. Built from fixed words
# so it needs none of the tools it is reporting missing.
cannot_judge() { # what is wrong
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
    "agent-toolkit's guard could not judge this call: $1. Approve it only if you would approve it unseen."
  exit 0
}

# Every rule below matches with grep and reports through sed and tr, so those
# are as load-bearing as the payload reader and are checked with it.
for t in grep sed tr; do
  command -v "$t" >/dev/null 2>&1 || cannot_judge "$t is not on PATH"
done

# jq and python3 do not accept the same JSON: an unpaired surrogate is valid to
# one and not the other. Whichever parses this payload reads it, so a payload
# jq chokes on is judged rather than waved through.
reader=""
if command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  reader=jq
elif command -v python3 >/dev/null 2>&1 \
  && printf '%s' "$input" | python3 -I -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  reader=python3
fi
[ -n "$reader" ] || cannot_judge "neither jq nor python3 can read the payload"

# -I keeps the session's project directory off the import path, where its own
# json.py would otherwise be what this reads the payload with. The value is
# written as bytes because a lone surrogate has no encoding print would accept.
field() {
  if [ "$reader" = jq ]; then
    printf '%s' "$input" | jq -r ".$1 // empty"
  else
    printf '%s' "$input" | python3 -I -c '
import json, sys
node = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    node = node.get(key) if isinstance(node, dict) else None
sys.stdout.buffer.write((node if isinstance(node, str) else "").encode("utf-8", "surrogatepass"))' "$1"
  fi
}

verdict() { # decision, reason
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(printf '%s' "$2" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  exit 0
}

tool="$(field tool_name 2>/dev/null)" || cannot_judge "reading tool_name with $reader failed"

# ── Linear: shared team state, so a write surfaces before it lands ────────────
case "$tool" in
  mcp__linear*)
    case "$tool" in *__list_*|*__get_*|*__search_*|*__extract_*) exit 0 ;; esac
    verdict ask "Linear write ($tool): show the change table and get approval first."
    ;;
esac

cmd="$(field tool_input.command 2>/dev/null)" || cannot_judge "reading the command with $reader failed"
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

# ── never: AI attribution in a commit or a pull request ──────────────────────
# CLAUDE.md forbids it outright, so there is nothing for the user to approve.
#
# Blunt on purpose. Reading only the message needs the shell's own parse of
# quoting, heredocs and separators, and every approximation of it leaked: a
# heredoc anywhere ahead of the commit turned the whole rule off. So a command
# that names a writing command and carries one of these strings is refused,
# wherever in the text either of them sits.
#
# The cost is that mentioning the words beside a commit is refused too. The
# deny says what to do about it, because there is no prompt behind it.
#
# A message the command does not carry cannot be read here: -F, --body-file,
# --amend reusing an old one, and an editor session. The attribution settings
# the installer owns are what covers those.
hit '\bgit[[:space:]][^|;&]*\b(commit|merge)\b|\bgit[[:space:]][^|;&]*\btag\b[^|;&]*[[:space:]]-m\b|\bgh[[:space:]][^|;&]*\bpr[[:space:]]+(create|edit)\b' \
  && printf '%s' "$cmd" | grep -qiE \
    'claude-session:|co-authored-by:[[:blank:]]*claude|generated with \[claude code\]|claude\.ai/code/session_' \
  && verdict deny "No AI attribution in a commit or a pull request. Drop the trailer. If these words are only being mentioned, split the command in two or build them from a variable."

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
