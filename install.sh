#!/usr/bin/env bash
# Install the toolkit from the version directory this file sits in, and keep the
# machine in step with it.
#
# Contract: documentation/specs/install.md.
set -uo pipefail
# Hooks run in the session's project directory, and python puts the working
# directory first on its import path: a project's own ast.py would run here.
export PYTHONDONTWRITEBYTECODE=1 PYTHONSAFEPATH=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLAUDE_DIR="$HOME/.claude"
STABLE="$CLAUDE_DIR/agent-toolkit"
LAUNCHER="$CLAUDE_DIR/agent-toolkit-run"
SETTINGS="$CLAUDE_DIR/settings.json"
LEDGER="$CLAUDE_DIR/agent-toolkit-applied.json"
POINTER="$CLAUDE_DIR/CLAUDE.md"
STAMP="$CLAUDE_DIR/agent-toolkit-version"
BACKUPS="$CLAUDE_DIR/backups"
SKILLS_DST="$CLAUDE_DIR/skills"
AGENTS_DST="$CLAUDE_DIR/agents"
MANIFEST="$AGENTS_DST/.toolkit-agents"
SCRATCH="/tmp/claude-$(id -u)"

# The lowest release with every CLI and hook surface used here: plugin install
# --json arrived in 2.1.268, after everything else.
MIN_CLAUDE=2.1.268

# id and the GitHub source its marketplace is registered from.
PLUGINS=(
  "pr-review-toolkit@claude-plugins-official anthropics/claude-plugins-official"
  "claude-notifications-go@claude-notifications-go 777genius/agent-notifications"
)

# Every hook the toolkit wires, relative to the version directory. Each becomes a
# launcher command; matcher "" writes the group with no matcher.
#
# Notification events (Notification, Stop) are deliberately absent: the
# claude-notifications-go plugin owns them.
#
# taskline must stay synchronous: only a hook that finishes before the turn does
# has its stdout injected as context.
#
# The retro recorder is the mirror image: async on every event, so it can neither
# block a turn nor inject its stdout.
WIRING='[
  {"event":"SessionStart","matcher":"startup|resume|clear",
   "hooks":[{"entry":"install.sh --sync"}]},
  {"event":"SessionStart","matcher":"",
   "hooks":[{"entry":"hooks/retro.py record","async":true}]},
  {"event":"PreCompact","matcher":"",
   "hooks":[{"entry":"hooks/retro.py record","async":true}]},
  {"event":"UserPromptSubmit","matcher":"",
   "hooks":[{"entry":"hooks/taskline.py"},
            {"entry":"hooks/retro.py record --interval 900","async":true}]},
  {"event":"PreToolUse","matcher":"Bash",
   "hooks":[{"entry":"hooks/guard.sh"}]},
  {"event":"PreToolUse","matcher":"mcp__linear.*",
   "hooks":[{"entry":"hooks/guard.sh"}]},
  {"event":"PostToolUse","matcher":"Write|Edit",
   "hooks":[{"entry":"hooks/sync.sh"},
            {"entry":"hooks/format.sh","async":true}]},
  {"event":"SessionEnd","matcher":"",
   "hooks":[{"entry":"hooks/reap.sh"},
            {"entry":"hooks/retro.py record","async":true}]}
]'
STATUSLINE_ENTRY="hooks/statusline.py"

# The toolkit-owned settings, shaped like settings.json. The launcher path is
# written with a literal $HOME inside double quotes, which the shell Claude Code
# runs each command in expands to one word whatever the home path holds.
read -r -d '' DESIRED <<'JQ'
def run($caller; $entry): "\"$HOME/.claude/agent-toolkit-run\" \($caller) \($entry)";
{
  env: {
    # Depth 2 lets a subagent spawn one layer of its own: the developer and
    # reviewer need it to run their review agents.
    CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH: "2",
    # The task tools are removed by default for this generation of models, and
    # the task list this toolkit runs on cannot exist without them.
    CLAUDE_CODE_ENABLE_TODO_TOOLS: "1"
  },
  # Sessions on this machine work on different projects, and cross-session
  # messaging is on by default. Both settings govern the peer socket only, so an
  # agent still messages main over SendMessage.
  crossSessionInbound: "refuse",
  isolatePeerMachines: true,
  permissions: {
    # Safe because the guard hook fires in every permission mode.
    defaultMode: "auto",
    # A path inside one is approved before any rule is consulted, which is what
    # stops a background agent stalling on a prompt.
    additionalDirectories: [$claude_dir, $scratch, $root],
    # ~/.claude is approved wholesale above, and these files carry tokens. A
    # deny governs the Read tool only, so jq and python still reach settings.
    deny: [
      "Read(~/.claude/.credentials.json)",
      "Read(~/.claude/settings*.json)",
      "Read(~/.claude/backups/settings.json.*)",
      "Read(~/.claude/backups/.claude.json.backup.*)"
    ]
  },
  includeCoAuthoredBy: false,
  enabledPlugins: ($plugins | map({key: ., value: true}) | from_entries),
  statusLine: {type: "command", command: run("statusline"; $statusline), padding: 0},
  hooks: (reduce $wiring[] as $w ({};
    .[$w.event] += [
      (if $w.matcher == "" then {} else {matcher: $w.matcher} end)
      + {hooks: [$w.hooks[] | {type: "command",
                               command: run(if .async then "async" else $w.event end; .entry)}
                             + (if .async then {async: true} else {} end)]}]))
}
JQ

# Agent teams spawn whole parallel sessions, a different model from one session
# delegating to subagents. Kept unset rather than merely not written.
ABSENT='[["env","CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"]]'

pointer_content() {
  cat <<'EOF'
# Global instructions

Everything lives in the portable agent-toolkit repo. This file is only this device's pointer to it. New rules go into the toolkit, never here.

@~/.claude/agent-toolkit/CLAUDE.md
EOF
}

usage() {
  cat <<'EOF'
usage: install.sh [--dry-run | --sync | --help]

  (none)     install from this directory: link it, apply settings, fetch plugins
  --dry-run  print every change a full install would make, and write nothing
  --sync     apply local state and print a hook report; used by Claude Code hooks
  --help     this text

exit: 0 no required finding remains, 1 one does, 2 bad arguments.
--dry-run exits 1 when a full install could not go green on its own.
EOF
}

# ── findings and changes ─────────────────────────────────────────────────────
F_SEV=() F_WHO=() F_TEXT=() F_FIX=()
CHANGES=()   # what changed, or in a dry run what would
WROTE=()     # settings and pointer writes, which a hook report names
RESTART=()   # what changed that Claude Code reads only at start
SKILLS_CHANGED=0

finding() { # severity (required|advisory), who (user|install|toolkit), text, fix lines
  F_SEV+=("$1") F_WHO+=("$2") F_TEXT+=("$3") F_FIX+=("${4:-}")
}

count() { # severity
  local n=0 s
  for s in "${F_SEV[@]}"; do [ "$s" = "$1" ] && n=$((n + 1)); done
  echo "$n"
}

have() { command -v "$1" >/dev/null 2>&1; }

one_line() { tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-400; }

join() { # separator, items
  local sep="$1" out="" item
  shift
  for item in "$@"; do out+="${out:+$sep}$item"; done
  printf '%s' "$out"
}

restart_reasons() {
  local reasons
  mapfile -t reasons < <(printf '%s\n' "${RESTART[@]}" | LC_ALL=C sort -u)
  join ", " "${reasons[@]}"
}

shq() {
  case "$1" in
    "" | *[!A-Za-z0-9_./+:@%=-]*) printf "'%s'" "${1//\'/\'\\\'\'}" ;;
    *) printf '%s' "$1" ;;
  esac
}
home_path() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "$(shq "${1#"$HOME"/}")" ;;
    *) shq "$1" ;;
  esac
}

install_command() {
  if [ "$MODE" = sync ]; then echo "~/.claude/agent-toolkit/install.sh"; else echo "$(home_path "$ROOT")/install.sh"; fi
}

# A write, or in a dry run only its description. A failed write is a finding
# naming what did not apply. -q keeps a successful write out of the change list.
act() { # [-q] description, command...
  local quiet=0 what err
  [ "$1" = -q ] && quiet=1 && shift
  what="$1"
  shift
  if [ "$MODE" = dry ] || err="$("$@" 2>&1)"; then
    [ "$quiet" -eq 1 ] || CHANGES+=("$what")
    return 0
  fi
  finding required install "did not apply: $what: $(printf '%s' "$err" | one_line)" "$(install_command)"
  return 1
}

write_atomic() { # path, mode; the content on stdin
  local tmp
  mkdir -p "$(dirname "$1")" && tmp="$(mktemp "$(dirname "$1")/.$(basename "$1").XXXXXX")" || return 1
  if cat >"$tmp" && chmod "$2" "$tmp" && mv -T "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# ln -s over an existing link is unlink then symlink, which leaves a moment with
# no link at all. A rename is one step.
link_atomic() { # target, path
  local tmp
  tmp="$(dirname "$2")/.$(basename "$2").$$.link"
  rm -f "$tmp"
  if ln -sT "$1" "$tmp" && mv -T "$tmp" "$2"; then return 0; fi
  rm -f "$tmp"
  return 1
}

backup_name() { # path inside backups, without the timestamp
  local base p n=1
  base="$1.$(date +%Y%m%d-%H%M%S)"
  p="$base"
  while [ -e "$p" ]; do
    p="$base.$n"
    n=$((n + 1))
  done
  echo "$p"
}

backup_to() { # source, backup path
  mkdir -p "$(dirname "$2")" && (set -o noclobber && cat "$1" >"$2")
}

# ── requirements ─────────────────────────────────────────────────────────────
package_manager() {
  local m
  for m in apt-get dnf pacman; do have "$m" && { echo "$m"; return; }; done
}

package_name() { # manager, requirement
  case "$1:$2" in
    pacman:python3 | pacman:sqlite3) echo python ;;
    pacman:gh) echo github-cli ;;
    apt-get:sqlite3) echo libpython3-stdlib ;;
    dnf:sqlite3) echo python3-libs ;;
    dnf:setsid) echo util-linux-core ;;
    *:setsid) echo util-linux ;;
    *) echo "$2" ;;
  esac
}

package_line() { # requirements
  local manager names=() r n
  manager="$(package_manager)"
  for r in "$@"; do
    n="$(package_name "$manager" "$r")"
    [[ " ${names[*]} " == *" $n "* ]] || names+=("$n")
  done
  case "$manager" in
    apt-get) echo "sudo apt-get install -y ${names[*]}" ;;
    dnf) echo "sudo dnf install -y ${names[*]}" ;;
    pacman) echo "sudo pacman -S --needed ${names[*]}" ;;
    *) echo "install these packages with your package manager: ${names[*]}" ;;
  esac
}

GH_LOGIN="gh auth login --hostname github.com --git-protocol ssh --web"

# Returns 1 when jq or python3 is missing.
check_tools() {
  local missing=() stop=() rest=() t line
  for t in jq python3 git setsid gh; do have "$t" || missing+=("$t"); done
  have python3 && ! python3 -c 'import sqlite3' >/dev/null 2>&1 && missing+=(sqlite3)
  [ ${#missing[@]} -gt 0 ] || return 0
  line="$(package_line "${missing[@]}")"
  for t in "${missing[@]}"; do
    case "$t" in
      jq | python3) stop+=("$t") ;;
      git | setsid) rest+=("$t") ;;
    esac
  done
  [ ${#stop[@]} -eq 0 ] || finding required user "not on PATH: ${stop[*]}. Nothing can be merged or verified without it, so nothing was changed" "$line"
  [ ${#rest[@]} -eq 0 ] || finding required user "not on PATH: ${rest[*]}" "$line"
  [[ " ${missing[*]} " != *" sqlite3 "* ]] || finding advisory user "python3 cannot import sqlite3, so the retro recorder stores nothing" "$line"
  [[ " ${missing[*]} " != *" gh "* ]] || finding advisory user "gh is not on PATH, so PR and release flows fail" "$line"$'\n'"$GH_LOGIN"
  [ ${#stop[@]} -eq 0 ]
}

version_at_least() { # version, minimum
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# Local reads only, so no timeout.
claude_cli() { (cd "$HOME" && claude "$@" </dev/null 2>/dev/null); }

check_claude() {
  local version
  if ! have claude; then
    finding required user "claude is not on PATH, so the plugins are not installed" "curl -fsSL https://claude.ai/install.sh | bash"
    return 1
  fi
  if ! version="$(claude_cli --version)"; then
    finding required user "claude --version failed, so the plugins are not installed" "curl -fsSL https://claude.ai/install.sh | bash"
    return 1
  fi
  version="$(awk '{print $1; exit}' <<<"$version")"
  if ! version_at_least "$version" "$MIN_CLAUDE"; then
    finding required user "claude ${version:-of an unknown version} is older than $MIN_CLAUDE, so the plugins are not installed" "claude update"
    return 1
  fi
}

check_access() {
  # Bounded, because the token can sit behind a keyring that waits to be unlocked.
  if have gh && ! timeout 10 gh auth token --hostname github.com >/dev/null 2>&1; then
    finding advisory user "gh holds no token for github.com, so PR and release flows fail" "$GH_LOGIN"
  fi
  # A local probe of the agent this shell sees. Never a connection to GitHub.
  if [ -z "${SSH_AUTH_SOCK:-}" ] || ! have ssh-add || ! ssh-add -l >/dev/null 2>&1; then
    finding advisory user "no ssh-agent holding a key is reachable from this shell, so git over SSH from Claude Code fails, an approved push included" \
      'eval "$(ssh-agent -s)" && ssh-add && claude'
  fi
  if have git; then
    git_identity user.name || finding advisory user "git user.name is not set, so commits fail" 'git config --global user.name "<your name>"'
    git_identity user.email || finding advisory user "git user.email is not set, so commits fail" 'git config --global user.email "<your email>"'
  fi
}

# Read from outside any repository, so only what applies to every commit counts.
git_identity() { (cd / && env -u GIT_DIR -u GIT_WORK_TREE git config --get "$1") >/dev/null 2>&1; }

# The recorder degrades to silence by design, so silence is not evidence that it
# works. retro.py owns where the store lives and what a marker looks like, and a
# second copy of either here would drift from it.
check_retro() {
  local out problem
  if ! out="$(python3 - "$ROOT/hooks" 2>&1 <<'PY'
import os
import sys

sys.path.insert(0, sys.argv[1])
source = open(os.path.join(sys.argv[1], "retro.py")).read()
recorder = {}
exec(compile(source.replace('if __name__ == "__main__":', "if False:"), "retro", "exec"), recorder)

try:
    with open(recorder["SINCE_PATH"]) as f:
        raw = f.read(64).strip()
except FileNotFoundError:
    print("retro/since is missing, so nothing will be recorded until it is stamped")
except (OSError, ValueError) as e:
    print("retro/since cannot be read (%s), so nothing is being recorded" % e)
else:
    if recorder["parse_iso"](raw) is None:
        print("retro/since is not a timestamp (%r), so nothing is being recorded" % raw[:32])

if os.path.exists(recorder["DB_PATH"]):
    problem = recorder["store_problem"]()
    if recorder["open_store"](create=False) is None:
        print(problem)
PY
  )"; then
    finding advisory toolkit "the retro recorder check did not run" "$ROOT/hooks/retro.py"$'\n'"$(printf '%s' "$out" | tail -1)"
    return
  fi
  while IFS= read -r problem; do
    [ -n "$problem" ] || continue
    # A dry run already lists the marker it would stamp.
    case "$MODE:$problem" in dry:*"since is missing"*) continue ;; esac
    finding advisory user "the retro recorder is not recording" "$problem"
  done <<<"$out"
}

# ── the version directory ────────────────────────────────────────────────────
wiring_entries() {
  jq -r --arg statusline "$STATUSLINE_ENTRY" \
    '[.[].hooks[].entry | split(" ")[0]] + ["install.sh", $statusline] | unique[]' <<<"$WIRING"
}

# A script whose #! line cannot run exits 127 before doing anything, which
# Claude Code treats as a hook that let the call through.
cannot_start() { # path → the reason on stdout, or nothing
  local first prog arg
  IFS= read -r first <"$1" || true
  case "$first" in
    "#!"*) ;;
    *) echo "it has no #! line" && return ;;
  esac
  [[ "$first" != *$'\r'* ]] || { echo "its #! line ends in a carriage return" && return; }
  read -r prog arg _ <<<"${first#\#!}"
  if [ "$prog" = /usr/bin/env ]; then
    have "$arg" || echo "$arg, named on its #! line, is not on PATH"
  else
    [ -x "$prog" ] || echo "$prog, named on its #! line, is not executable"
  fi
}

# Runs a script the way exec would, through its #! line, without needing it to
# be executable.
via_shebang() { # path, arguments
  local first words
  IFS= read -r first <"$1"
  read -ra words <<<"${first#\#!}"
  "${words[@]}" "$@"
}

# Root checks: install writes nothing derived from this directory unless they pass.
check_root() {
  local before=${#F_SEV[@]} entries entry reason out detail
  if ! entries="$(wiring_entries)"; then
    finding required toolkit "install.sh cannot read its own wiring" "$ROOT/install.sh"
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ ! -f "$ROOT/$entry" ]; then
      finding required toolkit "$entry is missing from the version directory" "$ROOT/$entry"
    elif [ ! -x "$ROOT/$entry" ]; then
      finding required toolkit "$entry is not executable" "$ROOT/$entry"
    elif reason="$(cannot_start "$ROOT/$entry")" && [ -n "$reason" ]; then
      finding required toolkit "$entry cannot start: $reason" "$ROOT/$entry"
    fi
  done <<<"$entries"
  for entry in hooks/launcher.sh hooks/lib/settings.py hooks/lib/version.py; do
    [ -f "$ROOT/$entry" ] || finding required toolkit "$entry is missing from the version directory" "$ROOT/$entry"
  done
  # A partly unpacked directory would otherwise retire every skill and agent.
  [ -n "$(find "$ROOT/skills" -name SKILL.md -print -quit 2>/dev/null)" ] \
    || finding required toolkit "skills/ holds no skill" "$ROOT/skills"
  compgen -G "$ROOT/agents/*.md" >/dev/null || finding required toolkit "agents/ holds no agent" "$ROOT/agents"
  check_gate
  if ! out="$(python_problems 2>&1)"; then
    finding required toolkit "the python checks did not run: $(printf '%s' "$out" | tail -1)" "$ROOT/install.sh"
  fi
  while IFS=$'\t' read -r entry reason detail; do
    [ -n "$detail" ] && finding required toolkit "$reason: $entry" "$ROOT/$entry"$'\n'"$detail"
  done <<<"$out"
  [ ${#F_SEV[@]} -eq "$before" ]
}

# The approval gate, run before it goes live: the launcher must ask when the
# toolkit is unreachable, and the guard must ask before a push. HOME points
# nowhere, so neither can find or write anything.
check_gate() {
  local ask='"permissionDecision":"ask"' payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' reason
  if [ -f "$ROOT/hooks/launcher.sh" ]; then
    reason="$(cannot_start "$ROOT/hooks/launcher.sh")"
    if [ -n "$reason" ]; then
      finding required toolkit "hooks/launcher.sh cannot start: $reason" "$ROOT/hooks/launcher.sh"
    elif [[ "$(HOME=/nonexistent/agent-toolkit via_shebang "$ROOT/hooks/launcher.sh" PreToolUse hooks/guard.sh </dev/null 2>/dev/null)" != *"$ask"* ]]; then
      finding required toolkit "hooks/launcher.sh does not ask when the toolkit is unreachable" "$ROOT/hooks/launcher.sh"
    fi
  fi
  if [ -x "$ROOT/hooks/guard.sh" ] && [[ "$(HOME=/nonexistent/agent-toolkit "$ROOT/hooks/guard.sh" <<<"$payload" 2>/dev/null)" != *"$ask"* ]]; then
    finding required toolkit "hooks/guard.sh does not ask before a push" "$ROOT/hooks/guard.sh"
  fi
}

# Compiled in memory and imported with bytecode off, so the check writes nothing
# into the root.
python_problems() {
  python3 - "$ROOT" <<'PY'
import ast
import importlib
import os
import sys
import traceback

root = sys.argv[1]
hooks = os.path.join(root, "hooks")
wanted = set()


def last_line(error):
    return traceback.format_exception_only(type(error), error)[-1].strip()


def report(path, problem, error):
    detail = last_line(error).replace("\t", " ").replace("\n", " ")
    print("%s\t%s\t%s" % (os.path.relpath(path, root), problem, detail))


for folder in (hooks, os.path.join(hooks, "lib")):
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".py"):
            continue
        path = os.path.join(folder, name)
        if folder != hooks and not name.startswith("__"):
            wanted.add("lib." + name[:-3])
        try:
            with open(path, "rb") as f:
                tree = compile(f.read(), path, "exec", ast.PyCF_ONLY_AST)
            compile(tree, path, "exec")
        except Exception as error:
            report(path, "a python hook does not compile", error)
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and (node.module or "").startswith("lib"):
                wanted.add(node.module)
            elif isinstance(node, ast.Import):
                wanted |= {a.name for a in node.names if a.name.startswith("lib.")}

sys.path.insert(0, hooks)
for module in sorted(wanted - {"lib"}):
    try:
        importlib.import_module(module)
    except Exception as error:
        report(os.path.join(hooks, *module.split(".")) + ".py", "hooks/lib does not import", error)
PY
}

# ~/.claude/agent-toolkit must stay a link, free to point at any version
# directory. Returns 1 when it is not, and nothing may be written.
check_layout() {
  [ -e "$STABLE" ] && [ ! -L "$STABLE" ] || return 0
  finding required user "~/.claude/agent-toolkit is a real directory, not a link, so nothing was changed" \
    "mkdir -p ~/Documents/git-repo && mv -T ~/.claude/agent-toolkit ~/Documents/git-repo/agent-toolkit-v2 && ~/Documents/git-repo/agent-toolkit-v2/install.sh"
  return 1
}

resolve() { (cd "$1" 2>/dev/null && pwd -P) || readlink "$1" 2>/dev/null || true; }

# ── applying ─────────────────────────────────────────────────────────────────
# Held on ~/.claude itself, so serialising applies writes no file of its own.
# The lock belongs to fd 9, which outlives the python that took it. Returns 1
# when another apply held it past the deadline, 2 with LOCK_ERROR otherwise.
take_lock() { # seconds
  LOCK_FIX=""
  if ! { exec 9<"$CLAUDE_DIR"; } 2>/dev/null; then
    LOCK_ERROR="~/.claude cannot be opened" LOCK_FIX="chmod u+rwx ~/.claude"
    return 2
  fi
  LOCK_ERROR="$(python3 - "$1" 2>&1 <<'PY'
import fcntl
import sys
import time

deadline = time.monotonic() + float(sys.argv[1])
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        if time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.05)
    except OSError as e:
        print(e.strerror or e)
        sys.exit(2)
PY
  )"
}

apply_link() {
  [ "$MODE" != sync ] && [ "$PREV_ROOT" != "$ROOT" ] || return 0
  act "~/.claude/agent-toolkit → $ROOT${PREV_ROOT:+ (was $PREV_ROOT)}" link_atomic "$ROOT" "$STABLE"
}

apply_launcher() {
  cmp -s "$ROOT/hooks/launcher.sh" "$LAUNCHER" && [ -x "$LAUNCHER" ] && return 0
  act "launcher ~/.claude/agent-toolkit-run" write_atomic "$LAUNCHER" 755 <"$ROOT/hooks/launcher.sh"
}

# Anything else at a skill's name is the user's.
toolkit_link() {
  case "$1" in
    "$ROOT"/skills/* | "$STABLE"/skills/*) return 0 ;;
    "$PREV_ROOT"/skills/*) [ -n "$PREV_ROOT" ] ;;
    *) return 1 ;;
  esac
}

apply_skills() {
  local f dir name dst target
  declare -A linked=()
  if [ ! -d "$SKILLS_DST" ]; then
    act "create ~/.claude/skills" mkdir -p "$SKILLS_DST" && RESTART+=("~/.claude/skills was created")
  fi
  while IFS= read -r -d '' f; do
    dir="$(dirname "$f")" name="$(basename "$(dirname "$f")")" dst="$SKILLS_DST/$name"
    linked[$name]=1
    if [ -L "$dst" ]; then
      target="$(readlink "$dst")"
      [ "$target" = "$dir" ] && continue
      if [ -e "$dst" ] && ! toolkit_link "$target"; then
        skill_held "$name"
        continue
      fi
    elif [ -e "$dst" ]; then
      skill_held "$name"
      continue
    fi
    act "link skill $name" link_atomic "$dir" "$dst" && SKILLS_CHANGED=1
  done < <(find "$ROOT/skills" -name SKILL.md -print0 2>/dev/null | sort -z)

  for dst in "$SKILLS_DST"/*; do
    [ -L "$dst" ] && [ -z "${linked[$(basename "$dst")]:-}" ] || continue
    target="$(readlink "$dst")"
    if [ ! -e "$dst" ]; then
      act "unlink dangling skill $(basename "$dst")" rm -f "$dst" && SKILLS_CHANGED=1
    elif [ -n "$PREV_ROOT" ] && [ "$PREV_ROOT" != "$ROOT" ] && [[ "$target" == "$PREV_ROOT"/skills/* ]]; then
      act "unlink skill $(basename "$dst") of the replaced version directory" rm -f "$dst" && SKILLS_CHANGED=1
    fi
  done
}

skill_held() { # name
  local saved
  saved="$(home_path "$(backup_name "$BACKUPS/skills/$1")")"
  finding required user "skill $1 is not installed: ~/.claude/skills/$1 is not the toolkit's, and was left untouched" \
    "mkdir -p ~/.claude/backups/skills && mv -T ~/.claude/skills/$(shq "$1") $saved"
}

# Copied rather than linked, because the agents file watcher does not reliably
# follow symlinks. The manifest names what the toolkit owns, so a retired agent
# is removed without touching agents the user wrote.
apply_agents() {
  local a n names=() owned=() saved
  for a in "$ROOT"/agents/*.md; do [ -f "$a" ] && names+=("$(basename "$a")"); done
  if [ ! -d "$AGENTS_DST" ]; then
    act "create ~/.claude/agents" mkdir -p "$AGENTS_DST" && RESTART+=("~/.claude/agents was created")
  fi
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r n; do
      case "$n" in "" | */* | .*) continue ;; esac
      [ ! -f "$ROOT/agents/$n" ] && [ -e "$AGENTS_DST/$n" ] && act "remove retired agent $n" rm -f "$AGENTS_DST/$n"
    done <"$MANIFEST"
  fi
  for n in "${names[@]}"; do
    cmp -s "$ROOT/agents/$n" "$AGENTS_DST/$n" && continue
    if [ -e "$AGENTS_DST/$n" ] && ! grep -qxF "$n" "$MANIFEST" 2>/dev/null; then
      saved="$(backup_name "$BACKUPS/agents/$n")"
      act "back up your agents/$n to $(home_path "$saved")" backup_to "$AGENTS_DST/$n" "$saved" || continue
    fi
    act "copy agent $n" write_atomic "$AGENTS_DST/$n" 644 <"$ROOT/agents/$n"
  done
  # A name is the toolkit's once its copy landed, so a file whose backup failed
  # stays the user's and is backed up on the next run.
  for n in "${names[@]}"; do
    if cmp -s "$ROOT/agents/$n" "$AGENTS_DST/$n" || grep -qxF "$n" "$MANIFEST" 2>/dev/null; then owned+=("$n"); fi
  done
  printf '%s\n' "${owned[@]}" | cmp -s - "$MANIFEST" \
    || act -q "agent manifest ~/.claude/agents/.toolkit-agents" write_atomic "$MANIFEST" 644 < <(printf '%s\n' "${owned[@]}")
}

settings_request() {
  local desired
  desired="$(jq -n --arg claude_dir "$CLAUDE_DIR" --arg scratch "$SCRATCH" --arg root "$ROOT" \
    --arg statusline "$STATUSLINE_ENTRY" --argjson wiring "$WIRING" \
    --argjson plugins "$(printf '%s\n' "${PLUGINS[@]}" | jq -R 'split(" ")[0]' | jq -s .)" \
    "$DESIRED")" || return 1
  jq -n --arg settings "$SETTINGS" --arg ledger "$LEDGER" --arg backups "$BACKUPS" \
    --arg home "$HOME" --arg root "$ROOT" --arg prev_root "$PREV_ROOT" \
    --argjson desired "$desired" --argjson absent "$ABSENT" \
    '{settings: $settings, ledger: $ledger, backups: $backups, home: $home, root: $root,
      prev_root: $prev_root, desired: $desired, absent: $absent}'
}

apply_settings() {
  local request result state reason fix saved shown lines
  if ! request="$(settings_request)"; then
    finding required toolkit "install.sh does not build its own settings" "$ROOT/install.sh"
    return
  fi
  result="$(printf '%s' "$request" | python3 "$ROOT/hooks/lib/settings.py" "$([ "$MODE" = dry ] && echo plan || echo apply)" 2>&1)"
  if ! state="$(jq -er '.settings' <<<"$result" 2>/dev/null)"; then
    finding required toolkit "hooks/lib/settings.py failed: $(printf '%s' "$result" | tail -1)" "$ROOT/hooks/lib/settings.py"
    return
  fi
  reason="$(jq -r '.reason // ""' <<<"$result")"
  fix="$(jq -r '.fix // ""' <<<"$result")"
  saved="$(jq -r '.backup // ""' <<<"$result")"
  case "$state" in
    written)
      CHANGES+=("settings.json updated${saved:+ (backup: $(home_path "$saved"))}")
      WROTE+=("settings.json${saved:+ (backup: $(home_path "$saved"))}")
      ;;
    would-write)
      lines="$(jq -r '.diff' <<<"$result" | wc -l)"
      shown="$(jq -r '.diff' <<<"$result" | head -200 | sed 's/^/  /')"
      [ "$lines" -le 200 ] || shown+=$'\n'"  … $((lines - 200)) more lines"
      CHANGES+=("settings.json:"$'\n'"$shown")
      ;;
    failed)
      case "$(jq -r '.kind' <<<"$result")" in
        user) finding required user "settings.json was left untouched: $reason" "$fix" ;;
        *) finding required install "settings.json was not applied: $reason" "${fix:-$(install_command)}" ;;
      esac
      ;;
  esac
  if [ "$(jq -r '.replaced_link // ""' <<<"$result")" != "" ]; then
    finding advisory user "settings.json was a link to $(jq -r '.replaced_link' <<<"$result") and is now a file, so the link's target no longer receives changes"
  fi
  while IFS= read -r reason; do
    case "$reason" in
      env) RESTART+=("env changed") ;;
      enabledPlugins) RESTART+=("plugins changed") ;;
    esac
  done < <(jq -r '.restart[]? // empty' <<<"$result")
  case "$(jq -r '.ledger // ""' <<<"$result")" in
    failed) finding required install "the ledger was not written: $(jq -r '.ledger_reason' <<<"$result")" "$(install_command)" ;;
    would-write) CHANGES+=("ledger ~/.claude/agent-toolkit-applied.json") ;;
  esac
}

apply_pointer() {
  local saved="" link=""
  pointer_content | cmp -s - "$POINTER" && return 0
  if [ -e "$POINTER" ]; then
    saved="$(backup_name "$BACKUPS/CLAUDE.md")"
    act -q "back up ~/.claude/CLAUDE.md to $(home_path "$saved")" backup_to "$POINTER" "$saved" || return 0
  fi
  [ -L "$POINTER" ] && link="$(readlink "$POINTER")"
  local what="~/.claude/CLAUDE.md imports ~/.claude/agent-toolkit/CLAUDE.md${saved:+ (backup: $(home_path "$saved"))}"
  if act "$what" write_atomic "$POINTER" 644 < <(pointer_content); then
    WROTE+=("$what")
    RESTART+=("~/.claude/CLAUDE.md changed")
    [ -z "$link" ] || [ "$MODE" = dry ] \
      || finding advisory user "~/.claude/CLAUDE.md was a link to $link and is now a file, so the link's target no longer receives changes"
  fi
}

# Stamped only when absent, never rewritten: it is what keeps every transcript
# written before this toolkit out of the retro data.
apply_retro_marker() {
  [ -f "$CLAUDE_DIR/retro/since" ] && return 0
  act "retro marker ~/.claude/retro/since" write_atomic "$CLAUDE_DIR/retro/since" 644 < <(date -u +%Y-%m-%dT%H:%M:%SZ)
}

# Settings name the launcher, so they wait on it.
apply_local() {
  apply_link || return
  apply_launcher || return
  apply_skills
  apply_agents
  apply_settings
  apply_pointer
  apply_retro_marker
}

# ── plugins ──────────────────────────────────────────────────────────────────
# Both sources are public, so HTTPS needs no credentials, while the default SSH
# clone needs a key in an agent this shell may not have.
claude_fetch() {
  (cd "$HOME" && CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 GIT_TERMINAL_PROMPT=0 timeout 600 claude "$@" </dev/null)
}

FAILED_PLUGINS=" "

fetch_failure() { # exit status, output → Claude Code's own message
  local message
  [ "$1" -eq 124 ] && echo "it timed out after 600 seconds" && return
  message="$(grep '^{' <<<"$2" | jq -r '.message // empty' 2>/dev/null)"
  printf '%s' "${message:-$2}" | one_line
}

LISTING=""
listing() { # [marketplace] → the JSON array in LISTING, or a finding and status 1
  local args=(plugin "$@" list --json)
  if LISTING="$(claude_cli "${args[@]}")" && jq -e 'type == "array"' <<<"$LISTING" >/dev/null 2>&1; then
    return 0
  fi
  finding required install "claude ${args[*]} did not answer, so the plugins could not be checked" "$(install_command)"
  return 1
}

fetch_plugins() {
  local marketplaces plugins spec id source market out rc
  listing marketplace || return
  marketplaces="$LISTING"
  for spec in "${PLUGINS[@]}"; do
    id="${spec%% *}" source="${spec#* }" market="${spec%% *}"
    market="${market#*@}"
    jq -e --arg m "$market" 'any(.[]; .name == $m)' <<<"$marketplaces" >/dev/null && continue
    if [ "$MODE" = dry ]; then
      CHANGES+=("register plugin marketplace $market from $source")
      continue
    fi
    out="$(claude_fetch plugin marketplace add "$source" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      CHANGES+=("registered plugin marketplace $market")
    else
      finding required install "plugin marketplace $market was not registered: $(fetch_failure "$rc" "$out")" "$(install_command)"
      FAILED_PLUGINS+="$id "
    fi
  done
  listing || return
  plugins="$LISTING"
  for spec in "${PLUGINS[@]}"; do
    id="${spec%% *}"
    [[ "$FAILED_PLUGINS" == *" $id "* ]] && continue
    jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$plugins" >/dev/null && continue
    if [ "$MODE" = dry ]; then
      CHANGES+=("install plugin $id")
      continue
    fi
    out="$(claude_fetch plugin install "$id" --scope user --json 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      CHANGES+=("installed plugin $id")
      RESTART+=("plugins changed")
    else
      finding required install "plugin $id was not installed: $(fetch_failure "$rc" "$out")" "$(install_command)"
      FAILED_PLUGINS+="$id "
    fi
  done
}

check_plugins() {
  local plugins spec id state
  listing || return
  plugins="$LISTING"
  for spec in "${PLUGINS[@]}"; do
    id="${spec%% *}"
    [[ "$FAILED_PLUGINS" == *" $id "* ]] && continue
    state="$(jq -r --arg id "$id" 'first(.[] | select(.id == $id) | if .enabled then "enabled" else "disabled" end) // "missing"' <<<"$plugins")"
    case "$MODE:$state" in
      *:missing) finding required install "plugin $id is not installed" "$(install_command)" ;;
      dry:disabled | *:enabled) ;;
      *:disabled) finding required install "plugin $id is installed but not enabled" "$(install_command)" ;;
    esac
  done
  check_notifications "$plugins"
}

# The plugin picks its own config file, and says which through its own CLI. An
# absent file or key is its default, which is quiet for subagents.
check_notifications() { # plugin listing
  local dir cfg
  dir="$(jq -r 'first(.[] | select(.id == "claude-notifications-go@claude-notifications-go") | .installPath) // empty' <<<"$1")"
  [ -n "$dir" ] && [ -x "$dir/bin/agent-notifications" ] || return 0
  cfg="$(cd "$HOME" && timeout 10 "$dir/bin/agent-notifications" config path --json </dev/null 2>/dev/null | jq -r '.path // empty' 2>/dev/null)"
  [ -n "$cfg" ] && jq -e '.notifications.suppressForSubagents == false' "$cfg" >/dev/null 2>&1 || return 0
  finding advisory user "notifications fire when a subagent finishes: notifications.suppressForSubagents is false in $(home_path "$cfg")" \
    "jq '.notifications.suppressForSubagents = true' $(home_path "$cfg") > $(home_path "$cfg").new && mv $(home_path "$cfg").new $(home_path "$cfg")"
}

# ── version stamp ────────────────────────────────────────────────────────────
# Written only while no required finding stands, so the status line never shows
# a version as applied when it is not. Written under the lock, and left alone
# when the link no longer points here or another apply holds the lock: that
# apply owns the stamp.
apply_stamp() {
  local out rc
  [ "$MODE" = dry ] || [ "$(resolve "$STABLE")" = "$ROOT" ] || return 0
  out="$(python3 "$ROOT/hooks/lib/version.py" "$ROOT" 2>&1)"
  rc=$?
  case "$rc" in
    0) ;;
    3) finding advisory install "git did not report the version in time, so the version stamp was left as it was" "$(install_command)" && return ;;
    4) finding advisory user "git cannot read the version directory's history, so the version stamp was left as it was: $(printf '%s' "$out" | one_line)" \
      "git -C $(home_path "$ROOT") status" && return ;;
    *) finding advisory toolkit "hooks/lib/version.py failed, so the version stamp was left as it was" "$ROOT/hooks/lib/version.py"$'\n'"$(printf '%s' "$out" | tail -1)" && return ;;
  esac
  if [ "$MODE" != dry ]; then
    take_lock 5 && [ "$(resolve "$STABLE")" = "$ROOT" ] || { exec 9<&-; return 0; }
  fi
  if [ -z "$out" ]; then
    [ ! -e "$STAMP" ] || act "version stamp removed: this version directory has no version" rm -f "$STAMP"
  elif [ "$(count required)" -eq 0 ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$out" ]; then
    act "version stamp $out" write_atomic "$STAMP" 644 <<<"$out"
  fi
  exec 9<&-
}

# ── reports ──────────────────────────────────────────────────────────────────
mark() { [ "$1" = required ] && printf '✗' || printf '!'; }

plural() { [ "$1" -eq 1 ] && echo "$1 $2" || echo "$1 ${2}s"; }

# A fix shared by consecutive findings, or a fix line already printed under the
# heading, is printed once.
report_group() { # who, heading
  local order=() i j sev line next seen=$'\n'
  for sev in required advisory; do
    for i in "${!F_WHO[@]}"; do
      [ "${F_WHO[i]}" = "$1" ] && [ "${F_SEV[i]}" = "$sev" ] && order+=("$i")
    done
  done
  [ ${#order[@]} -gt 0 ] || return 0
  printf '\n%s\n' "$2"
  for j in "${!order[@]}"; do
    i="${order[j]}"
    printf '  %s %s\n' "$(mark "${F_SEV[i]}")" "${F_TEXT[i]}"
    next="${order[j + 1]:-}"
    [ -n "$next" ] && [ "${F_FIX[next]}" = "${F_FIX[i]}" ] && continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [[ "$seen" == *$'\n'"$line"$'\n'* ]] && continue
      seen+="$line"$'\n'
      printf '    %s\n' "$line"
    done <<<"${F_FIX[i]}"
  done
}

report_terminal() {
  local change required advisory
  if [ ${#CHANGES[@]} -eq 0 ]; then
    echo "Nothing to change"
  else
    [ "$MODE" = dry ] && echo "Would change" || echo "Changed"
    for change in "${CHANGES[@]}"; do printf '  %s\n' "$change"; done
  fi
  report_group user "Needs you"
  report_group install "Run install again"
  report_group toolkit "Toolkit"
  if [ ${#RESTART[@]} -gt 0 ]; then
    printf '\nRestart Claude Code: %s.\n' "$(restart_reasons)"
  fi
  required="$(count required)" advisory="$(count advisory)"
  printf '\n%s %s, %s\n' "$([ "$required" -eq 0 ] && echo ✓ || echo ✗)" "$(plural "$required" "required finding")" "$advisory advisory"
}

json_str() {
  local s="$1"
  s="${s//\\/\\\\}" s="${s//\"/\\\"}" s="${s//$'\n'/\\n}" s="${s//$'\t'/\\t}" s="${s//$'\r'/}"
  s="${s//[[:cntrl:]]/}"
  printf '"%s"' "$s"
}

# Exactly one JSON object, or nothing when there is nothing to say. A skill link
# applied cleanly is not reported, but at session start still asks for a rescan.
report_hook() {
  local i required context="" message=() fixes names=() reload=0
  required="$(count required)"
  [ "$EVENT" = SessionStart ] && [ "$SKILLS_CHANGED" -eq 1 ] && reload=1
  if [ ${#F_SEV[@]} -eq 0 ] && [ ${#WROTE[@]} -eq 0 ] && [ ${#RESTART[@]} -eq 0 ]; then
    [ "$reload" -eq 1 ] && printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","reloadSkills":true}}\n'
    return 0
  fi
  context="agent-toolkit doctor:"
  for i in "${!F_SEV[@]}"; do
    mapfile -t fixes <<<"${F_FIX[i]}"
    if [ -n "${F_FIX[i]}" ]; then
      context+=$'\n'"$(mark "${F_SEV[i]}") ${F_TEXT[i]}. Fix (${F_WHO[i]}): $(join "; then " "${fixes[@]}")"
    else
      context+=$'\n'"$(mark "${F_SEV[i]}") ${F_TEXT[i]}. Who acts: ${F_WHO[i]}"
    fi
  done
  for i in "${WROTE[@]}"; do
    context+=$'\n'"wrote $i"
    names+=("${i%% *}")
  done
  [ "$required" -eq 0 ] || message+=("$(plural "$required" problem). Ask Claude to fix it, or run ~/.claude/agent-toolkit/install.sh")
  [ ${#WROTE[@]} -eq 0 ] || message+=("Updated $(join ", " "${names[@]}")")
  if [ ${#RESTART[@]} -gt 0 ]; then
    message+=("Restart Claude Code to load it")
    context+=$'\n'"Restart Claude Code: $(restart_reasons)."
  fi
  printf '{'
  if [ ${#message[@]} -gt 0 ]; then
    printf '"systemMessage":%s,' "$(json_str "agent-toolkit: $(join ". " "${message[@]}")")"
  fi
  printf '"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s' "$(json_str "$EVENT")" "$(json_str "$context")"
  [ "$reload" -eq 1 ] && printf ',"reloadSkills":true'
  printf '}}\n'
}

# Claude Code drops the plain stdout of a hook that exits non-zero, so --sync
# always exits 0.
finish() {
  if [ "$MODE" = sync ]; then
    report_hook
    exit 0
  fi
  report_terminal
  local i
  for i in "${!F_SEV[@]}"; do
    [ "${F_SEV[i]}" = required ] || continue
    [ "$MODE" = full ] && exit 1
    [ "${F_WHO[i]}" = install ] || exit 1
  done
  exit 0
}

# Read without jq, which may be the very thing missing.
hook_event() {
  local payload=""
  [ -t 0 ] || IFS= read -r -d '' -t 2 payload
  if [[ "$payload" =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"PostToolUse\" ]]; then
    echo PostToolUse
  else
    echo SessionStart
  fi
}

main() {
  if [ $# -eq 0 ]; then
    MODE=full
  elif [ $# -eq 1 ]; then
    case "$1" in
      --dry-run) MODE=dry ;;
      --sync) MODE=sync ;;
      --help) usage && exit 0 ;;
      *) usage >&2 && exit 2 ;;
    esac
  else
    usage >&2
    exit 2
  fi
  cd / || exit 1

  if [ "$MODE" = sync ]; then
    [ "$(resolve "$STABLE")" = "$ROOT" ] || exit 0
    EVENT="$(hook_event)"
  fi

  check_tools || finish
  PREV_ROOT="$(resolve "$STABLE")"
  local ready=0 err
  check_layout && check_root && ready=1

  if [ "$ready" -eq 1 ] && [ "$MODE" = dry ]; then
    apply_local
  elif [ "$ready" -eq 1 ]; then
    ready=0
    if ! err="$(mkdir -p "$CLAUDE_DIR" 2>&1)"; then
      if [ -e "$CLAUDE_DIR" ]; then
        finding required user "~/.claude is not a directory, so nothing was changed" "mv ~/.claude ~/.claude.not-a-directory"
      else
        finding required user "~/.claude cannot be created: $(printf '%s' "$err" | one_line)" "chmod u+w ~"
      fi
    else
      take_lock "$([ "$MODE" = sync ] && echo 5 || echo 60)"
      case $? in
        0)
          # A full install may have moved the link while this waited for the lock.
          PREV_ROOT="$(resolve "$STABLE")"
          if [ "$MODE" = sync ] && [ "$PREV_ROOT" != "$ROOT" ]; then
            exit 0
          fi
          ready=1
          apply_local
          ;;
        1)
          [ "$MODE" != sync ] || [ "$(resolve "$STABLE")" = "$ROOT" ] || exit 0
          if [ "$MODE" = sync ]; then
            finding advisory install "another install held the lock for 5 seconds, so this session start applied nothing" "$(install_command)"
          else
            finding required install "another install held the lock for a minute, so nothing was applied" "$(install_command)"
          fi
          ;;
        *) finding required user "the apply lock on ~/.claude could not be taken, so nothing was applied: $LOCK_ERROR" "$LOCK_FIX" ;;
      esac
      exec 9<&-
    fi
    # A simple command, so the forked shell execs it: a backgrounded list would
    # keep this run's stdout open, and a hook's caller waits for that to close.
    if have setsid; then setsid "$ROOT/hooks/reap.sh" </dev/null >/dev/null 2>&1 & fi
  fi

  if check_claude && [ "$ready" -eq 1 ]; then
    [ "$MODE" = sync ] || fetch_plugins
    check_plugins
  fi
  check_access
  check_retro
  [ "$ready" -eq 1 ] && apply_stamp
  finish
}

main "$@"
