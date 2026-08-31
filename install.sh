#!/usr/bin/env bash
# Install or repair this toolkit on a machine.
#
#   ./install.sh            full install: symlink, skills, agents, settings, pointer, doctor
#   ./install.sh --sync     session-start mode: re-link and re-check, print only problems
#   ./install.sh --dry-run  show every change a full install would make, write nothing
#
# Device config points at the stable path ~/.claude/agent-toolkit, a symlink
# this script owns, so moving the checkout is repaired by re-running from the
# new location — only the symlink changes.
set -uo pipefail

# pwd -P: --sync runs through the stable symlink, and the logical path would
# make ln -sfn point the symlink at itself.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLAUDE_DIR="$HOME/.claude"
STABLE="$CLAUDE_DIR/agent-toolkit"
SETTINGS="$CLAUDE_DIR/settings.json"
POINTER="$CLAUDE_DIR/CLAUDE.md"
SCRATCH="/tmp/claude-$(id -u)"
AGENTS_DST="$CLAUDE_DIR/agents"
MANIFEST="$AGENTS_DST/.toolkit-agents"
MODE="${1:-full}"
ts="$(date +%Y%m%d-%H%M%S)"
problems=0

say()  { [ "$MODE" != "--sync" ] && echo "$@" || true; }
warn() { echo "agent-toolkit: ✗ $*"; problems=$((problems + 1)); }
need() { command -v "$1" >/dev/null 2>&1 || warn "missing dependency: $1"; }
need jq; need python3; need git

# Where the checkout lived at the last install. Read before section 1 re-aims
# the symlink, so a moved checkout can be dropped from the approved directories.
PREV_ROOT="$(readlink "$STABLE" 2>/dev/null || true)"

# ── 1. stable symlink ────────────────────────────────────────────────────────
if [ "$MODE" = "--dry-run" ]; then
  cur="$(readlink "$STABLE" 2>/dev/null || echo "<none>")"
  [ "$cur" = "$ROOT" ] || echo "symlink: $STABLE → $ROOT (was $cur)"
else
  mkdir -p "$CLAUDE_DIR"
  [ "$(readlink "$STABLE" 2>/dev/null)" = "$ROOT" ] || ln -sfn "$ROOT" "$STABLE"
fi

# ── 2. skills — symlinked, so an edit is live without re-installing ──────────
skill_count="$(find "$ROOT/skills" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "$MODE" = "--dry-run" ]; then
  echo "skills: $skill_count symlinked into $CLAUDE_DIR/skills"
else
  mkdir -p "$CLAUDE_DIR/skills"
  # -sfn so a moved skill repoints instead of nesting inside the old link.
  find "$ROOT/skills" -name SKILL.md -print0 2>/dev/null | while IFS= read -r -d '' f; do
    d="$(dirname "$f")"
    ln -sfn "$d" "$CLAUDE_DIR/skills/$(basename "$d")"
  done
  find "$CLAUDE_DIR/skills" -maxdepth 1 -type l ! -exec test -e {} \; -delete
  # Links into the checkout we replaced still resolve, so they survive the prune
  # above and keep firing skills this toolkit no longer has. Only that one path
  # is swept, never anything the user linked themselves.
  if [ -n "$PREV_ROOT" ] && [ "$PREV_ROOT" != "$ROOT" ]; then
    for l in "$CLAUDE_DIR"/skills/*; do
      [ -L "$l" ] || continue
      case "$(readlink "$l")" in "$PREV_ROOT"/skills/*) rm -f "$l"; say "  - unlinked stale skill $(basename "$l")" ;; esac
    done
  fi
fi

# ── 3. agents — copied, because the agents file watcher does not reliably
# follow symlinks. The manifest names what this toolkit owns, so a renamed or
# retired agent is pruned without touching agents the user wrote. ────────────
agent_count="$(ls "$ROOT"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "$MODE" = "--dry-run" ]; then
  echo "agents: $agent_count copied into $AGENTS_DST"
else
  mkdir -p "$AGENTS_DST"
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && [ ! -f "$ROOT/agents/$name" ] && rm -f "$AGENTS_DST/$name"
    done < "$MANIFEST"
  fi
  : > "$MANIFEST.tmp"
  for a in "$ROOT"/agents/*.md; do
    [ -e "$a" ] || continue
    n="$(basename "$a")"
    if ! cmp -s "$a" "$AGENTS_DST/$n" 2>/dev/null; then
      # A file we do not already own is the user's — keep a dated copy.
      if [ -f "$AGENTS_DST/$n" ] && ! grep -qxF "$n" "$MANIFEST" 2>/dev/null; then
        mkdir -p "$CLAUDE_DIR/backups/agents"
        cp "$AGENTS_DST/$n" "$CLAUDE_DIR/backups/agents/$n.$ts"
        say "  ! kept your existing $n → backups/agents/$n.$ts"
      fi
      cp -f "$a" "$AGENTS_DST/$n"
    fi
    printf '%s\n' "$n" >> "$MANIFEST.tmp"
  done
  mv "$MANIFEST.tmp" "$MANIFEST"
  "$ROOT/hooks/reap.sh" </dev/null >/dev/null 2>&1 || true
fi

# ── 4. settings.json ─────────────────────────────────────────────────────────
# The wiring is declared once here: the merge builds settings.json from it, and
# the doctor checks the installed file against it. Neither side can drift.
# Commands are relative to $STABLE; matcher "" means the event takes none.
#
# Notification events (Notification, Stop) are deliberately absent — the
# claude-notifications-go plugin owns them, and its suppressForSubagents keeps
# a sub-agent finishing from ever being a false cue.
#
# taskline must stay synchronous: only a hook that finishes before the turn does
# has its stdout injected as context, and an async one would print into the void.
#
# The retro recorder is the mirror image: async on every event, so it can neither
# block a turn nor inject its stdout. No single trigger is load-bearing —
# whichever fires first catches up everything the others missed — and --interval
# is the whole scheduling mechanism, so nothing lands outside this repo and
# ~/.claude.
WIRING='[
  {"event":"SessionStart","matcher":"startup|resume|clear|compact|fork",
   "hooks":[{"command":"/install.sh --sync"}]},
  {"event":"SessionStart","matcher":"",
   "hooks":[{"command":"/hooks/retro.py record","async":true}]},
  {"event":"PreCompact","matcher":"",
   "hooks":[{"command":"/hooks/retro.py record","async":true}]},
  {"event":"UserPromptSubmit","matcher":"",
   "hooks":[{"command":"/hooks/taskline.py"},
            {"command":"/hooks/retro.py record --interval 900","async":true}]},
  {"event":"PreToolUse","matcher":"Bash",
   "hooks":[{"command":"/hooks/guard.sh"}]},
  {"event":"PreToolUse","matcher":"mcp__linear.*",
   "hooks":[{"command":"/hooks/guard.sh"}]},
  {"event":"PostToolUse","matcher":"Write|Edit",
   "hooks":[{"command":"/hooks/sync.sh"},
            {"command":"/hooks/format.sh","async":true}]},
  {"event":"SessionEnd","matcher":"",
   "hooks":[{"command":"/hooks/reap.sh"},
            {"command":"/hooks/retro.py record","async":true}]}
]'

# No apostrophes anywhere in the jq program below — it is a single-quoted shell
# argument, and two of them balance out, so bash accepts the script while jq
# receives a program truncated at the first one. A truncated program writes a
# settings.json with the statusline and every hook missing, and reports success.
desired_settings() {
  jq --arg base "$STABLE" --arg cfg "$CLAUDE_DIR" --arg root "$ROOT" \
     --arg scratch "$SCRATCH" --arg prev "$PREV_ROOT" --argjson wiring "$WIRING" '
    # install-skills is matched so hook entries written by the previous
    # generation of this toolkit are cleaned out rather than left to run.
    def ours: test("agent-toolkit|install-skills");
    def clean(a): (a // [])
      | map(select((((.hooks // []) | map(.command // "") | join(" ")) | ours) | not));

    # Directories an agent works in outside the repo it was started in. A path
    # inside one is approved before any rule is consulted, for writes as much as
    # reads, which is what stops a background agent stalling on a prompt.
    def dirs: [$cfg, $scratch, $root];
    # A checkout that moved: drop the path it used to live at rather than leave
    # it write-approved for whatever occupies it next.
    def stale: [$prev] | map(select(length > 0 and . != $root));
    # ~/.claude is approved wholesale above, which would otherwise hand over the
    # credentials file and the settings files, whose env block carries MCP tokens
    # on machines this toolkit travels to. A deny is evaluated first, and governs
    # the Read tool only, so jq and python still reach settings.
    # The leading slash is doubled because $cfg is already absolute; a single one
    # anchors the pattern at the settings directory, where it matches nothing.
    def denied: ["Read(/" + $cfg + "/.credentials.json)",
                 "Read(/" + $cfg + "/settings*.json)",
                 "Read(/" + $cfg + "/backups/settings.json.*)",
                 "Read(/" + $cfg + "/backups/.claude.json.backup.*)"];

    # Depth 2 lets a subagent spawn one layer of its own and no further: the
    # developer and reviewer need it to run their review agents.
    # CLAUDE_CODE_ENABLE_TODO_TOOLS opts out of a vendor deprecation: the task
    # tools are removed by default for this generation of models, and without
    # them the task list this toolkit runs on cannot exist. Written over whatever
    # is there, because a session without the task tools is not one we support.
    # Agent teams spawn whole parallel Claude sessions as teammates, which is a
    # different model from one session delegating to subagents. Deleted rather
    # than merely not written, so an earlier install stops enabling it.
    # CLAUDE_CODE_ENABLE_TASKS is deleted by neither: it is opt-out only, so
    # setting it changes nothing and deleting it would discard a deliberate off.
    .env = ((.env // {}) + {CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH: "2",
                            CLAUDE_CODE_ENABLE_TODO_TOOLS: "1"}
            | del(.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS))

    # Sessions on this machine work on different projects and must not reach
    # into each other. Cross-session messaging is on by default, so it is closed
    # here explicitly. This governs the peer socket only, so an agent inside this
    # session still messages main over SendMessage, which is how it asks a
    # question mid-run. A message to another machine is outward-facing, so it
    # takes an approval like any other.
    | .crossSessionInbound = "refuse"
    | .isolatePeerMachines = true

    # Auto mode is what lets an agent finish unattended. It is safe because the
    # guard hook fires independently of permission mode and re-introduces a
    # prompt exactly where one is wanted.
    | .permissions = ((.permissions // {}) + {defaultMode: "auto"})
    | .permissions.additionalDirectories =
        (((.permissions.additionalDirectories // []) - (dirs + stale)) + dirs)
    | .permissions.deny = (((.permissions.deny // []) - denied) + denied)

    # Mechanical version of the no-attribution rule.
    | .includeCoAuthoredBy = false

    # The agents spawned as review gates live in pr-review-toolkit; the turn-is-
    # yours notifications live in claude-notifications-go. Every other plugin is
    # the users own choice and is left alone.
    | .enabledPlugins = ((.enabledPlugins // {})
        + {"pr-review-toolkit@claude-plugins-official": true,
           "claude-notifications-go@claude-notifications-go": true})

    | .statusLine = {type: "command", command: ($base + "/hooks/statusline.py"), padding: 0}

    # Every event is cleaned of our entries first, including events we no longer
    # wire, so retiring one cleans up after itself. Only arrays are cleaned: a
    # malformed foreign entry is left alone rather than failing the whole merge,
    # which would write nothing and report success.
    | .hooks = (reduce $wiring[] as $w (
        ((.hooks // {}) | with_entries(if (.value | type) == "array"
                                       then .value = clean(.value) else . end));
        .[$w.event] = ((.[$w.event] // []) + [
          (if $w.matcher == "" then {} else {matcher: $w.matcher} end)
          + {hooks: ($w.hooks | map({type: "command", command: ($base + .command)}
                                    + (if .async then {async: true} else {} end)))}]))
        | with_entries(select((.value | length) > 0)))
  ' "$1"
}

if [ ! -f "$SETTINGS" ]; then
  case "$MODE" in
    --dry-run) echo "settings: $SETTINGS would be created" ;;
    --sync)    warn "settings.json missing — run: $STABLE/install.sh" ;;
    *)         printf '{}\n' > "$SETTINGS" ;;
  esac
fi
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  new="$(desired_settings "$SETTINGS")"; rc=$?
  # A merge that aborted looks exactly like "nothing to change" — jq exits
  # non-zero with no output when, say, permissions.allow is a string. Branch on
  # the status, and on empty output from a non-empty file, or a failed install
  # reports success and stamps a version it never applied.
  if [ "$rc" -ne 0 ] || { [ -z "$new" ] && [ -s "$SETTINGS" ]; }; then
    warn "settings.json merge failed — nothing applied. Run: $STABLE/install.sh"
  elif ! printf '%s\n' "$new" | cmp -s - "$SETTINGS"; then
    case "$MODE" in
      --dry-run)
        echo "settings: $SETTINGS would change:"
        printf '%s\n' "$new" | diff -u "$SETTINGS" - | sed 's/^/  /' | head -200
        ;;
      --sync) warn "settings.json is stale — run: $STABLE/install.sh" ;;
      *)
        mkdir -p "$CLAUDE_DIR/backups"
        cp "$SETTINGS" "$CLAUDE_DIR/backups/settings.json.$ts"
        printf '%s\n' "$new" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
        say "✓ settings.json updated (backup: backups/settings.json.$ts)"
        ;;
    esac
  else
    say "✓ settings.json already current"
  fi
fi

# ── 5. device pointer ────────────────────────────────────────────────────────
pointer_content() {
  cat <<EOF
# Global instructions

Everything lives in the portable agent-toolkit repo. This file is only this device's pointer to it. New rules go into the toolkit, never here.

@$STABLE/CLAUDE.md
EOF
}

if ! pointer_content | cmp -s - "$POINTER" 2>/dev/null; then
  case "$MODE" in
    --dry-run)
      echo "pointer: $POINTER would change:"
      pointer_content | diff -u "$POINTER" - 2>/dev/null | sed 's/^/  /' | head -20
      ;;
    --sync) warn "~/.claude/CLAUDE.md does not point at $STABLE — run: $STABLE/install.sh" ;;
    *)
      mkdir -p "$CLAUDE_DIR/backups"
      [ -f "$POINTER" ] && cp "$POINTER" "$CLAUDE_DIR/backups/CLAUDE.md.$ts"
      pointer_content > "$POINTER"
      say "✓ ~/.claude/CLAUDE.md points at $STABLE"
      ;;
  esac
else
  say "✓ ~/.claude/CLAUDE.md already current"
fi

# ── 6. retro store ───────────────────────────────────────────────────────────
# The since marker is stamped once, at first install, and never rewritten: it is
# what keeps every transcript written before this toolkit out of the data.
if [ "$MODE" = "--dry-run" ]; then
  [ -f "$CLAUDE_DIR/retro/since" ] || echo "retro: $CLAUDE_DIR/retro/since would be created"
else
  mkdir -p "$CLAUDE_DIR/retro"
  [ -f "$CLAUDE_DIR/retro/since" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$CLAUDE_DIR/retro/since"
fi

# ── 7. doctor ────────────────────────────────────────────────────────────────
for f in "$ROOT"/hooks/*.sh "$ROOT"/hooks/*.py "$ROOT/install.sh"; do
  [ -x "$f" ] || warn "not executable: $f"
done

# The python hooks import their shared modules inside their own guards, and a
# hook that will not compile is just as quiet: both cost a statusline segment
# and the whole task line while still exiting clean. This is what says so out
# loud, and it carries the interpreter's own last line so the reason is not lost.
if command -v python3 >/dev/null 2>&1; then
  if ! err="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import lib.out, lib.tasks' \
              "$ROOT/hooks" 2>&1)"; then
    warn "hooks/lib does not import — $(printf '%s' "$err" | tail -1)"
  fi
  if ! err="$(python3 -m py_compile "$ROOT"/hooks/*.py "$ROOT"/hooks/lib/*.py 2>&1)"; then
    warn "a python hook does not compile — $(printf '%s' "$err" | tail -1)"
  fi
  # Advisory, like the plugin lines below: a re-install cannot add a missing
  # stdlib module, so it must not withhold the version stamp. The recorder is
  # inert without it and every other hook is unaffected.
  python3 -c 'import sqlite3' >/dev/null 2>&1 \
    || echo "agent-toolkit: ! python3 has no sqlite3 module — the retro recorder cannot store anything"
  # The recorder degrades to silence by design, so silence is not evidence that
  # it is working. This is what tells the difference: a marker it can read, and
  # a store it can open at a schema it knows.
  retro_state="$(python3 - "$ROOT/hooks" <<'PY' 2>/dev/null || true
import os
import sys

# retro.py's own answers, not a second copy of them: it owns where the store
# lives, what a marker has to look like and which schema it reads, and a doctor
# that re-derived any of those would drift from it in silence.
sys.path.insert(0, sys.argv[1])
source = open(os.path.join(sys.argv[1], "retro.py")).read()
recorder = {}
exec(compile(source.replace('if __name__ == "__main__":', "if False:"), "retro", "exec"), recorder)

try:
    with open(recorder["SINCE_PATH"]) as f:
        raw = f.read(64).strip()
except OSError:
    raw = None
if raw is None:
    print("retro/since is missing — nothing will be recorded until it is stamped")
elif recorder["parse_iso"](raw) is None:
    print("retro/since is not a timestamp (%r) — nothing is being recorded" % raw[:32])

if os.path.exists(recorder["DB_PATH"]):
    problem = recorder["store_problem"]()
    # store_problem answers for a store that will not open at all; one that
    # opens and reads clean has nothing to say.
    if recorder["open_store"](create=False) is None:
        print(problem)
PY
)"
  # One line each: the block can report a marker and a store in the same breath,
  # and a single prefixed echo would label the first and orphan the second.
  # --dry-run wrote nothing, so it does not also complain that nothing is there;
  # it has already said it would create it.
  # The || keeps the last line: the block's output has no trailing newline, and
  # read reports failure on it while still having filled the variable.
  printf '%s' "$retro_state" | while IFS= read -r problem || [ -n "$problem" ]; do
    [ -z "$problem" ] && continue
    case "$MODE:$problem" in
      --dry-run:*"since is missing"*) continue ;;
    esac
    echo "agent-toolkit: ! $problem"
  done
fi

# Our wiring must be present, not merely valid. Checking only the paths found in
# settings passes a settings.json that lost every hook — there is nothing left to
# check — and the next --sync compares it against the same output and calls it
# current, so the whole gate can vanish while both checks report green.
if [ "$MODE" != "--dry-run" ] && [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  if ! gone="$(jq -r --argjson want "$WIRING" --arg base "$STABLE" '
    [ $want[] as $w | $w.hooks[] as $h
      | {event: $w.event, matcher: $w.matcher, command: ($base + $h.command)} ] as $want_t
    | [ (.hooks // {}) | to_entries[] as $ev | $ev.value[] as $e | ($e.hooks // [])[] as $h
        | {event: $ev.key, matcher: ($e.matcher // ""), command: ($h.command // "")} ] as $have_t
    | (if ((.statusLine.command // "") | test("agent-toolkit")) then [] else ["statusLine"] end)
      + (($want_t - $have_t) | map(.event + "[" + .matcher + "] " + .command))
    | join(", ")' "$SETTINGS" 2>/dev/null)"; then
    warn "cannot verify the wiring (unreadable settings.json) — run: $STABLE/install.sh"
  elif [ -n "$gone" ]; then
    warn "settings.json is missing wiring ($gone) — run: $STABLE/install.sh"
  fi
  # Every referenced hook path must exist and run.
  while IFS= read -r cmd; do
    case "$cmd" in
      "$STABLE"/*".sh "*) exe="${cmd%".sh "*}.sh" ;;
      "$STABLE"/*".py "*) exe="${cmd%".py "*}.py" ;;
      /*)                 exe="${cmd%% *}" ;;
      *)                  continue ;;
    esac
    [ -x "$exe" ] || warn "settings references a missing or non-executable command: $exe"
  done < <(jq -r '([.statusLine.command] + [.hooks[]?[]?.hooks[]?.command]) | .[]? // empty' "$SETTINGS" 2>/dev/null)
fi

if [ -f "$POINTER" ]; then
  # The import path is the whole rest of the line, so a home directory with a
  # space in it is not truncated.
  while IFS= read -r imp; do
    [ -e "${imp#@}" ] || warn "~/.claude/CLAUDE.md imports a missing file: ${imp#@}"
  done < <(grep -oE '^@/.+' "$POINTER" || true)
fi

if [ "$MODE" != "--dry-run" ]; then
  linked="$(find "$CLAUDE_DIR/skills" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
  [ "$linked" -ge "$skill_count" ] || warn "only $linked of $skill_count skills are linked"
  copied=0
  for a in "$ROOT"/agents/*.md; do
    [ -e "$a" ] && cmp -s "$a" "$AGENTS_DST/$(basename "$a")" 2>/dev/null && copied=$((copied + 1))
  done
  [ "$copied" -ge "$agent_count" ] || warn "only $copied of $agent_count agents are installed and current"
fi

# Enabling a plugin is not installing it. Advisory rather than a failure: a
# re-install cannot fix it, so it must not withhold the version stamp.
if [ "$MODE" != "--dry-run" ] && command -v jq >/dev/null 2>&1; then
  for p in pr-review-toolkit@claude-plugins-official \
           claude-notifications-go@claude-notifications-go; do
    jq -e --arg k "$p" '(.plugins[$k] // []) | length > 0' \
      "$CLAUDE_DIR/plugins/installed_plugins.json" >/dev/null 2>&1 \
      || echo "agent-toolkit: ! plugin $p is enabled but not installed — see README"
  done
  ncfg="$CLAUDE_DIR/claude-notifications-go/config.json"
  [ ! -f "$ncfg" ] || jq -e '.notifications.suppressForSubagents == true' "$ncfg" >/dev/null 2>&1 \
    || echo "agent-toolkit: ! notifications fire for sub-agents — set notifications.suppressForSubagents to true in $ncfg"
fi

# ── 8. version stamp ─────────────────────────────────────────────────────────
# The statusline shows this and flags it once the repo moves past it. Any run
# that actually applies something stamps; only --dry-run is excluded. Held back
# while a problem stands, so the light never claims changes are applied when a
# stale settings.json means they are not.
if [ "$MODE" != "--dry-run" ] && [ "$problems" -eq 0 ] && git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
  printf 'v%s·%s\n' "$(git -C "$ROOT" rev-list --count HEAD)" \
                    "$(git -C "$ROOT" rev-parse --short HEAD)" > "$CLAUDE_DIR/agent-toolkit-version"
fi

if [ "$problems" -eq 0 ]; then
  say "✓ all checks green ($skill_count skills, $agent_count agents, wired via $STABLE)"
else
  say "$problems problem(s) above"
  exit 1
fi
