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
# caught. A quoted mention of a gated word can trip an ask; the cost is one
# extra prompt, which is the right direction to be wrong in. The attribution
# deny is the exception: it reads one command's own text, because a mention
# must not trip a verdict there is no prompt for.
set -uo pipefail

input="$(cat)"

# Install requires jq and python3 both, and either one alone keeps the gate
# live. They are needed to read the payload only: the verdict is printed here.
if command -v jq >/dev/null 2>&1; then
  field() { printf '%s' "$input" | jq -r ".$1 // empty" 2>/dev/null; }
elif command -v python3 >/dev/null 2>&1; then
  # -I keeps the session's project directory off the import path, where its own
  # json.py would otherwise be what this reads the payload with.
  field() {
    printf '%s' "$input" | python3 -I -c '
import json, sys
try:
    node = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
for key in sys.argv[1].split("."):
    node = node.get(key) if isinstance(node, dict) else None
print(node if isinstance(node, str) else "")' "$1"
  }
else
  echo "guard: neither jq nor python3 is on PATH, so no call can be judged" >&2
  exit 0
fi

verdict() { # decision, reason
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(printf '%s' "$2" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  exit 0
}

tool="$(field tool_name)" || exit 0

# ── Linear: shared team state, so a write surfaces before it lands ────────────
case "$tool" in
  mcp__linear*)
    case "$tool" in *__list_*|*__get_*|*__search_*|*__extract_*) exit 0 ;; esac
    verdict ask "Linear write ($tool): show the change table and get approval first."
    ;;
esac

cmd="$(field tool_input.command)" || exit 0
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
# Only the writing command's own text is judged. It has to sit at a command
# position and ahead of any heredoc opener, and everything from the first
# separator after it is dropped, which leaves the same words in a printf, in a
# heredoc body, or in a grep chained behind a commit as data that passes. An
# inline heredoc body carries no separator of its own, so it is judged with the
# command that opens it.
#
# What the command does not carry cannot be read here: a message from a file
# (-F, --body-file), --amend reusing an old one, an editor session, and a
# wrapped call such as `env X=1 git commit`. The attribution settings the
# installer owns are what covers those.
gap='[^|;&'$'\n'']*'                  # options only: never past a line or a separator
at_command='(^|[;&|(){}'$'\n''])[[:blank:]]*'
writes_message="$at_command(git$gap[[:blank:]](commit|merge)\
|git$gap[[:blank:]]tag$gap[[:blank:]]-m|gh[[:blank:]]+pr[[:blank:]]+(create|edit))[[:blank:]]"
if [[ "${cmd%%<<*}" =~ $writes_message ]]; then
  message="${cmd#*"${BASH_REMATCH[0]}"}"
  case "${message%%[;|&]*}" in
    *'<<'*) ;;
    *) message="${message%%[;|&]*}" ;;
  esac
  printf '%s' "$message" | grep -qiE \
    'claude-session:|co-authored-by:[[:blank:]]*claude|generated with \[claude code\]|claude\.ai/code/session_' \
    && verdict deny "No AI attribution in a commit or a pull request. Drop the trailer and run it again."
fi

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
