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
  "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "MY_VAR": "keep"},
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

for want in "guard.sh" "reap.sh" "format.sh" "sync.sh" "install.sh --sync"; do
  check "wires $want" "$want" "$(settings '[.hooks[][].hooks[].command] | join(" ")')"
done
check "linear matcher wired" "mcp__linear.*" "$(settings '[.hooks.PreToolUse[].matcher] | join(" ")')"

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
for label in "empty stdin" "malformed stdin"; do
  [ "$label" = "empty stdin" ] && data="" || data="not json"
  out="$(printf '%s' "$data" | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
  case "$out" in
    *Traceback*)             bad "$label never crashes" "$out" ;;
    *%*|*'$'*|*⚡*|*▰*|*▱*)  bad "$label invents no payload segment" "printed: $out" ;;
    *)                       ok "$label degrades safely" ;;
  esac
  check "$label keeps the placeholders" "$(dim '+0/-0') $sep $(dim '⏱ —')" "$out"
done

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
