# Installer cases, sourced by tests/run.sh after its helpers.
#
# Every install runs against a fake HOME. claude, gh, ssh and ssh-add are stubs
# that record their calls: a real claude would fetch plugins over the network
# into the fake home. Each case builds the home it needs, so none depends on
# what an earlier one left behind.

echo "install.sh"

STUBS="$TMP/stubs"
export STUB_STATE="$TMP/claude-state" CLAUDE_CALLS="$TMP/claude.calls" SSH_CALLS="$TMP/ssh.calls" \
  NOTIFY_STUB="$TMP/agent-notifications"
mkdir -p "$STUBS" "$STUB_STATE"

cat >"$STUBS/claude" <<'SH'
#!/usr/bin/env bash
# Plugin state lives outside the fake home, keyed by it, so a snapshot of a
# home sees only what install wrote.
state="$STUB_STATE/$(printf '%s' "$HOME" | md5sum | cut -c1-12)"
mkdir -p "$state"
touch "$state/markets" "$state/plugins"
printf '%s|%s\n' "${CLAUDE_CODE_PLUGIN_PREFER_HTTPS:-}" "$*" >>"$CLAUDE_CALLS"
case "$*" in
  --version) echo "${CLAUDE_STUB_VERSION:-2.1.272} (Claude Code)" ;;
  "plugin marketplace list --json")
    jq -Rn '[inputs | split(" ") | {name: .[0], source: "github", repo: .[1]}]' <"$state/markets" ;;
  "plugin list --json")
    jq -Rn --arg dir "$state/cache" \
      '[inputs | split(" ") | {id: .[0], enabled: (.[1] == "on"), scope: "user", installPath: ($dir + "/" + .[0])}]' <"$state/plugins" ;;
  "plugin marketplace add "*)
    [ "${CLAUDE_STUB_FAIL:-}" = add ] && { echo "✘ Failed to add marketplace: the stub refused" >&2; exit 1; }
    case "$4" in 777genius/*) name=claude-notifications-go ;; *) name="${4#*/}" ;; esac
    echo "$name $4" >>"$state/markets" ;;
  "plugin install "*" --scope user --json")
    [ "${CLAUDE_STUB_FAIL:-}" = install ] && { echo '{"outcome":"failed","message":"the stub fetch failed"}'; exit 1; }
    echo "$3 on" >>"$state/plugins"
    mkdir -p "$state/cache/$3/bin"
    cp "$NOTIFY_STUB" "$state/cache/$3/bin/"
    echo '{"outcome":"installed"}' ;;
  *) exit 1 ;;
esac
SH
cat >"$NOTIFY_STUB" <<'SH'
#!/bin/sh
[ "$*" = "config path --json" ] || exit 1
printf '{"path":"%s","exists":true}\n' "$HOME/.config/agent-notifications/config.json"
SH
printf '#!/bin/sh\n[ "$1 $2" = "auth token" ] && exit "${GH_STUB_RC:-0}"\nexit 0\n' >"$STUBS/gh"
printf '#!/bin/sh\necho "ssh-add $*" >>"$SSH_CALLS"\nexit "${SSH_ADD_STUB_RC:-0}"\n' >"$STUBS/ssh-add"
printf '#!/bin/sh\necho "ssh $*" >>"$SSH_CALLS"\nexit 255\n' >"$STUBS/ssh"
chmod +x "$STUBS"/* "$NOTIFY_STUB"

# A machine with nothing to advise about, so a case sees only what it caused.
export PATH="$STUBS:$PATH" SSH_AUTH_SOCK="$TMP/agent.sock" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.invalid\n' >"$GIT_CONFIG_GLOBAL"

home() { # name → a fresh home
  rm -rf "$TMP/$1"
  mkdir -p "$TMP/$1/.claude"
  printf '%s' "$TMP/$1"
}
copy_root() { # destination → a copy of the version directory with no git history
  rm -rf "$1"
  mkdir -p "$1"
  tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$1"
}
inst() { # root, home, arguments → out, rc
  out="$(HOME="$2" "$1/install.sh" "${@:3}" 2>&1)"
  rc=$?
}
stdout_of() { # root, home, arguments → out (stdout only), rc
  out="$(HOME="$2" "$1/install.sh" "${@:3}" 2>/dev/null)"
  rc=$?
}
js() { jq -r "$2" "$1/.claude/settings.json" 2>/dev/null; } # home, filter
snapshot() { # directory → one hash over every path, type, mode, size, mtime, link and content
  {
    find "$1" -printf '%P|%y|%m|%s|%T@|%l\n' | sort
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum)
  } | sha256sum | cut -d' ' -f1
}
file_id() { stat -c '%i %y' "$1"; }
exit_is() { [ "$rc" = "$2" ] && ok "$1" || bad "$1" "exit $rc, output: $out"; } # name, expected
same() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "${4:-it changed}"; }          # name, before, after
json_is() { jq -e "$2" <<<"$out" >/dev/null 2>&1 && ok "$1" || bad "$1" "${out:-<empty>}"; }
block() { sed -n "/^$1\$/,/^\$/p" <<<"$out"; } # heading → its lines, blank line included
# Fields are split on a unit separator: an empty matcher between two tabs would
# collapse, since read treats a tab as whitespace.
wired() { # home → event, matcher and command of every toolkit command
  jq -r '(.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m | .hooks[] | [$e, $m, .command]),
         ["statusline", "", .statusLine.command] | join("\u001f")' "$1/.claude/settings.json"
}
command_for() { # home, event, entry → the wired command
  wired "$1" | awk -F'\037' -v e="$2" -v n="$3" '$1 == e && index($3, n) { print $3; exit }'
}
hook() { # home, command, payload → out, rc, run as Claude Code runs a hook
  printf '%s' "$3" >"$TMP/hook.payload"
  out="$(HOME="$1" sh -c "$2" <"$TMP/hook.payload" 2>/dev/null)"
  rc=$?
}
lock_holder() { # home → holds the apply lock until killed; pid in $holder
  python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)' "$1/.claude" "$TMP/locked" &
  holder=$!
  for _ in $(seq 50); do [ -e "$TMP/locked" ] && break; sleep 0.1; done
  rm -f "$TMP/locked"
}
# Replaces settings_request in a copy's install.sh with one that edits what it
# returns, so a case can add or remove toolkit-owned values without depending on
# how the declaration is written.
patch_desired() { # root, jq filter over the request
  local marker='main "$@"'
  python3 - "$1/install.sh" "$2" "$marker" <<'PY'
import sys

path, edit, marker = sys.argv[1:]
source = open(path).read()
assert source.rstrip().endswith(marker), "install.sh no longer ends in main"
patch = (
    'eval "original_$(declare -f settings_request)"\n'
    "settings_request() { original_settings_request | jq '%s'; }\n" % edit
)
open(path, "w").write(source.rstrip()[: -len(marker)] + patch + marker + "\n")
PY
}

# ── modes and exit codes ─────────────────────────────────────────────────────
H="$(home args)"
printf '{"theme":"dark"}\n' >"$H/.claude/settings.json"
before="$(snapshot "$H")"
out="$(HOME="$H" "$ROOT/install.sh" --dryrun 2>&1 >/dev/null)"
rc=$?
exit_is "an unknown argument exits 2" 2
check "and prints usage on stderr" "usage: install.sh" "$out"
same "and writes nothing" "$before" "$(snapshot "$H")"
inst "$ROOT" "$H" --sync --sync
exit_is "two arguments exit 2" 2
stdout_of "$ROOT" "$H" --help
exit_is "--help exits 0" 0
check "and prints usage on stdout" "usage: install.sh" "$out"

inst "$ROOT" "$H" --dry-run
exit_is "a dry run that a full install can finish on its own exits 0" 0
same "a dry run writes nothing" "$before" "$(snapshot "$H")"
check "a dry run shows the settings diff" '+  "crossSessionInbound": "refuse",' "$out"
check "a dry run names the plugins it would install" "install plugin pr-review-toolkit@claude-plugins-official" "$out"
check "a plugin not yet installed is for install to fix" "$(printf 'Run install again\n  ✗ plugin pr-review-toolkit@claude-plugins-official is not installed')" "$out"
[ -z "$(grep -E '\|plugin (marketplace add|install) ' "$CLAUDE_CALLS" 2>/dev/null)" ] \
  && ok "a dry run fetches nothing" || bad "a dry run fetches nothing" "$(cat "$CLAUDE_CALLS")"

# The whole report for a finding that needs the user: its fix alone on its own
# line, under its heading.
H="$(home held)"
mkdir -p "$H/.claude/skills/toolkit"
printf 'mine\n' >"$H/.claude/skills/toolkit/SKILL.md"
held_before="$(snapshot "$H/.claude/skills/toolkit")"
inst "$ROOT" "$H"
exit_is "a required finding for the user exits 1" 1
same "a report of one user finding is its text and its fix" "$(printf '%s\n' 'Needs you' \
  "  ✗ skill toolkit is not installed: ~/.claude/skills/toolkit is not the toolkit's, and was left untouched" \
  '    mkdir -p ~/.claude/backups/skills && mv -T ~/.claude/skills/toolkit ~/.claude/backups/skills/toolkit' '')" \
  "$(block 'Needs you')" "got: $(block 'Needs you')"
check "the result line counts it" "✗ 1 required finding, 0 advisory" "$out"
same "and a skill name the toolkit does not hold is left untouched" "$held_before" "$(snapshot "$H/.claude/skills/toolkit")"
inst "$ROOT" "$H" --dry-run
exit_is "a dry run that needs the user exits 1" 1

H="$(home advisory)"
out="$(HOME="$H" SSH_AUTH_SOCK= "$ROOT/install.sh" 2>&1)"
rc=$?
exit_is "advisory findings alone exit 0" 0
check "and are counted as advisory" "✓ 0 required findings, 1 advisory" "$out"

# ── what a full install writes ───────────────────────────────────────────────
FAKE="$(home home)"
cat >"$FAKE/.claude/settings.json" <<'JSON'
{
  "theme": "dark",
  "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_ENABLE_TASKS": "false", "MY_VAR": "keep"},
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/bin/true"}]}]},
  "permissions": {"additionalDirectories": ["/my/own/dir"]}
}
JSON
inst "$ROOT" "$FAKE"
exit_is "a full install on a fresh machine goes green" 0
settings() { js "$FAKE" "$1"; }
check "statusline wired"      "statusline hooks/statusline.py" "$(settings '.statusLine.command')"
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
  *SendMessage* | *ListAgents*) bad "agents can still reach main" "SendMessage or ListAgents is denied" ;;
  *) ok "agents can still reach main" ;;
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
check "the version directory is approved" "$ROOT" "$(settings '.permissions.additionalDirectories | join(" ")')"
check "credentials denied through ~/" "Read(~/.claude/.credentials.json)" "$(settings '.permissions.deny | join(" ")')"
check "review plugin enabled" "true" "$(settings '.enabledPlugins["pr-review-toolkit@claude-plugins-official"]')"
check "the stable link points at the version directory" "$ROOT" "$(readlink "$FAKE/.claude/agent-toolkit")"
check "the pointer imports through ~/" "@~/.claude/agent-toolkit/CLAUDE.md" "$(cat "$FAKE/.claude/CLAUDE.md")"
cmp -s "$ROOT/hooks/launcher.sh" "$FAKE/.claude/agent-toolkit-run" && [ -x "$FAKE/.claude/agent-toolkit-run" ] \
  && ok "the launcher is installed outside the version directory" || bad "the launcher is installed" "missing or different"
check "a settings write takes a backup" "settings.json updated (backup: ~/.claude/backups/settings.json." "$out"

for want in "PreToolUse hooks/guard.sh" "SessionEnd hooks/reap.sh" "async hooks/format.sh" \
  "PostToolUse hooks/sync.sh" "UserPromptSubmit hooks/taskline.py" "SessionStart install.sh --sync"; do
  check "wires $want through the launcher" "\"\$HOME/.claude/agent-toolkit-run\" $want" \
    "$(settings '[.hooks[][].hooks[].command] | join(" ")')"
done
check "linear matcher wired" "mcp__linear.*" "$(settings '[.hooks.PreToolUse[].matcher] | join(" ")')"
[ -z "$(settings '[.hooks[][].hooks[].command, .statusLine.command] | map(select(test("agent-toolkit-run") | not)) | .[] | select(. != "/usr/bin/true")')" ] \
  && ok "every toolkit command runs the launcher" || bad "every toolkit command runs the launcher" "$(settings .hooks)"

# The recorder rides four events and no trigger is load-bearing, so all four
# have to be there, and every one of them async.
for want in SessionStart PreCompact UserPromptSubmit SessionEnd; do
  check "retro records on $want" "retro.py record" \
    "$(settings "[.hooks.$want[].hooks[] | select((.command // \"\") | test(\"retro\")) | .command] | join(\" \")")"
done
check "the retro sweep is asynchronous everywhere" "[true,true,true,true]" \
  "$(settings '[.hooks[][].hooks[] | select((.command // "") | test("retro")) | (.async // false)] | tostring')"
check "the prompt trigger carries an interval" "--interval 900" \
  "$(settings '[.hooks.UserPromptSubmit[].hooks[].command] | join(" ")')"
check "taskline is wired synchronously" "[false]" \
  "$(settings '[.hooks.UserPromptSubmit[].hooks[] | select((.command // "") | test("taskline")) | (.async // false)] | tostring')"
[ -s "$FAKE/.claude/retro/since" ] && ok "install stamps the since marker" \
  || bad "install stamps the since marker" "no ~/.claude/retro/since"
marker="$(cat "$FAKE/.claude/retro/since")"
inst "$ROOT" "$FAKE"
check "a re-install leaves the marker alone" "$marker" "$(cat "$FAKE/.claude/retro/since")"
check "re-install is idempotent" "Nothing to change" "$out"

linked="$(find "$FAKE/.claude/skills" -maxdepth 1 -type l | wc -l | tr -d ' ')"
have="$(find "$ROOT/skills" -name SKILL.md | wc -l | tr -d ' ')"
[ "$linked" = "$have" ] && ok "all $have skills linked" || bad "skills linked" "$linked of $have"
copied="$(ls "$FAKE/.claude/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')"
agents="$(ls "$ROOT/agents"/*.md | wc -l | tr -d ' ')"
[ "$copied" = "$agents" ] && ok "all $agents agents copied" || bad "agents copied" "$copied of $agents"

# Without sqlite3 the recorder is inert and everything else is unaffected.
mkdir -p "$TMP/nosqlite"
{ printf '#!/bin/sh\ncase "$*" in *"import sqlite3"*) exit 1 ;; esac\nexec %s "$@"\n' \
  "$(command -v python3)"; } >"$TMP/nosqlite/python3"
chmod +x "$TMP/nosqlite/python3"
out="$(HOME="$FAKE" PATH="$TMP/nosqlite:$PATH" "$ROOT/install.sh" 2>&1)"
rc=$?
check "a python without sqlite3 is an advisory" "python3 cannot import sqlite3" "$out"
exit_is "and the install still goes green" 0

# Replacing the version directory: links into the one replaced still resolve,
# so they survive the dangling-link prune and would keep firing retired skills.
OLD="$TMP/old-checkout"
mkdir -p "$OLD/skills/retired" "$TMP/my-skills/mine-too"
touch "$OLD/skills/retired/SKILL.md" "$TMP/my-skills/mine-too/SKILL.md"
ln -sfn "$OLD/skills/retired" "$FAKE/.claude/skills/retired"
ln -sfn "$TMP/my-skills/mine-too" "$FAKE/.claude/skills/mine-too"
ln -sfn "$OLD" "$FAKE/.claude/agent-toolkit"
inst "$ROOT" "$FAKE"
[ ! -e "$FAKE/.claude/skills/retired" ] && ok "a skill of the replaced version directory is unlinked" || bad "stale skill unlinked" "still linked"
[ -L "$FAKE/.claude/skills/mine-too" ] && ok "an unrelated skill link is kept" || bad "unrelated skill link kept" "removed"
rm -f "$FAKE/.claude/skills/mine-too"

# A retired agent is removed; one the user wrote is left alone; a file at a
# toolkit agent's name that the manifest does not list is backed up, then replaced.
touch "$FAKE/.claude/agents/mine.md" "$FAKE/.claude/agents/stale.md"
echo "stale.md" >>"$FAKE/.claude/agents/.toolkit-agents"
grep -vx developer.md "$FAKE/.claude/agents/.toolkit-agents" >"$TMP/manifest" && cp "$TMP/manifest" "$FAKE/.claude/agents/.toolkit-agents"
printf 'my own developer\n' >"$FAKE/.claude/agents/developer.md"
inst "$ROOT" "$FAKE"
[ ! -e "$FAKE/.claude/agents/stale.md" ] && ok "retired agent removed" || bad "retired agent removed" "still there"
[ -e "$FAKE/.claude/agents/mine.md" ] && ok "user agent untouched" || bad "user agent untouched" "deleted"
cmp -s "$ROOT/agents/developer.md" "$FAKE/.claude/agents/developer.md" && grep -qx 'my own developer' "$FAKE"/.claude/backups/agents/developer.md.* \
  && ok "an unlisted file at an agent's name is backed up, then replaced" || bad "unlisted agent file backed up" "$(ls "$FAKE/.claude/backups/agents" 2>&1)"

# ── the hook report ──────────────────────────────────────────────────────────
H="$(home hook)"
inst "$ROOT" "$H"
SYNC="$(command_for "$H" SessionStart install.sh)"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart","source":"startup"}'
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a clean session start prints nothing" || bad "a clean session start prints nothing" "exit $rc: $out"

rm -f "$STUB_STATE/$(printf '%s' "$H" | md5sum | cut -c1-12)/plugins"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart","source":"startup"}'
exit_is "a required finding at session start still exits 0" 0
json_is "and prints one SessionStart object with a message for the user" \
  '.hookSpecificOutput.hookEventName == "SessionStart" and (.systemMessage | test("^agent-toolkit: 2 problems"))'
json_is "and gives the model every finding with who acts and the fix" \
  '.hookSpecificOutput.additionalContext | startswith("agent-toolkit doctor:\n✗ plugin pr-review-toolkit@claude-plugins-official is not installed. Fix (install): ~/.claude/agent-toolkit/install.sh")'
hook "$H" "$(command_for "$H" PostToolUse sync.sh)" \
  "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$ROOT/skills/toolkit/SKILL.md\"}}"
json_is "an edit through sync.sh gets the PostToolUse shape" \
  '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput | has("reloadSkills") | not)'
hook "$H" "$(command_for "$H" PostToolUse sync.sh)" \
  '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/somewhere/else.md"}}'
[ -z "$out" ] && ok "an edit elsewhere runs nothing" || bad "an edit elsewhere runs nothing" "$out"

inst "$ROOT" "$H"
out="$(printf '{"hook_event_name":"SessionStart"}' | HOME="$H" SSH_AUTH_SOCK= sh -c "$SYNC" 2>/dev/null)"
json_is "advisories alone reach the model and not the user" \
  '(has("systemMessage") | not) and (.hookSpecificOutput.additionalContext | test("ssh-agent"))'
rm "$H/.claude/skills/backlog"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart","source":"startup"}'
json_is "a skill link changed at session start asks for a skill rescan" '.hookSpecificOutput.reloadSkills == true'
[ -L "$H/.claude/skills/backlog" ] && ok "and the link is back" || bad "and the link is back" "still missing"

# ── going live ───────────────────────────────────────────────────────────────
H="$(home live)"
inst "$ROOT" "$H"
BROKEN="$TMP/broken-root"
copy_root "$BROKEN"
printf '\ndef broken(\n' >>"$BROKEN/hooks/taskline.py"
chmod -x "$BROKEN/hooks/guard.sh"
before="$(snapshot "$H")"
inst "$BROKEN" "$H"
exit_is "a version directory failing its root checks exits 1" 1
same "and leaves the link, settings, agents and everything else byte-identical" "$before" "$(snapshot "$H")"
check "naming the file that is not executable" "✗ hooks/guard.sh is not executable" "$(block Toolkit)"
check "and the python file that does not compile, with the interpreter's line" "SyntaxError" "$(block Toolkit)"
[ -e "$BROKEN/hooks/taskline.py" ] && ok "the failing root stays on disk" || bad "the failing root stays on disk" "deleted"

# A root that is already live and then breaks, as a checkout updated in place.
H="$(home live-breaks)"
LIVE="$TMP/live-root"
copy_root "$LIVE"
inst "$LIVE" "$H"
chmod -x "$LIVE/hooks/sync.sh"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
before="$(snapshot "$H")"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
same "a live root that fails its checks applies nothing at session start" "$before" "$(snapshot "$H")"
json_is "and says what is broken" '.hookSpecificOutput.additionalContext | test("hooks/sync.sh is not executable")'

# The switch itself: a reader resolving the link never finds nothing there. The
# same reader against a remove-then-link switch is the control that shows it
# would notice.
eval "$(sed -n '/^link_atomic() {/,/^}/p' "$ROOT/install.sh")"
remove_then_link() { rm -f "$2" && ln -s "$1" "$2"; }
switch_misses() { # switch function → how often a reader found no link
  local sw="$TMP/switch" reader
  rm -rf "$sw"
  mkdir -p "$sw/a" "$sw/b"
  touch "$sw/a/install.sh" "$sw/b/install.sh"
  ln -s "$sw/a" "$sw/link"
  (misses=0; while [ ! -e "$sw/done" ]; do [ -e "$sw/link/install.sh" ] || misses=$((misses + 1)); done; echo "$misses" >"$sw/misses") &
  reader=$!
  for _ in $(seq 500); do "$1" "$sw/b" "$sw/link"; "$1" "$sw/a" "$sw/link"; done
  touch "$sw/done"
  wait "$reader"
  cat "$sw/misses"
}
if declare -f link_atomic >/dev/null; then
  check "a reader resolving the link during 1000 switches never misses" "0" "$(switch_misses link_atomic)"
  [ "$(switch_misses remove_then_link)" -gt 0 ] && ok "and the same reader catches a switch that is not atomic" \
    || bad "and the same reader catches a switch that is not atomic" "it never missed, so it proves nothing"
else
  bad "a reader resolving the link during switches never misses" "install.sh has no link_atomic"
fi

H="$(home alternate)"
OTHER="$TMP/other-root"
copy_root "$OTHER"
inst "$ROOT" "$H"
(misses=0; while [ ! -e "$TMP/alternate.done" ]; do [ -e "$H/.claude/agent-toolkit/install.sh" ] || misses=$((misses + 1)); done; echo "$misses" >"$TMP/alternate.misses") &
reader=$!
for root in "$OTHER" "$ROOT" "$OTHER" "$ROOT"; do inst "$root" "$H"; done
touch "$TMP/alternate.done"
wait "$reader"
check "installs alternating between two version directories never leave the link unresolvable" "0" "$(cat "$TMP/alternate.misses")"
exit_is "and the last one goes green" 0

READONLY="$TMP/readonly-root"
copy_root "$READONLY"
chmod -R a-w "$READONLY"
H="$(home readonly)"
before="$(snapshot "$READONLY")"
inst "$READONLY" "$H"
exit_is "a read-only version directory with no git history goes green" 0
same "and gains no files" "$before" "$(snapshot "$READONLY")"
chmod -R u+w "$READONLY"

H="$(home unlinked)"
inst "$ROOT" "$H"
UNLINKED="$TMP/unlinked-root"
copy_root "$UNLINKED"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
before="$(snapshot "$H")"
inst "$UNLINKED" "$H" --sync
[ "$rc" = 0 ] && [ -z "$out" ] && ok "--sync from a directory the link does not point at prints nothing" || bad "--sync from an unlinked copy prints nothing" "exit $rc: $out"
same "and changes nothing, the link included" "$before" "$(snapshot "$H")"

# ── version identity ─────────────────────────────────────────────────────────
H="$(home version)"
RELEASE="$TMP/release-v7"
copy_root "$RELEASE"
printf 'v7·abc1234\n' >"$RELEASE/VERSION"
inst "$RELEASE" "$H"
check "a release's VERSION is stamped" "v7·abc1234" "$(cat "$H/.claude/agent-toolkit-version" 2>/dev/null)"
printf '{"cwd":"/"}' >"$TMP/sl.payload"
out="$(HOME="$H" python3 "$ROOT/hooks/statusline.py" <"$TMP/sl.payload" 2>&1)"
case "$out" in
  *"$(printf '\033[2m⬡ v7·abc1234\033[0m')") ok "the status line shows a matching release root with no ⚠ or ?" ;;
  *) bad "the status line shows a matching release root with no ⚠ or ?" "$(printf '%s' "$out" | cat -v)" ;;
esac
printf 'v8·abc1234\n' >"$RELEASE/VERSION"
check "and ⚠ once the version directory moves past the stamp" "⚠" "$(HOME="$H" python3 "$ROOT/hooks/statusline.py" <"$TMP/sl.payload" 2>&1)"
printf '7-abc1234\n' >"$RELEASE/VERSION"
inst "$RELEASE" "$H"
[ ! -e "$H/.claude/agent-toolkit-version" ] && ok "a malformed VERSION removes the stamp" || bad "a malformed VERSION removes the stamp" "$(cat "$H/.claude/agent-toolkit-version")"
exit_is "and still installs" 0

PARENT="$TMP/parent-repo"
rm -rf "$PARENT"
mkdir -p "$PARENT"
git -C "$PARENT" init -q && git -C "$PARENT" commit -q --allow-empty -m parent
copy_root "$PARENT/toolkit"
printf 'v1·abc1234\n' >"$H/.claude/agent-toolkit-version"
inst "$PARENT/toolkit" "$H"
[ ! -e "$H/.claude/agent-toolkit-version" ] && ok "a copy inside a parent repository never takes the parent's version" \
  || bad "a copy inside a parent repository never takes the parent's version" "stamped $(cat "$H/.claude/agent-toolkit-version")"

check "a checkout is stamped from its own history" \
  "v$(git -C "$ROOT" rev-list --count HEAD)·$(git -C "$ROOT" rev-parse --short HEAD)" "$(cat "$FAKE/.claude/agent-toolkit-version")"

cat >"$TMP/version.py" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from lib.version import parse, same

print(" ".join(str(x) for x in [
    same("v7·abc1234", "v7·abc1234ff00"), same("v7·abc1234", "v8·abc1234"),
    same("v7·abc1234", "v7·abd1234"), parse("v7·abc1234\nv8·abc1234"), parse(" v7·abc1234"),
]))
PY
check "versions compare by count and sha prefix, and a label is exactly one line" "True False False None None" \
  "$(python3 "$TMP/version.py" "$ROOT/hooks")"

# ── sync applies ─────────────────────────────────────────────────────────────
H="$(home sync)"
inst "$ROOT" "$H"
SYNC="$(command_for "$H" SessionStart install.sh)"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
backups="$(ls "$H/.claude/backups" | wc -l)"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
check "session start restores deleted wiring" "hooks/guard.sh" "$(js "$H" '[.hooks.PreToolUse[].hooks[].command] | join(" ")')"
[ "$(ls "$H/.claude/backups" | wc -l)" -gt "$backups" ] && ok "with a backup" || bad "with a backup" "no new backup"
json_is "and tells the user" '.systemMessage == "agent-toolkit: Updated settings.json"'

jq '.hooks.PreToolUse += [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/bin/true"}]}]' \
  "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")" backups="$(ls "$H/.claude/backups" | wc -l)"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
same "a user hook after the toolkit's is current: same inode and mtime" "$id_before" "$(file_id "$H/.claude/settings.json")"
same "and no backup" "$backups" "$(ls "$H/.claude/backups" | wc -l)"
[ -z "$out" ] && ok "and nothing to report" || bad "and nothing to report" "$out"

jq -S . "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
same "reformatting with jq -S causes no write" "$id_before" "$(file_id "$H/.claude/settings.json")"

jq '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = "5"' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
check "an env value edited by hand is restored" "2" "$(js "$H" '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')"
json_is "and the user is told to restart" '.systemMessage == "agent-toolkit: Updated settings.json. Restart Claude Code to load it"'
json_is "with the reason given to the model" '.hookSpecificOutput.additionalContext | test("Restart Claude Code: env changed.")'
jq '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = "5"' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
inst "$ROOT" "$H"
check "a full install prints the restart line" "Restart Claude Code: env changed." "$out"

jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
printf '{"hook_event_name":"SessionStart"}' >"$TMP/hook.payload"
HOME="$H" sh -c "$SYNC" <"$TMP/hook.payload" >"$TMP/sync1.out" 2>&1 &
first=$!
HOME="$H" sh -c "$SYNC" <"$TMP/hook.payload" >"$TMP/sync2.out" 2>&1 &
second=$!
wait "$first" "$second"
jq -e '.hooks.PreToolUse | length == 2' "$H/.claude/settings.json" >/dev/null 2>&1 \
  && ok "two concurrent session starts end in one valid, current settings.json" || bad "two concurrent syncs" "$(cat "$H/.claude/settings.json")"
[ -z "$(find "$H/.claude" -maxdepth 1 -name '.*' ! -name .claude)" ] \
  && ok "and leave no temporary file behind" || bad "and leave no temporary file behind" "$(find "$H/.claude" -maxdepth 1 -name '.*')"

jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
lock_holder "$H"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
same "a session start that cannot take the lock writes nothing" "$id_before" "$(file_id "$H/.claude/settings.json")"
json_is "and still reports" '.hookSpecificOutput.additionalContext | test("held the lock")'

cat >"$TMP/reread.py" <<'PY'
import json
import os
import sys

sys.path.insert(0, sys.argv[1])
from lib import settings

home = sys.argv[2]
path = os.path.join(home, "settings.json")
request = {
    "settings": path, "ledger": os.path.join(home, "ledger.json"), "backups": os.path.join(home, "backups"),
    "desired": {"env": {"TOOLKIT_VALUE": "1"}}, "absent": [], "home": home, "root": "/r", "prev_root": "",
}
reads = []


def read(p):
    reads.append(p)
    if len(reads) == 2:
        with open(p, "w") as f:
            json.dump({"theme": "written by claude code"}, f)
    return settings.read_bytes(p)


result = settings.run(request, write=True, read=read)
print(json.dumps({"reads": len(reads), "settings": json.load(open(path)), "result": result["settings"]}))
PY
mkdir -p "$TMP/reread"
printf '{}\n' >"$TMP/reread/settings.json"
out="$(python3 "$TMP/reread.py" "$ROOT/hooks" "$TMP/reread")"
json_is "a change between the merge and the re-read is merged again, not overwritten" \
  '.reads == 4 and .settings.theme == "written by claude code" and .settings.env.TOOLKIT_VALUE == "1" and .result == "written"'

H="$(home broken-json)"
printf '{}\n' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
printf '{"broken": ' >"$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
inst "$ROOT" "$H"
exit_is "a settings.json that does not parse exits 1" 1
same "and is never written" "$id_before" "$(file_id "$H/.claude/settings.json")"
check "the finding gives the reason and the newest backup" "settings.json does not parse" "$(block 'Needs you')"
check "as a command" "cp ~/.claude/backups/settings.json." "$(block 'Needs you')"

# ── retiring what the toolkit stops setting ──────────────────────────────────
EXTRA="$TMP/root-with-extras"
copy_root "$EXTRA"
patch_desired "$EXTRA" '.desired.env.TOOLKIT_TEST_ENV = "1" | .desired.permissions.deny += ["Read(~/.toolkit-test)"]
  | .desired.permissions.additionalDirectories += ["/toolkit-test-dir"] | .desired.enabledPlugins["test@test"] = true
  | .desired.toolkitTestKey = "on"'
five='[.env.TOOLKIT_TEST_ENV, (.permissions.deny | index("Read(~/.toolkit-test)")), (.permissions.additionalDirectories | index("/toolkit-test-dir")), .enabledPlugins["test@test"], .toolkitTestKey] | map(. != null)'

H="$(home retire)"
inst "$EXTRA" "$H"
check "a version directory can add five kinds of toolkit-owned value" "[true,true,true,true,true]" "$(js "$H" "$five | tostring")"
inst "$ROOT" "$H"
check "and the next install from one without them removes all five" "[false,false,false,false,false]" "$(js "$H" "$five | tostring")"
check "including the replaced version directory from the approved directories" "null" \
  "$(jq --arg x "$EXTRA" '.permissions.additionalDirectories | index($x)' "$H/.claude/settings.json")"

H="$(home retire-kept)"
printf '{"toolkitTestKey": "on"}\n' >"$H/.claude/settings.json"
inst "$EXTRA" "$H"
jq '.env.TOOLKIT_TEST_ENV = "mine"' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
inst "$ROOT" "$H"
check "a value the user changed after the toolkit wrote it is kept" "mine" "$(js "$H" '.env.TOOLKIT_TEST_ENV')"
check "and one that held the value before the toolkit first wrote it" "on" "$(js "$H" '.toolkitTestKey')"
check "while the others still go" "[false,false,false]" \
  "$(js "$H" '[(.permissions.deny | index("Read(~/.toolkit-test)")), (.permissions.additionalDirectories | index("/toolkit-test-dir")), .enabledPlugins["test@test"]] | map(. != null) | tostring')"

# ── upgrading an install that predates the ledger ────────────────────────────
# The shape the previous install.sh leaves: absolute paths everywhere, no
# launcher, no ledger.
H="$(home predates-ledger)"
ln -s "$ROOT" "$H/.claude/agent-toolkit"
cat >"$H/.claude/settings.json" <<JSON
{
  "env": {"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "2", "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1", "MINE": "1"},
  "crossSessionInbound": "refuse",
  "isolatePeerMachines": true,
  "permissions": {
    "defaultMode": "auto",
    "additionalDirectories": ["$H/.claude", "/tmp/claude-$(id -u)", "$ROOT"],
    "deny": ["Read(/$H/.claude/.credentials.json)", "Read(/$H/.claude/settings*.json)",
             "Read(/$H/.claude/backups/settings.json.*)", "Read(/$H/.claude/backups/.claude.json.backup.*)"]
  },
  "includeCoAuthoredBy": false,
  "enabledPlugins": {"pr-review-toolkit@claude-plugins-official": true, "claude-notifications-go@claude-notifications-go": true},
  "statusLine": {"type": "command", "command": "$H/.claude/agent-toolkit/hooks/statusline.py", "padding": 0},
  "hooks": {
    "SessionStart": [{"matcher": "startup|resume|clear", "hooks": [{"type": "command", "command": "$H/.claude/agent-toolkit/install.sh --sync"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "$H/.claude/agent-toolkit/hooks/guard.sh"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "$H/.claude/agent-toolkit/hooks/reap.sh"}]}]
  }
}
JSON
inst "$ROOT" "$H"
exit_is "an install that predates the ledger upgrades green" 0
[ -s "$H/.claude/agent-toolkit-applied.json" ] && ok "and bootstraps the ledger" || bad "and bootstraps the ledger" "no ledger"
check "leaving exactly the four deny rules, none of them in the absolute form" \
  '["Read(~/.claude/.credentials.json)","Read(~/.claude/settings*.json)","Read(~/.claude/backups/settings.json.*)","Read(~/.claude/backups/.claude.json.backup.*)"]' \
  "$(js "$H" '.permissions.deny | tostring')"
check "with no command left that bypasses the launcher" "[]" \
  "$(js "$H" '[.hooks[][].hooks[].command, .statusLine.command] | map(select(test("agent-toolkit-run") | not)) | tostring')"
check "and the user's own env kept" "1" "$(js "$H" '.env.MINE')"
LEAN="$TMP/root-without-todo-tools"
copy_root "$LEAN"
patch_desired "$LEAN" 'del(.desired.env.CLAUDE_CODE_ENABLE_TODO_TOOLS)'
inst "$LEAN" "$H"
check "a value present when the ledger was bootstrapped counts as the toolkit's" "null" "$(js "$H" '.env.CLAUDE_CODE_ENABLE_TODO_TOOLS')"

# ── the previous generation ──────────────────────────────────────────────────
# After installing over a v1 machine nothing v1 may still be wired. A leftover
# skill or agent keeps instructing sessions from a generation whose rules no
# longer hold. Names share no prefix, so no assertion matches one inside another.
V1="$TMP/old-checkout-v1"
V1HOME="$(home machine-on-v1)"
mkdir -p "$V1"/{hooks,agents} "$V1HOME/.claude"/{skills,agents}
for s in orchestrating-subagents develop feature-spec linear-sync retro chore; do
  mkdir -p "$V1/skills/group/$s" && touch "$V1/skills/group/$s/SKILL.md"
done
for a in architect-designer lead developer project-manager researcher reviewer; do
  printf 'v1 agent\n' >"$V1/agents/$a.md"
done
for h in guard-git guard-config guard-linear format-on-edit sync-on-skill-edit reap-managed spawn-managed; do
  printf '#!/bin/sh\n' >"$V1/hooks/$h.sh" && chmod +x "$V1/hooks/$h.sh"
done
printf '#!/bin/sh\n' >"$V1/install-skills.sh" && chmod +x "$V1/install-skills.sh"
ln -sfn "$V1" "$V1HOME/.claude/agent-toolkit"
for d in "$V1"/skills/group/*/; do ln -sfn "${d%/}" "$V1HOME/.claude/skills/$(basename "${d%/}")"; done
for a in "$V1"/agents/*.md; do cp "$a" "$V1HOME/.claude/agents/"; basename "$a"; done >"$V1HOME/.claude/agents/.toolkit-agents"
mkdir -p "$TMP/user-skill/my-skill" && touch "$TMP/user-skill/my-skill/SKILL.md"
ln -sfn "$TMP/user-skill/my-skill" "$V1HOME/.claude/skills/my-skill"
printf 'mine\n' >"$V1HOME/.claude/agents/my-agent.md"
cat >"$V1HOME/.claude/settings.json" <<JSON
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
printf '@%s/.claude/agent-toolkit/CLAUDE.md\n' "$V1HOME" >"$V1HOME/.claude/CLAUDE.md"
inst "$ROOT" "$V1HOME"
v1s() { js "$V1HOME" "$1"; }
left="$(ls -1 "$V1HOME/.claude/skills" | grep -Ex 'orchestrating-subagents|develop|feature-spec|linear-sync|retro|chore' | tr '\n' ' ')"
[ -z "$left" ] && ok "v1 skills unlinked" || bad "v1 skills unlinked" "still present: $left"
left="$(ls -1 "$V1HOME/.claude/agents" | grep -Ex 'architect-designer.md|lead.md' | tr '\n' ' ')"
[ -z "$left" ] && ok "retired v1 agents pruned" || bad "retired v1 agents pruned" "still present: $left"
grep -q 'v1 agent' "$V1HOME/.claude/agents/developer.md" \
  && bad "shared agent names overwritten" "developer.md is still the v1 file" || ok "shared agent names overwritten"
wired_v1="$(v1s '[.hooks[][].hooks[].command] + [.statusLine.command] | join(" ")')"
left=""
for h in guard-git guard-config guard-linear format-on-edit sync-on-skill-edit reap-managed install-skills; do
  case "$wired_v1" in *"$h"*) left="$left $h" ;; esac
done
[ -z "$left" ] && ok "no v1 hook still wired" || bad "no v1 hook still wired" "wired:$left"
check "v1 SubagentStop entry dropped" "null" "$(v1s '.hooks.SubagentStop')"
check "v1 agent-teams flag dropped" "null" "$(v1s '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')"
check "v1 spawn depth replaced" "2" "$(v1s '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')"
check "old checkout dropped from approved dirs" "null" "$(jq --arg v "$V1" '.permissions.additionalDirectories | index($v)' "$V1HOME/.claude/settings.json")"
[ -L "$V1HOME/.claude/skills/my-skill" ] && ok "user's own skill survives" || bad "user's own skill survives" "removed"
grep -q mine "$V1HOME/.claude/agents/my-agent.md" 2>/dev/null && ok "user's own agent survives" || bad "user's own agent survives" "removed"
check "stable link re-aimed at v2" "$ROOT" "$(readlink "$V1HOME/.claude/agent-toolkit")"

# ── the launcher and its wiring ──────────────────────────────────────────────
# Every wired command, run the way Claude Code runs it, from a home whose path
# has a space in it. A command this does not know how to check is a failure, so
# new wiring cannot go untested.
SPACE="$(home 'home with space')"
inst "$ROOT" "$SPACE"
exit_is "a home path with a space installs green" 0
mkdir -p "$TMP/formatter"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$TMP/ruff.calls" >"$TMP/formatter/ruff"
chmod +x "$TMP/formatter/ruff"
printf 'x = 1\n' >"$TMP/format-me.py"
while IFS=$'\037' read -r event matcher command; do
  read -r _ caller entry args <<<"$command"
  name="$event${matcher:+[$matcher]} $entry${args:+ $args}"
  case "$entry" in
    hooks/guard.sh)
      if [ "$matcher" = Bash ]; then
        hook "$SPACE" "$command" "$(bash_payload 'gh pr comment 12 --body hi')"
        check "$name reaches the guard, which denies a comment" "deny" "$(decision "$out")"
      else
        hook "$SPACE" "$command" "$(tool_payload 'mcp__linear__save_issue')"
        check "$name reaches the guard, which asks before a Linear write" "ask" "$(decision "$out")"
      fi
      ;;
    hooks/statusline.py)
      hook "$SPACE" "$command" '{"model":{"display_name":"Opus 5"},"cwd":"/"}'
      check "$name renders" "Opus 5" "$out"
      ;;
    hooks/taskline.py)
      hook "$SPACE" "$command" '{"hook_event_name":"UserPromptSubmit","session_id":"no-tasks","prompt":"go"}'
      check "$name reaches the task line" "Tasks: none open" "$out"
      ;;
    install.sh)
      rm -f "$SPACE/.claude/skills/toolkit"
      hook "$SPACE" "$command" '{"hook_event_name":"SessionStart","source":"startup"}'
      [ -L "$SPACE/.claude/skills/toolkit" ] && ok "$name reaches install.sh, which relinks a skill" || bad "$name reaches install.sh" "exit $rc: $out"
      ;;
    hooks/sync.sh)
      rm -f "$SPACE/.claude/skills/toolkit"
      hook "$SPACE" "$command" "{\"hook_event_name\":\"PostToolUse\",\"tool_input\":{\"file_path\":\"$ROOT/skills/toolkit/SKILL.md\"}}"
      [ -L "$SPACE/.claude/skills/toolkit" ] && ok "$name reaches sync.sh, which relinks a skill" || bad "$name reaches sync.sh" "exit $rc: $out"
      ;;
    hooks/format.sh)
      rm -f "$TMP/ruff.calls"
      printf '{"tool_input":{"file_path":"%s"}}' "$TMP/format-me.py" >"$TMP/hook.payload"
      HOME="$SPACE" PATH="$TMP/formatter:$PATH" sh -c "$command" <"$TMP/hook.payload" >/dev/null 2>&1
      check "$name reaches the formatter" "format-me.py" "$(cat "$TMP/ruff.calls" 2>/dev/null)"
      ;;
    hooks/reap.sh)
      pid="$(HOME="$SPACE" CLAUDE_CODE_SESSION_ID=wired-reap "$ROOT/hooks/bg.sh" -- sleep 300 | awk '{print $3}')"
      hook "$SPACE" "$command" '{"hook_event_name":"SessionEnd","session_id":"wired-reap"}'
      for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      kill -0 "$pid" 2>/dev/null && { bad "$name reaches the reaper" "pid $pid survived"; kill -KILL "$pid"; } || ok "$name reaches the reaper, which ends the session's process"
      ;;
    hooks/retro.py)
      rm -f "$SPACE/.claude/retro/last-sweep"
      hook "$SPACE" "$command" "{\"hook_event_name\":\"$event\"}"
      [ -e "$SPACE/.claude/retro/last-sweep" ] && ok "$name reaches the recorder" || bad "$name reaches the recorder" "no sweep: exit $rc"
      ;;
    *) bad "every wired command is checked here" "no check for: $name" ;;
  esac
done < <(wired "$SPACE" | grep -F 'agent-toolkit-run')

# The version directory moves out from under the stable link.
H="$(home dangling)"
MOVABLE="$TMP/movable-root"
rm -rf "$TMP/moved-root"
copy_root "$MOVABLE"
inst "$MOVABLE" "$H"
mv "$MOVABLE" "$TMP/moved-root"
hook "$H" "$(command_for "$H" PreToolUse guard.sh)" "$(bash_payload 'ls')"
check "with the link dangling, a PreToolUse call is asked" "ask" "$(decision "$out")"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
json_is "session start tells the user and the model where the link points" \
  "(.systemMessage | test(\"1 problem\")) and .hookSpecificOutput.hookEventName == \"SessionStart\" and (.hookSpecificOutput.additionalContext | contains(\"$MOVABLE\"))"
hook "$H" "$(command_for "$H" statusline statusline.py)" '{"cwd":"/"}'
check "the status line says the toolkit is unreachable" "agent-toolkit unreachable" "$out"
hook "$H" "$(command_for "$H" SessionStart retro.py)" '{"hook_event_name":"SessionStart"}'
[ "$rc" = 0 ] && [ -z "$out" ] && ok "an async command stays silent, so session start reports once" || bad "an async command stays silent" "exit $rc: $out"
hook "$H" "$(command_for "$H" SessionEnd reap.sh)" '{"hook_event_name":"SessionEnd"}'
[ "$rc" = 0 ] && [ -z "$out" ] && ok "any other event exits 0 with no output" || bad "any other event exits 0 with no output" "exit $rc: $out"
inst "$TMP/moved-root" "$H"
exit_is "a full install from the new location goes green" 0
check "and re-points the link" "$TMP/moved-root" "$(readlink "$H/.claude/agent-toolkit")"
check "and drops the old location from the approved directories" "null" \
  "$(jq --arg v "$MOVABLE" '.permissions.additionalDirectories | index($v)' "$H/.claude/settings.json")"
[ -z "$(find "$H/.claude/skills" -maxdepth 1 -lname "$MOVABLE/*")" ] && ok "and unlinks the old location's skills" || bad "and unlinks the old location's skills" "$(ls -l "$H/.claude/skills")"

# ── reaping never blocks ─────────────────────────────────────────────────────
H="$(home reap)"
pid="$(HOME="$H" CLAUDE_CODE_SESSION_ID=stubborn "$ROOT/hooks/bg.sh" -- bash -c 'trap "" TERM; while :; do sleep 1; done' | awk '{print $3}')"
printf '{"hook_event_name":"SessionEnd","session_id":"stubborn"}' >"$TMP/reap.payload"
start=$(date +%s%N)
HOME="$H" "$ROOT/hooks/reap.sh" <"$TMP/reap.payload"
took=$((($(date +%s%N) - start) / 1000000))
[ "$took" -lt 1000 ] && ok "reap.sh returns in under a second against a process that ignores TERM (${took}ms)" \
  || bad "reap.sh returns in under a second" "took ${took}ms"
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pid" 2>/dev/null && { bad "and the process is gone within 5s" "pid $pid survived"; kill -KILL -- "-$pid"; } || ok "and the process is gone within 5s"
for _ in $(seq 20); do [ -e "$H/.claude/bg-procs/$pid.json" ] || break; sleep 0.1; done
[ ! -e "$H/.claude/bg-procs/$pid.json" ] && ok "and its entry is cleared" || bad "and its entry is cleared" "still registered"

inst "$ROOT" "$H"
pid="$(HOME="$H" "$ROOT/hooks/bg.sh" -- bash -c 'trap "" TERM; while :; do sleep 1; done' | awk '{print $3}')"
jq '.owner = "999999999"' "$H/.claude/bg-procs/$pid.json" >"$TMP/entry" && cp "$TMP/entry" "$H/.claude/bg-procs/$pid.json"
inst "$ROOT" "$H" --sync
kill -0 "$pid" 2>/dev/null && ok "install returns while the reaper is still waiting on a stubborn process" \
  || bad "install does not wait on reaping" "the process was already gone"
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pid" 2>/dev/null && { bad "and that process is gone within 5s" "pid $pid survived"; kill -KILL -- "-$pid"; } || ok "and that process is gone within 5s"

# ── layout ───────────────────────────────────────────────────────────────────
H="$(home at-stable-path)"
copy_root "$H/.claude/agent-toolkit"
before="$(snapshot "$H")"
inst "$H/.claude/agent-toolkit" "$H"
exit_is "a version directory at ~/.claude/agent-toolkit exits 1" 1
same "and writes nothing, no link inside it included" "$before" "$(snapshot "$H")"
check "giving the command that moves it" "mv -T ~/.claude/agent-toolkit ~/Documents/git-repo/agent-toolkit-v2 && ~/Documents/git-repo/agent-toolkit-v2/install.sh" "$out"

H="$(home user-skill-link)"
mkdir -p "$H/.claude/skills" "$TMP/their-backlog"
ln -s "$TMP/their-backlog" "$H/.claude/skills/backlog"
inst "$ROOT" "$H"
exit_is "a user's own link at a skill name exits 1" 1
check "and is left pointing where it did" "$TMP/their-backlog" "$(readlink "$H/.claude/skills/backlog")"
check "while the other skills still install" "$ROOT/skills/toolkit" "$(readlink "$H/.claude/skills/toolkit")"

# ── requirements ─────────────────────────────────────────────────────────────
# A PATH holding every tool on this one except the ones a case takes away.
FARM="$TMP/farm"
python3 - "$FARM" "$PATH" "$STUBS" <<'PY'
import os
import sys

farm, path, stubs = sys.argv[1:]
taken = {"jq", "apt-get", "dnf", "pacman", "sudo", "claude", "gh", "ssh", "ssh-add"}
os.makedirs(farm, exist_ok=True)
for folder in path.split(os.pathsep):
    if not os.path.isdir(folder) or os.path.realpath(folder) == os.path.realpath(stubs):
        continue
    for name in os.listdir(folder):
        source, target = os.path.join(folder, name), os.path.join(farm, name)
        if name in taken or os.path.lexists(target) or os.path.isdir(source) or not os.access(source, os.X_OK):
            continue
        os.symlink(source, target)
PY
scenario() { # name, tools… → a PATH over the farm: a recording stub per tool, the real one for =tool
  local dir="$TMP/scenario-$1" tool
  rm -rf "$dir"
  mkdir -p "$dir"
  for tool in "${@:2}"; do
    case "$tool" in
      =*) ln -s "$(PATH="$STUBS:$PATH" command -v "${tool#=}")" "$dir/${tool#=}" ;;
      *)
        printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$tool" "$TMP/tool.calls" >"$dir/$tool"
        chmod +x "$dir/$tool"
        ;;
    esac
  done
  printf '%s:%s' "$dir" "$FARM"
}
H="$(home no-jq)"
before="$(snapshot "$H")"
rm -f "$TMP/tool.calls"
out="$(HOME="$H" PATH="$(scenario apt apt-get sudo =gh =claude)" "$ROOT/install.sh" 2>&1)"
rc=$?
exit_is "without jq install exits 1" 1
same "and writes nothing" "$before" "$(snapshot "$H")"
check "and prints the apt-get line" "$(printf '\n    sudo apt-get install -y jq\n')" "$out"
[ ! -e "$TMP/tool.calls" ] && ok "and never runs sudo, or anything else it names" || bad "and never runs sudo" "$(cat "$TMP/tool.calls")"
out="$(HOME="$H" PATH="$(scenario dnf dnf =gh =claude)" "$ROOT/install.sh" 2>&1)"
check "with dnf the line is its own" "sudo dnf install -y jq" "$out"
out="$(HOME="$H" PATH="$(scenario pacman pacman =claude)" "$ROOT/install.sh" 2>&1)"
check "with pacman every missing package is in one command, by its own names" "sudo pacman -S --needed jq github-cli" "$out"
out="$(HOME="$H" PATH="$(scenario none =gh =claude)" "$ROOT/install.sh" --sync 2>&1)"
[ -z "$out" ] && ok "a sync from an unlinked home stays silent even without jq" || bad "a sync from an unlinked home stays silent" "$out"
out="$(HOME="$H" PATH="$(scenario none =gh =claude)" "$ROOT/install.sh" 2>&1)"
check "with no known package manager the packages are named" "install these packages with your package manager: jq" "$out"

H="$(home no-identity)"
: >"$TMP/empty-gitconfig"
out="$(HOME="$H" GIT_CONFIG_GLOBAL="$TMP/empty-gitconfig" "$ROOT/install.sh" 2>&1)"
rc=$?
check "an empty global gitconfig gives the user.name line" 'git config --global user.name "<your name>"' "$out"
check "and the user.email line" 'git config --global user.email "<your email>"' "$out"
exit_is "and exits 0" 0

H="$(home old-claude)"
: >"$CLAUDE_CALLS"
out="$(HOME="$H" CLAUDE_STUB_VERSION=2.1.100 "$ROOT/install.sh" 2>&1)"
rc=$?
check "a claude below the minimum gives claude update" "$(printf '✗ claude 2.1.100 is older than 2.1.268, so the plugins are not installed\n    claude update')" "$out"
check "and makes no plugin call" "|--version" "$(cat "$CLAUDE_CALLS")"
[ "$(wc -l <"$CLAUDE_CALLS")" -eq 1 ] && ok "only the version check" || bad "only the version check" "$(cat "$CLAUDE_CALLS")"
exit_is "and exits 1" 1

H="$(home no-claude)"
out="$(HOME="$H" PATH="$(scenario no-claude =gh =jq =ssh-add)" "$ROOT/install.sh" 2>&1)"
check "a machine without claude gets the installer line" "curl -fsSL https://claude.ai/install.sh | bash" "$out"

H="$(home no-agent)"
rm -f "$SSH_CALLS"
out="$(HOME="$H" SSH_AUTH_SOCK= "$ROOT/install.sh" 2>&1)"
rc=$?
check "with no ssh-agent the advisory gives the fix" "$(printf '! no ssh-agent holding a key is reachable from this shell, so git over SSH from Claude Code fails, an approved push included\n    eval "$(ssh-agent -s)" && ssh-add && claude')" "$out"
exit_is "without changing the exit code" 0
grep -q '^ssh ' "$SSH_CALLS" 2>/dev/null && bad "and nothing touches the network" "$(cat "$SSH_CALLS")" || ok "and nothing touches the network"

H="$(home no-gh)"
out="$(HOME="$H" PATH="$(scenario no-gh apt-get =claude =jq =ssh-add)" "$ROOT/install.sh" 2>&1)"
check "without gh the package line comes before the login" "$(printf '    sudo apt-get install -y gh\n    gh auth login --hostname github.com --git-protocol ssh --web')" "$out"

# ── plugins ──────────────────────────────────────────────────────────────────
H="$(home plugins)"
: >"$CLAUDE_CALLS"
inst "$ROOT" "$H"
check "a full install registers each marketplace over HTTPS" "1|plugin marketplace add anthropics/claude-plugins-official" "$(cat "$CLAUDE_CALLS")"
check "from the notifications plugin's current source" "1|plugin marketplace add 777genius/agent-notifications" "$(cat "$CLAUDE_CALLS")"
check "and installs each plugin at user scope over HTTPS" "1|plugin install claude-notifications-go@claude-notifications-go --scope user --json" "$(cat "$CLAUDE_CALLS")"
check "and asks for a restart" "plugins changed" "$out"
: >"$CLAUDE_CALLS"
inst "$ROOT" "$H" --sync
inst "$ROOT" "$H" --dry-run
[ -z "$(grep -E '\|plugin (marketplace add|install) ' "$CLAUDE_CALLS")" ] && ok "--sync and --dry-run fetch nothing" || bad "--sync and --dry-run fetch nothing" "$(cat "$CLAUDE_CALLS")"

H="$(home old-source)"
state="$STUB_STATE/$(printf '%s' "$H" | md5sum | cut -c1-12)"
mkdir -p "$state"
echo "claude-notifications-go 777genius/claude-notifications-go" >"$state/markets"
: >"$CLAUDE_CALLS"
inst "$ROOT" "$H"
grep -q 'marketplace add 777genius' "$CLAUDE_CALLS" && bad "a marketplace registered under its old source is not added again" "$(cat "$CLAUDE_CALLS")" \
  || ok "a marketplace registered under its old source is not added again"

H="$(home plugin-fails)"
out="$(HOME="$H" CLAUDE_STUB_FAIL=install "$ROOT/install.sh" 2>&1)"
rc=$?
exit_is "a failing plugin install exits 1" 1
check "with Claude Code's own message" "plugin pr-review-toolkit@claude-plugins-official was not installed: the stub fetch failed" "$(block 'Run install again')"
check "and settings still applied" "agent-toolkit-run" "$(js "$H" '.statusLine.command')"
H="$(home marketplace-fails)"
out="$(HOME="$H" CLAUDE_STUB_FAIL=add "$ROOT/install.sh" 2>&1)"
check "a failing marketplace fetch carries its message too" "was not registered: ✘ Failed to add marketplace: the stub refused" "$out"

H="$(home notifications)"
inst "$ROOT" "$H"
[[ "$out" != *suppressForSubagents* ]] && ok "an absent notifications config says nothing" || bad "an absent notifications config says nothing" "$out"
mkdir -p "$H/.config/agent-notifications"
printf '{"notifications":{"suppressForSubagents":false}}\n' >"$H/.config/agent-notifications/config.json"
inst "$ROOT" "$H"
check "a config that notifies for subagents is an advisory naming the file" \
  "notifications.suppressForSubagents is false in ~/.config/agent-notifications/config.json" "$out"
exit_is "and does not fail the install" 0
