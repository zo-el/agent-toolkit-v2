#!/usr/bin/env bash
# Regression suite for the enforcement layer and the installer.
#
#   tests/run.sh
#
# Guard payloads are written to files rather than piped inline: the payload text
# names the very commands the guard flags, and a shell cannot tell a mention
# from an invocation, so an inline pipe would prompt for permission.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok()   { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  ✗ %s\n    %s\n' "$1" "$2"; }
check() { # name, expected-substring, actual
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected '$2' in: ${3:-<empty>}" ;; esac
}

# ── guard ────────────────────────────────────────────────────────────────────
echo "guard.sh"

bash_payload() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')"; }
tool_payload() { printf '{"tool_name":%s,"tool_input":{}}' "$(jq -Rn --arg t "$1" '$t')"; }

guard() { printf '%s' "$1" > "$TMP/p.json"; "$ROOT/hooks/guard.sh" < "$TMP/p.json"; }

# No output at all is how the guard says "not my business".
decision() {
  [ -n "${1//[[:space:]]/}" ] || { echo silent; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "silent"' 2>/dev/null || echo malformed
}

expect() { # name, expected decision, payload
  local got; got="$(decision "$(guard "$3")")"
  [ "$got" = "$2" ] && ok "$1" || bad "$1" "expected $2, got $got"
}

expect "git push asks"                ask    "$(bash_payload 'git push origin main')"
expect "git push inside a compound"   ask    "$(bash_payload 'cd /tmp && git push --force')"
expect "gh pr create asks"            ask    "$(bash_payload 'gh pr create --title x')"
expect "cargo publish asks"           ask    "$(bash_payload 'cargo publish')"
expect "gh pr comment is denied"      deny   "$(bash_payload 'gh pr comment 12 --body hi')"
expect "gh pr review is denied"       deny   "$(bash_payload 'gh pr review 12 --approve')"
expect "sudo asks"                    ask    "$(bash_payload 'sudo systemctl restart nginx')"
expect "global npm install asks"      ask    "$(bash_payload 'npm install -g typescript')"
expect "crontab asks"                 ask    "$(bash_payload 'crontab -e')"
expect "reset --hard asks"            ask    "$(bash_payload 'git reset --hard HEAD~1')"
expect "stash drop asks"              ask    "$(bash_payload 'git stash drop')"
expect "switch --force asks"          ask    "$(bash_payload 'git switch -f main')"
expect "checkout --force asks"        ask    "$(bash_payload 'git checkout --force main')"
expect "git config write asks"        ask    "$(bash_payload 'git config --global user.name x')"
expect "git config read is free"      silent "$(bash_payload 'git config --global --get user.email')"
expect "commit is free"               silent "$(bash_payload 'git commit -m "feat: x"')"
expect "branch is free"               silent "$(bash_payload 'git switch -c feat/x')"
expect "rebase is free"               silent "$(bash_payload 'git rebase -i main')"
expect "in-repo rm is free"           silent "$(bash_payload 'rm -rf ./build')"
expect "tests are free"               silent "$(bash_payload 'cargo test --all')"
expect "reading settings is free"     silent "$(bash_payload 'jq . ~/.claude/settings.json')"
expect "linear read is free"          silent "$(tool_payload 'mcp__linear__list_issues')"
expect "linear get is free"           silent "$(tool_payload 'mcp__linear__get_issue')"
expect "linear write asks"            ask    "$(tool_payload 'mcp__linear__save_issue')"
expect "linear delete asks"           ask    "$(tool_payload 'mcp__linear__delete_comment')"
expect "non-linear mcp is free"       silent "$(tool_payload 'mcp__context7__query-docs')"

# Without jq the guard must fail open rather than block every command. env -i so
# it sees a bare environment, which is what a hook actually gets.
mkdir -p "$TMP/nojq"
for b in bash grep sed awk cat printf; do
  p="$(command -v "$b")" && ln -sf "$p" "$TMP/nojq/$b"
done
printf '%s' "$(bash_payload 'git push')" > "$TMP/p.json"
out="$(env -i PATH="$TMP/nojq" HOME="$TMP" "$ROOT/hooks/guard.sh" < "$TMP/p.json" 2>/dev/null)"
[ -z "$out" ] && ok "fails open without jq" || bad "fails open without jq" "emitted a verdict: $out"

# ── installer ────────────────────────────────────────────────────────────────
echo "install.sh"

FAKE="$TMP/home"
mkdir -p "$FAKE/.claude"
run_install() { HOME="$FAKE" "$ROOT/install.sh" "$@" 2>&1; }
settings() { jq -r "$1" "$FAKE/.claude/settings.json" 2>/dev/null; }

# A foreign hook and a foreign key must survive every merge.
cat > "$FAKE/.claude/settings.json" <<'JSON'
{
  "theme": "dark",
  "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_ENABLE_TASKS": "false", "MY_VAR": "keep"},
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/bin/true"}]}]},
  "permissions": {"additionalDirectories": ["/my/own/dir"]}
}
JSON

out="$(run_install --dry-run)"
check "dry-run previews the settings change" "would change" "$out"
check "dry-run writes nothing" "1" "$(jq -r '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' "$FAKE/.claude/settings.json")"

out="$(run_install)"
check "install reports green" "all checks green" "$out"
check "statusline wired"      "statusline.py" "$(settings '.statusLine.command')"
check "auto mode set"         "auto"          "$(settings '.permissions.defaultMode')"
check "spawn depth set"       "2"             "$(settings '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')"
check "todo tools enabled"    "1"             "$(settings '.env.CLAUDE_CODE_ENABLE_TODO_TOOLS')"
check "tasks opt-out kept"    "false"         "$(settings '.env.CLAUDE_CODE_ENABLE_TASKS')"
check "co-authored-by off"    "false"         "$(settings '.includeCoAuthoredBy')"
check "agent teams removed"   "null"          "$(settings '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')"
check "peer inbox refused"    "refuse"        "$(settings '.crossSessionInbound')"
check "cross-machine gated"   "true"          "$(settings '.isolatePeerMachines')"
# SendMessage must stay out of the deny list: denying it would also cut off an
# agent messaging main, which is how it asks a question mid-run.
case "$(settings '.permissions.deny | join(" ")')" in
  *SendMessage*|*ListAgents*) bad "agents can still reach main" "SendMessage or ListAgents is denied" ;;
  *)                          ok "agents can still reach main" ;;
esac
missing=""
for a in "$ROOT"/agents/*.md; do
  grep -q '^tools:.*SendMessage' "$a" || missing="$missing $(basename "$a")"
done
[ -z "$missing" ] && ok "every agent carries SendMessage" || bad "every agent carries SendMessage" "missing in:$missing"
check "foreign env kept"      "keep"          "$(settings '.env.MY_VAR')"
check "foreign key kept"      "dark"          "$(settings '.theme')"
check "foreign hook kept"     "/usr/bin/true" "$(settings '[.hooks.PreToolUse[].hooks[].command] | join(" ")')"
check "foreign dir kept"      "/my/own/dir"   "$(settings '.permissions.additionalDirectories | join(" ")')"
check "checkout approved"     "$ROOT"         "$(settings '.permissions.additionalDirectories | join(" ")')"
check "credentials denied"    ".credentials.json" "$(settings '.permissions.deny | join(" ")')"
check "review plugin enabled" "true" "$(settings '.enabledPlugins["pr-review-toolkit@claude-plugins-official"]')"
check "pointer written"       "$ROOT"         "$(readlink "$FAKE/.claude/agent-toolkit")"
check "pointer imports CLAUDE.md" "agent-toolkit/CLAUDE.md" "$(cat "$FAKE/.claude/CLAUDE.md")"

for want in "guard.sh" "reap.sh" "format.sh" "sync.sh" "taskline.py" "install.sh --sync"; do
  check "wires $want" "$want" "$(settings '[.hooks[][].hooks[].command] | join(" ")')"
done
check "linear matcher wired" "mcp__linear.*" "$(settings '[.hooks.PreToolUse[].matcher] | join(" ")')"

# The recorder rides four events and no trigger is load-bearing, so all four
# have to be there — and every one of them async, or a sweep could block a turn
# or inject its stdout as context.
for want in SessionStart PreCompact UserPromptSubmit SessionEnd; do
  check "retro records on $want" "retro.py record" \
    "$(settings "[.hooks.$want[].hooks[] | select((.command // \"\") | test(\"retro\")) | .command] | join(\" \")")"
done
check "the retro sweep is asynchronous everywhere" "[true,true,true,true]" \
  "$(settings '[.hooks[][].hooks[] | select((.command // "") | test("retro")) | (.async // false)] | tostring')"
check "the prompt trigger carries an interval" "--interval 900" \
  "$(settings '[.hooks.UserPromptSubmit[].hooks[].command] | join(" ")')"
[ -s "$FAKE/.claude/retro/since" ] && ok "install stamps the since marker" \
                                   || bad "install stamps the since marker" "no ~/.claude/retro/since"
# Rewriting it would let the whole pre-toolkit corpus in.
marker="$(cat "$FAKE/.claude/retro/since")"
run_install >/dev/null
check "a re-install leaves the marker alone" "$marker" "$(cat "$FAKE/.claude/retro/since")"

# Without sqlite3 the recorder is inert and everything else is unaffected, so
# the doctor says so without failing the install.
mkdir -p "$TMP/nosqlite"
{ printf '#!/bin/sh\ncase "$*" in *"import sqlite3"*) exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v python3)"; } > "$TMP/nosqlite/python3"
chmod +x "$TMP/nosqlite/python3"
out="$(PATH="$TMP/nosqlite:$PATH" run_install)"
check "the doctor flags a python without sqlite3" "no sqlite3 module" "$out"
check "and the install is still green"            "all checks green"  "$out"
# An async hook's stdout is never injected as context, so an async taskline
# would print into the void. Asserted as the whole array, which also pins that
# exactly one entry runs it.
check "taskline is wired synchronously" "[false]" \
  "$(settings '[.hooks.UserPromptSubmit[].hooks[] | select((.command // "") | test("taskline")) | (.async // false)] | tostring')"

linked="$(find "$FAKE/.claude/skills" -maxdepth 1 -type l | wc -l | tr -d ' ')"
have="$(find "$ROOT/skills" -name SKILL.md | wc -l | tr -d ' ')"
[ "$linked" = "$have" ] && ok "all $have skills linked" || bad "skills linked" "$linked of $have"

copied="$(ls "$FAKE/.claude/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')"
agents="$(ls "$ROOT/agents"/*.md | wc -l | tr -d ' ')"
[ "$copied" = "$agents" ] && ok "all $agents agents copied" || bad "agents copied" "$copied of $agents"

out="$(run_install)"
check "re-install is idempotent" "already current" "$out"

# Replacing the checkout: links into the one we replaced still resolve, so they
# survive the broken-link prune and would keep firing retired skills.
OLD="$TMP/old-checkout"
mkdir -p "$OLD/skills/retired" "$OLD/agents" "$OLD/hooks"
touch "$OLD/skills/retired/SKILL.md"
mkdir -p "$TMP/my-skills/mine-too"
touch "$TMP/my-skills/mine-too/SKILL.md"
ln -sfn "$OLD/skills/retired" "$FAKE/.claude/skills/retired"
ln -sfn "$TMP/my-skills/mine-too" "$FAKE/.claude/skills/mine-too"   # the user's own, unrelated
ln -sfn "$OLD" "$FAKE/.claude/agent-toolkit"
run_install >/dev/null
[ ! -e "$FAKE/.claude/skills/retired" ] && ok "stale checkout skill unlinked" || bad "stale checkout skill unlinked" "still linked"
[ -L "$FAKE/.claude/skills/mine-too" ] && ok "unrelated skill link kept" || bad "unrelated skill link kept" "removed"
rm -f "$FAKE/.claude/skills/mine-too"

# A retired agent is pruned; one the user wrote is left alone.
touch "$FAKE/.claude/agents/mine.md"
echo "stale.md" >> "$FAKE/.claude/agents/.toolkit-agents"
touch "$FAKE/.claude/agents/stale.md"
run_install >/dev/null
[ ! -e "$FAKE/.claude/agents/stale.md" ] && ok "retired agent pruned" || bad "retired agent pruned" "still there"
[ -e "$FAKE/.claude/agents/mine.md" ] && ok "user agent untouched" || bad "user agent untouched" "deleted"

# The doctor must notice its own wiring going missing, not just bad paths.
jq 'del(.hooks.PreToolUse)' "$FAKE/.claude/settings.json" > "$TMP/s" && mv "$TMP/s" "$FAKE/.claude/settings.json"
out="$(run_install --sync)"
check "sync flags stale settings" "stale" "$out"
run_install >/dev/null

# ── switching off the previous generation ────────────────────────────────────
# The whole point of the cutover: after installing over a v1 machine, nothing v1
# may still be wired. A leftover skill or agent keeps instructing sessions from
# a generation whose rules no longer hold.
echo "switch from v1"

# Names deliberately share no prefix: an assertion that matched one inside the
# other would pass or fail for the wrong reason.
V1="$TMP/old-checkout-v1"; V1HOME="$TMP/machine-on-v1"
mkdir -p "$V1"/{hooks,agents} "$V1HOME/.claude"/{skills,agents}
for s in orchestrating-subagents develop feature-spec linear-sync retro chore; do
  mkdir -p "$V1/skills/group/$s" && touch "$V1/skills/group/$s/SKILL.md"
done
for a in architect-designer lead developer project-manager researcher reviewer; do
  printf 'v1 agent\n' > "$V1/agents/$a.md"
done
for h in guard-git guard-config guard-linear format-on-edit sync-on-skill-edit reap-managed spawn-managed; do
  printf '#!/bin/sh\n' > "$V1/hooks/$h.sh" && chmod +x "$V1/hooks/$h.sh"
done
printf '#!/bin/sh\n' > "$V1/install-skills.sh" && chmod +x "$V1/install-skills.sh"

# Wire the fake home exactly as a v1 install leaves it.
ln -sfn "$V1" "$V1HOME/.claude/agent-toolkit"
for d in "$V1"/skills/group/*/; do ln -sfn "${d%/}" "$V1HOME/.claude/skills/$(basename "${d%/}")"; done
for a in "$V1"/agents/*.md; do cp "$a" "$V1HOME/.claude/agents/"; basename "$a"; done > "$V1HOME/.claude/agents/.toolkit-agents"
# ...plus things that are the user's, which must survive untouched.
mkdir -p "$TMP/user-skill/my-skill" && touch "$TMP/user-skill/my-skill/SKILL.md"
ln -sfn "$TMP/user-skill/my-skill" "$V1HOME/.claude/skills/my-skill"
printf 'mine\n' > "$V1HOME/.claude/agents/my-agent.md"
cat > "$V1HOME/.claude/settings.json" <<JSON
{
  "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "3"},
  "statusLine": {"type": "command", "command": "$V1HOME/.claude/agent-toolkit/hooks/statusline.py"},
  "permissions": {"additionalDirectories": ["$V1"]},
  "hooks": {
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "$V1HOME/.claude/agent-toolkit/install.sh --sync"}]}],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$V1HOME/.claude/agent-toolkit/hooks/guard-git.sh"}]},
      {"matcher": "Write|Edit|NotebookEdit", "hooks": [{"type": "command", "command": "$V1HOME/.claude/agent-toolkit/hooks/guard-config.sh"}]},
      {"matcher": "mcp__linear.*", "hooks": [{"type": "command", "command": "$V1HOME/.claude/agent-toolkit/hooks/guard-linear.sh"}]}
    ],
    "SubagentStop": [{"hooks": [{"type": "command", "command": "$V1HOME/.claude/agent-toolkit/hooks/reap-managed.sh"}]}]
  }
}
JSON
printf '@%s/.claude/agent-toolkit/CLAUDE.md\n' "$V1HOME" > "$V1HOME/.claude/CLAUDE.md"

HOME="$V1HOME" "$ROOT/install.sh" >/dev/null 2>&1
v1s() { jq -r "$1" "$V1HOME/.claude/settings.json" 2>/dev/null; }

left="$(ls -1 "$V1HOME/.claude/skills" | grep -Ex 'orchestrating-subagents|develop|feature-spec|linear-sync|retro|chore' | tr '\n' ' ')"
[ -z "$left" ] && ok "v1 skills unlinked" || bad "v1 skills unlinked" "still present: $left"

left="$(ls -1 "$V1HOME/.claude/agents" | grep -Ex 'architect-designer.md|lead.md' | tr '\n' ' ')"
[ -z "$left" ] && ok "retired v1 agents pruned" || bad "retired v1 agents pruned" "still present: $left"

grep -q 'v1 agent' "$V1HOME/.claude/agents/developer.md" \
  && bad "shared agent names overwritten" "developer.md is still the v1 file" \
  || ok "shared agent names overwritten"

wired="$(v1s '[.hooks[][].hooks[].command] + [.statusLine.command] | join(" ")')"
left=""
for h in guard-git guard-config guard-linear format-on-edit sync-on-skill-edit reap-managed install-skills; do
  case "$wired" in *"$h"*) left="$left $h" ;; esac
done
[ -z "$left" ] && ok "no v1 hook still wired" || bad "no v1 hook still wired" "wired:$left"

check "v1 SubagentStop entry dropped" "null" "$(v1s '.hooks.SubagentStop')"
check "v1 agent-teams flag dropped"   "null" "$(v1s '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')"
check "v1 spawn depth replaced"       "2"    "$(v1s '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')"

jq -e --arg v "$V1" '(.permissions.additionalDirectories | index($v)) == null' \
  "$V1HOME/.claude/settings.json" >/dev/null 2>&1 \
  && ok "old checkout dropped from approved dirs" \
  || bad "old checkout dropped from approved dirs" "$V1 is still approved"

[ -L "$V1HOME/.claude/skills/my-skill" ] && ok "user's own skill survives" || bad "user's own skill survives" "removed"
grep -q mine "$V1HOME/.claude/agents/my-agent.md" 2>/dev/null && ok "user's own agent survives" || bad "user's own agent survives" "removed"
check "pointer re-aimed at v2" "$ROOT" "$(readlink "$V1HOME/.claude/agent-toolkit")"

# ── statusline ───────────────────────────────────────────────────────────────
echo "statusline.py"

# Placeholders have to be inert next to the populated form, so these assertions
# pin the escape sequences rather than the bare text.
dim() { printf '\033[2m%s\033[0m' "$1"; }
sep=$'\033[2m│\033[0m'

# Reset times are relative to now, so the fixture computes them rather than
# pinning epochs that would go stale and silently stop exercising the branch.
# The extra 30s absorbs the seconds that pass before the script reads the clock:
# remaining time is floored, so a bare 2h14m would render as 2h13m.
in2h=$(( $(date +%s) + 2*3600 + 14*60 + 30 ))
in4d=$(( $(date +%s) + 4*86400 + 3*3600 + 30 ))
# The task directory is named for the full session id with agent teams off, and
# session-<first8> with them on. Both layouts must be found.
mkdir -p "$FAKE/.claude/tasks/abc12345-dead-beef"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/abc12345-dead-beef/1.json"
printf '{"id":"2","status":"in_progress"}' > "$FAKE/.claude/tasks/abc12345-dead-beef/2.json"
printf '{"id":"3","status":"pending"}' > "$FAKE/.claude/tasks/abc12345-dead-beef/3.json"

payload='{"model":{"display_name":"Opus 5","id":"claude-opus-5[1m]"},
  "cwd":"'"$ROOT"'","effort":{"level":"xhigh"},"session_id":"abc12345-dead-beef",
  "context_window":{"total_input_tokens":120000,"used_percentage":12},
  "cost":{"total_cost_usd":1.5,"total_lines_added":10,"total_lines_removed":2},
  "pr":{"number":42,"review_state":"approved"},
  "rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'"$in2h"'},
                 "seven_day":{"used_percentage":12,"resets_at":'"$in4d"'}}}'
out="$(printf '%s' "$payload" | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "renders the model"    "Opus 5" "$out"
check "renders 1M marker"    "1M"     "$out"
check "renders the effort"   "xhigh"  "$out"
check "renders the context"  "12%"    "$out"
check "renders lines changed" "$(printf '\033[32m+10\033[0m\033[2m/\033[0m\033[31m-2\033[0m')" "$out"
check "renders hours left"   "$(printf '\033[2m⏱ 30%% 2h14m')" "$out"
check "renders days left"    "4d3h"   "$out"
check "renders task progress" "1/3"   "$out"
check "renders the PR"       "#42"    "$out"
case "$out" in
  *'$'*)  bad "never renders a dollar amount" "printed: $out" ;;
  *'5h'*) bad "no fixed window label when a reset time is known" "printed: $out" ;;
  *)      ok "no dollar amount, no fixed window label" ;;
esac

# The opening of a session: the line counters are still 0, and the CLI omits
# rate_limits until it has a window to report — on an API key, never. Both
# segments hold their slot dim, in order, so the bar keeps its shape throughout.
out="$(printf '%s' '{"cwd":"/","cost":{"total_cost_usd":0,"total_lines_added":0,"total_lines_removed":0}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "zero lines hold the slot"      "$(dim '+0/-0')" "$out"
check "absent limits hold the slot"   "$(dim '⏱ —')"   "$out"
check "placeholders keep their order" "$(dim '+0/-0') $sep $(dim '⏱ —')" "$out"

# A rate_limits key carrying nothing usable is the same not-yet-known state.
out="$(printf '%s' '{"cwd":"/","rate_limits":{"five_hour":{}}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "unusable limits hold the slot" "$(dim '⏱ —')" "$out"

# Without resets_at the labels have to come back, or two bare percentages give
# no way to tell the windows apart.
out="$(printf '%s' '{"cwd":"/","rate_limits":{"five_hour":{"used_percentage":30},"seven_day":{"used_percentage":12}}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "falls back to window labels" "5h 30%" "$out"
check "labels both windows"         "7d 12%" "$out"

# The team-derived layout must be found too, so the segment survives whichever
# way the platform names the directory.
mkdir -p "$FAKE/.claude/tasks/session-99999999"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/session-99999999/1.json"
printf '{"id":"2","status":"pending"}' > "$FAKE/.claude/tasks/session-99999999/2.json"
out="$(printf '%s' '{"cwd":"/","session_id":"99999999-aaaa-bbbb"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "finds the team-named task dir" "1/2" "$out"

out="$(printf '%s' '{"cwd":"/","session_id":"no-such-session-at-all"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
case "$out" in *☰*) bad "no task dir renders nothing" "printed: $out" ;; *) ok "no task dir renders nothing" ;; esac

# The session's own empty directory must not win over the team-named one that
# holds the list; and a file that is valid JSON but not an object costs its own
# entry plus the claim that the count is the whole list — the ? says so, and the
# green "everything is done" is withheld because it would not be true.
mkdir -p "$FAKE/.claude/tasks/slteam77-aaaa-bbbb" "$FAKE/.claude/tasks/session-slteam77"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/session-slteam77/1.json"
printf '[1,2]' > "$FAKE/.claude/tasks/session-slteam77/2.json"
out="$(printf '%s' '{"cwd":"/","session_id":"slteam77-aaaa-bbbb"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "an empty directory does not hide the team-named list" "$(dim '☰ 1/1?')" "$out"

# A list read whole, with nothing left open, is the one case that renders green.
mkdir -p "$FAKE/.claude/tasks/sldone-aaaa-bbbb"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/sldone-aaaa-bbbb/1.json"
printf '{"id":"2","status":"completed"}' > "$FAKE/.claude/tasks/sldone-aaaa-bbbb/2.json"
out="$(printf '%s' '{"cwd":"/","session_id":"sldone-aaaa-bbbb"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "a whole list with nothing open renders green" "$(printf '\033[32m☰ 2/2\033[0m')" "$out"

# A reset time already in the past must not render a negative or absurd span: the
# window drops back to its label. Asserted as the exact segment, since a glob for
# a stray minus also matches the lines placeholder.
past=$(( $(date +%s) - 500 ))
out="$(printf '%s' '{"cwd":"/","rate_limits":{"five_hour":{"used_percentage":9,"resets_at":'"$past"'}}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "stale reset time renders the label, not a negative span" "$(dim '⏱ 5h 9%')" "$out"

# With no payload, every segment fed by it must drop out rather than guess —
# except the two placeholders, which hold width without claiming a measurement.
# Segments read from disk (directory, toolkit stamp) legitimately stay.
for label in "empty stdin" "malformed stdin" "non-object stdin"; do
  case "$label" in
    "empty stdin")  data="" ;;
    "malformed stdin") data="not json" ;;
    *)              data="[1,2]" ;;   # parses, then breaks every .get()
  esac
  out="$(printf '%s' "$data" | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
  case "$out" in
    *Traceback*)             bad "$label never crashes" "$out" ;;
    *%*|*'$'*|*⚡*|*▰*|*▱*)  bad "$label invents no payload segment" "printed: $out" ;;
    *)                       ok "$label degrades safely" ;;
  esac
  check "$label keeps the placeholders" "$(dim '+0/-0') $sep $(dim '⏱ —')" "$out"
done

# ── taskline ─────────────────────────────────────────────────────────────────
echo "taskline.py"

# The contract is: exactly one line, on stdout, only when it is true, and never
# a failed turn. stdout and stderr are captured apart — the harness injects only
# stdout, so a line written to stderr would kill the feature while looking fine.
HINT='Tasks: none open — open a lane before acting. Tools are deferred: ToolSearch "select:TaskCreate,TaskUpdate,TaskGet,TaskList"'
SPEC='Retro — spec (in_progress, arch-retro)'

tl_with() { # environment assignments, payload → tl_out, tl_err, tl_rc
  tl_out="$(printf '%s' "$2" | env HOME="$FAKE" $1 python3 "$ROOT/hooks/taskline.py" 2>"$TMP/tl.err")"; tl_rc=$?
  tl_err="$(cat "$TMP/tl.err")"
}
tl() { tl_with "" "$1"; }
prompt() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"go"}' "$1"; }
task() { mkdir -p "$1" && printf '%s' "$3" > "$1/$2"; }   # dir, file, json

clean() { # name → true when the turn survived: exit 0, nothing on stderr
  { [ "$tl_rc" = 0 ] && [ -z "$tl_err" ]; } && return 0
  bad "$1" "exit $tl_rc, stderr: ${tl_err:-<none>}"; return 1
}
survives() { clean "$1" && ok "$1"; }
is_line() { # name — one non-empty line on stdout
  clean "$1" || return
  [ -n "$tl_out" ] || { bad "$1" "printed nothing"; return; }
  [ "$(printf '%s\n' "$tl_out" | wc -l)" = 1 ] && ok "$1" || bad "$1" "not one line: $tl_out"
}
exact() { # name, expected stdout
  clean "$1" || return
  [ "$tl_out" = "$2" ] && ok "$1" || bad "$1" "expected '$2', got '${tl_out:-<empty>}'"
}
quiet() { tl "$2"; exact "$1" ""; }   # name, payload

OPEN="$FAKE/.claude/tasks/tl-open"
task "$OPEN" 1.json '{"id":"1","subject":"Retro — audit","status":"completed","blocks":[],"blockedBy":[]}'
task "$OPEN" 2.json '{"id":"2","subject":"Retro — spec","status":"in_progress","owner":"arch-retro","blocks":["3"],"blockedBy":[]}'
task "$OPEN" 3.json '{"id":"3","subject":"Retro — build","status":"pending","blocks":[],"blockedBy":["2"]}'
tl "$(prompt tl-open)"
is_line "an open list is one line"
exact "names every open task with status and owner" "Tasks: 2 open · $SPEC · Retro — build (blocked)"

# An ascii output encoding would raise on the first separator and lose the whole
# line. PYTHONIOENCODING stands in for the C-locale machine that does the same.
tl_with "PYTHONIOENCODING=ascii" "$(prompt tl-open)"
exact "an ascii output encoding keeps the line whole" "Tasks: 2 open · $SPEC · Retro — build (blocked)"

# The line sits in a block buffer until the process ends, so a reader that
# closed the pipe turns the interpreter's own shutdown flush into a failed turn
# — after every guard in the hook has gone out of scope.
printf '%s' "$(prompt tl-open)" > "$TMP/tl.payload"
HOME="$FAKE" python3 "$ROOT/hooks/taskline.py" < "$TMP/tl.payload" 2>"$TMP/tl.err" | true
tl_rc=${PIPESTATUS[0]}
{ [ "$tl_rc" = 0 ] && [ ! -s "$TMP/tl.err" ]; } \
  && ok "a closed pipe is still a clean exit" \
  || bad "a closed pipe is still a clean exit" "exit $tl_rc, stderr: $(cat "$TMP/tl.err")"

# stdout closed outright, where python hands the hook no stream at all. The line
# has nowhere to go, which is not a bug and must not be reported as one.
HOME="$FAKE" python3 "$ROOT/hooks/taskline.py" < "$TMP/tl.payload" >&- 2>"$TMP/tl.err"
tl_rc=$?
{ [ "$tl_rc" = 0 ] && [ ! -s "$TMP/tl.err" ]; } \
  && ok "closed stdout is still a clean exit" \
  || bad "closed stdout is still a clean exit" "exit $tl_rc, stderr: $(cat "$TMP/tl.err")"

# hooks/lib/__init__.py is a comment and nothing else, and it is load-bearing:
# without it, any lib package on PYTHONPATH takes over the import.
mkdir -p "$TMP/shadow/lib"
: > "$TMP/shadow/lib/__init__.py"
cat > "$TMP/shadow/lib/tasks.py" <<'PY'
from collections import namedtuple

TaskList = namedtuple("TaskList", "tasks complete")


def load_tasks(_):
    return TaskList([{"id": "1", "subject": "HIJACKED", "status": "pending"}], True)
PY
tl_with "PYTHONPATH=$TMP/shadow" "$(prompt tl-open)"
exact "a lib on PYTHONPATH cannot hijack the import" "Tasks: 2 open · $SPEC · Retro — build (blocked)"

# blocked is derived, so every way of not being blocked must read as pending: a
# blocker that finished, one that is not in the list at all, and a field of the
# wrong type — which must cost the derivation and not the line.
task "$OPEN" 3.json '{"id":"3","subject":"Retro — build","status":"pending","blocks":[],"blockedBy":["1"]}'
tl "$(prompt tl-open)"
exact "a finished blocker does not block" "Tasks: 2 open · $SPEC · Retro — build (pending)"
task "$OPEN" 3.json '{"id":"3","subject":"Retro — build","status":"pending","blocks":[],"blockedBy":["99"]}'
tl "$(prompt tl-open)"
exact "a dangling blocker does not block" "Tasks: 2 open · $SPEC · Retro — build (pending)"
task "$OPEN" 3.json '{"id":"3","subject":"Retro — build","status":"pending","blocks":[],"blockedBy":7}'
tl "$(prompt tl-open)"
exact "an unusable blockedBy costs the derivation only" "Tasks: 2 open · $SPEC · Retro — build (pending)"
# Ids are strings on disk today; integers must derive the same answer. Both the
# id and the blocker are integers here, or the comparison passes on one side.
task "$OPEN" 2.json '{"id":2,"subject":"Retro — spec","status":"in_progress","owner":"arch-retro","blocks":[3],"blockedBy":[]}'
task "$OPEN" 3.json '{"id":3,"subject":"Retro — build","status":"pending","blocks":[],"blockedBy":[2]}'
tl "$(prompt tl-open)"
exact "integer ids still derive blocked" "Tasks: 2 open · $SPEC · Retro — build (blocked)"
# Every field on the line is free text on the same line, so every field is cut.
task "$OPEN" 3.json "{\"id\":\"3\",\"subject\":\"Retro — build\",\"status\":\"pending\",\"owner\":\"$(printf 'o%.0s' $(seq 40))\",\"blockedBy\":[]}"
tl "$(prompt tl-open)"
exact "a long owner is cut too" "Tasks: 2 open · $SPEC · Retro — build (pending, $(printf 'o%.0s' $(seq 23))…)"
task "$OPEN" 3.json "{\"id\":\"3\",\"subject\":\"Retro — build\",\"status\":\"$(printf 's%.0s' $(seq 40))\",\"blockedBy\":[]}"
tl "$(prompt tl-open)"
exact "a long status is cut too" "Tasks: 2 open · $SPEC · Retro — build ($(printf 's%.0s' $(seq 15))…)"

# The tools are deferred, so a session that never searched for their schemas
# cannot open a task at all — which is exactly the session this line lands in.
tl "$(prompt tl-no-such-session)"
is_line "an empty list is one line"
exact "no task dir names the deferred tools" "$HINT"

task "$FAKE/.claude/tasks/tl-all-done" 1.json '{"id":"1","subject":"Lane — build","status":"completed","blocks":[],"blockedBy":[]}'
tl "$(prompt tl-all-done)"
exact "an all-complete list counts as none open" "$HINT"

# Agent teams name the directory session-<first8>, and the session's own empty
# directory sits beside it. The decoy must not win, or the list goes quiet.
mkdir -p "$FAKE/.claude/tasks/tlteam99-aaaa-bbbb"
TEAM="$FAKE/.claude/tasks/session-tlteam99"
task "$TEAM" 1.json '{"id":"1","subject":"Lane — spec","status":"completed","blocks":[],"blockedBy":[]}'
task "$TEAM" 2.json '{"id":"2","status":"pending","blocks":[],"blockedBy":[]}'
tl "$(prompt tlteam99-aaaa-bbbb)"
exact "an empty dir does not hide the team-named list" 'Tasks: 1 open · untitled (pending)'

# A list read in part says so. A bare count would read as the whole truth, and
# task files are written while this hook reads them on every prompt. Nesting
# deep enough to exhaust the stack is a file that will not parse like any other.
MAL="$FAKE/.claude/tasks/tl-malformed"
task "$MAL" 1.json 'not json at all'
task "$MAL" 2.json '[1,2]'
task "$MAL" 4.json "$(python3 -c "import sys; sys.stdout.write('[' * 200000)")"
task "$MAL" 3.json '{"id":"3","subject":"Lane — sane\nsecond line","status":"pending","blocks":[],"blockedBy":[]}'
tl "$(prompt tl-malformed)"
is_line "a partly read list is one line"
exact "an unparsable entry marks the line partial" \
  'Tasks: 1 open (partial list) · Lane — sane second line (pending)'
rm -f "$MAL/3.json"
quiet "a list that will not parse at all says nothing" "$(prompt tl-malformed)"

# Root reads a chmod 000 file regardless, so the assertions that depend on the
# read failing are skipped there rather than inverted.
UNREAD="$FAKE/.claude/tasks/tl-unreadable"
task "$UNREAD" 1.json '{"id":"1","subject":"Lane — build","status":"pending","blocks":[],"blockedBy":[]}'
task "$UNREAD" 2.json '{"id":"2","subject":"Lane — hidden","status":"pending","blocks":[],"blockedBy":[]}'
chmod 000 "$UNREAD/2.json"
tl "$(prompt tl-unreadable)"
survives "an unreadable file never fails the turn"
[ "$(id -u)" -eq 0 ] || exact "an unreadable file marks the line partial" \
  'Tasks: 1 open (partial list) · Lane — build (pending)'
chmod 644 "$UNREAD/2.json"

# A task file that is already gone is not one that would not read: the platform
# deletes the whole list when the last task completes, and a read that races it
# is still a whole read of what is there. A dangling symlink stands in for the
# file that disappears between the listing and the open.
GONE="$FAKE/.claude/tasks/tl-gone"
task "$GONE" 1.json '{"id":"1","subject":"Lane — build","status":"pending","blocks":[],"blockedBy":[]}'
ln -sfn /nonexistent-task-file "$GONE/2.json"
tl "$(prompt tl-gone)"
exact "a task file already gone is not an unreadable one" 'Tasks: 1 open · Lane — build (pending)'

# A directory that will not list is not an empty one, and saying "none open"
# there would instruct the model to open a lane that already exists.
BLOCKED="$FAKE/.claude/tasks/tl-blocked-dir"
task "$BLOCKED" 1.json '{"id":"1","subject":"Lane — build","status":"pending","blocks":[],"blockedBy":[]}'
chmod 000 "$BLOCKED"
tl "$(prompt tl-blocked-dir)"
survives "an unlistable task dir never fails the turn"
[ "$(id -u)" -eq 0 ] || exact "an unlistable task dir says nothing rather than guessing" ""
chmod 755 "$BLOCKED"

# Whichever layout answered first, an unlistable one beside it means the list
# may not be the whole list — the flag has to survive the early answer. This is
# the agent-teams shape: a stale directory found first, the real one refusing.
ASYM="$FAKE/.claude/tasks/tlasym01-aaaa-bbbb"
task "$ASYM" 1.json '{"id":"1","subject":"Lane — stale","status":"pending","blocks":[],"blockedBy":[]}'
TEAMDIR="$FAKE/.claude/tasks/session-tlasym01"
task "$TEAMDIR" 9.json '{"id":"9","subject":"Lane — real","status":"in_progress","blocks":[],"blockedBy":[]}'
chmod 000 "$TEAMDIR"
tl "$(prompt tlasym01-aaaa-bbbb)"
survives "an unlistable second layout never fails the turn"
[ "$(id -u)" -eq 0 ] || exact "an unlistable second layout still marks the line partial" \
  'Tasks: 1 open (partial list) · Lane — stale (pending)'
chmod 755 "$TEAMDIR"

# Over a partial list an unknown blocker is more likely a file that would not
# read than a dangling reference, and "pending" is the one wrong answer that
# gets the task picked up while something else owns it.
PART="$FAKE/.claude/tasks/tl-part-blocker"
task "$PART" 1.json '{"id":"1","subject":"Lane — spec","status":"in_progress","blocks":["2"],"blockedBy":[]}'
task "$PART" 2.json '{"id":"2","subject":"Lane — build","status":"pending","blocks":[],"blockedBy":["1"]}'
chmod 000 "$PART/1.json"
tl "$(prompt tl-part-blocker)"
[ "$(id -u)" -eq 0 ] || exact "a blocker that would not read still blocks" \
  'Tasks: 1 open (partial list) · Lane — build (blocked)'
chmod 644 "$PART/1.json"

# Sizing. At the cap every task is named and nothing is elided; past it the
# count stays true to every open task and what was dropped is stated.
MANY="$FAKE/.claude/tasks/tl-many"
for i in 1 2 3 4; do
  task "$MANY" "$i.json" "{\"id\":\"$i\",\"subject\":\"Lane — step $i\",\"status\":\"pending\",\"blocks\":[],\"blockedBy\":[]}"
done
tl "$(prompt tl-many)"
exact "at the cap nothing is elided" \
  'Tasks: 4 open · Lane — step 1 (pending) · Lane — step 2 (pending) · Lane — step 3 (pending) · Lane — step 4 (pending)'
case "$tl_out" in
  *ToolSearch*) bad "no tool hint while tasks are open" "printed: $tl_out" ;;
  *)            ok "no tool hint while tasks are open" ;;
esac

# Ids are numbers written as text, and a lane is past 9 quickly: a string sort
# would name 1, 10, 11, 2 and drop the steps actually in front of the user.
for i in 10 11; do
  task "$MANY" "$i.json" "{\"id\":\"$i\",\"subject\":\"Lane — step $i\",\"status\":\"pending\",\"blocks\":[],\"blockedBy\":[]}"
done
tl "$(prompt tl-many)"
exact "ids sort as numbers, not as text" \
  'Tasks: 6 open · Lane — step 1 (pending) · Lane — step 2 (pending) · Lane — step 3 (pending) · Lane — step 4 (pending) · +2 more'

# One line for the rest of the sizing contract: the running work is named first
# however late its id, a subject is cut to a fixed width with the cut visible,
# and the elided count covers everything that did not fit.
task "$MANY" 12.json "{\"id\":\"12\",\"subject\":\"Lane — $(printf 'x%.0s' $(seq 70))\",\"status\":\"in_progress\",\"owner\":\"dev-x\",\"blocks\":[],\"blockedBy\":[]}"
tl "$(prompt tl-many)"
is_line "a long list is still one line"
exact "running work first, subject cut, remainder counted" \
  "Tasks: 7 open · Lane — $(printf 'x%.0s' $(seq 52))… (in_progress, dev-x) · Lane — step 1 (pending) · Lane — step 2 (pending) · Lane — step 3 (pending) · +3 more"

# Nothing to say beats a guess: without a session there is no list to speak for.
quiet "no session id prints nothing"    '{"hook_event_name":"UserPromptSubmit","prompt":"go"}'
quiet "empty stdin prints nothing"      ''
quiet "malformed stdin prints nothing"  'not json'
quiet "non-object stdin prints nothing" '[1,2]'

# Both hooks import a shared module inside their own guards, so a broken one
# degrades quietly by design — the doctor is what says it out loud. Run against
# a copy of the tree, never the checkout itself.
COPY="$TMP/copy"
mkdir -p "$COPY"
tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$COPY"
rm -f "$COPY/hooks/lib/tasks.py"
check "the doctor flags a broken shared module" "hooks/lib does not import" \
  "$(HOME="$TMP/home-copy" "$COPY/install.sh" --dry-run 2>&1)"
tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$COPY"
printf '\ndef broken(\n' >> "$COPY/hooks/taskline.py"
check "the doctor flags a hook that will not compile" "does not compile" \
  "$(HOME="$TMP/home-copy" "$COPY/install.sh" --dry-run 2>&1)"

# ── retro ────────────────────────────────────────────────────────────────────
# The recorder reads Claude Code's own transcripts, so every fixture here lives
# in a fake home: HOME is the only thing that says where it looks and where it
# writes. Timestamps are literals, and `since` is set far enough back that every
# fixture is after it — a fixture dated before it is then unambiguously old.
echo "retro.py"

RH="$TMP/retro-home"
RP="$RH/.claude/projects"
mkdir -p "$RP/alpha/s-main/subagents" "$RP/beta/s-agents/subagents" "$RH/.claude/retro" \
         "$RH/.claude/skills/never-fired"
printf '2026-01-01T00:00:00Z\n' > "$RH/.claude/retro/since"

cat > "$TMP/dbq.py" <<'PY'
import os, sqlite3, sys

db = sqlite3.connect(os.path.join(os.path.expanduser("~"), ".claude", "retro", "retro.db"))
for row in db.execute(sys.argv[1]):
    print("|".join("" if v is None else str(v) for v in row))
PY

retro() { HOME="$RH" python3 "$ROOT/hooks/retro.py" "$@" </dev/null 2>"$TMP/retro.err"; }
dbq()   { HOME="$RH" python3 "$TMP/dbq.py" "$1" 2>/dev/null; }
eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '${3:-<empty>}'"; }
sql()   { eq "$1" "$2" "$(dbq "$3")"; }
# Every row of every table, read from the schema rather than from a list here:
# what "changes not one row" means, and a table or column added tomorrow is
# covered the day it lands rather than the day someone remembers.
cat > "$TMP/dbstate.py" <<'PY'
import os, sqlite3, sys

skip = set(sys.argv[1:])
db = sqlite3.connect(os.path.join(os.path.expanduser("~"), ".claude", "retro", "retro.db"))
tables = [r[0] for r in db.execute(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
for table in tables:
    if table in skip:
        continue
    cols = [c[1] for c in db.execute("PRAGMA table_info(%s)" % table)]
    cols = [c for c in cols if c != "inode"]   # changes with every fixture rewrite
    rows = db.execute("SELECT %s FROM %s ORDER BY %s" % (",".join(cols), table, ",".join(cols)))
    for row in rows:
        print(table, "|".join("" if v is None else str(v) for v in row))
PY
state()   { HOME="$RH" python3 "$TMP/dbstate.py" 2>/dev/null; }
# Everything but the cursor, for the cases where the transcript itself was
# rewritten and the cursor is supposed to move.
figures() { HOME="$RH" python3 "$TMP/dbstate.py" cursor 2>/dev/null; }

# A session that does its own work: two Bash verbs in one command, a failed Edit
# a denial refers back to, an MCP call, a hook summary, a boundary, and a retro
# line after it. m1 is written twice with one message id, which is how the CLI
# writes one response with two content blocks.
cat > "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T10:00:00.000Z","version":"2.1.232","gitBranch":"main","cwd":"/repo/alpha","message":{"role":"user","content":"go"}}
{"type":"assistant","uuid":"a1","timestamp":"2026-08-14T10:00:01.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git status && npm install -g typescript"}}]}}
{"type":"assistant","uuid":"a1b","timestamp":"2026-08-14T10:00:01.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40},"content":[{"type":"text","text":"still thinking"}]}}
{"type":"user","timestamp":"2026-08-14T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}
{"type":"assistant","uuid":"a2","timestamp":"2026-08-14T10:00:03.000Z","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/repo/alpha/x.py"}}]}}
{"type":"user","timestamp":"2026-08-14T10:00:04.000Z","toolDenialKind":"user-rejected","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"denied"}]}}
{"type":"assistant","uuid":"a2b","isSidechain":true,"timestamp":"2026-08-14T10:00:04.500Z","message":{"id":"m2b","usage":{"input_tokens":999,"output_tokens":999},"content":[{"type":"tool_use","id":"t2b","name":"Bash","input":{"command":"echo sidechain"}}]}}
{"type":"assistant","uuid":"a2c","timestamp":"2026-08-14T10:00:04.600Z","message":{"id":"m2c","content":[{"type":"tool_use","id":"t2c","name":"Bash","input":{"command":"git push origin main"}}]}}
{"type":"user","timestamp":"2026-08-14T10:00:04.700Z","toolDenialKind":"permission-rule","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2c","is_error":true,"content":"blocked"}]}}
{"type":"assistant","uuid":"a3","timestamp":"2026-08-14T10:00:05.000Z","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"mcp__linear__save_issue","input":{}}]}}
{"type":"user","timestamp":"2026-08-14T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]}}
{"type":"system","subtype":"turn_duration","durationMs":1200,"timestamp":"2026-08-14T10:00:07.000Z"}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T10:00:08.000Z","hookInfos":[{"command":"sh /home/x/.claude/agent-toolkit/hooks/taskline.py","durationMs":30}],"hookErrors":[]}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T10:00:09.000Z","hookInfos":[{"command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/notify.sh\"","durationMs":8}],"hookErrors":["Failed with non-blocking status code: /bin/sh: 1: /home/x/.claude/agent-toolkit/hooks/notify.sh: not found"]}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T10:00:10.000Z","hookInfos":[{"command":"Implement the CANARYHOOKPROSE feature end to end and prove it","durationMs":4}],"hookErrors":[]}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-14T10:06:00.000Z","compactMetadata":{"trigger":"auto","preTokens":1000,"postTokens":100,"cumulativeDroppedTokens":900,"durationMs":5000}}
{"type":"assistant","uuid":"a9","timestamp":"2026-08-14T10:07:00.000Z","message":{"id":"m9","content":[{"type":"text","text":"Retro: the session did the edits itself"}]}}
{"type":"assistant","uuid":"a8","timestamp":"2026-08-14T10:07:30.000Z","message":{"id":"m8","content":[{"type":"text","text":"**Retroactive correction:** CANARYRETROPROSE, which is not a retro line\nRetrospective aside — CANARYRETROPROSE either"}]}}
JSON

out="$(retro record)"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$TMP/retro.err" ]; } \
  && ok "record says nothing on stdout and exits 0" \
  || bad "record says nothing on stdout and exits 0" "exit $rc, out '$out', err $(cat "$TMP/retro.err")"

sql "a boundary closes the segment it ends" "compact|auto|900|5000" \
  "SELECT close_trigger,compact_trigger,dropped_tokens,compact_ms FROM segment WHERE id='s-main#0'"
sql "records after the boundary open the next segment" "s-main#1|1" \
  "SELECT id,ordinal FROM segment WHERE session_id='s-main' AND closed_seq IS NULL"
sql "the segment carries where and when it ran" "alpha|main|2.1.232|2026-08-14T10:00:00.000Z" \
  "SELECT repo,branch,cli_version,started_at FROM segment WHERE id='s-main#0'"
sql "turns are split by who took them" "1|0|5|1200|1200" \
  "SELECT user_turns,wake_turns,assistant_turns,turn_ms_total,turn_ms_max FROM segment WHERE id='s-main#0'"
# One response is written as one record per content block, all with the same
# message id and the same usage: summing per record would double every figure.
sql "usage is summed once per message, not per record" "11|22|30|40" \
  "SELECT tokens_in,tokens_out,cache_read,cache_create FROM segment WHERE id='s-main#0'"
sql "failed results are counted" "3" "SELECT tool_errors FROM segment WHERE id='s-main#0'"
sql "a tool use carries its own errors" "1|1" \
  "SELECT n,errors FROM tool_use WHERE segment_id='s-main#0' AND agent='' AND tool='Edit'"
sql "a driver keeps its subcommand" "1|1" \
  "SELECT n,errors FROM bash_verb WHERE segment_id='s-main#0' AND agent='' AND verb='git status'"
sql "a compound command counts every part" "1|1" \
  "SELECT n,errors FROM bash_verb WHERE segment_id='s-main#0' AND agent='' AND verb='npm install'"
sql "a denial names the tool it was for" "1" \
  "SELECT n FROM denial WHERE segment_id='s-main#0' AND kind='user-rejected' AND signature='Edit'"
# "Which permission prompt keeps firing" is a question about commands, so a
# denied Bash is signed with its verb rather than with the word Bash.
sql "a denied command is signed with its verb" "1" \
  "SELECT n FROM denial WHERE segment_id='s-main#0' AND kind='permission-rule' AND signature='git push'"
# A sidechain record in a session transcript is an agent's own work, counted in
# the agent's transcript. Counting it here too would read as delegation that
# never happened — and its tokens are deliberately absurd so a leak is obvious.
sql "a sidechain record in a session transcript is skipped" "0" \
  "SELECT count(*) FROM bash_verb WHERE segment_id='s-main#0' AND verb='echo'"
sql "and its tokens stay out of the segment" "11" \
  "SELECT tokens_in FROM segment WHERE id='s-main#0'"
sql "an mcp call names its server" "1" \
  "SELECT n FROM mcp_use WHERE segment_id='s-main#0' AND server='linear'"
sql "a hook is labelled, not quoted" "1|30|30" \
  "SELECT n,ms_total,ms_max FROM hook_run WHERE segment_id='s-main#0' AND hook='taskline.py'"
# The error message names the same hook with a colon stuck to it, and the
# command names it inside quotes: both have to land on the one label, or a
# hook's failures sit in a row of their own where nobody joins them up.
sql "a hook's errors land on the same label as its runs" "1|1|8" \
  "SELECT n,errors,ms_total FROM hook_run WHERE segment_id='s-main#0' AND hook='notify.sh'"
# hookInfos does not always hold a command — this store has records where it
# holds the user's prompt. A label taken from the first word of prose would be
# prompt text, which nothing here may store.
sql "a hook command that is not a command is labelled unknown" "1" \
  "SELECT n FROM hook_run WHERE segment_id='s-main#0' AND hook='unknown'"
sql "the session's own retro line is captured" "main|the session did the edits itself" \
  "SELECT author,text FROM retro_line WHERE source_uuid='a9'"
# "Retroactive" and "Retrospective" start with the word and are followed by
# ordinary prose. Without the colon they would both be harvested, which puts
# arbitrary assistant text into a store that holds counts and shapes.
sql "prose that merely starts with Retro is not a retro line" "0" \
  "SELECT count(*) FROM retro_line WHERE source_uuid='a8'"

state > "$TMP/retro.before"
retro record >/dev/null
state > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "a sweep with no new bytes changes not one row" \
  || bad "a sweep with no new bytes changes not one row" "$(diff "$TMP/retro.before" "$TMP/retro.after" | head -5)"

# Appending adds to the open segment. A trailing fragment is a record still
# being written: it must wait rather than be counted half-read.
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a10","timestamp":"2026-08-14T10:08:00.000Z","message":{"id":"m10","usage":{"input_tokens":5,"output_tokens":5},"content":[{"type":"tool_use","id":"t10","name":"Write","input":{}}]}}
JSON
printf '{"type":"assistant","uuid":"a11","timestamp":"2026-08-14T10:09:00.000Z","message":{"id":"m11","content":[{"type":"tool' >> "$RP/alpha/s-main.jsonl"
retro record >/dev/null
sql "an append lands in the open segment" "3|5" \
  "SELECT assistant_turns,tokens_in FROM segment WHERE id='s-main#1'"
sql "appending creates no second segment" "2" \
  "SELECT count(*) FROM segment WHERE session_id='s-main'"
sql "a half-written last line is not consumed" "1" \
  "SELECT count(*) FROM tool_use WHERE segment_id='s-main#1'"

printf '_use","id":"t11","name":"Glob","input":{}}]}}\n' >> "$RP/alpha/s-main.jsonl"
retro record >/dev/null
sql "the completed line is counted exactly once" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Glob'"

# A line that will not parse costs itself and nothing else.
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a12",
{"type":"assistant","uuid":"a13","timestamp":"2026-08-14T10:10:00.000Z","message":{"id":"m13","content":[{"type":"tool_use","id":"t13","name":"Read","input":{}}]}}
JSON
retro record >/dev/null
sql "a malformed line is counted, not fatal" "1|1" \
  "SELECT malformed_lines,(SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Read') FROM segment WHERE id='s-main#1'"

# A transcript whose head changed is a different file under the same name: the
# open segment is rebuilt from scratch, and the closed one is left alone.
figures > "$TMP/retro.before"
python3 - "$RP/alpha/s-main.jsonl" <<'PY'
import sys

path = sys.argv[1]
lines = open(path).read().splitlines(True)
lines[0] = lines[0].replace('"go"', '"go on then"')
open(path, "w").write("".join(lines))
PY
retro record >/dev/null
sql "a reparse leaves the closed segment untouched" "compact|1|5|11" \
  "SELECT close_trigger,user_turns,assistant_turns,tokens_in FROM segment WHERE id='s-main#0'"
sql "a reparse rebuilds the open segment without doubling it" "5|1" \
  "SELECT assistant_turns,(SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Write') FROM segment WHERE id='s-main#1'"

# No backfill, two ways: a transcript whose first record predates the marker,
# and one whose mtime does. Neither may contribute a single row.
cat > "$RP/alpha/s-ancient.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2025-11-01T10:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"old"}}
{"type":"assistant","uuid":"o1","timestamp":"2025-11-01T10:00:01.000Z","message":{"id":"mo1","content":[{"type":"tool_use","id":"o","name":"Bash","input":{"command":"ls"}}]}}
JSON
cat > "$RP/alpha/s-untouched.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T10:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"new text, old file"}}
JSON
touch -d '2025-06-01T00:00:00Z' "$RP/alpha/s-untouched.jsonl"
retro record >/dev/null
sql "a transcript older than the marker contributes nothing" "0" \
  "SELECT count(*) FROM segment WHERE session_id IN ('s-ancient','s-untouched')"
sql "but its cursor is parked at the end, so later work is caught" "2" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%s-ancient.jsonl' OR path LIKE '%s-untouched.jsonl'"
cat >> "$RP/alpha/s-ancient.jsonl" <<'JSON'
{"type":"assistant","uuid":"o2","timestamp":"2026-08-14T11:00:00.000Z","message":{"id":"mo2","content":[{"type":"tool_use","id":"o2t","name":"Bash","input":{"command":"cargo test"}}]}}
JSON
retro record >/dev/null
# A live pre-marker transcript can be caught mid-write with a record longer than
# the window a cursor is parked by. Answering "no complete line here" would park
# it at the start of the file, and the next sweep would read the whole thing —
# the backfill the marker exists to prevent.
cat > "$RP/alpha/s-bigtail.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2025-07-01T10:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"old work"}}
{"type":"assistant","uuid":"bt1","timestamp":"2025-07-01T10:00:01.000Z","message":{"id":"btm1","content":[{"type":"tool_use","id":"bt1t","name":"Bash","input":{"command":"terraform destroy"}}]}}
JSON
python3 - "$RP/alpha/s-bigtail.jsonl" <<'PY'
import sys

# A partial record larger than the chunk the parking search reads.
with open(sys.argv[1], "a") as f:
    f.write('{"type":"assistant","uuid":"bt2","text":"' + "x" * (1 << 21) + '"')
PY
retro record >/dev/null
# The parked cursor is only proved by what the sweep after it reads: parking at
# the start looks identical until the next sweep resumes from there.
retro record >/dev/null
sql "a huge unfinished record never parks a cursor at the start" "0" \
  "SELECT count(*) FROM segment WHERE session_id='s-bigtail'"
sql "and nothing of it is recorded" "0" \
  "SELECT count(*) FROM bash_verb WHERE verb='terraform destroy'"

sql "an old transcript contributes only what it gains after first contact" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-ancient#0' AND verb='cargo test'"
sql "and nothing it held before it" "0" \
  "SELECT count(*) FROM bash_verb WHERE segment_id='s-ancient#0' AND verb='ls'"
# The mtime shortcut parks a cursor without reading a byte, so the proof that it
# parked at the end rather than the start is what the next sweep does.
cat >> "$RP/alpha/s-untouched.jsonl" <<'JSON'
{"type":"assistant","uuid":"u2","timestamp":"2026-08-14T11:30:00.000Z","message":{"id":"mu2","content":[{"type":"tool_use","id":"u2t","name":"Bash","input":{"command":"terraform apply"}}]}}
JSON
retro record >/dev/null
sql "a transcript parked by its mtime gains only what comes after" "1|0" \
  "SELECT (SELECT n FROM bash_verb WHERE segment_id='s-untouched#0' AND verb='terraform apply'),
          (SELECT count(*) FROM segment WHERE id='s-untouched#0' AND user_turns > 0)"

# A second sweep, while one is running, is the same work: it must not do it
# twice. $$ is this shell, which is alive, so the lock is not stale.
printf '%s' "$$" > "$RH/.claude/retro/sweep.lock"
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a20","timestamp":"2026-08-14T10:20:00.000Z","message":{"id":"m20","content":[{"type":"tool_use","id":"t20","name":"Task","input":{}}]}}
JSON
state > "$TMP/retro.before"
retro record >/dev/null; rc=$?
state > "$TMP/retro.after"
{ [ "$rc" = 0 ] && cmp -s "$TMP/retro.before" "$TMP/retro.after"; } \
  && ok "a second concurrent sweep exits 0 and writes nothing" \
  || bad "a second concurrent sweep exits 0 and writes nothing" "exit $rc"
# A sweep that was killed leaves its lock behind, and nothing else ever removes
# it: without both steals the recorder goes silent for good, exit 0, no output.
printf '%s' "$$" > "$RH/.claude/retro/sweep.lock"
touch -d '30 minutes ago' "$RH/.claude/retro/sweep.lock"
retro record >/dev/null
sql "a lock older than ten minutes is stolen" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Task'"
[ ! -e "$RH/.claude/retro/sweep.lock" ] && ok "and the sweep that stole it cleans up" \
  || bad "and the sweep that stole it cleans up" "the lock is still there"
# A pid that no longer exists is the same condition, whatever the mtime says.
printf '4294967295' > "$RH/.claude/retro/sweep.lock"
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a21","timestamp":"2026-08-14T10:21:00.000Z","message":{"id":"m21","content":[{"type":"tool_use","id":"t21","name":"Monitor","input":{}}]}}
JSON
retro record >/dev/null
sql "a lock naming a dead process is stolen" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Monitor'"
rm -f "$RH/.claude/retro/sweep.lock"

# --interval is the whole scheduling mechanism, so it has to actually gate.
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a22","timestamp":"2026-08-14T10:22:00.000Z","message":{"id":"m22","content":[{"type":"tool_use","id":"t22","name":"WebSearch","input":{}}]}}
JSON
state > "$TMP/retro.before"
retro record --interval 3600 >/dev/null
state > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "--interval does no work twice inside its window" \
  || bad "--interval does no work twice inside its window" "it swept anyway"
retro record >/dev/null
sql "and the next sweep past the window catches up" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='WebSearch'"

# One transcript that will not open must not cost the rest of the sweep. Root
# reads a chmod 000 file regardless, so the assertion is skipped there.
cat > "$RP/alpha/s-locked.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T12:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"hi"}}
JSON
chmod 000 "$RP/alpha/s-locked.jsonl"
cat > "$RP/alpha/s-after.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T12:30:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"hi"}}
JSON
retro record >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "an unreadable transcript never fails the sweep" \
             || bad "an unreadable transcript never fails the sweep" "exit $rc"
sql "the sweep carries on past it" "1" \
  "SELECT count(*) FROM segment WHERE session_id='s-after'"
[ "$(id -u)" -eq 0 ] || sql "and the file it could not read is not recorded" "0" \
  "SELECT count(*) FROM segment WHERE session_id='s-locked'"
chmod 644 "$RP/alpha/s-locked.jsonl"

# ── delegation ───────────────────────────────────────────────────────────────
# The session transcript names an agent and nothing else. Every figure below is
# read from the agent's own transcript, opened by name at its stop.
SUB="$RP/beta/s-agents/subagents"
cat > "$SUB/agent-dev1.meta.json" <<'JSON'
{"agentType":"developer","description":"CANARYMETADESC","toolUseId":"tu1","spawnDepth":1}
JSON
# A skill's run is several records long and not every one of them is
# attributed, so an activation is counted where the run starts and nowhere
# else. The retro line is longer than the cap it is stored under.
cat > "$SUB/agent-dev1.jsonl" <<JSON
{"type":"assistant","uuid":"d1","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:00.000Z","message":{"id":"n1","usage":{"input_tokens":100,"output_tokens":200},"content":[{"type":"tool_use","id":"u1","name":"Edit","input":{}}]}}
{"type":"assistant","uuid":"d1b","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:10.000Z","message":{"id":"n1b","content":[{"type":"text","text":"still in the skill"}]}}
{"type":"assistant","uuid":"d1c","isSidechain":true,"timestamp":"2026-08-14T13:00:20.000Z","message":{"id":"n1c","content":[{"type":"text","text":"a turn the skill did not attribute"}]}}
{"type":"assistant","uuid":"d1d","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:25.000Z","message":{"id":"n1d","content":[{"type":"text","text":"and back inside it"}]}}
{"type":"assistant","uuid":"d2","isSidechain":true,"timestamp":"2026-08-14T13:00:30.000Z","message":{"id":"n2","content":[{"type":"tool_use","id":"u2","name":"Bash","input":{"command":"cargo test --all CANARYBASHARG"}}]}}
{"type":"assistant","uuid":"d2b","isSidechain":true,"attributionSkill":"backlog","timestamp":"2026-08-14T13:00:40.000Z","message":{"id":"n2b","content":[{"type":"text","text":"a different skill"}]}}
{"type":"assistant","uuid":"d2c","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:50.000Z","message":{"id":"n2c","content":[{"type":"text","text":"and the first one again"}]}}
{"type":"assistant","uuid":"d4","isSidechain":true,"timestamp":"2026-08-14T13:00:55.000Z","message":{"id":"n4","content":[{"type":"text","text":"Retro: $(printf 'w%.0s' $(seq 600))"}]}}
{"type":"assistant","uuid":"d3","isSidechain":true,"timestamp":"2026-08-14T13:01:00.000Z","message":{"id":"n3","content":[{"type":"text","text":"Retro: none"}]}}
JSON
cat > "$SUB/agent-rev2.meta.json" <<'JSON'
{"agentType":"pr-review-toolkit:code-reviewer","description":"nested","toolUseId":"tu2","parentAgentId":"dev1","spawnDepth":2}
JSON
cat > "$SUB/agent-rev2.jsonl" <<'JSON'
{"type":"assistant","uuid":"r1","isSidechain":true,"timestamp":"2026-08-14T13:02:00.000Z","message":{"id":"p1","usage":{"input_tokens":7,"output_tokens":8},"content":[{"type":"tool_use","id":"v1","name":"Read","input":{}}]}}
JSON
cat > "$SUB/agent-lost.meta.json" <<'JSON'
{"agentType":"reviewer","description":"its transcript is gone","toolUseId":"tu3","spawnDepth":1}
JSON
cat > "$SUB/agent-nometa.jsonl" <<'JSON'
{"type":"assistant","uuid":"q1","isSidechain":true,"timestamp":"2026-08-14T13:03:00.000Z","message":{"id":"q1m","content":[{"type":"tool_use","id":"w1","name":"Grep","input":{}}]}}
JSON
cat > "$SUB/agent-sync3.meta.json" <<'JSON'
{"agentType":"researcher","description":"finished before the result landed","toolUseId":"tu5","spawnDepth":1}
JSON
cat > "$SUB/agent-sync3.jsonl" <<'JSON'
{"type":"assistant","uuid":"y1","isSidechain":true,"timestamp":"2026-08-14T13:04:00.000Z","message":{"id":"y1m","usage":{"input_tokens":3,"output_tokens":4},"content":[{"type":"tool_use","id":"x1","name":"WebFetch","input":{}}]}}
JSON
cat > "$SUB/agent-running.meta.json" <<'JSON'
{"agentType":"architect","description":"has not stopped","toolUseId":"tu6","spawnDepth":1}
JSON
# A transcript that stats fine and will not open. A directory stands in for it,
# because root reads a chmod 000 file and the assertion would invert there.
mkdir -p "$SUB/agent-broken.jsonl"
cat > "$SUB/agent-broken.meta.json" <<'JSON'
{"agentType":"project-manager","description":"its transcript will not open","toolUseId":"tu7","spawnDepth":1}
JSON
# The whole path an id could traverse, laid out and readable: a real agent-x
# directory to climb out of, and a transcript and meta file at the far end,
# outside anything the sweep walks. Only the check on the id itself is between
# the notification below and this file.
mkdir -p "$SUB/agent-x"
cat > "$RP/escaped.jsonl" <<'JSON'
{"type":"assistant","uuid":"esc","isSidechain":true,"timestamp":"2026-08-14T13:02:55.000Z","message":{"id":"escm","content":[{"type":"tool_use","id":"esct","name":"Bash","input":{"command":"whoami"}}]}}
JSON
printf '{"agentType":"escaped","spawnDepth":1}\n' > "$RP/escaped.meta.json"
cat > "$SUB/agent-running.jsonl" <<'JSON'
{"type":"assistant","uuid":"z1","isSidechain":true,"timestamp":"2026-08-14T13:05:00.000Z","message":{"id":"z1m","content":[{"type":"tool_use","id":"zz","name":"Read","input":{}}]}}
JSON

cat > "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T13:00:00.000Z","version":"2.1.232","gitBranch":"main","cwd":"/repo/beta","message":{"role":"user","content":"delegate it"}}
{"type":"assistant","uuid":"s1","timestamp":"2026-08-14T13:00:01.000Z","message":{"id":"sm1","content":[{"type":"tool_use","id":"tu1","name":"Agent","input":{}}]}}
{"type":"user","timestamp":"2026-08-14T13:00:02.000Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"dev1","description":"CANARYDESCASYNC","prompt":"CANARYPROMPT","outputFile":"/tmp/x"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"launched"}]}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:01:10.000Z","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n<summary>CANARYSUMMARY</summary>\n<result>CANARYRESULT</result>\n</task-notification>"}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:01:11.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n<summary>CANARYSUMMARY</summary>\n<result>CANARYRESULT</result>\n</task-notification>"}}
{"type":"queue-operation","operation":"remove","timestamp":"2026-08-14T13:01:12.000Z","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n<summary>CANARYSUMMARY</summary>\n<result>CANARYRESULT</result>\n</task-notification>"}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:02:10.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>rev2</task-id>\n<status>completed</status>\n</task-notification>"}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:02:20.000Z","content":"<task-notification>\n<task-id>bgcmd</task-id>\n<status>completed</status>\n</task-notification>"}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:02:30.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>lost</task-id>\n<status>failed</status>\n</task-notification>"}}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:02:40.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>broken</task-id>\n<status>completed</status>\n</task-notification>"}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:02:50.000Z","content":"<task-notification>\n<task-id>x/../../../../escaped</task-id>\n<status>completed</status>\n</task-notification>"}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:03:10.000Z","content":"<task-notification>\n<task-id>nometa</task-id>\n<status>completed</status>\n</task-notification>"}
{"type":"user","timestamp":"2026-08-14T13:04:10.000Z","toolUseResult":{"agentId":"sync3","status":"completed","agentType":"researcher","totalTokens":99,"content":"CANARYSYNCCONTENT"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu5","content":"done"}]}}
{"type":"assistant","uuid":"s9","timestamp":"2026-08-14T13:05:00.000Z","message":{"id":"sm9","content":[{"type":"tool_use","id":"tu9","name":"Bash","input":{"command":"git commit -m CANARYCOMMITMSG"}}]}}
{"type":"assistant","uuid":"s11","timestamp":"2026-08-14T13:05:02.000Z","message":{"id":"sm11","content":[{"type":"tool_use","id":"tu11","name":"Bash","input":{"command":"grep -F '|' /home/x/CANARYPIPEARG.csv"}}]}}
{"type":"assistant","uuid":"s12","timestamp":"2026-08-14T13:05:03.000Z","message":{"id":"sm12","content":[{"type":"tool_use","id":"tu12","name":"Bash","input":{"command":"cat > cfg.rs << 'EOF'\n  let key = CANARYHEREDOC;\n  run(); other();\nEOF"}}]}}
{"type":"assistant","uuid":"s13","timestamp":"2026-08-14T13:05:06.000Z","message":{"id":"sm13","content":[{"type":"tool_use","id":"tu13","name":"Bash","input":{"command":"find . -name x -exec rm {} \\; CANARYESCAPED.txt"}}]}}
{"type":"assistant","uuid":"s14","timestamp":"2026-08-14T13:05:07.000Z","message":{"id":"sm14","content":[{"type":"tool_use","id":"tu14","name":"Bash","input":{"command":"git -C CANARYFLAGVAL status"}}]}}
{"type":"assistant","uuid":"s15","timestamp":"2026-08-14T13:05:08.000Z","message":{"id":"sm15","content":[{"type":"tool_use","id":"tu15","name":"Bash","input":{"command":"case \"$f\" in ;; CANARYCASEPAT.png) cp a b ;; esac"}}]}}
{"type":"assistant","uuid":"s16","timestamp":"2026-08-14T13:05:09.000Z","message":{"id":"sm16","content":[{"type":"text","text":"Here is what it printed:\n\n    Retro: CANARYQUOTEDLINE, which is pasted output and not mine\n\nRetro: the pasted line above is not the answer"}]}}
{"type":"assistant","uuid":"s17","timestamp":"2026-08-14T13:05:10.000Z","message":{"id":"sm17","content":[{"type":"tool_use","id":"tu17","name":"Bash","input":{"command":"grep -nE \"alpha|[\\\\\"x\\\\\"]|CANARYDESYNC|beta\" src/app.ts"}}]}}
{"type":"assistant","uuid":"s18","timestamp":"2026-08-14T13:05:11.000Z","message":{"id":"sm18","content":[{"type":"tool_use","id":"tu18","name":"Bash","input":{"command":"kits=\"2026-01-01-CANARYDATEID other\"; echo done"}}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T13:05:04.000Z","hookInfos":[{"command":"please audit /srv/reports/CANARYPROSEPATH.py and report back","durationMs":3}],"hookErrors":[]}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T13:05:05.000Z","hookInfos":[{"command":"bash /opt/a/first.sh","durationMs":2},{"command":"bash /opt/b/second.sh","durationMs":2}],"hookErrors":["/opt/b/second.sh: not found"]}
{"type":"user","timestamp":"2026-08-14T13:05:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu9","content":"ok"}]}}
JSON
retro record >/dev/null

sql "an async launch plus a stop yields the agent's own figures" "1|1|100|200|2" \
  "SELECT n,agents,tokens_in,tokens_out,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
sql "the agent's duration comes from its transcript" "60000" \
  "SELECT ms_total FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
sql "three deliveries of one notification are one stop" "1" \
  "SELECT n FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
# The two record shapes carry the identical payload, and either is a fence:
# rev2 is announced by a user record alone, nometa by a queue-operation alone.
sql "a user record with a task-notification origin fences" "1|2" \
  "SELECT n,spawn_depth FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='pr-review-toolkit:code-reviewer'"
sql "a queue-operation record fences too" "1" \
  "SELECT n FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='unknown'"
sql "a synchronous result is a fence like any other" "1|1" \
  "SELECT n,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='researcher'"
sql "a task with no meta file and no transcript is a background command" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%bgcmd%'"
sql "an agent id that is a path is not an id" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%escaped%'"
sql "and it fences nothing" "0" \
  "SELECT count(*) FROM agent_run WHERE agent_type='escaped'"
# One fence whose transcript is missing, one whose transcript will not open.
# Neither may cost the session file it was named in.
sql "a fence with no readable transcript is counted as lost" "2" \
  "SELECT agent_fences_lost FROM segment WHERE id='s-agents#0'"
sql "and the session file it was named in still lands" "8" \
  "SELECT n FROM tool_use WHERE segment_id='s-agents#0' AND agent='' AND tool='Bash'"
sql "and it counts no stop" "0" \
  "SELECT count(*) FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='reviewer'"
sql "a transcript with no meta file is still folded in" "1|1" \
  "SELECT n,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='unknown'"
sql "an agent that has not stopped is never opened" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%agent-running%'"
sql "the session's own work and its agents' are separable" "|Agent|1" \
  "SELECT agent,tool,n FROM tool_use WHERE segment_id='s-agents#0' AND tool='Agent'"
sql "an agent's edits are attributed to it" "developer|1" \
  "SELECT agent,n FROM tool_use WHERE segment_id='s-agents#0' AND tool='Edit'"
sql "an agent's retro line carries its type as author" "developer|" \
  "SELECT author,IFNULL(text,'') FROM retro_line WHERE source_uuid='d3'"
# Two activations, not four: the run survives a turn it did not attribute, and
# starts again only when another skill has been in between.
sql "a skill an agent loaded is recorded against it" "2" \
  "SELECT n FROM skill_use WHERE segment_id='s-agents#0' AND agent='developer' AND skill='ui-review'"
sql "and the skill that interrupted it is its own" "1" \
  "SELECT n FROM skill_use WHERE segment_id='s-agents#0' AND agent='developer' AND skill='backlog'"
# A retro line is a line, not a report: the cap is what keeps it one.
sql "a long retro line is cut to the cap" "500" \
  "SELECT length(text) FROM retro_line WHERE source_uuid='d4'"

# The privacy boundary. Every field named in the spec's "read past but never
# stored" table is planted with a canary; a driver's subcommand is captured by
# design, so the bash canary sits where an argument sits.
# Every canary sits where a real leak was found or would hide: a separator
# inside a quoted argument, a heredoc body, a path inside prompt prose, and
# every field of the spec's "read past but never stored" table.
leaked=""
for c in CANARYPROMPT CANARYDESCASYNC CANARYSYNCCONTENT CANARYSUMMARY CANARYRESULT \
         CANARYMETADESC CANARYBASHARG CANARYCOMMITMSG CANARYHOOKPROSE CANARYRETROPROSE \
         CANARYPIPEARG CANARYHEREDOC CANARYPROSEPATH CANARYESCAPED CANARYFLAGVAL \
         CANARYCASEPAT CANARYQUOTEDLINE CANARYDESYNC CANARYDATEID; do
  grep -qa "$c" "$RH"/.claude/retro/retro.db* 2>/dev/null && leaked="$leaked $c"
done
[ -z "$leaked" ] && ok "no prompt, brief, report or argument reaches the store" \
                 || bad "no prompt, brief, report or argument reaches the store" "found:$leaked"

# A separator that is itself the argument — quoted or escaped — must not split
# the line, or the filename after it becomes a command of its own. A heredoc
# body is a file being written, and a case pattern is a filename, not a command.
sql "a quoted separator is an argument, not a split" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='grep'"
sql "an escaped separator is too" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='find'"
sql "a heredoc body is not a command" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='cat'"
sql "a case pattern is not a command" "0" \
  "SELECT count(*) FROM bash_verb WHERE segment_id='s-agents#0' AND verb LIKE '%CANARY%'"
# A quote escaped inside a quoted string is past what a lexer without a shell's
# grammar can follow, so the command is not normalised at all rather than
# normalised into the fragments of its own argument.
sql "a command whose quoting cannot be followed is not guessed at" "2" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='other'"
# The one argument the store keeps, stated rather than assumed: a driver's
# subcommand, which is what tells a read from a publish. A flag's value looks
# the same and is not one.
sql "a driver's subcommand is kept, by design" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='git commit'"
sql "a driver flag's value is not a subcommand" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='git'"
# The required line is the last thing an agent writes; a Retro: above it is
# something it quoted.
sql "a quoted retro line loses to the agent's own" "the pasted line above is not the answer" \
  "SELECT text FROM retro_line WHERE source_uuid='s16'"
# hookInfos sometimes holds the user's prompt. A path inside prose is still
# prompt text, so only a script name is ever a label.
sql "a path inside prompt prose is not a hook label" "0" \
  "SELECT count(*) FROM hook_run WHERE segment_id='s-agents#0' AND hook LIKE '%CANARY%'"
# With one hook in the record the attribution is certain; with two, only the
# error message names which failed.
sql "an error among several hooks lands on the one it names" "0|1" \
  "SELECT (SELECT errors FROM hook_run WHERE segment_id='s-agents#0' AND hook='first.sh'),
          (SELECT errors FROM hook_run WHERE segment_id='s-agents#0' AND hook='second.sh')"

# A stdin payload is drained and discarded, never read.
printf '{"session_id":"x","prompt_text":"CANARYSTDIN"}' > "$TMP/retro.payload"
HOME="$RH" python3 "$ROOT/hooks/retro.py" record < "$TMP/retro.payload" >/dev/null 2>&1
grep -qa CANARYSTDIN "$RH"/.claude/retro/retro.db* 2>/dev/null \
  && bad "a hook payload never reaches the store" "CANARYSTDIN found" \
  || ok "a hook payload never reaches the store"

# Rebuilding a segment must re-read every agent it fenced, from where that
# segment first found it: not doubled, and not lost.
figures > "$TMP/retro.before"
python3 - "$RP/beta/s-agents.jsonl" <<'PY'
import sys

path = sys.argv[1]
lines = open(path).read().splitlines(True)
lines[0] = lines[0].replace('"delegate it"', '"delegate all of it"')
open(path, "w").write("".join(lines))
PY
retro record >/dev/null
figures > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "a reparse reproduces the identical delegation figures" \
  || bad "a reparse reproduces the identical delegation figures" \
         "$(diff "$TMP/retro.before" "$TMP/retro.after" | head -6)"

# An agent that is resumed stops again. New bytes are a second stop; a repeat
# delivery with none is not.
cat >> "$SUB/agent-dev1.jsonl" <<'JSON'
{"type":"assistant","uuid":"d4","isSidechain":true,"timestamp":"2026-08-14T14:00:00.000Z","message":{"id":"n4","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"u4","name":"Write","input":{}}]}}
JSON
cat >> "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T14:00:10.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n</task-notification>"}}
JSON
retro record >/dev/null
sql "new bytes since the last fence are a second stop, by one agent" "2|1|3" \
  "SELECT n,agents,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
cat >> "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T14:01:00.000Z","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n</task-notification>"}
JSON
retro record >/dev/null
sql "a fence with no new bytes adds nothing" "2|1" \
  "SELECT n,agents FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"

# A rebuild re-delivers fences this segment already counted. An agent that has
# run on since — resumed, still going, not yet fenced again — has bytes that
# belong to a stop nobody has seen. Counting them at the old fence would read as
# a lane that went round again.
cat >> "$SUB/agent-dev1.jsonl" <<'JSON'
{"type":"assistant","uuid":"d5","isSidechain":true,"timestamp":"2026-08-14T14:30:00.000Z","message":{"id":"n5","content":[{"type":"tool_use","id":"u5","name":"Glob","input":{}}]}}
JSON
python3 - "$RP/beta/s-agents.jsonl" <<'PY'
import sys

path = sys.argv[1]
lines = open(path, "rb").read().splitlines(True)
open(path, "wb").write(b"".join(lines[:-1]))
PY
retro record >/dev/null
sql "a rebuild does not re-count a stop it already has" "2|1" \
  "SELECT n,agents FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
sql "and the still-running agent's work waits for its own fence" "0" \
  "SELECT count(*) FROM tool_use WHERE segment_id='s-agents#0' AND agent='developer' AND tool='Glob'"

# Only the session transcripts are walked, one level deep. A subagent transcript
# is opened by name at a fence and never by the walk, or the whole subagent tree
# would be swept — 1,791 files here against 76 session transcripts.
mkdir -p "$RP/alpha/subagents"
cat > "$RP/alpha/subagents/agent-planted.jsonl" <<'JSON'
{"type":"assistant","uuid":"pl1","isSidechain":true,"timestamp":"2026-08-14T13:30:00.000Z","message":{"id":"pl","content":[{"type":"tool_use","id":"pl","name":"Bash","input":{"command":"whoami"}}]}}
JSON
retro record >/dev/null
sql "the walk goes one level deep and no further" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%agent-planted%'"
sql "and never opens an unfenced subagent transcript" "0" \
  "SELECT count(*) FROM cursor WHERE agent_id IS NULL AND path LIKE '%subagents%'"

# ── review ───────────────────────────────────────────────────────────────────
# Only closed segments are reviewable, so this closes the delegation segment
# first: everything above it is open except s-main#0.
cat >> "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"assistant","uuid":"s10","timestamp":"2026-08-14T14:30:00.000Z","message":{"id":"sm10","content":[{"type":"text","text":"Retro: the brief left the interval open"}]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-14T15:00:00.000Z","compactMetadata":{"trigger":"manual","preTokens":500,"postTokens":50,"cumulativeDroppedTokens":450,"durationMs":900}}
JSON
retro record >/dev/null
sql "a notification is a wake, not a user turn" "1|5" \
  "SELECT user_turns,wake_turns FROM segment WHERE id='s-agents#0'"
state > "$TMP/retro.before"
digest="$(retro review)"
state > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "review writes nothing" \
  || bad "review writes nothing" "the store changed"

# Column widths move with the data, so the digest is read with runs of spaces
# squeezed: these assert what a row says, not how wide it is.
flat="$(printf '%s' "$digest" | tr -s ' ')"
check "the digest names its window"        "segments 2 · projects 2" "$digest"
check "every grouped row carries n, segments and projects" "n segments projects" "$flat"
check "delegation separates the session"   "alpha session" "$flat"
check "delegation separates the agents"    "beta agents"   "$flat"
check "nesting above depth 1 is called out" "nested: pr-review-toolkit:code-reviewer at depth 2" "$digest"
check "an installed skill that never fired is named" "never fired: never-fired" "$digest"
check "permission friction is grouped"     "user-rejected" "$digest"
check "compaction is split auto from manual" "manual" "$digest"
check "retro lines are listed with author and date" "main beta 2026-08-14 the brief left the interval open" "$flat"
check "the count of none answers is beside them" "answered none: 1" "$digest"
# A figure that is short because something would not read has to say so, or the
# digest reads as complete when it is not.
check "the digest owns up to what it could not read" \
  "incomplete: 2 agent stops had no readable transcript" "$digest"
# Only closed segments are reviewable, and the store has open ones: the count
# the digest names has to be the closed count and not the total.
eq "the window holds closed segments only" \
  "$(dbq "SELECT count(*) FROM segment WHERE closed_seq IS NOT NULL")" \
  "$(printf '%s' "$digest" | sed -n 's/.*segments \([0-9]*\) · projects.*/\1/p')"
[ "$(dbq "SELECT count(*) FROM segment WHERE closed_seq IS NULL")" -gt 0 ] \
  && ok "with open segments in the store to leave out" \
  || bad "with open segments in the store to leave out" "every segment is closed, so this proves nothing"

# Reading the digest through a pager closes the pipe early, and the flush the
# interpreter does after every guard has gone out of scope must not raise.
HOME="$RH" python3 "$ROOT/hooks/retro.py" review </dev/null 2>"$TMP/retro.err" | head -2 >/dev/null
{ [ "${PIPESTATUS[0]}" = 0 ] && [ ! -s "$TMP/retro.err" ]; } \
  && ok "a digest read through a pager is a clean exit" \
  || bad "a digest read through a pager is a clean exit" \
         "exit ${PIPESTATUS[0]}, stderr: $(cat "$TMP/retro.err")"

# Accepting is what hides a window, permanently and with no undo, so a value
# nobody could have reviewed is refused rather than taken.
seq="$(dbq "SELECT MAX(closed_seq) FROM segment")"
out="$(retro review --accept 999999 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ "$(dbq "SELECT count(*) FROM meta WHERE key='reviewed_through'")" = 0 ]; } \
  && ok "a sequence past the last closed segment is refused" \
  || bad "a sequence past the last closed segment is refused" "exit $rc, marker moved"
out="$(retro review --accept "$seq")"
check "accepting says how much it hid" "accepted 2 segments · reviewed_through 0 → $seq" "$out"
out="$(retro review --accept "$seq" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "accepting the same window twice is refused" \
              || bad "accepting the same window twice is refused" "exit $rc"
retro review --accept "$seq" >/dev/null 2>&1
check "an accepted window comes back empty" "no closed segments to review" "$(retro review)"
check "--all still digests everything"      "segments 2" "$(retro review --all)"
sql "accepting moves the marker and nothing else" "$seq" \
  "SELECT value FROM meta WHERE key='reviewed_through'"

# A segment closed after the accept is the next review's window, and only it.
cat > "$RP/alpha/s-later.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T16:00:00.000Z","cwd":"/repo/gamma","message":{"role":"user","content":"more"}}
{"type":"assistant","uuid":"L1","timestamp":"2026-08-14T16:00:01.000Z","message":{"id":"lm1","content":[{"type":"tool_use","id":"l1","name":"Bash","input":{"command":"git push origin main"}}]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-14T16:01:00.000Z","compactMetadata":{"trigger":"auto","preTokens":9,"postTokens":1,"cumulativeDroppedTokens":8,"durationMs":10}}
JSON
retro record >/dev/null
digest="$(retro review)"
check "a later segment is the next window"  "segments 1 · projects 1" "$digest"
check "and it is the one that closed last"  "git push" "$digest"

# ── closing a segment nothing compacted ──────────────────────────────────────
# A transcript that has fallen idle closes its open segment: 24 hours is long
# enough that an overnight break does not.
cat > "$RP/alpha/s-idle.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T18:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"work"}}
{"type":"assistant","uuid":"i1","timestamp":"2026-08-14T18:00:01.000Z","message":{"id":"im1","content":[{"type":"tool_use","id":"i1t","name":"Read","input":{}}]}}
JSON
retro record >/dev/null
sql "a live transcript's segment stays open" "" \
  "SELECT IFNULL(close_trigger,'') FROM segment WHERE id='s-idle#0'"
touch -d '3 days ago' "$RP/alpha/s-idle.jsonl"
retro record >/dev/null
sql "a transcript left alone for a day closes its segment" "idle" \
  "SELECT close_trigger FROM segment WHERE id='s-idle#0'"
# A closed segment is immutable, so a session that wakes up again starts a new
# one rather than adding to a segment that may already have been reviewed.
cat >> "$RP/alpha/s-idle.jsonl" <<'JSON'
{"type":"assistant","uuid":"i2","timestamp":"2026-08-17T09:00:00.000Z","message":{"id":"im2","content":[{"type":"tool_use","id":"i2t","name":"Write","input":{}}]}}
{"type":"assistant","uuid":"i3","timestamp":"2026-08-17T09:01:00.000Z","message":{"id":"im3","content":[{"type":"tool_use","id":"i3t","name":"Glob","input":{}}]}}
JSON
retro record >/dev/null
sql "a resumed transcript opens the next segment instead" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-idle#1' AND tool='Write'"
sql "and the closed one is left exactly as it was" "1|idle" \
  "SELECT assistant_turns,close_trigger FROM segment WHERE id='s-idle#0'"

# An ordinal that came from an idle close exists only in the cursor — no
# boundary in the file produced it — so a rebuild that re-derived it from the
# bytes would land back on the closed segment and discard everything after it.
# The rewind drops the last record and leaves the one before it whole.
python3 - "$RP/alpha/s-idle.jsonl" <<'PY'
import sys

path = sys.argv[1]
lines = open(path, "rb").read().splitlines(True)
open(path, "wb").write(b"".join(lines[:-1]))
PY
retro record >/dev/null
sql "a rewound transcript rebuilds its reopened segment" "1|1" \
  "SELECT (SELECT n FROM tool_use WHERE segment_id='s-idle#1' AND tool='Write'),
          (SELECT assistant_turns FROM segment WHERE id='s-idle#1')"
sql "without the record the rewind took" "0" \
  "SELECT count(*) FROM tool_use WHERE segment_id='s-idle#1' AND tool='Glob'"
sql "and the closed segment is still untouched" "1|idle" \
  "SELECT assistant_turns,close_trigger FROM segment WHERE id='s-idle#0'"
sql "so nothing had to be given up" "0" \
  "SELECT IFNULL((SELECT value FROM meta WHERE key='segments_dropped'),'0')"

# A transcript whose head changed is a different file under an old name. Its
# open segment has no source any more, so what came from the session's own chain
# goes — and the count is what stops that being silent.
python3 - "$RP/alpha/s-idle.jsonl" <<'PY'
import sys

path = sys.argv[1]
lines = open(path).read().splitlines(True)
lines[0] = lines[0].replace('"work"', '"work now"')
open(path, "w").write("".join(lines))
PY
retro record >/dev/null
sql "a segment a replaced file cannot rebuild is counted, not hidden" "1" \
  "SELECT value FROM meta WHERE key='segments_dropped'"
check "and the digest owns it" "store, all time: 1 segments could not be rebuilt" "$(retro review --all)"

# A file replaced by one that predates the marker may not be read at all. Its
# open segment cannot survive that, and the cursor has to keep the segment id or
# the next append lands in a closed segment and is discarded in silence.
python3 - "$RP/alpha/s-idle.jsonl" <<'PY'
import sys

path = sys.argv[1]
open(path, "w").write(
    '{"type":"user","origin":{"kind":"human"},"timestamp":"2025-05-05T10:00:00.000Z",'
    '"cwd":"/repo/alpha","message":{"role":"user","content":"someone else\'s old file"}}\n'
)
PY
retro record >/dev/null
sql "a replaced pre-marker file gives up its open segment, and says so" "2" \
  "SELECT value FROM meta WHERE key='segments_dropped'"
sql "and records nothing of the file it now is" "0" \
  "SELECT count(*) FROM segment WHERE id='s-idle#2'"
cat >> "$RP/alpha/s-idle.jsonl" <<'JSON'
{"type":"assistant","uuid":"i9","timestamp":"2026-08-18T09:00:00.000Z","message":{"id":"im9","content":[{"type":"tool_use","id":"i9t","name":"Task","input":{}}]}}
JSON
retro record >/dev/null
sql "what it gains after that is still recorded" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-idle#1' AND tool='Task'"

# The 30-day cleanup deletes transcripts. The digest is the only record left, so
# it stays; the cursor pointing at a file that is gone does not.
cat > "$RP/alpha/s-deleted.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T19:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"work"}}
{"type":"assistant","uuid":"g1","timestamp":"2026-08-14T19:00:01.000Z","message":{"id":"gm1","content":[{"type":"tool_use","id":"g1t","name":"Grep","input":{}}]}}
JSON
retro record >/dev/null
rm -f "$RP/alpha/s-deleted.jsonl"
retro record >/dev/null
sql "a deleted transcript closes its segment as gone" "gone|1" \
  "SELECT close_trigger,assistant_turns FROM segment WHERE id='s-deleted#0'"
sql "and its cursor goes with it" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%s-deleted%'"

# ── the recorder's own failure paths ─────────────────────────────────────────
# A missing marker must never become a backfill: it is recreated, and the run it
# was missing on records nothing at all.
rm -f "$RH/.claude/retro/since"
cat > "$RP/alpha/s-nomarker.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T17:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"hi"}}
JSON
retro record >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ -s "$RH/.claude/retro/since" ]; } \
  && ok "a missing since marker is recreated" \
  || bad "a missing since marker is recreated" "exit $rc"
sql "and that run records nothing" "0" \
  "SELECT count(*) FROM segment WHERE session_id='s-nomarker'"
# A marker that is there but will not parse is a different condition from one
# that is absent: it is the one value in the store that must never move, so it
# is left exactly as it is and nothing is recorded until someone looks.
printf 'not a timestamp' > "$RH/.claude/retro/since"
retro record >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ "$(cat "$RH/.claude/retro/since")" = "not a timestamp" ]; } \
  && ok "an unreadable marker is left exactly as it is" \
  || bad "an unreadable marker is left exactly as it is" "exit $rc, now: $(cat "$RH/.claude/retro/since")"
check "and the doctor is what says so" "retro/since is not a timestamp" \
  "$(HOME="$RH" "$ROOT/install.sh" --sync 2>&1)"

# Put the fixtures back inside the window; the marker it wrote is now, which
# would make every one of them older than the store.
printf '2026-01-01T00:00:00Z\n' > "$RH/.claude/retro/since"

# A store another toolkit wrote is left alone rather than adopted or destroyed.
HOME="$RH" python3 -c "
import os, sqlite3
db = sqlite3.connect(os.path.expanduser('~/.claude/retro/retro.db'))
db.execute('PRAGMA user_version=99')
db.close()"
segments="$(dbq "SELECT count(*) FROM segment")"
retro record >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ "$(dbq "SELECT count(*) FROM segment")" = "$segments" ]; } \
  && ok "a store from a newer toolkit is not touched" \
  || bad "a store from a newer toolkit is not touched" "exit $rc"
retro review >/dev/null
check "and the review says which version it is" "schema version 99" "$(cat "$TMP/retro.err")"
ls "$RH"/.claude/retro/retro.db.corrupt.* >/dev/null 2>&1 \
  && bad "a newer schema is not treated as corruption" "it was moved aside" \
  || ok "a newer schema is not treated as corruption"
HOME="$RH" python3 -c "
import os, sqlite3
db = sqlite3.connect(os.path.expanduser('~/.claude/retro/retro.db'))
db.execute('PRAGMA user_version=1')
db.close()"

# A store that will not open is a store behind a problem, not a broken one:
# moving it aside would throw away the record that outlives every transcript.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$RH/.claude/retro/retro.db"
  retro record >/dev/null; rc=$?
  chmod 644 "$RH/.claude/retro/retro.db"
  { [ "$rc" = 0 ] && ! ls "$RH"/.claude/retro/retro.db.corrupt.* >/dev/null 2>&1; } \
    && ok "a store that will not open is left where it is" \
    || bad "a store that will not open is left where it is" "exit $rc, it was quarantined"
  sql "and everything in it survives" "$segments" "SELECT count(*) FROM segment"
fi

# A corrupt store is moved aside and rebuilt. This is last, because a rebuild
# re-derives every live transcript from scratch.
segments="$(dbq "SELECT count(*) FROM segment")"
printf 'this is not a database' > "$RH/.claude/retro/retro.db"
rm -f "$RH/.claude/retro/retro.db-wal" "$RH/.claude/retro/retro.db-shm"
retro record >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "a corrupt store still exits 0" || bad "a corrupt store still exits 0" "exit $rc"
ls "$RH"/.claude/retro/retro.db.corrupt.* >/dev/null 2>&1 \
  && ok "the corrupt store is kept, not deleted" \
  || bad "the corrupt store is kept, not deleted" "no retro.db.corrupt.* file"
retro record >/dev/null
rebuilt="$(dbq "SELECT count(*) FROM segment")"
[ "${rebuilt:-0}" -gt 0 ] && ok "the store is rebuilt from the live transcripts" \
                          || bad "the store is rebuilt from the live transcripts" "$rebuilt segments"

# Nothing to read at all is a first session on a new machine.
EMPTY="$TMP/retro-empty"
mkdir -p "$EMPTY"
out="$(HOME="$EMPTY" python3 "$ROOT/hooks/retro.py" record </dev/null 2>"$TMP/retro.err")"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$TMP/retro.err" ]; } \
  && ok "no ~/.claude/projects at all is still a clean exit" \
  || bad "no ~/.claude/projects at all is still a clean exit" "exit $rc, err $(cat "$TMP/retro.err")"
check "an empty store reviews as empty" "no closed segments to review" \
  "$(HOME="$EMPTY" python3 "$ROOT/hooks/retro.py" record </dev/null >/dev/null 2>&1; \
     HOME="$EMPTY" python3 "$ROOT/hooks/retro.py" review </dev/null 2>&1)"

# The retro line is a required field, so every agent's return contract states it.
missing=""
for a in "$ROOT"/agents/*.md; do
  grep -q '`Retro: none`' "$a" || missing="$missing $(basename "$a")"
done
[ -z "$missing" ] && ok "every agent must answer Retro" || bad "every agent must answer Retro" "missing in:$missing"

# ── bg + reap ────────────────────────────────────────────────────────────────
echo "bg.sh + reap.sh"

reg="$FAKE/.claude/bg-procs"
out="$(HOME="$FAKE" "$ROOT/hooks/bg.sh" -- sleep 300)"
pid="$(printf '%s' "$out" | awk '{print $3}')"
[ -f "$reg/$pid.json" ] && ok "registers the process" || bad "registers the process" "no $reg/$pid.json"

# No owner recorded and no session ending: it must be left alone, not killed.
printf '{"hook_event_name":"SubagentStop"}' | HOME="$FAKE" "$ROOT/hooks/reap.sh"
kill -0 "$pid" 2>/dev/null && ok "spares a process it cannot judge" || bad "spares a process it cannot judge" "killed pid $pid"

# Another session ending must not touch it.
printf '{"hook_event_name":"SessionEnd","session_id":"someone-else"}' | HOME="$FAKE" "$ROOT/hooks/reap.sh"
kill -0 "$pid" 2>/dev/null && ok "another session does not reap it" || bad "another session does not reap it" "killed pid $pid"

# Its own session ending does.
sess="$(jq -r '.session' "$reg/$pid.json")"
printf '{"hook_event_name":"SessionEnd","session_id":"%s"}' "$sess" | HOME="$FAKE" "$ROOT/hooks/reap.sh"
kill -0 "$pid" 2>/dev/null && bad "own session reaps it" "pid $pid survived" || ok "own session reaps it"
[ ! -f "$reg/$pid.json" ] && ok "registry entry cleared" || bad "registry entry cleared" "still there"

# A recycled pid must be pruned, never signalled.
printf '{"pid":%d,"start":"999999","owner":"","owner_start":"","session":"x","cmd":["sleep"]}' 1 > "$reg/1.json"
printf '{"hook_event_name":"SessionEnd","session_id":"x"}' | HOME="$FAKE" "$ROOT/hooks/reap.sh"
[ ! -f "$reg/1.json" ] && ok "recycled pid pruned unsignalled" || bad "recycled pid pruned" "entry remains"

# ── result ───────────────────────────────────────────────────────────────────
echo
if [ "$fail" -eq 0 ]; then
  echo "$pass passed"
else
  echo "$pass passed, $fail failed"
  exit 1
fi
