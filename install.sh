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
RELEASES="$CLAUDE_DIR/agent-toolkit-releases"
WORKTREES="$CLAUDE_DIR/worktrees"
BRIDGE_SRC="$ROOT/tools/penpot-mcp"
BRIDGE_DST="$CLAUDE_DIR/tools/penpot-mcp"
# Install copies every file it finds, so a fifth travels on its own. These four
# are the evidence the directory arrived whole.
BRIDGE_FILES=(package.json package-lock.json start-bridge.sh check-bridge.sh)
SCRATCH="/tmp/claude-$(id -u)"

# The report shape and the requirement text hooks/update.sh prints too. Sourced
# before anything else needs them, so a root missing one says so in a line
# rather than in a bash error partway through a report.
for shared in hooks/lib/report.sh hooks/lib/requirements.sh; do
  # shellcheck source=/dev/null
  . "$ROOT/$shared" 2>/dev/null \
    || { printf 'agent-toolkit: %s is missing from %s. Fix: reinstall the toolkit\n' "$shared" "$ROOT" >&2; exit 1; }
done

# The lowest release with every CLI and hook surface used here: plugin install
# --json arrived in 2.1.268, after everything else.
MIN_CLAUDE=2.1.268

# id and the GitHub source its marketplace is registered from.
PLUGINS=(
  "pr-review-toolkit@claude-plugins-official anthropics/claude-plugins-official"
  "frontend-design@claude-plugins-official anthropics/claude-plugins-official"
  "modern-web-guidance@claude-plugins-official anthropics/claude-plugins-official"
  "claude-notifications-go@claude-notifications-go 777genius/agent-notifications"
)

# Every hook the toolkit wires, relative to the version directory. Each becomes a
# launcher command; matcher "" writes the group with no matcher.
#
# Notification events (Notification, Stop, SubagentStop) are deliberately
# absent: the claude-notifications-go plugin owns them, and which of them reach
# the user is its own configuration.
#
# taskline and style must stay synchronous. Only a hook that finishes before the
# turn or the tool call does is read at all: an async taskline prints its line
# into the void, and an async style hook cannot deny a commit that already ran.
#
# style.py takes the whole Bash matcher rather than an if. That field is
# permission rule syntax, and Bash(git commit *) misses git -C <repo> commit.
#
# The retro recorder is the mirror image: async on every event, so it can neither
# block a turn nor inject its stdout. The updater's stage half is the same shape,
# because it is where the network lives; its apply half waits, because taking a
# release is the one session start that has work to do, and it skips fork, which
# inherits a context that is already running.
WIRING='[
  {"event":"SessionStart","matcher":"startup|resume|clear|compact|fork",
   "hooks":[{"entry":"install.sh --sync"}]},
  {"event":"SessionStart","matcher":"startup|resume|clear|compact",
   "hooks":[{"entry":"hooks/update.sh apply"}]},
  {"event":"SessionStart","matcher":"",
   "hooks":[{"entry":"hooks/retro.py record","async":true},
            {"entry":"hooks/update.sh stage","async":true}]},
  {"event":"PreCompact","matcher":"",
   "hooks":[{"entry":"hooks/retro.py record","async":true}]},
  {"event":"UserPromptSubmit","matcher":"",
   "hooks":[{"entry":"hooks/taskline.py"},
            {"entry":"hooks/retro.py record --interval 900","async":true}]},
  {"event":"PreToolUse","matcher":"Bash",
   "hooks":[{"entry":"hooks/guard.sh"},
            {"entry":"hooks/style.py"}]},
  {"event":"PreToolUse","matcher":"mcp__linear.*",
   "hooks":[{"entry":"hooks/guard.sh"}]},
  {"event":"PostToolUse","matcher":"Write|Edit",
   "hooks":[{"entry":"hooks/sync.sh"},
            {"entry":"hooks/format.sh","async":true}]},
  {"event":"SessionEnd","matcher":"",
   "hooks":[{"entry":"hooks/retro.py record","async":true}]}
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
    # The agents' own working state, and nothing else. A path inside one is
    # approved before any rule is consulted, which is what stops a background
    # agent stalling on a prompt, and it approves writing as readily as reading:
    # ~/.claude holds the credentials file, the transcripts, the plugin store and
    # settings.json, so approving the parent approves a silent write to each.
    #
    # The version directory only where somebody edits it. On a machine installed
    # from a release the same entry would hand every agent the code that runs at
    # the next session start.
    additionalDirectories: ([$scratch, $worktrees] + (if $work_tree then [$root] else [] end)),
    # A deny governs the Read tool only, so jq and python still reach settings.
    deny: [
      "Read(~/.claude/.credentials.json)",
      "Read(~/.claude/settings*.json)",
      "Read(~/.claude/backups/settings.json.*)",
      "Read(~/.claude/backups/.claude.json.backup.*)"
    ]
  },
  # The no-attribution rule, mechanically. includeCoAuthoredBy alone leaves the
  # session URL trailer and the link in a pull request body.
  includeCoAuthoredBy: false,
  attribution: {sessionUrl: false, commitTrailers: false},
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

# Approvals kept unset in the same way, because retiring one needs a ledger to
# vouch that the toolkit wrote it and a machine that lost its ledger would keep
# the approval for good.
forbidden_approvals() {
  jq -n --arg claude_dir "$CLAUDE_DIR" --arg releases "$RELEASES" \
    '[{path: ["permissions", "additionalDirectories"], is: $claude_dir},
      {path: ["permissions", "additionalDirectories"], under: $releases}]'
}

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
CHANGES=()   # what changed, or in a dry run what would
WROTE=()     # settings and pointer writes, which a hook report names
REMOVED=()   # deletions, which a hook report names as well
RESTART=()   # what changed that Claude Code reads only at start
SKILLS_CHANGED=0

have() { command -v "$1" >/dev/null 2>&1; }

restart_reasons() {
  local reasons
  mapfile -t reasons < <(printf '%s\n' "${RESTART[@]}" | LC_ALL=C sort -u)
  join ", " "${reasons[@]}"
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
    dnf:flock) echo util-linux-core ;;
    *:flock) echo util-linux ;;
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

# Returns 1 when jq or python3 is missing. gh is checked with the token it
# carries, which a session start skips: the same three lines every session
# cannot be acted on from inside the session that would print them.
check_tools() {
  local missing=() stop=() rest=() t line tools=(jq python3 git flock)
  [ "$MODE" = sync ] || tools+=(gh)
  for t in "${tools[@]}"; do have "$t" || missing+=("$t"); done
  have python3 && ! python3 -c 'import sqlite3' >/dev/null 2>&1 && missing+=(sqlite3)
  [ ${#missing[@]} -gt 0 ] || return 0
  line="$(package_line "${missing[@]}")"
  for t in "${missing[@]}"; do
    case "$t" in
      jq | python3) stop+=("$t") ;;
      git | flock) rest+=("$t") ;;
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

# The running Claude Code names its own executable, which is the one whose
# plugins these are. PATH answers for a terminal, where there is no session.
CLAUDE=""
claude_bin() {
  if [ -z "$CLAUDE" ]; then
    CLAUDE="${CLAUDE_CODE_EXECPATH:-}"
    [ -n "$CLAUDE" ] && [ -x "$CLAUDE" ] || CLAUDE="$(command -v claude)" || return 1
  fi
  [ -n "$CLAUDE" ]
}

# Local reads only, so no timeout.
claude_cli() { (cd "$HOME" && "$CLAUDE" "$@" </dev/null 2>/dev/null); }

# The version gates the plugin step alone, and --sync never fetches, so it is
# read only where it decides something.
check_claude() {
  local version
  if ! claude_bin; then
    finding required user "claude is not on PATH, so the plugins are not installed" "curl -fsSL https://claude.ai/install.sh | bash"
    return 1
  fi
  [ "$MODE" != sync ] || return 0
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

# What the user can only fix in their own terminal, and only a full install
# reports: at every session start these cost a process each and say the same
# thing, which nothing inside Claude Code can act on.
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
  # first is given a value because a read that never runs leaves it unset,
  # which under set -u kills the subshell and leaves the caller reading the
  # empty output as a script that starts fine.
  local first="" prog arg
  [ -r "$1" ] || { echo "it cannot be read" && return; }
  IFS= read -r first <"$1" 2>/dev/null || true
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
  local first="" words=()
  IFS= read -r first <"$1" 2>/dev/null || true
  read -ra words <<<"${first#\#!}"
  [ ${#words[@]} -gt 0 ] || return 127
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
    fi
  done <<<"$entries"
  for entry in hooks/launcher.sh hooks/lib/settings.py hooks/lib/version.py; do
    [ -f "$ROOT/$entry" ] || finding required toolkit "$entry is missing from the version directory" "$ROOT/$entry"
  done
  # A partly unpacked directory would otherwise retire every skill and agent.
  [ -n "$(find "$ROOT/skills" -name SKILL.md -print -quit 2>/dev/null)" ] \
    || finding required toolkit "skills/ holds no skill" "$ROOT/skills"
  compgen -G "$ROOT/agents/*.md" >/dev/null || finding required toolkit "agents/ holds no agent" "$ROOT/agents"
  check_bridge
  check_gate
  if ! out="$(python_problems 2>&1)"; then
    finding required toolkit "the python checks did not run: $(printf '%s' "$out" | tail -1)" "$ROOT/install.sh"
  fi
  while IFS=$'\t' read -r entry reason detail; do
    [ -n "$detail" ] && finding required toolkit "$reason: $entry" "$ROOT/$entry"$'\n'"$detail"
  done <<<"$out"
  [ ${#F_SEV[@]} -eq "$before" ]
}

# Every file install copies out is in the root, and each script starts, which is
# the same evidence of a whole directory that skills/ and agents/ are.
check_bridge() {
  local entry reason
  for entry in "${BRIDGE_FILES[@]}"; do
    if [ ! -f "$BRIDGE_SRC/$entry" ]; then
      finding required toolkit "tools/penpot-mcp/$entry is missing from the version directory" "$BRIDGE_SRC/$entry"
      continue
    fi
    case "$entry" in *.sh) ;; *) continue ;; esac
    reason="$(cannot_start "$BRIDGE_SRC/$entry")"
    [ -z "$reason" ] || finding required toolkit "tools/penpot-mcp/$entry cannot start: $reason" "$BRIDGE_SRC/$entry"
  done
}

# The approval gate, run before it goes live: the launcher must ask when the
# toolkit is unreachable, and the guard must ask before a push. HOME points
# nowhere, so neither can find or write anything. These two are the only entry
# points whose #! line is probed: a hook that cannot start is a hook that let
# the call through, and for the rest the failure is visible where it happens.
# The style gate is deliberately out, because what it lets through is a local
# commit rather than anything that leaves the machine.
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
  if [ -x "$ROOT/hooks/guard.sh" ]; then
    reason="$(cannot_start "$ROOT/hooks/guard.sh")"
    if [ -n "$reason" ]; then
      finding required toolkit "hooks/guard.sh cannot start: $reason" "$ROOT/hooks/guard.sh"
    elif [[ "$(HOME=/nonexistent/agent-toolkit "$ROOT/hooks/guard.sh" <<<"$payload" 2>/dev/null)" != *"$ask"* ]]; then
      finding required toolkit "hooks/guard.sh does not ask before a push" "$ROOT/hooks/guard.sh"
    fi
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

# Every path a tool reaches without the user being asked, which is every path an
# agent writes unprompted. Resolved, because a path is compared against $ROOT.
approved_directory() { # a path → 0 when it is one of them, or inside one
  local approved
  for approved in "$(resolve "$CLAUDE_DIR")" "$(resolve "$SCRATCH")"; do
    [ -n "$approved" ] || continue
    case "$1/" in "$approved/"*) return 0 ;; esac
  done
  return 1
}

# A worktree is approved for every agent, so it never becomes the live toolkit.
# A machine already live from one is exempt at --sync: a doctor that refused
# would leave it with no doctor at all until somebody ran a full install.
check_location() {
  local worktrees common checkout tail fix
  [ "$MODE" != sync ] || return 0
  # $ROOT resolves every component of its path and $CLAUDE_DIR is written as
  # $HOME names it, so a home reached through a symlink would make this miss.
  worktrees="$(resolve "$WORKTREES")"
  [ -n "$worktrees" ] || return 0
  case "$ROOT/" in "$worktrees/"*) ;; *) return 0 ;; esac
  checkout="$(names_a_checkout)"
  if [ -n "$checkout" ]; then
    tail=". The worktree names the checkout at $(home_path "$checkout"), which is what installs"
    fix="cd $(home_path "$checkout") && ./install.sh"
  else
    tail=""
    fix="mv -T $(home_path "$ROOT") <a directory outside ~/.claude> && <that directory>/install.sh"
  fi
  finding required user "the version directory is under ~/.claude/worktrees, which every agent may write, so nothing was changed$tail" "$fix"
  return 1
}

# The checkout a worktree belongs to, or nothing. The answer comes out of
# $ROOT/.git, inside the directory every agent may write, so it is asked only of
# a real work tree, with the variables that would answer for another repository
# out of the way, and given back only when it points where no agent writes
# unasked: a rewritten gitdir line would otherwise have the finding hand the user
# a command that installs whatever an agent put there.
names_a_checkout() {
  local common checkout
  python3 "$ROOT/hooks/lib/version.py" worktree "$ROOT" >/dev/null 2>&1 || return 0
  common="$( (cd "$ROOT" && cd "$(env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE \
    timeout 5 git rev-parse --git-common-dir 2>/dev/null)" && pwd -P) 2>/dev/null)"
  checkout="${common%/.git}"
  [ -n "$checkout" ] && [ "$checkout" != "$common" ] && [ "$checkout" != "$ROOT" ] || return 0
  approved_directory "$checkout" || printf '%s' "$checkout"
}

# ~/.claude/agent-toolkit must stay a link, free to point at any version
# directory. Returns 1 when it is not, and nothing may be written.
check_layout() {
  [ -e "$STABLE" ] && [ ! -L "$STABLE" ] || return 0
  if [ -d "$STABLE" ]; then
    finding required user "~/.claude/agent-toolkit is a real directory, not a link, so nothing was changed" \
      "mkdir -p ~/Documents/git-repo && mv -T ~/.claude/agent-toolkit ~/Documents/git-repo/agent-toolkit-v2 && ~/Documents/git-repo/agent-toolkit-v2/install.sh"
  else
    finding required user "~/.claude/agent-toolkit is a file, not a link to a version directory, so nothing was changed" \
      "mv ~/.claude/agent-toolkit ~/.claude/agent-toolkit.not-a-link && $(install_command)"
  fi
  return 1
}

resolve() { (cd "$1" 2>/dev/null && pwd -P) || readlink "$1" 2>/dev/null || true; }

# ── applying ─────────────────────────────────────────────────────────────────
# Held on ~/.claude itself, so serialising applies writes no file of its own.
# The lock belongs to fd 9, which outlives the flock that took it. Returns 1
# when another apply held it past the deadline, 2 with LOCK_ERROR otherwise.
take_lock() { # seconds
  LOCK_FIX=""
  if ! have flock; then
    LOCK_ERROR="flock is not on PATH" LOCK_FIX="$(package_line flock)"
    return 2
  fi
  if ! { exec 9<"$CLAUDE_DIR"; } 2>/dev/null; then
    LOCK_ERROR="~/.claude cannot be opened" LOCK_FIX="chmod u+rwx ~/.claude"
    return 2
  fi
  # -E separates the deadline from flock's own failures, which exit 1.
  LOCK_ERROR="$(flock -w "$1" -E 4 9 2>&1)"
  case $? in
    0) return 0 ;;
    4) return 1 ;;
    *) return 2 ;;
  esac
}

apply_link() {
  [ "$MODE" != sync ] && [ "$PREV_ROOT" != "$ROOT" ] || return 0
  act "~/.claude/agent-toolkit → $ROOT${PREV_ROOT:+ (was $PREV_ROOT)}" link_atomic "$ROOT" "$STABLE"
}

apply_launcher() {
  cmp -s "$ROOT/hooks/launcher.sh" "$LAUNCHER" && [ -x "$LAUNCHER" ] && return 0
  act "launcher ~/.claude/agent-toolkit-run" write_atomic "$LAUNCHER" 755 <"$ROOT/hooks/launcher.sh"
}

# A link the toolkit made points at a path under some version directory's
# skills/, ending in the name it is linked as. Naming the version directories
# this run knows about instead would leave a link into a third one unrecognised
# for good: neither relinked nor removed, so every install repeats the same
# finding and a retired skill goes on resolving. The previous generation nested
# its skills a directory deeper, which is why only skills/ is anchored, not the
# depth below it. Anything else at a skill's name is the user's.
toolkit_link() { # name, target
  case "$2" in /*/skills/*) [ "${2##*/}" = "$1" ] ;; *) return 1 ;; esac
}

apply_skills() {
  local f dir name dst target
  declare -A linked=()
  if [ ! -d "$SKILLS_DST" ]; then
    act "create ~/.claude/skills" mkdir -p "$SKILLS_DST" && RESTART+=("~/.claude/skills was created")
  fi
  # find walks past what it cannot read, so a skill would go missing with the
  # report saying nothing.
  while IFS= read -r -d '' f; do
    finding required toolkit "skills/${f#"$ROOT"/skills/} cannot be read, so its skill may not be installed" "$f"
  done < <(find "$ROOT/skills" ! -readable -print0 2>/dev/null | sort -z)
  while IFS= read -r -d '' f; do
    dir="$(dirname "$f")" name="$(basename "$(dirname "$f")")" dst="$SKILLS_DST/$name"
    linked[$name]=1
    if [ -L "$dst" ]; then
      target="$(readlink "$dst")"
      [ "$target" = "$dir" ] && continue
      # Dangling or not, a name the user's own link holds is theirs.
      if ! toolkit_link "$name" "$target"; then
        skill_held "$name"
        continue
      fi
    elif [ -e "$dst" ]; then
      skill_held "$name"
      continue
    fi
    act "link skill $name" link_atomic "$dir" "$dst" && SKILLS_CHANGED=1
  done < <(find "$ROOT/skills" -name SKILL.md -print0 2>/dev/null | sort -z)

  # A name this version directory no longer provides, still held by a link the
  # toolkit made. Which version directory it points into does not matter: left
  # alone, a retired skill goes on resolving out of whichever one it was.
  for dst in "$SKILLS_DST"/*; do
    name="$(basename "$dst")"
    [ -L "$dst" ] && [ -z "${linked[$name]:-}" ] || continue
    target="$(readlink "$dst")"
    toolkit_link "$name" "$target" || continue
    if [ -e "$dst" ]; then
      unlink_skill "unlink skill $name, which this version directory no longer has" "$dst"
    else
      unlink_skill "unlink dangling skill $name" "$dst"
    fi
  done
}

# A deletion the user never asked for, so a hook report names it even though it
# applied without a problem.
unlink_skill() { # description, path
  act "$1" rm -f "$2" || return 1
  SKILLS_CHANGED=1
  REMOVED+=("$1")
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
      [ ! -f "$ROOT/agents/$n" ] && [ -e "$AGENTS_DST/$n" ] || continue
      saved="$(backup_name "$BACKUPS/agents/$n")"
      act -q "back up the retired agents/$n to $(home_path "$saved")" backup_to "$AGENTS_DST/$n" "$saved" || continue
      act "remove retired agent $n (backup: $(home_path "$saved"))" rm -f "$AGENTS_DST/$n" \
        && REMOVED+=("remove retired agent $n (backup: $(home_path "$saved"))")
    done <"$MANIFEST"
  fi
  for n in "${names[@]}"; do
    cmp -s "$ROOT/agents/$n" "$AGENTS_DST/$n" && continue
    if [ ! -r "$ROOT/agents/$n" ]; then
      finding required toolkit "agents/$n cannot be read, so it was not copied" "$ROOT/agents/$n"
      continue
    fi
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
  local desired releases work_tree=false
  # A release directory is approved for nobody, and git init inside one is a
  # local command nothing gates, so where the root sits answers before what it
  # holds does. Resolved on both sides, because $ROOT is and $HOME need not be.
  # Otherwise it is the question dev mode asks, and git failing to answer it
  # keeps the approval rather than quietly revoking one.
  releases="$(resolve "$RELEASES")"
  case "$ROOT/" in
    "${releases:-$RELEASES}/"*) ;;
    *)
      python3 "$ROOT/hooks/lib/version.py" worktree "$ROOT" >/dev/null 2>&1
      case $? in 0 | 3 | 4) work_tree=true ;; esac
      ;;
  esac
  desired="$(jq -n --arg scratch "$SCRATCH" --arg root "$ROOT" \
    --arg worktrees "$WORKTREES" \
    --argjson work_tree "$work_tree" \
    --arg statusline "$STATUSLINE_ENTRY" --argjson wiring "$WIRING" \
    --argjson plugins "$(printf '%s\n' "${PLUGINS[@]}" | jq -R 'split(" ")[0]' | jq -s .)" \
    "$DESIRED")" || return 1
  jq -n --arg settings "$SETTINGS" --arg ledger "$LEDGER" --arg backups "$BACKUPS" \
    --arg home "$HOME" --arg root "$ROOT" --arg prev_root "$PREV_ROOT" \
    --argjson desired "$desired" --argjson absent "$ABSENT" \
    --argjson forbidden "$(forbidden_approvals)" \
    '{settings: $settings, ledger: $ledger, backups: $backups, home: $home, root: $root,
      prev_root: $prev_root, desired: $desired, absent: $absent, forbidden: $forbidden}'
}

apply_settings() {
  local request result state reason fix newest aside saved shown lines
  if ! request="$(settings_request)"; then
    finding required toolkit "install.sh does not build its own settings" "$ROOT/install.sh"
    return
  fi
  result="$(printf '%s' "$request" | python3 "$ROOT/hooks/lib/settings.py" "$([ "$MODE" = dry ] && echo plan || echo apply)" 2>&1)"
  if ! state="$(jq -er '.settings' <<<"$result" 2>/dev/null)"; then
    finding required toolkit "hooks/lib/settings.py failed: $(printf '%s' "$result" | tail -1)" "$ROOT/hooks/lib/settings.py"
    return
  fi
  # settings.py names absolute paths, which the report writes the way the user
  # types them.
  reason="$(jq -r '.reason // ""' <<<"$result")"
  reason="${reason//"$HOME"\//\~/}"
  fix="$(jq -r '.fix // ""' <<<"$result")"
  newest="$(jq -r '.newest_backup // ""' <<<"$result")"
  [ -z "$newest" ] || reason+=". The newest backup that parses is $(home_path "$newest"), from $(jq -r '.backup_when' <<<"$result")"
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
  reason="$(jq -r '.ledger_unreadable // ""' <<<"$result")"
  if [ -n "$reason" ]; then
    aside="$(jq -r '.ledger_aside // ""' <<<"$result")"
    finding advisory user "the ledger ~/.claude/agent-toolkit-applied.json does not read ($reason), so what the toolkit owns was read back from settings.json for this run, which can only vouch for what the file still holds${aside:+. The old ledger is kept at $(home_path "$aside")}"
  fi
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

# Every file the version directory carries, and nothing else in that directory:
# the dependencies and the build the bridge puts there at its first run are the
# user's, and outlive every version installed over them.
apply_bridge() {
  local path f mode
  for path in "$BRIDGE_SRC"/*; do
    [ -f "$path" ] || continue
    f="$(basename "$path")"
    if [ -x "$path" ]; then mode=755; else mode=644; fi
    cmp -s "$path" "$BRIDGE_DST/$f" && [ "$(stat -c %a "$BRIDGE_DST/$f" 2>/dev/null)" = "$mode" ] && continue
    act "bridge file ~/.claude/tools/penpot-mcp/$f" write_atomic "$BRIDGE_DST/$f" "$mode" <"$path"
  done
}

# Settings name the launcher, so they wait on it.
apply_local() {
  apply_link || return
  apply_launcher || return
  apply_bridge
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
  (cd "$HOME" && CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 GIT_TERMINAL_PROMPT=0 timeout 600 "$CLAUDE" "$@" </dev/null)
}

FAILED_PLUGINS=" "

fetch_failure() { # exit status, output → Claude Code's own message
  local message
  [ "$1" -eq 124 ] && echo "it timed out after 600 seconds" && return
  message="$(grep '^{' <<<"$2" | jq -r '.message // empty' 2>/dev/null)"
  printf '%s' "${message:-$2}" | one_line
}

LISTING=""
FAILED_LISTINGS=" "
listing() { # [marketplace] → the JSON array in LISTING, or a finding and status 1
  local args=(plugin "$@" list --json) said
  # Asking again after it failed once would fetch the same answer and report it
  # a second time.
  [[ "$FAILED_LISTINGS" == *" ${*:-plugin} "* ]] && return 1
  if LISTING="$(claude_cli "${args[@]}")" && jq -e 'type == "array"' <<<"$LISTING" >/dev/null 2>&1; then
    return 0
  fi
  # Run again for what it said, which the call above sends to stderr: on the
  # success path a word of stderr in the listing would break the JSON.
  said="$( (cd "$HOME" && "$CLAUDE" "${args[@]}" </dev/null 2>&1 >/dev/null) | one_line)"
  FAILED_LISTINGS+="${*:-plugin} "
  finding required install "claude ${args[*]} did not answer, so the plugins could not be checked${said:+: $said}" "$(install_command)"
  return 1
}

fetch_plugins() {
  local marketplaces plugins spec id source market out rc asked=" " refused=" "
  listing marketplace || return
  marketplaces="$LISTING"
  for spec in "${PLUGINS[@]}"; do
    id="${spec%% *}" source="${spec#* }" market="${spec%% *}"
    market="${market#*@}"
    jq -e --arg m "$market" 'any(.[]; .name == $m)' <<<"$marketplaces" >/dev/null && continue
    # The listing is taken once, so a marketplace several plugins share would be
    # registered once for each of them without this. One that would not register
    # fails every plugin behind it rather than being asked for again.
    if [[ "$asked" == *" $market "* ]]; then
      [[ "$refused" != *" $market "* ]] || FAILED_PLUGINS+="$id "
      continue
    fi
    asked+="$market "
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
      refused+="$market "
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
}

# ── version stamp ────────────────────────────────────────────────────────────
# Written only while no required finding stands, so the status line never shows
# a version as applied when it is not, and only while this directory is the one
# the stable link points at.
apply_stamp() {
  local out rc
  [ "$MODE" = dry ] || [ "$(resolve "$STABLE")" = "$ROOT" ] || return 0
  out="$(python3 "$ROOT/hooks/lib/version.py" root "$ROOT" 2>&1)"
  rc=$?
  case "$rc" in
    0) ;;
    3) finding advisory install "git did not report the version in time, so the version stamp was left as it was" "$(install_command)" && return ;;
    4) finding advisory user "git cannot read the version directory's history, so the version stamp was left as it was: $(printf '%s' "$out" | one_line)" \
      "git -C $(home_path "$ROOT") status" && return ;;
    5) finding advisory user "the version stamp was left as it was: $(printf '%s' "$out" | one_line)" \
      "ls -l $(home_path "$ROOT")" && return ;;
    *) finding advisory toolkit "hooks/lib/version.py failed, so the version stamp was left as it was" "$ROOT/hooks/lib/version.py"$'\n'"$(printf '%s' "$out" | tail -1)" && return ;;
  esac
  if [ -z "$out" ]; then
    [ ! -e "$STAMP" ] || act "version stamp removed: this version directory has no version" rm -f "$STAMP"
  elif [ "$(count required)" -eq 0 ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$out" ]; then
    act "version stamp $out" write_atomic "$STAMP" 644 <<<"$out"
  fi
}

# ── reports ──────────────────────────────────────────────────────────────────
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

# A skill link applied cleanly is not reported, but at session start still asks
# for a rescan.
report_hook() {
  local i required names=() reload=0
  required="$(count required)"
  [ "$EVENT" = SessionStart ] && [ "$SKILLS_CHANGED" -eq 1 ] && reload=1
  for i in "${WROTE[@]}"; do
    CONTEXT+=("wrote $i")
    names+=("${i%% *}")
  done
  for i in "${REMOVED[@]}"; do CONTEXT+=("$i"); done
  [ "$required" -eq 0 ] || MESSAGE+=("$(plural "$required" problem). Ask Claude to fix it, or run ~/.claude/agent-toolkit/install.sh")
  [ ${#WROTE[@]} -eq 0 ] || MESSAGE+=("Updated $(join ", " "${names[@]}")")
  if [ ${#RESTART[@]} -gt 0 ]; then
    MESSAGE+=("Restart Claude Code to load it")
    CONTEXT+=("Restart Claude Code: $(restart_reasons).")
  fi
  hook_report "$EVENT" "agent-toolkit doctor:" "$reload"
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

# What a --sync run is, in the report's words.
occasion() { [ "${EVENT:-}" = PostToolUse ] && echo "this edit" || echo "this session start"; }

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
  check_location && check_layout && check_root && ready=1

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
            finding advisory install "another install held the lock for 5 seconds, so $(occasion) applied nothing" "$(install_command)"
          else
            finding required install "another install held the lock for a minute, so nothing was applied" "$(install_command)"
          fi
          ;;
        *) finding required user "the apply lock on ~/.claude could not be taken, so nothing was applied: $LOCK_ERROR" "$LOCK_FIX" ;;
      esac
      exec 9<&-
    fi
  fi

  if check_claude && [ "$ready" -eq 1 ]; then
    [ "$MODE" = sync ] || fetch_plugins
    check_plugins
  fi
  [ "$MODE" = sync ] || check_access
  check_retro
  [ "$ready" -eq 1 ] && apply_stamp
  finish
}

main "$@"
