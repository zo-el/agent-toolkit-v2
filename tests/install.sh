# Installer cases, sourced by tests/run.sh after its helpers. tests/run.sh keeps
# using $FAKE after this file.
#
# Every install runs against a fake HOME, with claude, gh, ssh and ssh-add
# stubbed: a real claude would fetch plugins over the network into the fake home.

echo "install.sh"

STUBS="$TMP/stubs"
export STUB_STATE="$TMP/claude-state" CLAUDE_CALLS="$TMP/claude.calls" SSH_CALLS="$TMP/ssh.calls" NET_CALLS="$TMP/net.calls"
mkdir -p "$STUBS" "$STUB_STATE"

cat >"$STUBS/claude" <<'SH'
#!/usr/bin/env bash
# Plugin state lives outside the fake home, keyed by it, so a snapshot of a
# home sees only what install wrote.
state="$STUB_STATE/$(printf '%s' "$HOME" | cksum | cut -d' ' -f1)"
mkdir -p "$state"
touch "$state/markets" "$state/plugins"
printf '%s|%s\n' "${CLAUDE_CODE_PLUGIN_PREFER_HTTPS:-}" "$*" >>"$CLAUDE_CALLS"
case "$*" in
  --version)
    [ "${CLAUDE_STUB_FAIL:-}" = version ] && exit 1
    echo "${CLAUDE_STUB_VERSION:-2.1.272} (Claude Code)" ;;
  "plugin marketplace list --json")
    [ "${CLAUDE_STUB_FAIL:-}" = list ] && { echo "the stub would not list marketplaces" >&2; exit 1; }
    jq -Rn '[inputs | split(" ") | {name: .[0], source: "github", repo: .[1]}]' <"$state/markets" ;;
  "plugin list --json")
    [ "${CLAUDE_STUB_FAIL:-}" = pluginlist ] && { echo "the stub would not list plugins" >&2; exit 1; }
    jq -Rn --arg dir "$state/cache" \
      '[inputs | split(" ") | {id: .[0], enabled: (.[1] == "on"), scope: "user", installPath: ($dir + "/" + .[0])}]' <"$state/plugins" ;;
  "plugin marketplace add "*)
    { [ "${CLAUDE_STUB_FAIL:-}" = add ] || [ "${CLAUDE_STUB_FAIL_MARKET:-}" = "$4" ]; } \
      && { echo "✘ Failed to add marketplace: the stub refused" >&2; exit 1; }
    case "$4" in 777genius/*) name=claude-notifications-go ;; *) name="${4#*/}" ;; esac
    echo "$name $4" >>"$state/markets" ;;
  "plugin install "*" --scope user --json")
    [ "${CLAUDE_STUB_FAIL:-}" = install ] && { echo '{"outcome":"failed","message":"the stub fetch failed"}'; exit 1; }
    echo "$3 on" >>"$state/plugins"
    echo '{"outcome":"installed"}' ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\necho "gh $*" >>"$NET_CALLS"\n[ "$1 $2" = "auth token" ] && exit "${GH_STUB_RC:-0}"\nexit 0\n' >"$STUBS/gh"
for tool in curl wget; do printf '#!/bin/sh\necho "%s $*" >>"$NET_CALLS"\nexit 1\n' "$tool" >"$STUBS/$tool"; done
printf '#!/bin/sh\necho "ssh-add $*" >>"$SSH_CALLS"\nexit "${SSH_ADD_STUB_RC:-0}"\n' >"$STUBS/ssh-add"
printf '#!/bin/sh\necho "ssh $*" >>"$SSH_CALLS"\nexit 255\n' >"$STUBS/ssh"
chmod +x "$STUBS"/*

# A machine with nothing to advise about, so a case sees only what it caused.
# CLAUDE_CODE_EXECPATH names the real Claude Code when the suite runs inside a
# session, and install prefers it over PATH: unset, every case gets the stub.
unset CLAUDE_CODE_EXECPATH
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
json_is() { jq -se "length == 1 and (.[0] | $2)" <<<"$out" >/dev/null 2>&1 && ok "$1" || bad "$1" "${out:-<empty>}"; }
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
  [ -n "$2" ] || { bad "a command to run as a hook" "no wired command was found"; out=""; rc=1; return; }
  printf '%s' "$3" >"$TMP/hook.payload"
  out="$(HOME="$1" sh -c "$2" <"$TMP/hook.payload" 2>/dev/null)"
  rc=$?
}
lock_holder() { # path → holds a flock on it until killed; pid in $holder
  python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)' "$1" "$TMP/locked" &
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
  '    mkdir -p ~/.claude/backups/skills && mv -T ~/.claude/skills/toolkit ~/.claude/backups/skills/toolkit.<time>' '')" \
  "$(block 'Needs you' | sed -E 's/(skills\/toolkit)\.[0-9]{8}-[0-9]{6}(\.[0-9]+)?$/\1.<time>/')" "got: $(block 'Needs you')"
check "the result line counts it" "✗ 1 required finding, 0 advisory" "$out"
held_fix="$(block 'Needs you' | sed -n 3p | sed 's/^ *//')"
same "and a skill name the toolkit does not hold is left untouched" "$held_before" "$(snapshot "$H/.claude/skills/toolkit")"
inst "$ROOT" "$H" --dry-run
exit_is "a dry run that needs the user exits 1" 1
HOME="$H" bash -c "$held_fix" && inst "$ROOT" "$H"
exit_is "and the fix it printed, run as printed, leads to a green install" 0

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
# The exit code alone counts no advisory, so a new one on a machine with nothing
# to advise about would go unnoticed.
check "with nothing left to report" "✓ 0 required findings, 0 advisory" "$out"
check "a first install asks for a restart for the pointer, both directories, env and plugins" \
  "Restart Claude Code: env changed, plugins changed, ~/.claude/CLAUDE.md changed, ~/.claude/agents was created, ~/.claude/skills was created." "$out"
settings() { js "$FAKE" "$1"; }
same "the whole wiring, event, matcher and caller included" "$(LC_ALL=C sort <<'WIRED'
SessionStart[startup|resume|clear|compact|fork] SessionStart install.sh --sync
SessionStart[startup|resume|clear|compact] SessionStart hooks/update.sh apply
SessionStart[] async hooks/retro.py record (async)
SessionStart[] async hooks/update.sh stage (async)
PreCompact[] async hooks/retro.py record (async)
UserPromptSubmit[] UserPromptSubmit hooks/taskline.py
UserPromptSubmit[] async hooks/retro.py record --interval 900 (async)
PreToolUse[Bash] PreToolUse hooks/guard.sh
PreToolUse[Bash] PreToolUse hooks/style.py
PreToolUse[mcp__linear.*] PreToolUse hooks/guard.sh
PostToolUse[Write|Edit] PostToolUse hooks/sync.sh
PostToolUse[Write|Edit] async hooks/format.sh (async)
SessionEnd[] async hooks/retro.py record (async)
statusLine statusline hooks/statusline.py
WIRED
)" "$(settings '(.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m | .hooks[]
    | select(.command | startswith("\"$HOME/.claude/agent-toolkit-run\" "))
    | "\($e)[\($m)] \(.command | ltrimstr("\"$HOME/.claude/agent-toolkit-run\" "))\(if .async then " (async)" else "" end)"),
  "statusLine \(.statusLine.command | ltrimstr("\"$HOME/.claude/agent-toolkit-run\" "))"' | LC_ALL=C sort)" "got: $(settings .hooks)"
check "statusline wired"      "statusline hooks/statusline.py" "$(settings '.statusLine.command')"
check "auto mode set"         "auto"          "$(settings '.permissions.defaultMode')"
check "spawn depth set"       "2"             "$(settings '.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')"
check "todo tools enabled"    "1"             "$(settings '.env.CLAUDE_CODE_ENABLE_TODO_TOOLS')"
check "tasks opt-out kept"    "false"         "$(settings '.env.CLAUDE_CODE_ENABLE_TASKS')"
check "co-authored-by off"    "false"         "$(settings '.includeCoAuthoredBy')"
check "session url off"       "false"         "$(settings '.attribution.sessionUrl')"
check "commit trailers off"   "false"         "$(settings '.attribution.commitTrailers')"
check "agent teams removed"   "null"          "$(settings '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')"
check "peer inbox refused"    "refuse"        "$(settings '.crossSessionInbound')"
check "cross-machine gated"   "true"          "$(settings '.isolatePeerMachines')"
# SendMessage must stay out of the deny list: denying it would also cut off an
# agent messaging main, which is how it asks a question mid-run.
case "$(settings '.permissions.deny | join(" ")')" in
  *SendMessage* | *ListAgents*) bad "agents can still reach main" "SendMessage or ListAgents is denied" ;;
  *) ok "agents can still reach main" ;;
esac
# Glob and Grep are not tools this harness has, and an unknown name is dropped in
# silence. Whole names, because BashOutput contains Bash, ListAgents contains
# Agent, and neither searches. A duplicate key resolves to the last line.
missing=""; unknown=""; blind=""; armed=""; loose=""; barred=0; shellless=""; claimed=0
bare=""; undeclared=""; declaring=0; ragged=""; unused=""
for a in "$ROOT"/agents/*.md; do
  n="$(basename "$a")"
  # Frontmatter only. Claude Code reads the allowlist and the servers from
  # there, so a block that slipped below the closing --- is declared to nobody.
  front="$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside' "$a")"
  names=",$(printf '%s\n' "$front" | grep '^tools:' | tail -1 | sed 's/^tools://; s/[[:space:]]//g'),"
  case "$names" in *,SendMessage,*) ;; *) missing="$missing $n" ;; esac
  case "$names" in *,Glob,* | *,Grep,*) unknown="$unknown $n" ;; esac
  case "$names" in *,Bash,* | *,Agent,*) ;; *) blind="$blind $n" ;; esac
  if grep -qF 'Repo history is yours to read directly' "$a"; then
    claimed=$((claimed + 1))
    case "$names" in *,Bash,*) ;; *) shellless="$shellless $n" ;; esac
  fi
  # A trailing space turns a frontmatter key into one nothing reads, and every
  # check below reads these keys.
  printf '%s\n' "$front" | grep -qE '[[:space:]]$' && ragged="$ragged $n"
  # Both YAML spellings of a server block, since either is a real declaration.
  servers="$(printf '%s\n' "$front" | awk '/^mcpServers:$/ { inside = 1; next } inside && /^[^ ]/ { exit } inside')"
  [ -n "$servers" ] && declaring=$((declaring + 1))
  named=" "
  for tool in $(printf '%s' "$names" | tr ',' ' '); do
    case "$tool" in
      mcp__*__?*)
        server="${tool#mcp__}"; server="${server%%__*}"
        case "$named" in *" $server "*) continue ;; esac
        named="$named$server "
        # Both spellings of an entry: a name with its config under it, and a
        # bare name referring to a server the device config already holds.
        printf '%s\n' "$servers" | grep -qE "^ +(- )?$server:?$" || undeclared="$undeclared $n:$server" ;;
      mcp__*)
        [ -n "$servers" ] && bare="$bare $n:$tool" ;;
    esac
  done
  # A server nobody names connects at spawn and contributes nothing.
  for declared in $(printf '%s\n' "$servers" | sed -n 's/^ *- *\([a-z][a-z-]*\):\{0,1\}$/\1/p'); do
    case "$named" in *" $declared "*) ;; *) unused="$unused $n:$declared" ;; esac
  done
  case "$names" in *,Write,* | *,Edit,* | *,NotebookEdit,*) edits=1 ;; *) edits=0 ;; esac
  case "$(grep -F "| \`${n%.md}\` |" "$ROOT/README.md")" in
    *"write anything"*)
      barred=$((barred + 1))
      [ "$edits" = 1 ] && armed="$armed $n" ;;
    # A cell naming what may not be written is role text for the barred
    # direction, since one tool name covers every file either way, but the agent
    # still writes something, so it still needs a tool that writes.
    *write*) [ "$edits" = 0 ] && loose="$loose $n" ;;
    *)
      [ "$edits" = 0 ] && loose="$loose $n" ;;
  esac
done
[ -z "$missing" ] && ok "every agent carries SendMessage" || bad "every agent carries SendMessage" "missing in:$missing"
[ -z "$unknown" ] && ok "no agent asks for a tool the harness dropped" \
  || bad "no agent asks for a tool the harness dropped" "declared in:$unknown"
[ -z "$blind" ] && ok "every agent can search a repo" \
  || bad "every agent can search a repo" "no Bash or Agent in:$blind"
# README's table says what each agent cannot do and its tools line is what stops
# it, read from the table so that rewording a definition cannot take it out of
# scope. A table barring nobody is vacuous, so it fails. Only an unqualified
# "write anything" is a claim the allowlist can answer: a cell naming what may
# not be written, production source against tests, is role text, because one
# name covers every file either way. Bash is not held here either, since a shell
# writes as well as reads.
if [ "$barred" -eq 0 ]; then
  bad "an agent the README bars from writing declares no editing tool" "the table bars none of them"
elif [ -n "$armed" ]; then
  bad "an agent the README bars from writing declares no editing tool" "an editing tool in:$armed"
else
  ok "an agent the README bars from writing declares no editing tool"
fi
[ -z "$loose" ] && ok "and one it says nothing about carries the tools to write" \
  || bad "and one it says nothing about carries the tools to write" "no editing tool in:$loose"
# Where a definition declares its own servers, a bare server name on the tools
# line was measured not to resolve: it is dropped in silence, leaving the agent
# without the tools its role is built on. That measurement says nothing about a
# server the device config holds, which is how the project manager reaches
# Linear, so those are not read here. A fully qualified name is answered for
# either way: the server behind it has to be declared in the file that names it.
if [ "$declaring" -eq 0 ]; then
  skip "an MCP tool is named in full" "no definition declares a server of its own"
elif [ -n "$bare" ]; then
  bad "an MCP tool is named in full" "a server name with no tool behind it in:$bare"
else
  ok "an MCP tool is named in full"
fi
[ -z "$undeclared" ] && ok "and the server behind it is declared beside it" \
  || bad "and the server behind it is declared beside it" "no mcpServers entry for:$undeclared"
[ -z "$unused" ] && ok "and every server declared has a tool that names it" \
  || bad "and every server declared has a tool that names it" "nothing names:$unused"
[ -z "$ragged" ] && ok "and no frontmatter key ends in whitespace" \
  || bad "and no frontmatter key ends in whitespace" "trailing whitespace in:$ragged"
# Repo history is read with a shell, so a definition claiming it declares one.
if [ "$claimed" -eq 0 ]; then
  bad "an agent that reads repo history directly carries a shell" "no definition claims it"
elif [ -n "$shellless" ]; then
  bad "an agent that reads repo history directly carries a shell" "no Bash in:$shellless"
else
  ok "an agent that reads repo history directly carries a shell"
fi
check "foreign env kept"      "keep"          "$(settings '.env.MY_VAR')"
check "foreign key kept"      "dark"          "$(settings '.theme')"
check "foreign hook kept"     "/usr/bin/true" "$(settings '[.hooks.PreToolUse[].hooks[].command] | join(" ")')"
check "foreign dir kept"      "/my/own/dir"   "$(settings '.permissions.additionalDirectories | join(" ")')"
# The list is the agents' own working state. Approving ~/.claude would approve a
# silent write to the credentials file, the transcripts, the plugin store and
# settings.json itself, which is an agent rewriting its own permissions.
approved="$(settings '.permissions.additionalDirectories | join(" ")')"
check "the scratchpad is approved" "/tmp/claude-$(id -u)" "$approved"
check "and the worktrees an agent is given" "$FAKE/.claude/worktrees" "$approved"
case " $approved " in
  *" $FAKE/.claude/tools "*) bad "the bridge's directory is not approved either" "it is: $approved" ;;
  *) ok "the bridge's directory is not approved either" ;;
esac
# A work tree, which the suite runs from: a checkout, a worktree, or the runner's
# own shallow clone. An unpacked source archive is not, and this case says so.
check "a clone is approved, because the toolkit skill edits one" "$ROOT" "$approved"
GITLESS="$TMP/gitless-root"
copy_root "$GITLESS"
mkdir -p "$GITLESS/.git"
inst "$GITLESS" "$H"
check "and so is one git would not answer for, because that is not the answer no" "$GITLESS" \
  "$(js "$H" '.permissions.additionalDirectories | join(" ")')"
case " $approved " in
  *" $FAKE/.claude "*) bad "~/.claude itself is not approved" "it is: $approved" ;;
  *) ok "~/.claude itself is not approved" ;;
esac
same "so a clone approves three paths, and keeps the user's own where it was" \
  "/my/own/dir /tmp/claude-$(id -u) $FAKE/.claude/worktrees $ROOT" "$approved"
check "credentials denied through ~/" "Read(~/.claude/.credentials.json)" "$(settings '.permissions.deny | join(" ")')"
# The rule names a directory, and there are a dozen spellings of one. Every form
# here resolves to the same path, and a path resolver reads them all as it.
# The last one is the user's own, below ~/.claude but not it: the rule names one
# path exactly, so a path under it is theirs and stays.
for spelling in "$FAKE/.claude/" "~/.claude" "~/.claude/." "$FAKE//.claude" "$FAKE/.claude/skills/.." "$FAKE/.claude/agent-toolkit-releases/v1.2.3" "$FAKE/.claude/worktrees/../agent-toolkit-releases/v9" "$FAKE/.claude/projects"; do
  jq --arg s "$spelling" '.permissions.additionalDirectories += [$s]' "$FAKE/.claude/settings.json" >"$TMP/spelled" \
    && cp "$TMP/spelled" "$FAKE/.claude/settings.json"
done
inst "$ROOT" "$FAKE"
same "an approval kept unset goes in every spelling of the directory it names" \
  "/my/own/dir /tmp/claude-$(id -u) $FAKE/.claude/worktrees $ROOT $FAKE/.claude/projects" \
  "$(settings '.permissions.additionalDirectories | join(" ")')"
check "review plugin enabled" "true" "$(settings '.enabledPlugins["pr-review-toolkit@claude-plugins-official"]')"
# The ui-developer names both of these, so every machine's has to have them.
check "and the two the ui-developer works from" "true true" \
  "$(settings '[.enabledPlugins["frontend-design@claude-plugins-official"], .enabledPlugins["modern-web-guidance@claude-plugins-official"]] | join(" ")')"
same "the stable link points at the version directory" "$ROOT" "$(readlink "$FAKE/.claude/agent-toolkit")"
check "the pointer imports through ~/" "@~/.claude/agent-toolkit/CLAUDE.md" "$(cat "$FAKE/.claude/CLAUDE.md")"
cmp -s "$ROOT/hooks/launcher.sh" "$FAKE/.claude/agent-toolkit-run" && [ -x "$FAKE/.claude/agent-toolkit-run" ] \
  && ok "the launcher is installed outside the version directory" || bad "the launcher is installed" "missing or different"
check "a settings write takes a backup" "settings.json updated (backup: ~/.claude/backups/settings.json." "$out"

for want in "PreToolUse hooks/guard.sh" "PreToolUse hooks/style.py" "async hooks/format.sh" \
  "PostToolUse hooks/sync.sh" "UserPromptSubmit hooks/taskline.py" "SessionStart install.sh --sync"; do
  check "wires $want through the launcher" "\"\$HOME/.claude/agent-toolkit-run\" $want" \
    "$(settings '[.hooks[][].hooks[].command] | join(" ")')"
done
check "linear matcher wired" "mcp__linear.*" "$(settings '[.hooks.PreToolUse[].matcher] | join(" ")')"
# An if field is permission rule syntax, and Bash(git commit *) does not match
# git -C <repo> commit, which is the form CLAUDE.md requires.
check "no hook narrows itself with an if" "[]" \
  "$(settings '[.hooks[][] | select(has("if")), (.hooks[]? | select(has("if")))] | tostring')"
[ -z "$(settings '[.hooks[][].hooks[].command, .statusLine.command] | map(select(test("agent-toolkit-run") | not)) | .[] | select(. != "/usr/bin/true")')" ] \
  && ok "every toolkit command runs the launcher" || bad "every toolkit command runs the launcher" "$(settings .hooks)"

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
# A link of the user's own that dangles is still theirs, and the toolkit's own
# dangling link is a deletion the hook report names.
mv "$TMP/my-skills/mine-too" "$TMP/my-skills/moved-away"
ln -s "$ROOT/skills/never-existed" "$FAKE/.claude/skills/never-existed"
hook "$FAKE" "$(command_for "$FAKE" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
[ -L "$FAKE/.claude/skills/mine-too" ] && ok "a user's skill link whose target moved away is left alone" \
  || bad "a user's dangling skill link is left alone" "removed"
[ ! -L "$FAKE/.claude/skills/never-existed" ] && ok "while one into the version directory is unlinked" \
  || bad "a dangling toolkit link is unlinked" "still there"
json_is "and the removal is reported, with a skill rescan" \
  '.hookSpecificOutput.reloadSkills == true and (.hookSpecificOutput.additionalContext | test("unlink dangling skill never-existed"))'
rm -f "$FAKE/.claude/skills/mine-too"

# A skill directory install cannot read would go missing in silence: find walks
# straight past it.
UNREADABLE="$TMP/unreadable-root"
copy_root "$UNREADABLE"
chmod 000 "$UNREADABLE/skills/toolkit"
chmod 000 "$UNREADABLE/agents/developer.md"
H="$(home unreadable)"
if [ "$(id -u)" -ne 0 ]; then
  inst "$UNREADABLE" "$H"
  exit_is "a version directory holding a file install cannot read exits 1" 1
  check "naming the skill under Toolkit" "✗ skills/toolkit cannot be read" "$(block Toolkit)"
  check "and the agent it did not copy" "✗ agents/developer.md cannot be read, so it was not copied" "$(block Toolkit)"
  [ ! -e "$H/.claude/agents/developer.md" ] && ok "which is not installed" || bad "an unreadable agent is not installed" "copied anyway"
else
  skip "a version directory holding a file install cannot read" "running as root, which reads anything"
fi
chmod 755 "$UNREADABLE/skills/toolkit"
chmod 644 "$UNREADABLE/agents/developer.md"

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

rm -f "$STUB_STATE/$(printf '%s' "$H" | cksum | cut -d' ' -f1)/plugins"
: >"$CLAUDE_CALLS"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart","source":"startup"}'
exit_is "a required finding at session start still exits 0" 0
[ -z "$(grep -E '\|plugin (marketplace add|install) ' "$CLAUDE_CALLS")" ] && ok "and a session start with plugins missing fetches nothing" \
  || bad "a session start with plugins missing fetches nothing" "$(cat "$CLAUDE_CALLS")"
json_is "and prints one SessionStart object with a message for the user" \
  '.hookSpecificOutput.hookEventName == "SessionStart" and (.systemMessage | test("^agent-toolkit: 4 problems"))'
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
out="$(printf '{"hook_event_name":"SessionStart"}' | HOME="$H" SSH_AUTH_SOCK= GIT_CONFIG_GLOBAL="$TMP/empty-gitconfig" sh -c "$SYNC" 2>/dev/null)"
[ -z "$out" ] && ok "a session start says nothing about the checks only a terminal can fix" \
  || bad "a session start skips the checks only a terminal can fix" "$out"
out="$(HOME="$H" SSH_AUTH_SOCK= "$ROOT/install.sh" 2>&1)"
check "while a full install still reports them" "no ssh-agent holding a key" "$out"
# Two processes a session start no longer pays for: the token check and the
# version check, neither of which decides anything it does.
rm -f "$NET_CALLS"
: >"$CLAUDE_CALLS"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
[ ! -s "$NET_CALLS" ] && ok "and a session start asks gh for nothing" || bad "a session start asks gh for nothing" "$(cat "$NET_CALLS")"
[ "$(wc -l <"$CLAUDE_CALLS")" -eq 1 ] && ok "and calls claude once" || bad "a session start calls claude once" "$(cat "$CLAUDE_CALLS")"

# The executable the running Claude Code names is the one whose plugins these
# are, whatever PATH answers.
mkdir -p "$TMP/execpath-bin"
printf '#!/bin/sh\necho "$*" >>"%s"\nexec "%s" "$@"\n' "$TMP/execpath.calls" "$STUBS/claude" >"$TMP/execpath-bin/claude"
chmod +x "$TMP/execpath-bin/claude"
rm -f "$TMP/execpath.calls"
out="$(HOME="$(home execpath)" CLAUDE_CODE_EXECPATH="$TMP/execpath-bin/claude" "$ROOT/install.sh" 2>&1)"
rc=$?
exit_is "an install that finds claude through CLAUDE_CODE_EXECPATH goes green" 0
grep -q -- '--version' "$TMP/execpath.calls" 2>/dev/null && ok "and runs the executable it names, ahead of PATH" \
  || bad "CLAUDE_CODE_EXECPATH is preferred over PATH" "$(cat "$TMP/execpath.calls" 2>/dev/null)"
rm "$H/.claude/skills/backlog"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart","source":"startup"}'
json_is "a skill link changed at session start asks for a skill rescan, and tells the user nothing" \
  '.hookSpecificOutput.reloadSkills == true and (has("systemMessage") | not)'
rm "$H/.claude/agents/developer.md"
hook "$H" "$(command_for "$H" PostToolUse sync.sh)" \
  "{\"hook_event_name\":\"PostToolUse\",\"tool_input\":{\"file_path\":\"$H/.claude/agent-toolkit/agents/developer.md\"}}"
cmp -s "$ROOT/agents/developer.md" "$H/.claude/agents/developer.md" && ok "an edit to an agent through the stable link copies it again" \
  || bad "an edit to an agent through the stable link copies it again" "not restored"
[ -z "$out" ] && ok "and a clean agent copy is not reported" || bad "and a clean agent copy is not reported" "$out"
[ -L "$H/.claude/skills/backlog" ] && ok "and the link is back" || bad "and the link is back" "still missing"

# ── going live ───────────────────────────────────────────────────────────────
H="$(home live)"
inst "$ROOT" "$H"
BROKEN="$TMP/broken-root"
copy_root "$BROKEN"
printf '\ndef broken(\n' >>"$BROKEN/hooks/taskline.py"
chmod -x "$BROKEN/hooks/guard.sh"
before="$(snapshot "$H")"
inst "$BROKEN" "$H" --dry-run
exit_is "a dry run of a version directory failing its root checks exits 1" 1
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

WRITABLE="$TMP/writable-root"
copy_root "$WRITABLE"
H="$(home writable)"
before="$(snapshot "$WRITABLE")"
inst "$WRITABLE" "$H"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
same "a writable version directory gains no files from an install or a session start" "$before" "$(snapshot "$WRITABLE")"

H="$(home unlinked)"
inst "$ROOT" "$H"
UNLINKED="$TMP/unlinked-root"
copy_root "$UNLINKED"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
before="$(snapshot "$H")"
inst "$UNLINKED" "$H" --sync
[ "$rc" = 0 ] && [ -z "$out" ] && ok "--sync from a directory the link does not point at prints nothing" || bad "--sync from an unlinked copy prints nothing" "exit $rc: $out"
same "and changes nothing, the link included" "$before" "$(snapshot "$H")"

# ── the bridge ───────────────────────────────────────────────────────────────
# What the bridge fetches at its first run is the machine's, and no install goes
# near it.
H="$(home bridge)"
mkdir -p "$H/.claude/tools/penpot-mcp/node_modules/@penpot"
printf 'fetched\n' >"$H/.claude/tools/penpot-mcp/node_modules/@penpot/marker"
printf 'a log of its own\n' >"$H/.claude/tools/penpot-mcp/.pnpm-install.log"
untouched="$(snapshot "$H/.claude/tools/penpot-mcp/node_modules") $(cat "$H/.claude/tools/penpot-mcp/.pnpm-install.log")"
inst "$ROOT" "$H"
carried=""
for f in package.json package-lock.json start-bridge.sh check-bridge.sh; do
  cmp -s "$ROOT/tools/penpot-mcp/$f" "$H/.claude/tools/penpot-mcp/$f" || carried="$carried $f"
done
[ -z "$carried" ] && ok "a full install copies every file the bridge needs" || bad "the bridge's files are copied" "differing:$carried"
{ [ -x "$H/.claude/tools/penpot-mcp/start-bridge.sh" ] && [ -x "$H/.claude/tools/penpot-mcp/check-bridge.sh" ]; } \
  && ok "and leaves its scripts runnable" || bad "the bridge scripts are executable" "they are not"
same "while its dependencies and its logs are left exactly as they were" "$untouched" \
  "$(snapshot "$H/.claude/tools/penpot-mcp/node_modules") $(cat "$H/.claude/tools/penpot-mcp/.pnpm-install.log")"
bridge_ids() { local f; for f in "$H"/.claude/tools/penpot-mcp/*; do printf '%s ' "$(file_id "$f")"; done; }
before="$(bridge_ids)"
inst "$ROOT" "$H"
same "an install with the same files writes none of them again" "$before" "$(bridge_ids)"
printf 'edited\n' >"$H/.claude/tools/penpot-mcp/package.json"
inst "$ROOT" "$H"
cmp -s "$ROOT/tools/penpot-mcp/package.json" "$H/.claude/tools/penpot-mcp/package.json" \
  && ok "and one that drifted is put back" || bad "a drifted bridge file is replaced" "it was left"
chmod -x "$H/.claude/tools/penpot-mcp/start-bridge.sh"
inst "$ROOT" "$H"
[ -x "$H/.claude/tools/penpot-mcp/start-bridge.sh" ] && ok "so is one that lost the bit that lets it run" \
  || bad "a bridge script that lost +x is replaced" "it is still not executable"

BRIDGELESS="$TMP/bridgeless-root"
copy_root "$BRIDGELESS"
rm -f "$BRIDGELESS/tools/penpot-mcp/package-lock.json"
before="$(snapshot "$H")"
inst "$BRIDGELESS" "$H"
exit_is "a version directory missing a bridge file exits 1" 1
check "naming it under Toolkit" "✗ tools/penpot-mcp/package-lock.json is missing from the version directory" "$(block Toolkit)"
same "and writes nothing" "$before" "$(snapshot "$H")"
copy_root "$BRIDGELESS"
printf 'no shebang here\n' >"$BRIDGELESS/tools/penpot-mcp/start-bridge.sh"
inst "$BRIDGELESS" "$H"
exit_is "nor does one whose bridge script cannot start" 1
check "saying why" "✗ tools/penpot-mcp/start-bridge.sh cannot start: it has no #! line" "$(block Toolkit)"

# A release directory is approved for nobody: a staged tree is one activation
# away from running, and a live one is running already.
H="$(home approved-release)"
RELEASE_ROOT="$TMP/approved-release-root"
copy_root "$RELEASE_ROOT"
printf '1.5.0\n' >"$RELEASE_ROOT/VERSION"
printf 'abc1234\n' >"$RELEASE_ROOT/REVISION"
inst "$RELEASE_ROOT" "$H"
approved="$(js "$H" '.permissions.additionalDirectories | join(" ")')"
case " $approved " in
  *" $RELEASE_ROOT "*) bad "a version directory that is not a work tree is approved for nobody" "it is: $approved" ;;
  *) ok "a version directory that is not a work tree is approved for nobody" ;;
esac
check "while the agents' own directories still are" "$H/.claude/worktrees" "$approved"
same "and a release root approves those two and nothing else" \
  "/tmp/claude-$(id -u) $H/.claude/worktrees" "$approved"

# git init inside a release directory is a local command nothing gates, so where
# a version directory sits has to answer before what it holds does.
UNPACKED="$H/.claude/agent-toolkit-releases/v1.5.0"
mkdir -p "$(dirname "$UNPACKED")"
cp -r "$RELEASE_ROOT" "$UNPACKED"
git -C "$UNPACKED" init -q && git -C "$UNPACKED" add -A >/dev/null 2>&1 && git -C "$UNPACKED" commit -q -m planted
inst "$UNPACKED" "$H"
case " $(js "$H" '.permissions.additionalDirectories | join(" ")') " in
  *" $UNPACKED "*) bad "a release directory made to look like a clone is approved for nobody either" "it is approved" ;;
  *) ok "a release directory made to look like a clone is approved for nobody either" ;;
esac

# The wholesale entry the previous generation wrote is retired at the next apply,
# which is what every toolkit-owned value it stops setting gets.
H="$(home approved-retire)"
WHOLESALE="$TMP/wholesale-root"
copy_root "$WHOLESALE"
patch_desired "$WHOLESALE" '.desired.permissions.additionalDirectories += [$ENV.HOME + "/.claude"]'
inst "$WHOLESALE" "$H"
case " $(js "$H" '.permissions.additionalDirectories | join(" ")') " in
  *" $H/.claude "*) ok "a home that was installed with ~/.claude approved has it" ;;
  *) bad "a home that was installed with ~/.claude approved has it" "$(js "$H" '.permissions.additionalDirectories | join(" ")')" ;;
esac
# A write that leaves it approved took nothing away, whichever rule moved it.
jq '.permissions.deny = []' "$H/.claude/settings.json" >"$TMP/settings" \
  && cp "$TMP/settings" "$H/.claude/settings.json"
inst "$WHOLESALE" "$H"
case "$out" in
  *"settings.json updated"*) ;;
  *) bad "the version that approves it writes settings.json again" "it wrote nothing, so the case proves nothing: $out" ;;
esac
case "$out" in
  *"was approved for every agent"*) bad "and a run that leaves it approved never says it was taken away" "$out" ;;
  *) ok "and a run that leaves it approved never says it was taken away" ;;
esac
inst "$ROOT" "$H"
case " $(js "$H" '.permissions.additionalDirectories | join(" ")') " in
  *" $H/.claude "*) bad "and the next install takes it away" "it is still approved" ;;
  *) ok "and the next install takes it away" ;;
esac
check "saying so, though the ledger took it before the rule did" \
  "! ~/.claude was approved for every agent without a question, which this toolkit keeps unset, so it was removed from settings.json" "$out"

# The ledger is what says the toolkit wrote a value, and a machine that lost one
# is exactly the machine this approval must still be taken from.
H="$(home approved-ledgerless)"
inst "$WHOLESALE" "$H"
jq --arg h "$H" '.permissions.additionalDirectories += [$h, "/my/own/dir", "~/.claude", $h + "/.claude/agent-toolkit-releases/v1.5.0"]' \
  "$H/.claude/settings.json" >"$TMP/settings" && cp "$TMP/settings" "$H/.claude/settings.json"
rm -f "$H/.claude/agent-toolkit-applied.json"
inst "$ROOT" "$H"
approved="$(js "$H" '.permissions.additionalDirectories | join(" ")')"
case " $approved " in
  *" $H/.claude "*) bad "~/.claude goes even with no ledger to vouch for it" "it stayed: $approved" ;;
  *) ok "~/.claude goes even with no ledger to vouch for it" ;;
esac
case " $approved " in
  *" ~/.claude "*) bad "and so does the same path written the way a user writes it" "it stayed: $approved" ;;
  *) ok "and so does the same path written the way a user writes it" ;;
esac
case " $approved " in
  *" $H/.claude/agent-toolkit-releases/v1.5.0 "*) bad "and so does a release directory somebody approved" "it stayed: $approved" ;;
  *) ok "and so does a release directory somebody approved" ;;
esac
check "while the user's own entry stays" "/my/own/dir" "$approved"
case " $approved " in
  *" $H "*) ok "and so does their home, which the toolkit never wrote" ;;
  *) bad "the user's home stays" "it went: $approved" ;;
esac
same "two spellings of ~/.claude are one approval taken away, said once" 1 \
  "$(grep -c '! ~/.claude was approved for every agent without a question' <<<"$out")"
check "and the release directory is said on its own" \
  "! ~/.claude/agent-toolkit-releases/v1.5.0 was approved for every agent without a question, which this toolkit keeps unset" "$out"
case "$out" in
  *"! /my/own/dir was approved"* | *"! ~ was approved"*) bad "and nothing the user keeps is said" "$out" ;;
  *) ok "and nothing the user keeps is said" ;;
esac

# The session start is the run that takes it away on most machines, and it says
# so there. One set again is one taken away again.
H="$(home approved-revoked)"
inst "$ROOT" "$H"
sets_claude_dir() {
  jq '.permissions.additionalDirectories += ["~/.claude"]' "$H/.claude/settings.json" >"$TMP/settings" \
    && cp "$TMP/settings" "$H/.claude/settings.json"
}
revoked() { # name, how often the session start says it
  hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
  same "$1" "$2" "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null \
    | grep -c '! ~/.claude was approved for every agent without a question, which this toolkit keeps unset, so it was removed from settings.json')" \
    "said $(grep -c 'was approved for every agent' <<<"$out") times: ${out:-<empty>}"
}
sets_claude_dir
revoked "a session start that takes ~/.claude away says so once" 1
case " $(js "$H" '.permissions.additionalDirectories | join(" ")') " in
  *" ~/.claude "*) bad "having taken it" "it is still approved" ;;
  *) ok "having taken it" ;;
esac
revoked "and the next one says nothing of it" 0
sets_claude_dir
inst "$ROOT" "$H" --dry-run
case "$out" in
  *"was approved for every agent"*) bad "a dry run takes nothing away, so says nothing was" "$out" ;;
  *) ok "a dry run takes nothing away, so says nothing was" ;;
esac
revoked "and setting it again is said again" 1

# ── a version directory under ~/.claude/worktrees ────────────────────────────
# Every agent may write there without being asked, so the one path by which an
# agent-writable directory becomes the code that runs on every tool call is shut.
H="$(home worktree-root)"
WT="$H/.claude/worktrees/wt"
mkdir -p "$(dirname "$WT")"
copy_root "$WT"
before="$(snapshot "$H")"
inst "$WT" "$H"
exit_is "a version directory under ~/.claude/worktrees exits 1" 1
check "saying why, under Needs you" "✗ the version directory is under ~/.claude/worktrees, which every agent may write" "$(block 'Needs you')"
same "and writes nothing at all" "$before" "$(snapshot "$H")"
inst "$WT" "$H" --dry-run
exit_is "and a dry run of one exits 1 as well" 1
same "writing nothing either" "$before" "$(snapshot "$H")"
SIBLING_HOME="$(home worktree-sibling)"
copy_root "$SIBLING_HOME/.claude/worktrees-old/wt"
inst "$SIBLING_HOME/.claude/worktrees-old/wt" "$SIBLING_HOME"
exit_is "while a directory beside it that only shares its name's start installs" 0
case "$out" in
  *"every agent may write"*) bad "and is never called one an agent may write" "$out" ;;
  *) ok "and is never called one an agent may write" ;;
esac

# The answer comes from inside the refused tree, so it is asked only of a real
# work tree and only with the variables that would answer for another repository
# out of the way.
git -C "$H" init -q && git -C "$H" add -A >/dev/null 2>&1 && git -C "$H" commit -q -m dotfiles
inst "$WT" "$H"
case "$(block 'Needs you')" in
  *"names the checkout"*) bad "a repository above the worktree is never read as its checkout" "it named one" ;;
  *) ok "a repository above the worktree is never read as its checkout" ;;
esac
rm -rf "$H/.git"

# A linked worktree knows the checkout it belongs to, so the finding names it and
# the fix is the command that installs from there.
CHECKOUT="$TMP/worktree-checkout"
copy_root "$CHECKOUT"
git -C "$CHECKOUT" init -q && git -C "$CHECKOUT" add -A >/dev/null 2>&1 && git -C "$CHECKOUT" commit -q -m checkout
LINKED="$H/.claude/worktrees/linked"
git -C "$CHECKOUT" worktree add -q --detach "$LINKED" HEAD
cp "$ROOT/install.sh" "$LINKED/install.sh"
inst "$LINKED" "$H"
exit_is "a linked worktree is refused too" 1
check "naming the checkout it belongs to" "The worktree names the checkout at $CHECKOUT" "$(block 'Needs you')"
worktree_fix="$(block 'Needs you' | grep -F "cd $CHECKOUT" | sed 's/^ *//')"
# A variable naming another repository would answer for that one instead, which
# is a checkout this worktree does not belong to.
OTHER="$TMP/other-checkout"
copy_root "$OTHER"
git -C "$OTHER" init -q && git -C "$OTHER" add -A >/dev/null 2>&1 && git -C "$OTHER" commit -q -m other
out="$(HOME="$H" GIT_DIR="$OTHER/.git" GIT_COMMON_DIR="$OTHER/.git" "$LINKED/install.sh" 2>&1)"
case "$out" in
  *"$OTHER"*) bad "and a git variable never answers for another repository" "it named $OTHER" ;;
  *) ok "and a git variable never answers for another repository" ;;
esac
check "naming the one the worktree belongs to instead" "names the checkout at $CHECKOUT" "$out"
check "with the command that installs from there" "cd $CHECKOUT && ./install.sh" "$worktree_fix"
HOME="$H" bash -c "$worktree_fix" >/dev/null 2>&1
same "and the fix, run as printed, is what goes live" "$CHECKOUT" "$(readlink "$H/.claude/agent-toolkit")"
git -C "$CHECKOUT" worktree remove --force "$LINKED" 2>/dev/null

# The checkout comes out of the worktree's own .git, inside the directory the
# refusal exists because every agent may write it. A rewritten one that names a
# tree an agent could have built is not a checkout to hand the user.
PLANTED_CHECKOUT="$H/.claude/planted-checkout"
copy_root "$PLANTED_CHECKOUT"
git -C "$PLANTED_CHECKOUT" init -q && git -C "$PLANTED_CHECKOUT" add -A >/dev/null 2>&1 \
  && git -C "$PLANTED_CHECKOUT" commit -q -m planted
printf 'gitdir: %s/.git\n' "$PLANTED_CHECKOUT" >"$WT/.git"
inst "$WT" "$H"
exit_is "a worktree naming a checkout of its own is refused all the same" 1
case "$(block 'Needs you')" in
  *"$PLANTED_CHECKOUT"*) bad "and the fix never sends the user into a directory an agent may write" "it named $PLANTED_CHECKOUT" ;;
  *) ok "and the fix never sends the user into a directory an agent may write" ;;
esac
check "saying only what it can stand behind" "mv -T ~/.claude/worktrees/wt <a directory of your own>" "$(block 'Needs you')"
rm -f "$WT/.git"

# --sync needs no rule: a worktree never becomes the live root, so a --sync from
# one finds the link pointing elsewhere and stops before anything else.
inst "$WT" "$H" --sync
[ "$rc" = 0 ] && [ -z "$out" ] && ok "and --sync from one says nothing and changes nothing" \
  || bad "--sync from a worktree says nothing" "exit $rc: $out"

# A machine installed from a worktree before this rule existed keeps working: the
# doctor is not what tells it, because a doctor that refused would leave it with
# no doctor at all until somebody ran a full install.
ln -sfn "$WT" "$H/.claude/agent-toolkit"
rm -f "$H/.claude/skills/toolkit"
inst "$WT" "$H" --sync
[ -L "$H/.claude/skills/toolkit" ] && ok "and a machine already live from one still gets its doctor" \
  || bad "a live worktree root still syncs" "exit $rc: $out"
case "$out" in
  *"every agent may write"*) bad "which never refuses at a session start" "it refused: $out" ;;
  *) ok "which never refuses at a session start" ;;
esac

# ── a version directory inside the scratchpad ────────────────────────────────
# The scratchpad is approved for every agent as well, and it is /tmp/claude-<uid>
# whatever $HOME says, so no fake home keeps these cases away from the real one.
# The mktemp directory is the suite's own, and goes with the suite.
SCRATCH_DIR="/tmp/claude-$(id -u)"
mkdir -p "$SCRATCH_DIR"
SCRATCH_ROOTS="$(mktemp -d "$SCRATCH_DIR/agent-toolkit-suite.XXXXXX")"
CLEANUP+=("$SCRATCH_ROOTS")
H="$(home scratch-root)"
IN_SCRATCH="$SCRATCH_ROOTS/toolkit"
copy_root "$IN_SCRATCH"
before="$(snapshot "$H")"
inst "$IN_SCRATCH" "$H"
exit_is "a version directory inside the scratchpad exits 1" 1
check "exactly as one under the worktrees does" "✗ the version directory is under $SCRATCH_DIR, which every agent may write" \
  "$(block 'Needs you')"
check "with the fix that moves it out" "mv -T $IN_SCRATCH <a directory of your own>" "$(block 'Needs you')"
same "writing nothing" "$before" "$(snapshot "$H")"
inst "$IN_SCRATCH" "$H" --dry-run
exit_is "and a dry run of one exits 1 too" 1
same "writing nothing either" "$before" "$(snapshot "$H")"
inst "$IN_SCRATCH" "$H" --sync
[ "$rc" = 0 ] && [ -z "$out" ] && ok "while --sync from one says nothing, since it is not the live root" \
  || bad "--sync from a scratchpad root says nothing" "exit $rc: $out"
ln -sfn "$IN_SCRATCH" "$H/.claude/agent-toolkit"
rm -f "$H/.claude/skills/toolkit"
inst "$IN_SCRATCH" "$H" --sync
[ -L "$H/.claude/skills/toolkit" ] && ok "and a machine already live from one still gets its doctor" \
  || bad "a live scratchpad root still syncs" "exit $rc: $out"
SCRATCH_LINKED="$TMP/scratch-linked-home"
rm -f "$SCRATCH_LINKED"
ln -s "$(home scratch-linked)" "$SCRATCH_LINKED"
before="$(snapshot "$TMP/scratch-linked")"
out="$(HOME="$SCRATCH_LINKED" "$IN_SCRATCH/install.sh" 2>&1)"
rc=$?
exit_is "and through a symlinked home it is refused all the same" 1
check "saying the same thing" "under $SCRATCH_DIR, which every agent may write" "$out"
same "and writing nothing there either" "$before" "$(snapshot "$TMP/scratch-linked")"

H="$(home clone-accepts-itself)"
CLONE_SELF="$TMP/clone-self"
copy_root "$CLONE_SELF"
git -C "$CLONE_SELF" init -q && git -C "$CLONE_SELF" add -A >/dev/null 2>&1 && git -C "$CLONE_SELF" commit -q -m self
inst "$CLONE_SELF" "$H"
exit_is "a clone, which is approved, is never refused for sitting inside its own approval" 0
check "and is approved" "$CLONE_SELF" "$(js "$H" '.permissions.additionalDirectories | join(" ")')"

# A version directory resolves every component of its own path and $HOME need
# not, so a home reached through a symlink is where a rule written against $HOME
# stops matching. A dotfile manager or a /home on another mount is enough.
LINKED_REAL="$(home linked-real)"
LINKED="$TMP/linked-home"
rm -f "$LINKED"
ln -s "$LINKED_REAL" "$LINKED"
mkdir -p "$LINKED_REAL/.claude/worktrees"
copy_root "$LINKED_REAL/.claude/worktrees/wt"
before="$(snapshot "$LINKED_REAL")"
out="$(HOME="$LINKED" "$LINKED/.claude/worktrees/wt/install.sh" 2>&1)"
rc=$?
exit_is "a worktree root is refused through a symlinked home too" 1
check "saying the same thing" "under ~/.claude/worktrees, which every agent may write" "$out"
same "and writing nothing" "$before" "$(snapshot "$LINKED_REAL")"

PLANTED="$LINKED_REAL/.claude/agent-toolkit-releases/v1.5.0"
mkdir -p "$(dirname "$PLANTED")"
copy_root "$PLANTED"
printf '1.5.0\n' >"$PLANTED/VERSION"
printf 'abc1234\n' >"$PLANTED/REVISION"
git -C "$PLANTED" init -q && git -C "$PLANTED" add -A >/dev/null 2>&1 && git -C "$PLANTED" commit -q -m planted
out="$(HOME="$LINKED" "$LINKED/.claude/agent-toolkit-releases/v1.5.0/install.sh" 2>&1)"
case " $(js "$LINKED_REAL" '.permissions.additionalDirectories | join(" ")') " in
  *" $PLANTED "*) bad "and a release made to look like a clone is approved for nobody through one" "it is approved" ;;
  *) ok "and a release made to look like a clone is approved for nobody through one" ;;
esac

# ── version identity ─────────────────────────────────────────────────────────
H="$(home version)"
RELEASE="$TMP/release-v1.5.0"
copy_root "$RELEASE"
printf '1.5.0\n' >"$RELEASE/VERSION"
printf 'abc1234\n' >"$RELEASE/REVISION"
inst "$RELEASE" "$H"
same "a release's two halves are stamped as one version" "v1.5.0·abc1234" "$(cat "$H/.claude/agent-toolkit-version" 2>/dev/null)"
printf '{"cwd":"/"}' >"$TMP/sl.payload"
out="$(HOME="$H" python3 "$ROOT/hooks/statusline.py" <"$TMP/sl.payload" 2>&1)"
case "$out" in
  *"$(printf '\033[2m⬡ v1.5.0·abc1234\033[0m')") ok "the status line shows a matching release root with no ⚠ or ?" ;;
  *) bad "the status line shows a matching release root with no ⚠ or ?" "$(printf '%s' "$out" | cat -v)" ;;
esac
printf '1.6.0\n' >"$RELEASE/VERSION"
check "and ⚠ once the version directory moves past the stamp" "⚠" "$(HOME="$H" python3 "$ROOT/hooks/statusline.py" <"$TMP/sl.payload" 2>&1)"
# A commit that bumps nothing still moves the revision, which is what catches a
# checkout whose edits are not applied.
printf '1.5.0\n' >"$RELEASE/VERSION"
printf 'abd1234\n' >"$RELEASE/REVISION"
check "and on a moved revision under the same version" "⚠" "$(HOME="$H" python3 "$ROOT/hooks/statusline.py" <"$TMP/sl.payload" 2>&1)"
printf '1.5\n' >"$RELEASE/VERSION"
printf 'abc1234\n' >"$RELEASE/REVISION"
inst "$RELEASE" "$H"
[ ! -e "$H/.claude/agent-toolkit-version" ] && ok "a malformed VERSION removes the stamp" || bad "a malformed VERSION removes the stamp" "$(cat "$H/.claude/agent-toolkit-version")"
exit_is "and still installs" 0
printf '1.5.0\n' >"$RELEASE/VERSION"
rm -f "$RELEASE/REVISION"
inst "$RELEASE" "$H"
[ ! -e "$H/.claude/agent-toolkit-version" ] && ok "and so does a VERSION with no revision beside it" || bad "a half version removes the stamp" "$(cat "$H/.claude/agent-toolkit-version")"

PARENT="$TMP/parent-repo"
rm -rf "$PARENT"
mkdir -p "$PARENT"
git -C "$PARENT" init -q && git -C "$PARENT" commit -q --allow-empty -m parent
copy_root "$PARENT/toolkit"
printf 'v1.0.0·abc1234\n' >"$H/.claude/agent-toolkit-version"
inst "$PARENT/toolkit" "$H"
[ ! -e "$H/.claude/agent-toolkit-version" ] && ok "a copy inside a parent repository never takes the parent's version" \
  || bad "a copy inside a parent repository never takes the parent's version" "stamped $(cat "$H/.claude/agent-toolkit-version")"

if [ -e "$ROOT/.git" ]; then
  same "a checkout is stamped from its declared version and its own history" \
    "v$(cat "$ROOT/VERSION")·$(git -C "$ROOT" rev-parse --short HEAD)" "$(cat "$FAKE/.claude/agent-toolkit-version")"
else
  skip "a checkout is stamped from its declared version and its own history" "the suite is not running from a git checkout"
fi

# REVISION answers for a release, and a work tree answers for itself, so one
# left lying in a clone is never what the clone is stamped with.
CLONE="$TMP/clone-with-revision"
copy_root "$CLONE"
git -C "$CLONE" init -q && git -C "$CLONE" add -A >/dev/null 2>&1 && git -C "$CLONE" commit -q -m clone
printf 'deadbee\n' >"$CLONE/REVISION"
inst "$CLONE" "$H"
same "a work tree ignores a REVISION left in it" \
  "v$(cat "$CLONE/VERSION")·$(git -C "$CLONE" rev-parse --short HEAD)" "$(cat "$H/.claude/agent-toolkit-version" 2>/dev/null)"

cat >"$TMP/version.py" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from lib.version import newer, parse, same, semantic

print(" ".join(str(x) for x in [
    same("v1.5.0·abc1234", "v1.5.0·abc1234ff00"), same("v1.5.0·abc1234", "v1.6.0·abc1234"),
    same("v1.5.0·abc1234", "v1.5.0·abd1234"),
    newer("v1.6.0·abc1234", "v1.5.0·fff0000"), newer("v1.5.0·abc1234", "v1.5.0·abd1234"),
    newer("v1.5.0·fff0000", "v1.5.0·abc1234"),
    newer("v1.10.0", "v1.9.0"), newer("v1.5.0", "v1.5.0·abc1234"),
    semantic("v1.5.0") == semantic("v1.5.0·abc1234"), semantic("1.5.0"),
    parse("v1.5.0·abc1234\nv1.6.0·abc1234"), parse(" v1.5.0·abc1234"), parse("v1.5·abc1234"),
]))
PY
check "equal by version and sha prefix, newer by version alone, and a label is exactly one line" \
  "True False False True False False True False True None None None None" \
  "$(python3 "$TMP/version.py" "$ROOT/hooks")"

# ── sync applies ─────────────────────────────────────────────────────────────
H="$(home sync)"
inst "$ROOT" "$H"
SYNC="$(command_for "$H" SessionStart install.sh)"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
backups="$(ls "$H/.claude/backups" | wc -l)" inode="$(stat -c %i "$H/.claude/settings.json")"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
check "session start restores deleted wiring" "hooks/guard.sh" "$(js "$H" '[.hooks.PreToolUse[].hooks[].command] | join(" ")')"
[ "$(stat -c %i "$H/.claude/settings.json")" != "$inode" ] && ok "by a rename, not a rewrite in place" || bad "by a rename, not a rewrite in place" "same inode"
[ "$(ls "$H/.claude/backups" | wc -l)" -gt "$backups" ] && ok "with a backup" || bad "with a backup" "no new backup"
json_is "and tells the user" '.systemMessage == "agent-toolkit: Updated settings.json"'
json_is "and gives the model the backup it took" '.hookSpecificOutput.additionalContext | test("wrote settings.json \\(backup: ~/.claude/backups/settings.json.")'

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
[ -z "$(find "$H/.claude" -maxdepth 1 \( -name '.*' -o -name 'settings.*.json' \) ! -name .claude)" ] \
  && ok "and leave no temporary file behind" || bad "and leave no temporary file behind" "$(ls -a "$H/.claude")"

jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
lock_holder "$H/.claude"
HOME="$H" sh -c "$SYNC" <"$TMP/hook.payload" >"$TMP/waiting.out" 2>&1 &
waiting=$!
sleep 1
same "a session start waits while another apply holds the lock" "$id_before" "$(file_id "$H/.claude/settings.json")"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
wait "$waiting"
check "and applies once it is released" "hooks/guard.sh" "$(js "$H" '[.hooks.PreToolUse[].hooks[].command] | join(" ")')"
[[ "$(cat "$TMP/waiting.out")" != *"held the lock"* ]] && ok "without reporting the wait" || bad "without reporting the wait" "$(cat "$TMP/waiting.out")"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
lock_holder "$H/.claude"
hook "$H" "$SYNC" '{"hook_event_name":"SessionStart"}'
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
same "a session start that cannot take the lock writes nothing" "$id_before" "$(file_id "$H/.claude/settings.json")"
json_is "and still reports" '.hookSpecificOutput.additionalContext | test("held the lock for 5 seconds, so this session start applied nothing")'
lock_holder "$H/.claude"
hook "$H" "$(command_for "$H" PostToolUse sync.sh)" \
  "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$ROOT/skills/toolkit/SKILL.md\"}}"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
json_is "and an edit that cannot take it says so as an edit" \
  '.hookSpecificOutput.additionalContext | test("held the lock for 5 seconds, so this edit applied nothing")'

# Every settings fixture drives lib/settings through the same request and differs
# only in what it patches, so the preamble is written once and the body arrives
# on stdin.
settings_fixture() { # path
  { cat <<'PY'
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
PY
    cat
  } >"$1"
}

settings_fixture "$TMP/reread.py" <<'PY'
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
check "the finding gives the reason" "settings.json does not parse" "$(block 'Needs you')"
check "and the newest backup that parses" ". The newest backup that parses is ~/.claude/backups/settings.json." "$(block 'Needs you')"
# A backup that does not parse is no backup to offer, however new it is.
printf 'half a file' >"$H/.claude/backups/settings.json.99999999-999999"
inst "$ROOT" "$H"
[[ "$out" != *"settings.json.99999999-999999"* ]] && ok "and never one that does not parse itself" \
  || bad "a backup that does not parse is skipped" "$(block 'Needs you')"
offered="$(block 'Needs you' | grep -oE '~/\.claude/backups/settings\.json\.[0-9.-]+' | head -1)"
cp "$H/${offered#\~/}" "$H/.claude/settings.json" && inst "$ROOT" "$H"
exit_is "and the backup it names restores a green install" 0

printf '{"z": 1, "env": "not an object", "a": 2}\n' >"$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
inst "$ROOT" "$H"
exit_is "a settings.json the merge cannot apply to exits 1" 1
same "and is never written" "$id_before" "$(file_id "$H/.claude/settings.json")"
check "the finding gives the reason" "settings.json was left untouched: env is not an object" "$out"
check "and a command that opens the file, since no command knows the right value" \
  '"${EDITOR:-vi}" ~/.claude/settings.json' "$out"
[[ "$out" != *"cp ~/.claude/backups"* ]] && ok "and offers no restore that would discard the file" || bad "and offers no restore" "$out"

# The value the toolkit itself sets, in the shape a hand edit leaves it: every
# apply fails on it until the user acts, so the finding has to name a command.
printf '{"attribution": true}\n' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
check "a toolkit-owned value edited to the wrong type names its own path" \
  "settings.json was left untouched: attribution is not an object" "$out"
check "and the same command" '"${EDITOR:-vi}" ~/.claude/settings.json' "$out"
check "but names the newest backup that parses" ". The newest backup that parses is ~/.claude/backups/settings.json." "$out"

H="$(home blank-settings)"
printf '{}\n' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
: >"$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
inst "$ROOT" "$H"
exit_is "a settings.json holding nothing exits 1" 1
same "and is never written over" "$id_before" "$(file_id "$H/.claude/settings.json")"
check "with the reason and the backup that would restore it" \
  "settings.json is empty. The newest backup that parses is ~/.claude/backups/settings.json." "$(block 'Needs you')"

printf '{"zebra": 1, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/bin/true"}]}]}, "apple": 2, "mango": {"b": 1, "a": 2}}\n' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
check "a write keeps foreign keys in the order they had" '["zebra","apple","mango"]' \
  "$(js "$H" '[keys_unsorted[] | select(. == "zebra" or . == "apple" or . == "mango")] | tostring')"
check "and the order inside a foreign value" '["b","a"]' "$(js "$H" '.mango | keys_unsorted | tostring')"
check "and a foreign event ahead of the toolkit's" "Stop" "$(js "$H" '.hooks | keys_unsorted[0]')"

cat >"$TMP/backups.py" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from lib.settings import backup

first, second = backup(sys.argv[2], b"first"), backup(sys.argv[2], b"second")
print(first != second, open(first, "rb").read() == b"first", open(second, "rb").read() == b"second")
PY
check "two settings backups in the same second never overwrite each other" "True True True" \
  "$(python3 "$TMP/backups.py" "$ROOT/hooks" "$TMP/backup-race")"
eval "$(sed -n '/^backup_name() {/,/^}/p' "$ROOT/install.sh")"
mkdir -p "$TMP/backup-names"
now="$(date +%s)"
for second in 0 1; do touch "$TMP/backup-names/CLAUDE.md.$(date -d "@$((now + second))" +%Y%m%d-%H%M%S)"; done
case "$(backup_name "$TMP/backup-names/CLAUDE.md")" in
  *.1) ok "a pointer or agent backup takes the next free name" ;;
  *) bad "a pointer or agent backup takes the next free name" "$(backup_name "$TMP/backup-names/CLAUDE.md")" ;;
esac

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
check "and asks for a restart for the plugin entry" "plugins changed" "$out"
grep -q '|plugin uninstall' "$CLAUDE_CALLS" 2>/dev/null && bad "retiring a plugin entry uninstalls nothing" "$(cat "$CLAUDE_CALLS")" \
  || ok "retiring a plugin entry uninstalls nothing"
# A clone is approved while it is the one installed, and dropped when another
# takes over. Both roots are work trees, because a release is approved for nobody.
H="$(home moved-clone)"
for clone in "$TMP/clone-one" "$TMP/clone-two"; do
  copy_root "$clone"
  git -C "$clone" init -q && git -C "$clone" add -A >/dev/null 2>&1 && git -C "$clone" commit -q -m clone
done
inst "$TMP/clone-one" "$H"
check "the clone installed from is approved" "$TMP/clone-one" "$(js "$H" '.permissions.additionalDirectories | join(" ")')"
inst "$TMP/clone-two" "$H"
approved="$(js "$H" '.permissions.additionalDirectories | join(" ")')"
check "and installing from another approves that one" "$TMP/clone-two" "$approved"
case " $approved " in
  *" $TMP/clone-one "*) bad "while the one it replaced is dropped" "it is still approved" ;;
  *) ok "while the one it replaced is dropped" ;;
esac

# Deleting the ledger recovers; corrupting it has to recover the same way, or
# the ledger this run writes holds only what this run changed and nothing the
# toolkit stops setting can ever be retired again.
for state in deleted corrupt; do
  H="$(home "ledger-$state")"
  inst "$EXTRA" "$H"
  check "($state: the five are set)" "[true,true,true,true,true]" "$(js "$H" "$five | tostring")"
  case "$state" in
    deleted) rm -f "$H/.claude/agent-toolkit-applied.json" ;;
    corrupt) printf 'not json at all' >"$H/.claude/agent-toolkit-applied.json" ;;
  esac
  inst "$EXTRA" "$H"
  exit_is "a $state ledger still applies, and the run goes on" 0
  inst "$ROOT" "$H"
  check "and the next version directory still retires all five" "[false,false,false,false,false]" \
    "$(js "$H" "$five | tostring")"
done

H="$(home retire-kept-members)"
printf '{"permissions": {"deny": ["Read(~/.toolkit-test)"], "additionalDirectories": ["/toolkit-test-dir"]}}\n' >"$H/.claude/settings.json"
inst "$EXTRA" "$H"
inst "$ROOT" "$H"
check "a deny rule and a directory the user had before the toolkit set them are kept" "[true,true]" \
  "$(js "$H" '[(.permissions.deny | index("Read(~/.toolkit-test)")), (.permissions.additionalDirectories | index("/toolkit-test-dir"))] | map(. != null) | tostring')"

H="$(home shared-group)"
cat >"$H/.claude/settings.json" <<JSON
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
  {"type": "command", "command": "$H/.claude/agent-toolkit/hooks/guard-git.sh"},
  {"type": "command", "command": "/usr/local/bin/my-guard"}]}]}}
JSON
inst "$ROOT" "$H"
check "a user's handler sharing a group with an old toolkit handler keeps its matcher" "Bash /usr/local/bin/my-guard" \
  "$(js "$H" '.hooks.PreToolUse[] | select(any(.hooks[]; .command == "/usr/local/bin/my-guard")) | "\(.matcher) \([.hooks[].command] | join(","))"')"
check "and the old toolkit handler is gone" "[]" "$(js "$H" '[.. | .command? // empty | select(test("guard-git"))] | tostring')"

H="$(home retire-kept)"
printf '{"toolkitTestKey": "on"}\n' >"$H/.claude/settings.json"
inst "$EXTRA" "$H"
jq '.env.TOOLKIT_TEST_ENV = "mine"' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
inst "$ROOT" "$H"
check "a value the user changed after the toolkit wrote it is kept" "mine" "$(js "$H" '.env.TOOLKIT_TEST_ENV')"
check "and one that held the value before the toolkit first wrote it" "on" "$(js "$H" '.toolkitTestKey')"
check "while the others still go" "[false,false,false]" \
  "$(js "$H" '[(.permissions.deny | index("Read(~/.toolkit-test)")), (.permissions.additionalDirectories | index("/toolkit-test-dir")), .enabledPlugins["test@test"]] | map(. != null) | tostring')"

# ── attribution stays off ────────────────────────────────────────────────────
# The rule against AI attribution is absolute, so the three values that switch
# it off are not left to anyone remembering: a hand edit of any of them is put
# back at the next session start, and the report says the file was written.
H="$(home attribution)"
inst "$ROOT" "$H"
jq '.attribution.sessionUrl = true | .attribution.commitTrailers = true | .includeCoAuthoredBy = true' \
  "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
attribution_now() { js "$1" '[.attribution.sessionUrl, .attribution.commitTrailers, .includeCoAuthoredBy] | tostring'; }
check "(the hand edit lands, so the check below is not vacuous)" "[true,true,true]" "$(attribution_now "$H")"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
check "the three attribution values are put back at session start" "[false,false,false]" \
  "$(attribution_now "$H")"
json_is "and the run says so rather than fixing it silently" \
  '.hookSpecificOutput.additionalContext | test("wrote settings.json")'

# ── a name held across version directories ───────────────────────────────────
# The stable link is the only past this run has: PREV_ROOT is wherever it points
# now. So a skill link left behind by a run whose link moved and whose skills did
# not points at a directory this run knows nothing about. Recognising a link by
# the three paths a run can name leaves that one neither relinked nor removed,
# and the finding then repeats every session while the skill goes on resolving
# out of a directory nothing else points at.
FIRST="$TMP/hop-one" SECOND="$TMP/hop-two"
copy_root "$FIRST"
copy_root "$SECOND"
H="$(home two-hops)"
inst "$FIRST" "$H"
inst "$SECOND" "$H"
ln -sfn "$FIRST/skills/toolkit" "$H/.claude/skills/toolkit"
inst "$ROOT" "$H"
exit_is "a skill link older than the stable link's own past installs green" 0
same "and is relinked at the version directory installing" "$ROOT/skills/toolkit" \
  "$(readlink "$H/.claude/skills/toolkit")"
[[ "$out" != *"is not the toolkit's"* ]] && ok "with no finding claiming the name is the user's" \
  || bad "a link older than PREV_ROOT is still the toolkit's" "$out"

# The same link, for a name the version directory installing no longer has.
RETIRING="$TMP/root-retiring-a-skill"
copy_root "$RETIRING"
rm -rf "$RETIRING/skills/backlog"
H="$(home retire-skill-two-hops)"
inst "$FIRST" "$H"
inst "$SECOND" "$H"
ln -sfn "$FIRST/skills/backlog" "$H/.claude/skills/backlog"
inst "$RETIRING" "$H"
[ ! -e "$H/.claude/skills/backlog" ] && [ ! -L "$H/.claude/skills/backlog" ] \
  && ok "and is unlinked once a version directory stops providing it" \
  || bad "a retired skill is unlinked whichever directory it points into" "$(ls -l "$H/.claude/skills")"
check "which the report names" "unlink skill backlog" "$out"

# A link the user made at a toolkit skill's name, whose target has gone. The
# toolkit never made it, so it is left alone and the finding says so.
H="$(home user-link-dangling)"
mkdir -p "$TMP/user-skills" "$H/.claude/skills"
ln -sfn "$TMP/user-skills/gone-toolkit" "$H/.claude/skills/toolkit"
inst "$ROOT" "$H"
same "a dangling link the user made at a skill's name is left untouched" \
  "$TMP/user-skills/gone-toolkit" "$(readlink "$H/.claude/skills/toolkit")"
check "and is a required finding, not a silent replacement" \
  "skill toolkit is not installed: ~/.claude/skills/toolkit is not the toolkit's, and was left untouched" "$out"

# ── a retired agent ──────────────────────────────────────────────────────────
# A deletion the user never asked for: the skill path backs up and reports, and
# an agent file is no less theirs to have kept notes in.
RETIRED="$TMP/root-with-an-extra-agent"
copy_root "$RETIRED"
printf 'an agent that goes away\n' >"$RETIRED/agents/soon-retired.md"
H="$(home retired-agent)"
inst "$RETIRED" "$H"
[ -f "$H/.claude/agents/soon-retired.md" ] || bad "the extra agent installs" "missing"
rm -f "$RETIRED/agents/soon-retired.md"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
[ ! -e "$H/.claude/agents/soon-retired.md" ] && ok "a retired agent is removed at session start" \
  || bad "a retired agent is removed" "still there"
json_is "and the session start names the removal" \
  '.hookSpecificOutput.additionalContext | test("remove retired agent soon-retired.md")'
saved="$(ls "$H"/.claude/backups/agents/soon-retired.md.* 2>/dev/null | head -1)"
[ -n "$saved" ] && grep -q 'an agent that goes away' "$saved" \
  && ok "with the file kept in backups" || bad "a retired agent is backed up" "$(ls -R "$H/.claude/backups" 2>&1)"

# ── upgrading an install that predates the ledger ────────────────────────────
# The shape the previous install.sh leaves: absolute paths everywhere, no
# launcher, no ledger, and the reaper it used to wire at SessionEnd.
H="$(home predates-ledger)"
ln -s "$ROOT" "$H/.claude/agent-toolkit"
cat >"$H/.claude/settings.json" <<JSON
{
  "env": {"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "2", "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1", "MINE": "1"},
  "crossSessionInbound": "refuse",
  "isolatePeerMachines": true,
  "permissions": {
    "defaultMode": "auto",
    "additionalDirectories": ["/tmp/claude-$(id -u)", "$H/.claude", "$ROOT"],
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
check "and the reaper a previous version wired is unwired, not carried forward" "[]" \
  "$(js "$H" '[.hooks[][].hooks[].command | select(test("reap"))] | tostring')"
check "and the user's own env kept" "1" "$(js "$H" '.env.MINE')"
# The real upgrade path for an approval kept unset: no ledger to vouch for it,
# so retirement alone would leave the wholesale entry there for good.
same "with the approval a previous generation wrote gone, ledger or none" \
  "/tmp/claude-$(id -u) $ROOT $H/.claude/worktrees" "$(js "$H" '.permissions.additionalDirectories | join(" ")')"
check "and the upgrade says it took that approval away" \
  "! ~/.claude was approved for every agent without a question, which this toolkit keeps unset, so it was removed from settings.json" "$out"
LEAN="$TMP/root-without-todo-tools"
copy_root "$LEAN"
patch_desired "$LEAN" 'del(.desired.env.CLAUDE_CODE_ENABLE_TODO_TOOLS)'
inst "$LEAN" "$H"
check "a value present when the ledger was bootstrapped counts as the toolkit's" "null" "$(js "$H" '.env.CLAUDE_CODE_ENABLE_TODO_TOOLS')"

# ── the previous generation ──────────────────────────────────────────────────
# After installing over a v1 machine nothing v1 may still be wired. A leftover
# skill or agent keeps instructing sessions from a generation whose rules no
# longer hold. No v1 hook name appears inside a v2 command, so the substring
# check cannot match the wrong one.
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
same "stable link re-aimed at v2" "$ROOT" "$(readlink "$V1HOME/.claude/agent-toolkit")"

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
    hooks/style.py)
      # A message finding needs no repository, so this proves the wiring rather
      # than re-proving the check.
      hook "$SPACE" "$command" "$(bash_payload "git commit -m \"the parser $EM dropped a token\"" "$SPACE")"
      check "$name reaches the style gate, which denies a dash in the message" "deny" "$(decision "$out")"
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
    hooks/retro.py)
      rm -f "$SPACE/.claude/retro/last-sweep"
      hook "$SPACE" "$command" "{\"hook_event_name\":\"$event\"}"
      [ -e "$SPACE/.claude/retro/last-sweep" ] && ok "$name reaches the recorder" || bad "$name reaches the recorder" "no sweep: exit $rc"
      ;;
    hooks/update.sh)
      if [ "$args" = stage ]; then
        rm -f "$SPACE/.claude/agent-toolkit-staging.json"
        hook "$SPACE" "$command" '{"hook_event_name":"SessionStart","source":"startup"}'
        [ -e "$SPACE/.claude/agent-toolkit-staging.json" ] && ok "$name reaches the updater, which records the check it began" \
          || bad "$name reaches the updater" "nothing was recorded: exit $rc"
      else
        printf 'neither latest nor a release\n' >"$SPACE/.claude/agent-toolkit-track"
        hook "$SPACE" "$command" '{"hook_event_name":"SessionStart","source":"startup"}'
        rm -f "$SPACE/.claude/agent-toolkit-track"
        check "$name reaches the updater, which refuses a track it cannot read" "agent-toolkit-track holds" "$out"
      fi
      ;;
    *) bad "every wired command is checked here" "no check for: $name" ;;
  esac
done < <(wired "$SPACE" | grep -F 'agent-toolkit-run')

same "stage runs at every session start, whatever brought it about" "" \
  "$(wired "$SPACE" | awk -F'\037' '$3 ~ /update.sh stage/ { print $2 }')"
same "and apply at the starts that rebuild a context, fork apart" "startup|resume|clear|compact" \
  "$(wired "$SPACE" | awk -F'\037' '$3 ~ /update.sh apply/ { print $2 }')"
same "nothing waits on stage" "true" \
  "$(jq -r 'first(.hooks.SessionStart[].hooks[] | select(.command | test("update.sh stage")) | .async)' "$SPACE/.claude/settings.json")"
same "and apply is waited for" "null" \
  "$(jq -r 'first(.hooks.SessionStart[].hooks[] | select(.command | test("update.sh apply")) | .async)' "$SPACE/.claude/settings.json")"

# "Runnable as printed" is only really tested by a path with a space in it: the
# quoter returns one already inside quotes, where a ~ substituted in afterwards
# would be a literal the shell never expands.
SPACEFIX="$(home 'fix with a space')"
printf '{"env": "not an object"}\n' >"$SPACEFIX/.claude/settings.json"
inst "$ROOT" "$SPACEFIX"
printf '#!/bin/sh\nprintf "opened %%s\\n" "$1"\n' >"$STUBS/fake-editor"
chmod +x "$STUBS/fake-editor"
fix="$(block 'Needs you' | grep -F 'EDITOR' | sed 's/^ *//')"
check "the fix a settings failure prints opens that very file" \
  "opened $SPACEFIX/.claude/settings.json" "$(HOME="$SPACEFIX" EDITOR=fake-editor bash -c "$fix")"

# The version directory moves out from under the stable link.
H="$(home dangling)"
MOVABLE="$TMP/movable-root"
rm -rf "$TMP/moved-root"
copy_root "$MOVABLE"
# A work tree, because that is the version directory an approved directory names,
# and dropping the old location is what this case is about.
git -C "$MOVABLE" init -q && git -C "$MOVABLE" add -A >/dev/null 2>&1 && git -C "$MOVABLE" commit -q -m movable
inst "$MOVABLE" "$H"
check "the checkout installed from is approved" "$MOVABLE" "$(js "$H" '.permissions.additionalDirectories | join(" ")')"
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
hook "$H" "$(command_for "$H" PostToolUse sync.sh)" '{"hook_event_name":"PostToolUse"}'
[ "$rc" = 0 ] && [ -z "$out" ] && ok "any other event exits 0 with no output" || bad "any other event exits 0 with no output" "exit $rc: $out"
inst "$TMP/moved-root" "$H"
exit_is "a full install from the new location goes green" 0
printf '{}' >"$TMP/hook.payload"
HOME="$H" "$H/.claude/agent-toolkit-run" PreToolUse install.sh --dryrun <"$TMP/hook.payload" >/dev/null 2>&1
rc=$?
exit_is "the launcher passes the entry point's exit status through" 2
hook "$H" '"$HOME/.claude/agent-toolkit-run" PreToolUse hooks/no-such-hook.sh' "$(bash_payload 'ls')"
check "an entry point missing behind a good link is asked too" "ask" "$(decision "$out")"
json_is "naming the entry point" '.hookSpecificOutput.permissionDecisionReason | test("hooks/no-such-hook.sh is missing or not executable")'
same "and re-points the link" "$TMP/moved-root" "$(readlink "$H/.claude/agent-toolkit")"
check "and drops the old location from the approved directories" "null" \
  "$(jq --arg v "$MOVABLE" '.permissions.additionalDirectories | index($v)' "$H/.claude/settings.json")"
[ -z "$(find "$H/.claude/skills" -maxdepth 1 -lname "$MOVABLE/*")" ] && ok "and unlinks the old location's skills" || bad "and unlinks the old location's skills" "$(ls -l "$H/.claude/skills")"

# ── a wired file that cannot be read ─────────────────────────────────────────
# The root check opens every wired entry point. One it cannot read has to be a
# finding, not two bash errors and a run that calls the directory healthy.
if [ "$(id -u)" -ne 0 ]; then
  UNREADABLE="$TMP/root-unreadable-hook"
  copy_root "$UNREADABLE"
  chmod 111 "$UNREADABLE/hooks/guard.sh"
  H="$(home unreadable-hook)"
  out="$(HOME="$H" "$UNREADABLE/install.sh" 2>&1)"
  rc=$?
  chmod 755 "$UNREADABLE/hooks/guard.sh"
  exit_is "a wired entry point that cannot be read exits 1" 1
  check "with a finding naming it" "hooks/guard.sh cannot start: it cannot be read" "$out"
  [[ "$out" != *"unbound variable"* ]] && ok "and no bash error of its own" || bad "no bash error" "$out"
else
  skip "a wired entry point that cannot be read" "running as root, which reads anything"
fi

# ── a write that fails ───────────────────────────────────────────────────────
# Root writes into a read-only directory regardless, so this is skipped there.
VERSIONED="$TMP/versioned-root"
copy_root "$VERSIONED"
printf 'abc1234\n' >"$VERSIONED/REVISION"
if [ "$(id -u)" -ne 0 ]; then
  H="$(home write-fails)"
  inst "$VERSIONED" "$H"
  rm -f "$H/.claude/agent-toolkit-version" "$H/.claude/skills/toolkit"
  printf 'edited\n' >"$H/.claude/agents/developer.md"
  chmod a-w "$H/.claude/agents"
  inst "$VERSIONED" "$H"
  chmod u+w "$H/.claude/agents"
  exit_is "a write inside ~/.claude that fails exits 1" 1
  check "and the report names what did not apply" "✗ did not apply: copy agent developer.md" "$(block 'Run install again')"
  [ -L "$H/.claude/skills/toolkit" ] && ok "while the steps before it stay applied" || bad "while the steps before it stay applied" "the skill link was not restored"
  [ ! -e "$H/.claude/agent-toolkit-version" ] && ok "and no version stamp is written" || bad "and no version stamp is written" "stamped"
else
  skip "a write inside ~/.claude that fails" "running as root, which writes into a read-only directory"
fi

H="$(home stamp-with-finding)"
UNVERSIONED="$TMP/unversioned-root"
copy_root "$UNVERSIONED"
printf 'v0.9.0·abc1234\n' >"$H/.claude/agent-toolkit-version"
out="$(HOME="$H" CLAUDE_STUB_VERSION=2.1.1 "$UNVERSIONED/install.sh" 2>&1)"
[ ! -e "$H/.claude/agent-toolkit-version" ] && ok "a root with no version removes the stamp even while a required finding stands" \
  || bad "a root with no version removes the stamp even while a required finding stands" "$(cat "$H/.claude/agent-toolkit-version")"

# ── layout ───────────────────────────────────────────────────────────────────
H="$(home at-stable-path)"
copy_root "$H/.claude/agent-toolkit"
before="$(snapshot "$H")"
inst "$H/.claude/agent-toolkit" "$H"
exit_is "a version directory at ~/.claude/agent-toolkit exits 1" 1
same "and writes nothing, no link inside it included" "$before" "$(snapshot "$H")"
check "giving the command that moves it" "mv -T ~/.claude/agent-toolkit ~/Documents/git-repo/agent-toolkit-v2 && ~/Documents/git-repo/agent-toolkit-v2/install.sh" "$out"
fix="$(block 'Needs you' | sed -n 3p | sed 's/^ *//')"
out="$(HOME="$H" bash -c "$fix" 2>&1)"
rc=$?
exit_is "and that command, run as printed, installs green from the new place" 0
same "leaving the stable path a link" "$H/Documents/git-repo/agent-toolkit-v2" "$(readlink "$H/.claude/agent-toolkit")"

H="$(home stable-path-dir)"
mkdir -p "$H/.claude/agent-toolkit"
printf 'old\n' >"$H/.claude/agent-toolkit/old-file"
before="$(snapshot "$H")"
: >"$CLAUDE_CALLS"
inst "$ROOT" "$H"
exit_is "a real directory at the stable path stops an install run from elsewhere too" 1
same "which writes nothing" "$before" "$(snapshot "$H")"
[ -z "$(grep -F '|plugin' "$CLAUDE_CALLS")" ] && ok "and fetches no plugin" || bad "and fetches no plugin" "$(cat "$CLAUDE_CALLS")"

H="$(home stable-path-file)"
printf 'not a link\n' >"$H/.claude/agent-toolkit"
before="$(snapshot "$H")"
inst "$ROOT" "$H"
exit_is "a file at the stable path exits 1" 1
same "and writes nothing" "$before" "$(snapshot "$H")"
check "calling it a file, not a directory" "✗ ~/.claude/agent-toolkit is a file, not a link to a version directory" "$(block 'Needs you')"
fix="$(block 'Needs you' | sed -n 3p | sed 's/^ *//')"
HOME="$H" bash -c "$fix" >/dev/null 2>&1
inst "$ROOT" "$H"
exit_is "and its fix, run as printed, installs green" 0

H="$(home user-skill-link)"
mkdir -p "$H/.claude/skills" "$TMP/their-backlog"
ln -s "$TMP/their-backlog" "$H/.claude/skills/backlog"
inst "$ROOT" "$H"
exit_is "a user's own link at a skill name exits 1" 1
check "and is left pointing where it did" "$TMP/their-backlog" "$(readlink "$H/.claude/skills/backlog")"
check "while the other skills still install" "$ROOT/skills/toolkit" "$(readlink "$H/.claude/skills/toolkit")"

# ── requirements ─────────────────────────────────────────────────────────────
# A PATH holding every tool on this one except jq, the package managers, sudo,
# claude, gh, ssh, ssh-add and any named here. A scenario adds tools back.
make_farm() { # directory, further tools to leave out
  python3 - "$1" "$PATH" "$STUBS" "${@:2}" <<'PY'
import os
import sys

farm, path, stubs = sys.argv[1:4]
taken = {"jq", "apt-get", "dnf", "pacman", "sudo", "claude", "gh", "ssh", "ssh-add", *sys.argv[4:]}
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
}
FARM="$TMP/farm"
make_farm "$FARM"
scenario() { # name, tools… → a PATH over the farm: a recording stub per tool, the test PATH's own for =tool
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
  printf '%s:%s' "$dir" "${SCENARIO_FARM:-$FARM}"
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
out="$(HOME="$H" PATH="$(scenario dnf dnf sudo =gh =claude)" "$ROOT/install.sh" 2>&1)"
check "with dnf the line is its own" "sudo dnf install -y jq" "$out"
out="$(HOME="$H" PATH="$(scenario pacman pacman sudo =claude)" "$ROOT/install.sh" 2>&1)"
check "with pacman every missing package is in one command, by its own names" "sudo pacman -S --needed jq github-cli" "$out"
out="$(HOME="$H" PATH="$(scenario none sudo =gh =claude)" "$ROOT/install.sh" --sync 2>&1)"
[ -z "$out" ] && ok "a sync from an unlinked home stays silent even without jq" || bad "a sync from an unlinked home stays silent" "$out"
out="$(HOME="$H" PATH="$(scenario none sudo =gh =claude)" "$ROOT/install.sh" 2>&1)"
check "with no known package manager the packages are named" "install these packages with your package manager: jq" "$out"
[ ! -e "$TMP/tool.calls" ] && ok "and no package manager or sudo is ever run" || bad "and no package manager or sudo is ever run" "$(cat "$TMP/tool.calls")"
make_farm "$TMP/farm-no-python" python3
out="$(HOME="$H" PATH="$(SCENARIO_FARM="$TMP/farm-no-python" scenario no-python apt-get sudo =jq =gh =claude)" "$ROOT/install.sh" 2>&1)"
check "without python3 the finding stops the install too" "$(printf '✗ not on PATH: python3. Nothing can be merged or verified without it, so nothing was changed\n    sudo apt-get install -y python3')" "$out"

# A linked machine that loses jq still hears about it at session start.
H="$(home linked-no-jq)"
inst "$ROOT" "$H"
id_before="$(file_id "$H/.claude/settings.json")"
printf '{"hook_event_name":"SessionStart"}' >"$TMP/hook.payload"
out="$(HOME="$H" PATH="$(scenario linked-no-jq =gh =claude =ssh-add)" sh -c "$(command_for "$H" SessionStart install.sh)" <"$TMP/hook.payload" 2>/dev/null)"
rc=$?
exit_is "a session start without jq still exits 0" 0
json_is "with one object telling the user and naming the package" \
  '(.systemMessage | test("1 problem")) and (.hookSpecificOutput.additionalContext | test("not on PATH: jq.*install these packages with your package manager: jq"))'
same "and applies nothing" "$id_before" "$(file_id "$H/.claude/settings.json")"

H="$(home no-identity)"
: >"$TMP/empty-gitconfig"
out="$(HOME="$H" GIT_CONFIG_GLOBAL="$TMP/empty-gitconfig" "$ROOT/install.sh" 2>&1)"
rc=$?
[ ! -s "$TMP/empty-gitconfig" ] && ok "install never sets git identity itself" || bad "install never sets git identity itself" "$(cat "$TMP/empty-gitconfig")"
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
check "while everything local still applies" "agent-toolkit-run" "$(js "$H" '.statusLine.command')"

H="$(home no-claude)"
out="$(HOME="$H" PATH="$(scenario no-claude =gh =jq =ssh-add)" "$ROOT/install.sh" 2>&1)"
check "a machine without claude gets the installer line" "curl -fsSL https://claude.ai/install.sh | bash" "$out"
same "and still gets everything local" "$ROOT" "$(readlink "$H/.claude/agent-toolkit")"

H="$(home no-agent)"
rm -f "$SSH_CALLS"
out="$(HOME="$H" SSH_AUTH_SOCK= "$ROOT/install.sh" 2>&1)"
rc=$?
check "with no ssh-agent the advisory gives the fix" "$(printf '! no ssh-agent holding a key is reachable from this shell, so git over SSH from Claude Code fails, an approved push included\n    eval "$(ssh-agent -s)" && ssh-add && claude')" "$out"
exit_is "without changing the exit code" 0
grep -q '^ssh ' "$SSH_CALLS" 2>/dev/null && bad "and nothing touches the network" "$(cat "$SSH_CALLS")" || ok "and nothing touches the network"
H="$(home agent-no-key)"
rm -f "$SSH_CALLS"
out="$(HOME="$H" SSH_ADD_STUB_RC=1 "$ROOT/install.sh" 2>&1)"
rc=$?
check "an ssh-agent holding no key gets the same advisory" "! no ssh-agent holding a key is reachable from this shell" "$out"
exit_is "as an advisory" 0
same "found by asking the agent alone" "ssh-add -l" "$(cat "$SSH_CALLS")"

H="$(home no-git)"
make_farm "$TMP/farm-no-git" git
rm -f "$TMP/tool.calls"
out="$(HOME="$H" PATH="$(SCENARIO_FARM="$TMP/farm-no-git" scenario no-git apt-get sudo =claude =jq =gh =ssh-add)" "$ROOT/install.sh" 2>&1)"
rc=$?
check "without git the finding is required, with the package line" "$(printf '✗ not on PATH: git\n    sudo apt-get install -y git')" "$out"
exit_is "and exits 1" 1
check "while everything local still applies" "agent-toolkit-run" "$(js "$H" '.statusLine.command')"
[ ! -e "$TMP/tool.calls" ] && ok "and still runs neither sudo nor the package manager" || bad "and still runs neither sudo nor the package manager" "$(cat "$TMP/tool.calls")"

# gh is checked with the token it carries, and neither at a session start: the
# same advisory in every session cannot be acted on from inside that session.
H="$(home gh-at-session-start)"
inst "$ROOT" "$H"
make_farm "$TMP/farm-no-gh" gh
printf '{"hook_event_name":"SessionStart"}' >"$TMP/hook.payload"
out="$(HOME="$H" PATH="$(SCENARIO_FARM="$TMP/farm-no-gh" scenario without-gh =claude =jq =ssh-add)" \
  sh -c "$(command_for "$H" SessionStart install.sh)" <"$TMP/hook.payload" 2>/dev/null)"
[[ "$out" != *"gh is not on PATH"* ]] && ok "a session start says nothing about gh being absent" \
  || bad "a session start skips the gh check" "$out"
out="$(HOME="$H" PATH="$(SCENARIO_FARM="$TMP/farm-no-gh" scenario without-gh =claude =jq =ssh-add)" "$ROOT/install.sh" 2>&1)"
check "while a full install still gives the advisory" \
  "gh is not on PATH, so PR and release flows fail" "$out"

H="$(home gh-no-token)"
out="$(HOME="$H" GH_STUB_RC=1 "$ROOT/install.sh" 2>&1)"
rc=$?
check "a gh with no token for github.com gets the login line" "$(printf '! gh holds no token for github.com, so PR and release flows fail\n    gh auth login --hostname github.com --git-protocol ssh --web')" "$out"
exit_is "as an advisory" 0

H="$(home no-gh)"
rm -f "$TMP/tool.calls"
out="$(HOME="$H" PATH="$(scenario no-gh apt-get sudo =claude =jq =ssh-add)" "$ROOT/install.sh" 2>&1)"
[ ! -e "$TMP/tool.calls" ] && ok "a machine without gh gets no package installed for it" || bad "a machine without gh gets no package installed" "$(cat "$TMP/tool.calls")"
check "without gh the package line comes before the login" "$(printf '    sudo apt-get install -y gh\n    gh auth login --hostname github.com --git-protocol ssh --web')" "$out"

# ── plugins ──────────────────────────────────────────────────────────────────
H="$(home plugins)"
: >"$CLAUDE_CALLS"
inst "$ROOT" "$H"
check "a full install registers each marketplace over HTTPS" "1|plugin marketplace add anthropics/claude-plugins-official" "$(cat "$CLAUDE_CALLS")"
check "from the notifications plugin's current source" "1|plugin marketplace add 777genius/agent-notifications" "$(cat "$CLAUDE_CALLS")"
check "and installs each plugin at user scope over HTTPS" "1|plugin install claude-notifications-go@claude-notifications-go --scope user --json" "$(cat "$CLAUDE_CALLS")"
# Three of the four share a marketplace, so a run that registered it once for
# each would have registered it three times.
same "a marketplace three plugins share is registered once" "1" \
  "$(grep -c 'plugin marketplace add anthropics/claude-plugins-official' "$CLAUDE_CALLS")"
same "and every plugin in the list is fetched" "4" \
  "$(grep -c 'plugin install .* --scope user --json' "$CLAUDE_CALLS")"
check "and asks for a restart" "plugins changed" "$out"
: >"$CLAUDE_CALLS"
inst "$ROOT" "$H" --sync
inst "$ROOT" "$H" --dry-run
[ -z "$(grep -E '\|plugin (marketplace add|install) ' "$CLAUDE_CALLS")" ] && ok "--sync and --dry-run fetch nothing" || bad "--sync and --dry-run fetch nothing" "$(cat "$CLAUDE_CALLS")"

H="$(home old-source)"
state="$STUB_STATE/$(printf '%s' "$H" | cksum | cut -d' ' -f1)"
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
: >"$CLAUDE_CALLS"
out="$(HOME="$H" CLAUDE_STUB_FAIL=add "$ROOT/install.sh" 2>&1)"
check "a failing marketplace fetch carries its message too" "was not registered: ✘ Failed to add marketplace: the stub refused" "$out"
# Asked once, and every plugin behind it told, rather than asked once per plugin.
same "a marketplace that would not register is asked for once" "1" \
  "$(grep -c 'plugin marketplace add anthropics/claude-plugins-official' "$CLAUDE_CALLS")"
same "and none of the plugins behind it is fetched" "" \
  "$(grep 'plugin install .*claude-plugins-official' "$CLAUDE_CALLS")"
# One refusing while the other registers is what separates "its three went with
# it" from "nothing registered at all".
H="$(home one-market-refused)"
: >"$CLAUDE_CALLS"
out="$(HOME="$H" CLAUDE_STUB_FAIL_MARKET=anthropics/claude-plugins-official "$ROOT/install.sh" 2>&1)"
same "a marketplace that refuses takes every plugin behind it" "" \
  "$(grep 'plugin install .*claude-plugins-official' "$CLAUDE_CALLS")"
check "and leaves the one behind another alone" "plugin install claude-notifications-go@claude-notifications-go" "$(cat "$CLAUDE_CALLS")"

# Which events notify is the plugin's setting and the user's decision, so the
# doctor says the same thing either way. Both paths a check could plausibly
# read are written, because the report is what has to stay identical, whichever
# file a view would have opened.
H="$(home notifications)"
# Installed first, so both runs compared below are the same idempotent report.
inst "$ROOT" "$H"
inst "$ROOT" "$H"
silent="$out"
for ncfg in "$H/.config/agent-notifications/config.json" "$H/.claude/claude-notifications-go/config.json"; do
  mkdir -p "$(dirname "$ncfg")"
  printf '{"notifications":{"suppressForSubagents":false,"notifyOnSubagentStop":true}}\n' >"$ncfg"
  # The settings a view would object to, or the case below passes on a file
  # nothing would have flagged either.
  jq -e '.notifications.suppressForSubagents == false and .notifications.notifyOnSubagentStop == true' \
    "$ncfg" >/dev/null 2>&1 \
    || bad "the notifications fixture is the one a view would flag" "$(cat "$ncfg" 2>/dev/null)"
  inst "$ROOT" "$H"
  same "the doctor holds no view on ~/${ncfg#"$H/"}" "$silent" "$out" \
    "the plugin's config changed what the doctor said: $out"
done
exit_is "and the install is green with both of them there" 0

# ── failure paths ────────────────────────────────────────────────────────────
# A version directory whose gate would not hold never goes live.
GATELESS="$TMP/gateless-root"
copy_root "$GATELESS"
printf '#!/bin/sh\nexit 0\n' >"$GATELESS/hooks/launcher.sh"
H="$(home gateless)"
inst "$GATELESS" "$H"
exit_is "a launcher that would not ask fails the root checks" 1
check "naming it" "✗ hooks/launcher.sh does not ask when the toolkit is unreachable" "$out"
copy_root "$GATELESS"
sed -i '0,/^set -uo pipefail$/s//set -uo pipefail\nexit 0/' "$GATELESS/hooks/guard.sh"
inst "$GATELESS" "$H"
check "a guard that would not ask before a push fails them too" "✗ hooks/guard.sh does not ask before a push" "$out"
copy_root "$GATELESS"
sed -i '1s/$/\r/' "$GATELESS/hooks/guard.sh"
inst "$GATELESS" "$H"
check "an entry point whose #! line cannot run fails them" "✗ hooks/guard.sh cannot start: its #! line ends in a carriage return" "$out"
copy_root "$GATELESS"
rm -f "$GATELESS"/agents/*.md
H="$(home no-agents)"
inst "$ROOT" "$H"
before="$(snapshot "$H")"
inst "$GATELESS" "$H"
exit_is "a version directory holding no agent fails them" 1
same "rather than retiring every agent" "$before" "$(snapshot "$H")"

# The launcher never lets a call through unasked, whatever the guard does.
H="$(home unstartable)"
mkdir -p "$TMP/unstartable/hooks"
printf '#!/nonexistent/interpreter\n' >"$TMP/unstartable/hooks/guard.sh"
printf '#!/bin/sh\nexit 1\n' >"$TMP/unstartable/hooks/crash.sh"
chmod +x "$TMP/unstartable/hooks/guard.sh" "$TMP/unstartable/hooks/crash.sh"
ln -s "$TMP/unstartable" "$H/.claude/agent-toolkit"
install -m 755 "$ROOT/hooks/launcher.sh" "$H/.claude/agent-toolkit-run"
hook "$H" '"$HOME/.claude/agent-toolkit-run" PreToolUse hooks/guard.sh' "$(bash_payload 'ls')"
check "a guard that cannot start is asked" "ask" "$(decision "$out")"
hook "$H" '"$HOME/.claude/agent-toolkit-run" PreToolUse hooks/crash.sh' "$(bash_payload 'ls')"
check "and so is a guard that crashes" "ask" "$(decision "$out")"
hook "$H" '"$HOME/.claude/agent-toolkit-run" PreToolUse' "$(bash_payload 'ls')"
check "and a command that names no entry point" "ask" "$(decision "$out")"

# Settings name the launcher, so a launcher that did not land holds them back.
H="$(home launcher-blocked)"
inst "$ROOT" "$H"
rm -f "$H/.claude/agent-toolkit-run"
mkdir "$H/.claude/agent-toolkit-run"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
inst "$ROOT" "$H"
exit_is "a launcher that cannot be written exits 1" 1
same "and settings are not rewired to it" "$id_before" "$(file_id "$H/.claude/settings.json")"
check "naming what did not apply" "did not apply: launcher ~/.claude/agent-toolkit-run" "$out"

# A session start queued behind an install that moves the link applies nothing
# once it gets the lock.
H="$(home queued)"
QUEUED_X="$TMP/queued-x" QUEUED_Y="$TMP/queued-y"
copy_root "$QUEUED_X"
copy_root "$QUEUED_Y"
inst "$QUEUED_Y" "$H"
ln -sfn "$QUEUED_X" "$H/.claude/agent-toolkit"
lock_holder "$H/.claude"
printf '{"hook_event_name":"SessionStart"}' >"$TMP/queued.payload"
HOME="$H" "$QUEUED_X/install.sh" --sync <"$TMP/queued.payload" >"$TMP/queued.out" 2>&1 &
queued=$!
for _ in $(seq 100); do pgrep -f 'flock -w 5' >/dev/null && break; sleep 0.1; done
pgrep -f 'flock -w 5' >/dev/null && ok "(the queued session start is waiting on the lock)" || bad "the queued session start reached the lock" "it never waited"
ln -sfn "$QUEUED_Y" "$H/.claude/agent-toolkit"
before="$(snapshot "$H")"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
wait "$queued"
same "a session start that finds the link moved once it holds the lock applies nothing" "$before" "$(snapshot "$H")"
[ ! -s "$TMP/queued.out" ] && ok "and prints nothing" || bad "and prints nothing" "$(cat "$TMP/queued.out")"

H="$(home dry-move)"
inst "$VERSIONED" "$H"
MOVED="$TMP/dry-moved-root"
copy_root "$MOVED"
inst "$MOVED" "$H" --dry-run
check "a dry run from a new location shows the link move" "~/.claude/agent-toolkit → $MOVED (was $VERSIONED)" "$out"
check "and the stamp it would remove" "version stamp removed" "$out"

# An agent file whose backup failed stays the user's.
H="$(home agent-backup-fails)"
inst "$ROOT" "$H"
grep -vx developer.md "$H/.claude/agents/.toolkit-agents" >"$TMP/manifest" && cp "$TMP/manifest" "$H/.claude/agents/.toolkit-agents"
printf 'my own developer\n' >"$H/.claude/agents/developer.md"
rm -rf "$H/.claude/backups"
printf 'not a directory\n' >"$H/.claude/backups"
inst "$ROOT" "$H"
inst "$ROOT" "$H"
grep -qx 'my own developer' "$H/.claude/agents/developer.md" \
  && ok "a user's agent whose backup failed is not replaced on the next run" || bad "a user's agent whose backup failed is not replaced" "replaced"
rm -f "$H/.claude/backups"
inst "$ROOT" "$H"
grep -qx 'my own developer' "$H"/.claude/backups/agents/developer.md.* 2>/dev/null \
  && ok "and is backed up once the backup can be taken" || bad "and is backed up once the backup can be taken" "no backup"

# A settings backup that cannot be taken leaves no copy of settings behind.
H="$(home backups-blocked)"
inst "$ROOT" "$H"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
rm -rf "$H/.claude/backups"
printf 'not a directory\n' >"$H/.claude/backups"
inst "$ROOT" "$H"
check "a settings backup that cannot be taken names the backups path" "cannot write ~/.claude/backups" "$out"
[ -z "$(find "$H/.claude" -maxdepth 1 -name 'settings.*.json')" ] \
  && ok "and leaves no staged copy of settings" || bad "and leaves no staged copy of settings" "$(ls -a "$H/.claude")"

H="$(home nan)"
printf '{"cleanupPeriodDays": NaN}\n' >"$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
inst "$ROOT" "$H"
check "NaN, which Claude Code cannot parse, does not parse here either" "settings.json does not parse" "$out"
same "and the file is left untouched" "$id_before" "$(file_id "$H/.claude/settings.json")"

H="$(home linked-settings)"
mkdir -p "$TMP/dotfiles"
printf '{"theme":"dark"}\n' >"$TMP/dotfiles/settings.json"
printf 'mine\n' >"$TMP/dotfiles/CLAUDE.md"
ln -s "$TMP/dotfiles/settings.json" "$H/.claude/settings.json"
ln -s "$TMP/dotfiles/CLAUDE.md" "$H/.claude/CLAUDE.md"
inst "$ROOT" "$H"
check "a settings.json that was a link says it is now a file" "settings.json was a link to $TMP/dotfiles/settings.json and is now a file" "$out"
check "and so does a pointer that was one" "~/.claude/CLAUDE.md was a link to $TMP/dotfiles/CLAUDE.md and is now a file" "$out"

# A project's own module never runs inside a session start.
H="$(home cwd-imports)"
inst "$ROOT" "$H"
HOSTILE="$TMP/hostile-project"
mkdir -p "$HOSTILE"
for module in ast sqlite3 importlib traceback fcntl json; do
  printf 'open(%s, "w").close()\n' "'$TMP/imported-$module'" >"$HOSTILE/$module.py"
done
cd "$HOSTILE" || exit 1
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
cd "$ROOT" || exit 1
[ -z "$(ls "$TMP"/imported-* 2>/dev/null)" ] && ok "a project's own ast.py or sqlite3.py never runs at session start" \
  || bad "a project's own module never runs at session start" "$(ls "$TMP"/imported-*)"
[ -z "$out" ] && ok "and the session start stays clean" || bad "and the session start stays clean" "$out"

if [ "$(id -u)" -ne 0 ]; then
  H="$(home lock-error)"
  inst "$ROOT" "$H"
  chmod 0300 "$H/.claude"
  inst "$ROOT" "$H"
  chmod 0755 "$H/.claude"
  exit_is "a lock that cannot be taken for another reason exits 1" 1
  check "and says why, not that another install held it" \
    "the apply lock on ~/.claude could not be taken, so nothing was applied: ~/.claude cannot be opened" "$out"
  check "with the command that opens it" "    chmod u+rwx ~/.claude" "$out"
else
  skip "a lock that cannot be taken for another reason" "running as root, which opens any directory"
fi

H="$(home corrupt-ledger)"
inst "$ROOT" "$H"
head -c 40 "$H/.claude/agent-toolkit-applied.json" >"$TMP/ledger" && cp "$TMP/ledger" "$H/.claude/agent-toolkit-applied.json"
jq 'del(.hooks.PreToolUse)' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
check "a ledger that will not read still restores the wiring" "hooks/guard.sh" \
  "$(js "$H" '[.hooks.PreToolUse[].hooks[].command] | join(" ")')"
json_is "and says so" '.hookSpecificOutput.additionalContext | test("ledger ~/.claude/agent-toolkit-applied.json does not read")'
[ -n "$(ls "$H"/.claude/backups/agent-toolkit-applied.json.unreadable-* 2>/dev/null)" ] \
  && ok "keeping the unreadable ledger in backups" || bad "keeping the unreadable ledger" "$(ls "$H/.claude/backups")"
jq -e . "$H/.claude/agent-toolkit-applied.json" >/dev/null 2>&1 && ok "and writing a ledger that reads" \
  || bad "and writing a ledger that reads" "$(cat "$H/.claude/agent-toolkit-applied.json")"
inst "$ROOT" "$H"
exit_is "so the next install goes green" 0

# A first apply that failed leaves the user's own values theirs: the ledger is
# rebuilt from the file only where the toolkit's own wiring is already in it.
H="$(home failed-first-apply)"
printf '{"includeCoAuthoredBy": false, "isolatePeerMachines": true,' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
exit_is "a first install against a settings.json that does not parse exits 1" 1
printf '{"includeCoAuthoredBy": false, "isolatePeerMachines": true}\n' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
exit_is "and goes green once the file parses" 0
check "with neither value the user already held claimed as the toolkit's" "[]" \
  "$(jq -c '[.values[].path | join(".")] | map(select(. == "includeCoAuthoredBy" or . == "isolatePeerMachines"))' \
    "$H/.claude/agent-toolkit-applied.json")"

# The ledger written before the settings rename is what a value applied now
# rests on, so a ledger write that fails after the rename loses nothing.
settings_fixture "$TMP/ledger-fails.py" <<'PY'
real = settings.replace
writes = []


def failing(target, data):
    # settings.json does not exist yet, so its being there is what marks the
    # ledger write that comes after the rename. That one fails.
    writes.append(target)
    if os.path.exists(path):
        raise OSError(5, "the ledger write failed")
    real(target, data)


settings.replace = failing
settings.run(request, write=True)
settings.replace = real
ledgered = json.load(open(request["ledger"]))["values"]
request["desired"] = {"env": {}}
settings.run(request, write=True)
print(json.dumps({"ledgered": ledgered, "env": json.load(open(path))["env"]}))
PY
out="$(python3 "$TMP/ledger-fails.py" "$ROOT/hooks" "$TMP/ledger-fails" 2>&1)"
json_is "a value whose ledger write failed after the rename is recorded, and retired by a later install" \
  '.ledgered == [{"path": ["env", "TOOLKIT_VALUE"], "value": "1"}] and .env == {}'

H="$(home crafted-ledger)"
inst "$ROOT" "$H"
jq '.permissions.allow = ["Bash(npm test)"] | .sandbox = {"enabled": true}' "$H/.claude/settings.json" >"$TMP/s" && cp "$TMP/s" "$H/.claude/settings.json"
jq '.values += [{"path": ["sandbox"], "value": {"enabled": true}}] | .members += [{"path": ["permissions", "allow"], "value": "Bash(npm test)"}]' \
  "$H/.claude/agent-toolkit-applied.json" >"$TMP/ledger" && cp "$TMP/ledger" "$H/.claude/agent-toolkit-applied.json"
inst "$ROOT" "$H"
check "a ledger naming a value the toolkit never sets cannot remove it" '["Bash(npm test)"] true' \
  "$(js "$H" '(.permissions.allow | tostring) + " " + (.sandbox.enabled | tostring)')"

H="$(home dubious-git)"
GITROOT="$TMP/git-root"
copy_root "$GITROOT"
git -C "$GITROOT" init -q && git -C "$GITROOT" add -A && git -C "$GITROOT" commit -q -m toolkit
inst "$GITROOT" "$H"
stamp="$(cat "$H/.claude/agent-toolkit-version")"
mkdir -p "$TMP/dubious"
printf '#!/bin/sh\ncase "$*" in *--show-toplevel*) echo "fatal: detected dubious ownership in repository" >&2; exit 128 ;; esac\nexec %s "$@"\n' \
  "$(command -v git)" >"$TMP/dubious/git"
chmod +x "$TMP/dubious/git"
out="$(HOME="$H" PATH="$TMP/dubious:$PATH" "$GITROOT/install.sh" 2>&1)"
rc=$?
[ -n "$stamp" ] && same "a checkout git refuses to read keeps its stamp" "$stamp" "$(cat "$H/.claude/agent-toolkit-version" 2>/dev/null)" \
  || bad "a checkout git refuses to read keeps its stamp" "the checkout was never stamped"
check "and says why" "git cannot read the version directory's history, so the version stamp was left as it was: fatal: detected dubious ownership" "$out"
exit_is "as an advisory" 0

H="$(home since-bytes)"
inst "$ROOT" "$H"
printf '\377\376\n' >"$H/.claude/retro/since"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
json_is "a retro marker that will not decode is reported with who acts and the recorder's reason" \
  '.hookSpecificOutput.additionalContext | test("! the retro recorder is not recording. Fix \\(user\\): retro/since cannot be read")'

H="$(home list-fails)"
: >"$CLAUDE_CALLS"
out="$(HOME="$H" CLAUDE_STUB_FAIL=list "$ROOT/install.sh" 2>&1)"
check "a plugin listing that does not answer is a finding" "claude plugin marketplace list --json did not answer" "$out"
check "carrying what Claude Code said about it" "could not be checked: the stub would not list marketplaces" "$out"
grep -q '|plugin marketplace add' "$CLAUDE_CALLS" && bad "and nothing is fetched on a guess" "$(cat "$CLAUDE_CALLS")" || ok "and nothing is fetched on a guess"
H="$(home plugin-list-fails)"
out="$(HOME="$H" CLAUDE_STUB_FAIL=pluginlist "$ROOT/install.sh" 2>&1)"
[ "$(grep -c 'claude plugin list --json did not answer' <<<"$out")" -eq 1 ] \
  && ok "a listing asked for twice in a run is reported once" || bad "a failed listing is reported once" "$out"

H="$(home claude-crashes)"
out="$(HOME="$H" CLAUDE_STUB_FAIL=version "$ROOT/install.sh" 2>&1)"
check "a claude whose --version fails is not called outdated" "claude --version failed" "$out"

H="$(home dry-secrets)"
python3 -c 'import json, sys
hooks = [{"hooks": [{"type": "command", "command": "~/.claude/agent-toolkit/hooks/old%d.sh" % i}]} for i in range(60)]
print(json.dumps({"env": {"SECRET_TOKEN": "sk-test-canary-1234"}, "hooks": {"Stop": hooks}}, indent=2))' >"$H/.claude/settings.json"
inst "$ROOT" "$H" --dry-run
[[ "$out" != *sk-test-canary* ]] && ok "a dry run never prints an env value that is not the toolkit's" || bad "a dry run never prints a foreign env value" "printed it"
check "and says it hid it" '"SECRET_TOKEN": "<redacted>"' "$out"
check "and says when the diff is cut" "more lines" "$out"

# A launcher whose own #! line cannot run would leave every hook to fail open.
copy_root "$GATELESS"
sed -i '1s|.*|#!/nonexistent/sh|' "$GATELESS/hooks/launcher.sh"
H="$(home launcher-shebang)"
inst "$GATELESS" "$H"
exit_is "a launcher whose #! line cannot run fails the root checks" 1
check "naming why" "✗ hooks/launcher.sh cannot start: /nonexistent/sh, named on its #! line, is not executable" "$out"

# Half a verdict from a guard that dies never reaches Claude Code ahead of the ask.
printf '#!/bin/sh\nprintf %%s "{\\"hookSpecificOutput\\":"\nkill -9 $$\n' >"$TMP/unstartable/hooks/dies.sh"
chmod +x "$TMP/unstartable/hooks/dies.sh"
H="$(home dies-midway)"
ln -s "$TMP/unstartable" "$H/.claude/agent-toolkit"
install -m 755 "$ROOT/hooks/launcher.sh" "$H/.claude/agent-toolkit-run"
hook "$H" '"$HOME/.claude/agent-toolkit-run" PreToolUse hooks/dies.sh' "$(bash_payload 'ls')"
json_is "a guard that dies halfway through its verdict gives exactly one object, which asks" \
  '.hookSpecificOutput.permissionDecision == "ask" and (.hookSpecificOutput.permissionDecisionReason | test("gave no verdict"))'

# Every path the toolkit writes a ledger entry for is one the ledger can retire,
# so a new toolkit value cannot be written and then never removed.
H="$(home retirable)"
inst "$ROOT" "$H"
cat >"$TMP/retirable.py" <<'PY'
import json
import sys

sys.path.insert(0, sys.argv[1])
from lib.settings import RETIRABLE_MEMBERS, retirable

ledger = json.load(open(sys.argv[2]))
stuck = [e["path"] for e in ledger["values"] if not retirable(tuple(e["path"]))]
stuck += [e["path"] for e in ledger["members"] if tuple(e["path"]) not in RETIRABLE_MEMBERS]
print(json.dumps(stuck) if ledger["values"] and ledger["members"] else "empty ledger")
PY
check "every value a fresh install ledgers is one a later install can retire" "[]" \
  "$(python3 "$TMP/retirable.py" "$ROOT/hooks" "$H/.claude/agent-toolkit-applied.json")"

# A file that will not read is not the same answer as no version: a stamp that
# is right must not be removed on the strength of it. Either half can be the one
# that failed, and the finding names whichever it was.
if [ "$(id -u)" -ne 0 ]; then
  H="$(home version-unreadable)"
  UNREADABLE_VERSION="$TMP/unreadable-version-root"
  copy_root "$UNREADABLE_VERSION"
  printf '9.0.0\n' >"$UNREADABLE_VERSION/VERSION"
  printf 'abc1234\n' >"$UNREADABLE_VERSION/REVISION"
  inst "$UNREADABLE_VERSION" "$H"
  chmod 000 "$UNREADABLE_VERSION/REVISION"
  inst "$UNREADABLE_VERSION" "$H"
  chmod 644 "$UNREADABLE_VERSION/REVISION"
  same "a REVISION that cannot be read keeps the stamp it had" "v9.0.0·abc1234" "$(cat "$H/.claude/agent-toolkit-version" 2>/dev/null)"
  check "and names the half that failed" "the version stamp was left as it was: REVISION cannot be read: Permission denied" "$out"
  exit_is "as an advisory" 0
  chmod 000 "$UNREADABLE_VERSION/VERSION"
  inst "$UNREADABLE_VERSION" "$H"
  chmod 644 "$UNREADABLE_VERSION/VERSION"
  check "and names the other half when that is the one" "the version stamp was left as it was: VERSION cannot be read: Permission denied" "$out"
else
  skip "a version half that cannot be read keeps the stamp" "running as root, which reads anything"
fi

# A session start that gave up on the lock after the link moved still says nothing.
H="$(home queued-timeout)"
inst "$QUEUED_Y" "$H"
ln -sfn "$QUEUED_X" "$H/.claude/agent-toolkit"
lock_holder "$H/.claude"
HOME="$H" "$QUEUED_X/install.sh" --sync <"$TMP/queued.payload" >"$TMP/queued.out" 2>&1 &
queued=$!
sleep 1
ln -sfn "$QUEUED_Y" "$H/.claude/agent-toolkit"
wait "$queued"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
[ ! -s "$TMP/queued.out" ] && ok "a session start that timed out on the lock after the link moved prints nothing" \
  || bad "a session start that timed out after the link moved prints nothing" "$(cat "$TMP/queued.out")"

# ── what install owns, end to end ────────────────────────────────────────────
# A root missing a file install itself runs never goes live.
H="$(home missing-own-files)"
inst "$ROOT" "$H"
before="$(snapshot "$H")"
for missing in hooks/lib/report.sh hooks/lib/requirements.sh; do
  copy_root "$TMP/missing-root"
  rm -f "$TMP/missing-root/$missing"
  inst "$TMP/missing-root" "$H"
  exit_is "a version directory without $missing exits 1" 1
  check "saying which library it cannot start without" "$missing is missing from" "$out"
done
same "and neither of them changes anything either" "$before" "$(snapshot "$H")"
for missing in hooks/launcher.sh hooks/lib/settings.py hooks/lib/version.py hooks/update.sh; do
  copy_root "$TMP/missing-root"
  rm -f "$TMP/missing-root/$missing"
  inst "$TMP/missing-root" "$H"
  exit_is "a version directory without $missing exits 1" 1
  check "naming it under Toolkit" "✗ $missing is missing from the version directory" "$(block Toolkit)"
done
same "and none of them changes anything" "$before" "$(snapshot "$H")"

# The user's own CLAUDE.md is kept before the pointer replaces it.
H="$(home pointer-backup)"
printf 'my rules\n' >"$H/.claude/CLAUDE.md"
inst "$ROOT" "$H"
backups=("$H"/.claude/backups/CLAUDE.md.*)
{ [ "${#backups[@]}" -eq 1 ] && grep -qx 'my rules' "${backups[0]}"; } \
  && ok "the user's own CLAUDE.md is backed up once before the pointer replaces it" || bad "the user's CLAUDE.md is backed up" "${backups[*]}"
check "and the change names the backup" "~/.claude/CLAUDE.md imports ~/.claude/agent-toolkit/CLAUDE.md (backup: ~/.claude/backups/CLAUDE.md." "$out"
H="$(home linked-pointer-backup)"
printf 'dotfile rules\n' >"$TMP/dotfile-claude.md"
ln -s "$TMP/dotfile-claude.md" "$H/.claude/CLAUDE.md"
inst "$ROOT" "$H"
grep -qx 'dotfile rules' "$H"/.claude/backups/CLAUDE.md.* 2>/dev/null && ok "a pointer that was a link is backed up with what it pointed at" \
  || bad "a linked pointer is backed up with its target's content" "$(ls "$H/.claude/backups" 2>&1)"

# A launcher that differs from the version directory's is replaced: by a session
# start when it still runs, and by a full install when it does not.
H="$(home stale-launcher)"
inst "$ROOT" "$H"
printf '# an older launcher\n' >>"$H/.claude/agent-toolkit-run"
inode="$(stat -c %i "$H/.claude/agent-toolkit-run")"
hook "$H" "$(command_for "$H" SessionStart install.sh)" '{"hook_event_name":"SessionStart"}'
cmp -s "$ROOT/hooks/launcher.sh" "$H/.claude/agent-toolkit-run" && [ "$(stat -c %i "$H/.claude/agent-toolkit-run")" != "$inode" ] \
  && ok "a launcher that differs is replaced at session start, by a rename" || bad "a differing launcher is replaced at session start" "unchanged"
printf '#!/bin/sh\nexit 0\n' >"$H/.claude/agent-toolkit-run"
inst "$ROOT" "$H"
cmp -s "$ROOT/hooks/launcher.sh" "$H/.claude/agent-toolkit-run" && [ -x "$H/.claude/agent-toolkit-run" ] \
  && ok "and a launcher that no longer runs anything is replaced by a full install" || bad "a broken launcher is replaced by a full install" "unchanged"

# Every file install writes is replaced by a rename: a hard link to the old file
# keeps the old bytes.
H="$(home renames)"
inst "$EXTRA" "$H"
printf 'v0.9.0·abc1234\n' >"$H/.claude/agent-toolkit-version"
printf '# stale\n' >>"$H/.claude/agent-toolkit-run"
printf 'stale\n' >"$H/.claude/CLAUDE.md"
printf 'stale\n' >"$H/.claude/agents/developer.md"
files=(agent-toolkit-run CLAUDE.md agents/developer.md agent-toolkit-applied.json agent-toolkit-version)
for f in "${files[@]}"; do
  ln "$H/.claude/$f" "$H/.claude/$f.hl"
  cp "$H/.claude/$f" "$TMP/renames.$(basename "$f").old"
done
inst "$VERSIONED" "$H"
in_place=""
for f in "${files[@]}"; do
  cmp -s "$H/.claude/$f.hl" "$TMP/renames.$(basename "$f").old" && ! cmp -s "$H/.claude/$f" "$H/.claude/$f.hl" || in_place="$in_place $f"
done
[ -z "$in_place" ] && ok "the launcher, pointer, agents, ledger and stamp are each replaced by a rename" || bad "every write is a rename" "written in place:$in_place"

H="$(home link-switch-by-rename)"
inst "$ROOT" "$H"
mkdir -p "$TMP/ln-recorder"
printf '#!/bin/sh\necho "$*" >>"%s"\nexec %s "$@"\n' "$TMP/ln.calls" "$(command -v ln)" >"$TMP/ln-recorder/ln"
chmod +x "$TMP/ln-recorder/ln"
rm -f "$TMP/ln.calls"
out="$(HOME="$H" PATH="$TMP/ln-recorder:$PATH" "$OTHER/install.sh" 2>&1)"
{ ! grep -qE " $H/.claude/agent-toolkit\$" "$TMP/ln.calls" && grep -qE " $H/.claude/.agent-toolkit\.[0-9]+\.link\$" "$TMP/ln.calls"; } \
  && ok "a full install creates the new stable link beside the old one and renames it into place" || bad "the stable link is switched by a rename" "$(cat "$TMP/ln.calls")"

# ── reports ──────────────────────────────────────────────────────────────────
H="$(home report-order)"
mkdir -p "$H/.claude/skills/toolkit"
out="$(HOME="$H" SSH_AUTH_SOCK= "$ROOT/install.sh" --dry-run 2>&1)"
line_of() { grep -nF -m1 -- "$1" <<<"$out" | cut -d: -f1; }
order="$(line_of 'Would change') $(line_of 'Needs you') $(line_of '  ✗ skill toolkit') $(line_of '  ! no ssh-agent') $(line_of 'Run install again') $(line_of 'Restart Claude Code:')"
[ "$(tr ' ' '\n' <<<"$order" | sort -n | paste -sd' ')" = "$order" ] && [ "$(wc -w <<<"$order")" -eq 6 ] \
  && [[ "$(tail -1 <<<"$out")" =~ ^✗\ [0-9]+\ required\ findings?,\ [0-9]+\ advisory$ ]] \
  && ok "a report runs changes, Needs you with required before advisory, Run install again, the restart line, then the result last" \
  || bad "the report keeps its order" "$out"
BROKEN_ORDER="$TMP/broken-order-root"
copy_root "$BROKEN_ORDER"
chmod -x "$BROKEN_ORDER/hooks/sync.sh"
out="$(HOME="$H" SSH_AUTH_SOCK= "$BROKEN_ORDER/install.sh" --dry-run 2>&1)"
[ "$(line_of 'Needs you')" -lt "$(line_of 'Toolkit')" ] && ok "and Toolkit comes after Needs you" || bad "Toolkit comes after Needs you" "$out"

H="$(home plugin-disabled)"
inst "$ROOT" "$H"
state="$STUB_STATE/$(printf '%s' "$H" | cksum | cut -d' ' -f1)"
sed -i 's/^pr-review-toolkit@claude-plugins-official on$/pr-review-toolkit@claude-plugins-official off/' "$state/plugins"
inst "$ROOT" "$H" --dry-run
[[ "$out" != *"not enabled"* ]] && ok "a dry run does not report a plugin a full install would enable" || bad "a dry run does not report a disabled plugin" "$out"
inst "$ROOT" "$H"
exit_is "a plugin that stays disabled after a full install exits 1" 1
check "for install to fix" "$(printf 'Run install again\n  ✗ plugin pr-review-toolkit@claude-plugins-official is installed but not enabled')" "$out"

# ── boundaries ───────────────────────────────────────────────────────────────
# Nothing leaves the machine but the plugin fetches, and nothing is written
# outside ~/.claude.
H="$(home boundaries)"
mkdir -p "$H/.config/other-tool" "$H/projects"
printf 'keep\n' >"$H/.config/other-tool/settings"
outside() { find "$1" -path "$1/.claude" -prune -o -printf '%P|%y|%m|%s|%T@\n' | sort | sha256sum; }
before="$(outside "$H")"
mkdir -p "$TMP/git-recorder"
printf '#!/bin/sh\necho "$*" >>"%s"\nexec %s "$@"\n' "$TMP/git.calls" "$(command -v git)" >"$TMP/git-recorder/git"
chmod +x "$TMP/git-recorder/git"
rm -f "$NET_CALLS" "$TMP/git.calls"
for mode in "" --dry-run --sync; do
  HOME="$H" PATH="$TMP/git-recorder:$PATH" "$ROOT/install.sh" $mode </dev/null >/dev/null 2>&1
done
same "install, a dry run and a session start write nothing outside ~/.claude" "$before" "$(outside "$H")"
same "and ask gh for nothing but a local token, calling neither curl nor wget" \
  "$(printf 'gh auth token --hostname github.com\n%.0s' 1 2)" "$(cat "$NET_CALLS")"
other_git="$(grep -vE '^(-C [^ ]+ )?(rev-parse|rev-list|config --get) ' "$TMP/git.calls")"
[ -z "$other_git" ] && ok "and run git only to read a version or an identity" || bad "and run git only to read" "$other_git"

# A backups directory holding a dangling entry still gives the real reason.
H="$(home dangling-backup)"
printf '{}\n' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
ln -s "$TMP/nowhere" "$H/.claude/backups/settings.json.zzzz"
printf '{"env": "not an object"}\n' >"$H/.claude/settings.json"
inst "$ROOT" "$H"
check "a dangling backup entry does not hide why settings.json was left untouched" "settings.json was left untouched: env is not an object" "$out"
[[ "$out" != *"settings.py failed"* ]] && ok "and blames nothing on the toolkit" || bad "and blames nothing on the toolkit" "$out"

H="$(home infinite)"
printf '{"cleanupPeriodDays": 1e999}\n' >"$H/.claude/settings.json"
id_before="$(file_id "$H/.claude/settings.json")"
inst "$ROOT" "$H"
check "a number JSON cannot carry gives its reason" \
  "holds a value JSON cannot carry: Out of range float values are not JSON compliant: inf" "$out"
same "and the file is left untouched" "$id_before" "$(file_id "$H/.claude/settings.json")"

H="$(home claude-is-a-file)"
rm -rf "$H/.claude"
printf 'not a directory\n' >"$H/.claude"
inst "$ROOT" "$H"
exit_is "a file at ~/.claude exits 1" 1
check "with a fix that moves it out of the way" "$(printf '✗ ~/.claude is not a directory, so nothing was changed\n    mv ~/.claude ~/.claude.not-a-directory')" "$out"
