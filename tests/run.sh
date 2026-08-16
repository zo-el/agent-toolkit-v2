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
pass=0; fail=0; skipped=0

ok()   { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  ✗ %s\n    %s\n' "$1" "$2"; }
# A check that could not run says so out loud: counted as neither, never as a pass.
skip() { skipped=$((skipped + 1)); printf '  ⊘ %s\n    %s\n' "$1" "$2"; }
check() { # name, expected-substring, actual
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected '$2' in: ${3:-<empty>}" ;; esac
}
stub_path() { # dir, tools… — a PATH carrying only these
  local dir="$1" b p
  mkdir -p "$dir"
  for b in "${@:2}"; do p="$(command -v "$b")" && ln -sf "$p" "$dir/$b"; done
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
stub_path "$TMP/nojq" bash grep sed awk cat printf
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

# Every payload field is read for its type before it is used: a workspace or a
# transcript path of the wrong shape raises where no segment guard reaches, and
# would cost the whole line instead of the segment that read it.
check "payload fields of the wrong type cost their segment, not the line" "Opus 5" \
  "$(printf '%s' '{"cwd":"/","model":{"display_name":"Opus 5"},"workspace":"nope","transcript_path":["nope"]}' \
    | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"

# An ascii output encoding raises on the first separator, and an unguarded write
# puts the traceback in the bar. PYTHONIOENCODING stands in for the C-locale
# machine that does the same.
out="$(printf '%s' '{"cwd":"/","model":{"display_name":"Opus 5"}}' \
  | HOME="$FAKE" PYTHONIOENCODING=ascii python3 "$ROOT/hooks/statusline.py" 2>&1)"
case "$out" in
  *Traceback*) bad "an ascii output encoding never crashes" "$out" ;;
  *)           ok "an ascii output encoding never crashes" ;;
esac
check "an ascii output encoding keeps the separators" "$sep" "$out"

# ...and where stdout cannot be forced to utf-8 at all, the glyph is what
# degrades, not the line: everything else on it still reads.
cat > "$TMP/degrade.py" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from lib.out import print_line

print_line("Opus 5 │ main")
PY
check "a stream that will not take utf-8 degrades the glyph, not the line" "Opus 5 ? main" \
  "$(PYTHONIOENCODING=ascii python3 "$TMP/degrade.py" "$ROOT/hooks" 2>&1)"

# Writing the line is the one thing both hooks share, so its own guard is
# asserted here rather than through a caller that ends in os._exit either way.
python3 "$TMP/degrade.py" "$ROOT/hooks" >&- 2>"$TMP/degrade.err"
{ [ $? = 0 ] && [ ! -s "$TMP/degrade.err" ]; } \
  && ok "printing to a closed stdout is silent, not an error" \
  || bad "printing to a closed stdout is silent, not an error" "stderr: $(cat "$TMP/degrade.err")"

# The bar's own shutdown: a reader that went away must not turn the interpreter's
# final flush into a failed hook.
printf '%s' '{"cwd":"/","model":{"display_name":"Opus 5"}}' > "$TMP/sl.payload"
HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" < "$TMP/sl.payload" 2>"$TMP/sl.err" | true
sl_rc=${PIPESTATUS[0]}
{ [ "$sl_rc" = 0 ] && [ ! -s "$TMP/sl.err" ]; } \
  && ok "the bar survives a closed pipe" \
  || bad "the bar survives a closed pipe" "exit $sl_rc, stderr: $(cat "$TMP/sl.err")"

# The other way the bar used to carry a traceback: a working directory deleted
# under the session, which raises where no segment guard reaches. It costs the
# segments read from disk and nothing else.
out="$(mkdir -p "$TMP/gone" && cd "$TMP/gone" && rmdir "$TMP/gone" \
  && printf '%s' '{"model":{"display_name":"Opus 5"}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
case "$out" in
  *Traceback*) bad "a deleted working directory never crashes" "$out" ;;
  *)           ok "a deleted working directory never crashes" ;;
esac
check "a deleted working directory costs its segment, not the line" "Opus 5" "$out"

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
printf '%s' "$(prompt tl-open)" > "$TMP/tl.payload"
for module in tasks out; do
  tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$COPY"
  rm -f "$COPY/hooks/lib/$module.py"
  check "the doctor flags lib/$module.py missing" "hooks/lib does not import" \
    "$(HOME="$TMP/home-copy" "$COPY/install.sh" --dry-run 2>&1)"
  # Quietly to the model, loudly to the debug log: no line, and a reason on
  # stderr, which a zero exit keeps out of the context.
  HOME="$FAKE" python3 "$COPY/hooks/taskline.py" < "$TMP/tl.payload" \
    > "$TMP/tl.out" 2>"$TMP/tl.err"
  tl_rc=$?
  { [ "$tl_rc" = 0 ] && [ ! -s "$TMP/tl.out" ] && [ -s "$TMP/tl.err" ]; } \
    && ok "lib/$module.py missing costs the line and says why" \
    || bad "lib/$module.py missing costs the line and says why" \
       "exit $tl_rc, stdout: $(cat "$TMP/tl.out"), stderr: $(cat "$TMP/tl.err")"
done
tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$COPY"
printf '\ndef broken(\n' >> "$COPY/hooks/taskline.py"
check "the doctor flags a hook that will not compile" "does not compile" \
  "$(HOME="$TMP/home-copy" "$COPY/install.sh" --dry-run 2>&1)"

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

# ── duplication ──────────────────────────────────────────────────────────────
# Both directions of the gate: the checkout as it stands is clean, and a
# function pasted into a second file is not.
echo "duplication.sh"

dup() { "$ROOT/tests/duplication.sh" "$1" > "$TMP/dup.out" 2>&1; }
verdict() { # name, expected exit, actual exit
  [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected exit $2, got $3: $(cat "$TMP/dup.out")"
}

dup "$ROOT"; rc=$?
case "$rc" in
  0) ok   "the checkout has no duplicated blocks" ;;
  2) skip "the checkout has no duplicated blocks" "$(cat "$TMP/dup.out")" ;;
  *) bad  "the checkout has no duplicated blocks" "$(cat "$TMP/dup.out")" ;;
esac

# Without jscpd there is nothing to prove, and the skip above already says so.
if [ "$rc" -ne 2 ]; then
  # The fixture lives under a .claude path because that is where an agent's
  # worktree runs this suite from, and an ignore glob that floats rather than
  # anchoring at the root swallows the whole checkout there.
  DUP="$TMP/.claude/worktrees/wt"
  mkdir -p "$DUP/hooks/lib"
  cp "$ROOT/hooks/lib/tasks.py" "$DUP/hooks/lib/tasks.py"
  cp "$ROOT/hooks/taskline.py" "$DUP/hooks/taskline.py"
  awk '/^def load_tasks/,0' "$ROOT/hooks/lib/tasks.py" >> "$DUP/hooks/taskline.py"
  dup "$DUP"; verdict "a pasted function fails the suite" 1 "$?"
  cp "$ROOT/hooks/taskline.py" "$DUP/hooks/taskline.py"
  dup "$DUP"; verdict "removing it passes again" 0 "$?"

  # Shell is half of what ships here, and a clone this size is the floor the
  # thresholds claim: retuning them past it has to fail a test, not go unnoticed.
  for f in one two; do
    cat > "$DUP/hooks/$f.sh" <<'SH'
#!/usr/bin/env bash
prune_registry() {
  local reg="$1" pid
  for entry in "$reg"/*.json; do
    [ -f "$entry" ] || continue
    pid="$(basename "$entry" .json)"
    kill -0 "$pid" 2>/dev/null || rm -f "$entry"
  done
}
SH
  done
  dup "$DUP"; verdict "a pasted shell function fails it too" 1 "$?"
  rm -f "$DUP/hooks/one.sh" "$DUP/hooks/two.sh"

  # A worktree nested inside the checkout is a whole copy of it, and stays out.
  mkdir -p "$DUP/.claude/worktrees/inner/hooks/lib"
  cp "$ROOT/hooks/lib/tasks.py" "$DUP/.claude/worktrees/inner/hooks/lib/tasks.py"
  cp "$ROOT/hooks/taskline.py" "$DUP/.claude/worktrees/inner/hooks/taskline.py"
  dup "$DUP"; verdict "a nested worktree copy is ignored" 0 "$?"

  # jscpd exits 0 over a tree it never read — a bad path, an unknown format, an
  # ignore that swallowed everything. A gate that cannot say it looked is a
  # failure, not a pass.
  mkdir -p "$TMP/dup-empty"
  dup "$TMP/dup-empty"; verdict "a tree it did not read is not a pass" 3 "$?"
fi

# The skip itself: without jscpd and without npx the gate says so and asks for
# neither a pass nor a failure.
stub_path "$TMP/nonpx" bash env mktemp rm python3
PATH="$TMP/nonpx" "$ROOT/tests/duplication.sh" "$ROOT" > "$TMP/dup.out" 2>&1
verdict "no jscpd and no npx is a skip, not a verdict" 2 "$?"
check "the skip names the install" "npm i -g jscpd@" "$(cat "$TMP/dup.out")"

# ── result ───────────────────────────────────────────────────────────────────
echo
summary="$pass passed"
[ "$skipped" -eq 0 ] || summary="$summary, $skipped skipped"
if [ "$fail" -eq 0 ]; then
  echo "$summary"
else
  echo "$summary, $fail failed"
  exit 1
fi
