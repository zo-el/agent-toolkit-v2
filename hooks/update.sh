#!/usr/bin/env bash
# Find the release this machine should run, unpack it in the background, and
# install it at the next safe point.
#
# Contract: documentation/specs/release.md.
set -uo pipefail
# Hooks run in the session's project directory, and python puts the working
# directory first on its import path: a project's own re.py would run here.
export PYTHONDONTWRITEBYTECODE=1 PYTHONSAFEPATH=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CLAUDE_DIR="$HOME/.claude"
STABLE="$CLAUDE_DIR/agent-toolkit"
RELEASES="$CLAUDE_DIR/agent-toolkit-releases"
TRACK="$CLAUDE_DIR/agent-toolkit-track"
RECORD="$CLAUDE_DIR/agent-toolkit-staging.json"
REPO="zo-el/agent-toolkit-v2"

# A root reaching this without its shared halves failed install's root checks and
# never went live, so this says so once rather than reporting from half a library.
# shellcheck source=/dev/null
. "$ROOT/hooks/lib/report.sh" 2>/dev/null && . "$ROOT/hooks/lib/requirements.sh" 2>/dev/null || {
  printf 'agent-toolkit: hooks/lib is incomplete in %s, so updates are off\n' "$ROOT" >&2
  exit 1
}

# A check that began less than this ago does nothing, and a machine that has not
# had one succeed in this long is worth telling. now ignores the first.
THROTTLE=21600
STALE=604800
# The whole of stage, bounded, so a hung network leaves no process behind.
STAGE_SECONDS=300

UPDATE_NOW="~/.claude/agent-toolkit/hooks/update.sh now"
INSTALL_AGAIN="~/.claude/agent-toolkit/install.sh"

usage() {
  cat <<'EOF'
usage: update.sh [stage | apply | now | --help]

  stage   find a release and unpack it, in the background. Prints nothing
  apply   install a release already unpacked, and report. Used by a hook
  now     the whole cycle in the foreground, whatever the throttle says
  --help  this text

exit: stage and apply always 0. now 0 when the wanted release is installed here,
1 when it is not. 2 bad arguments.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

now_seconds() { date -u +%s; }

# version.py prints the reason it could not answer on stdout, so a caller that
# read stdout without the status would take that sentence for a version and go on
# reinstalling a machine that is already where it should be.
version() { # version.py arguments → its answer, or nothing when it did not answer
  local out
  out="$(python3 "$ROOT/hooks/lib/version.py" "$@" 2>/dev/null)" && printf '%s' "$out"
}

# seal.py says on stderr why it could not read a tree, which is worth carrying
# where there is a workspace to hold it.
SEAL_REASON=/dev/null
take_seal() { # a version directory → its content digest, or nothing
  local out
  out="$(python3 "$ROOT/hooks/lib/seal.py" "$1" 2>"$SEAL_REASON")" && printf '%s' "$out"
}

sealed() { jq -r --arg v "$1" '.seals[$v] // empty' <<<"$RECORD_JSON" 2>/dev/null; }

# One program answers every version question, so a machine where it cannot run is
# told that, rather than told its own track file and its own releases are wrong.
version_reader_works() { version release v1.0.0 >/dev/null; }

# Every path the updater compares goes through this, because the stable link
# resolves every component of its target and $HOME does not: a home reached
# through a symlink would otherwise make each comparison read as a difference.
real_path() { (cd "$1" 2>/dev/null && pwd -P); }

live_root() { real_path "$STABLE"; }

# Nothing behind the stable link is not the working directory: a hook runs in a
# project, which may well be a git work tree with a VERSION of its own.
live_version() {
  local root
  root="$(live_root)"
  [ -n "$root" ] && version root "$root"
}

# ── the track ────────────────────────────────────────────────────────────────
TRACK_STATE=""
WANTED=""

# A file with nothing in it says nothing to misread, so it means what no file
# means. Everything else is returned as written, for the finding that quotes it.
track_line() {
  local raw
  raw="$(head -c 257 "$TRACK" 2>/dev/null)"
  raw="${raw//$'\r'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  printf '%s' "${raw%"${raw##*[![:space:]]}"}"
}

judge_track() {
  local line
  line="$(track_line)"
  case "$line" in
    "" | latest) TRACK_STATE=latest ;;
    off) TRACK_STATE=off ;;
    *)
      # A release name and nothing else: v1.5.0 stands for itself, while a whole
      # version or a bare number stands for something only the user can settle.
      if [ "$(version release "$line")" = "$line" ]; then
        TRACK_STATE=pin WANTED="$line"
      else
        TRACK_STATE=bad
        finding required user "~/.claude/agent-toolkit-track holds \"$(printf '%s' "$line" | one_line)\", so nothing is checked, downloaded or applied. It holds latest, a release such as v1.5.0, or off" \
          "edit or remove ~/.claude/agent-toolkit-track"
      fi
      ;;
  esac
}

# ── the record ───────────────────────────────────────────────────────────────
# One JSON object, replaced whole. Times are epoch seconds, so no run parses a
# date and no locale decides what a machine does.
RECORD_JSON="{}"
RECORD_DIRTY=0

read_record() {
  [ -e "$RECORD" ] || return 0
  RECORD_JSON="$(jq -ce 'select(type == "object" and ((.seals // {}) | type == "object"))' "$RECORD" 2>/dev/null)" && return 0
  RECORD_JSON='{"replaced":true}'
}

recorded() { jq -r "$1 // empty" <<<"$RECORD_JSON" 2>/dev/null; }

record_set() { # jq filter, then jq arguments
  local filter="$1" next
  shift
  next="$(jq -c "$@" "$filter" <<<"$RECORD_JSON" 2>/dev/null)" || return 1
  RECORD_JSON="$next" RECORD_DIRTY=1
}

record_write() {
  local tmp
  [ "$RECORD_DIRTY" -eq 1 ] || return 0
  mkdir -p "$CLAUDE_DIR" 2>/dev/null || return 1
  tmp="$(mktemp "$CLAUDE_DIR/.agent-toolkit-staging.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$RECORD_JSON" >"$tmp" 2>/dev/null && mv -T "$tmp" "$RECORD" 2>/dev/null && return 0
  rm -f "$tmp"
  return 1
}

# What stopped this run, for the apply that reports it. The severity says whether
# the release itself is wrong or the machine simply could not ask.
record_failure() { # severity, text, fix
  record_set '.failure = {severity: $s, text: $t, fix: $f}' \
    --arg s "$1" --arg t "$2" --arg f "${3:-}"
}

# ── locks ────────────────────────────────────────────────────────────────────
# The updater's own locks, so staging never delays an install and no session
# start waits out another session's activation. A lock held by another run is an
# answer; anything else is a failure, and reading the two as one would leave a
# machine that cannot lock at all updating in silence for good.
LOCK_PROBLEM=""

lock_is_takeable() { # the lock file
  LOCK_PROBLEM=""
  have flock || { LOCK_PROBLEM="flock is not on PATH, so no update can be serialised"; return 1; }
  : >>"$1" 2>/dev/null && return 0
  LOCK_PROBLEM="${1/#$HOME/\~} cannot be written, so no update can be serialised"
  return 1
}

take_stage_lock() {
  lock_is_takeable "$RELEASES/.stage.lock" || return 1
  exec 8<"$RELEASES/.stage.lock" 2>/dev/null || {
    LOCK_PROBLEM="~/.claude/agent-toolkit-releases/.stage.lock cannot be opened"
    return 1
  }
  flock -n 8 2>/dev/null
}

# ── GitHub ───────────────────────────────────────────────────────────────────
# Every call bounded, so a hung network cannot hold a session start or outlive
# the run that made it.
GH_SECONDS=60
GH_ERROR=""
GH_404=0

# The body lands in a file rather than on stdout: a caller reading it through a
# command substitution would run this in a subshell, where GH_404 and GH_ERROR
# would die with the subshell and every failure would read as an empty reason.
gh_read() { # api arguments → 0 with the body in $WORK/body
  GH_ERROR="" GH_404=0
  timeout "$GH_SECONDS" gh api "$@" >"$WORK/body" 2>"$WORK/gh.err" && return 0
  grep -q 'HTTP 404' "$WORK/gh.err" 2>/dev/null && GH_404=1
  GH_ERROR="$(one_line <"$WORK/gh.err")"
  return 1
}

body_field() { jq -r "$1 // empty" "$WORK/body" 2>/dev/null; }

gh_gave_no_answer() {
  record_failure advisory "the last update check failed: $GH_ERROR" ""
  return 1
}

# gh is the whole of the machine's reach, so a machine without it, or without a
# token, is told rather than left checking nothing in silence.
gh_is_ready() {
  have gh || {
    record_failure advisory "the last update check failed: gh is not on PATH" "$INSTALL_AGAIN"
    return 1
  }
  timeout 10 gh auth token --hostname github.com >/dev/null 2>&1 && return 0
  record_failure advisory "the last update check failed: gh holds no token for github.com" "$GH_LOGIN"
  return 1
}

# ── the cycle ────────────────────────────────────────────────────────────────
COMMIT=""
TARGET=""
STAGE_REASON=""  # what now prints when there is nothing to install
ACTIVATED=0

# A 404 is not an answer on its own: GitHub answers 404 rather than 403 for a
# repository a token cannot see, so that and a repository with no release read
# the same.
resolve_release() {
  local path tag
  case "$TRACK_STATE" in
    pin) path="repos/$REPO/releases/tags/$WANTED" ;;
    *) path="repos/$REPO/releases/latest" ;;
  esac
  if ! gh_read "$path"; then
    [ "$GH_404" -eq 1 ] || gh_gave_no_answer || return 1
    if ! gh_read "repos/$REPO"; then
      record_failure advisory "the last update check failed: gh cannot see $REPO" "$GH_LOGIN"
      return 1
    fi
    if [ "$TRACK_STATE" = pin ]; then
      record_failure required "~/.claude/agent-toolkit-track names $WANTED, which nobody has published, so nothing is downloaded" \
        "edit ~/.claude/agent-toolkit-track to a release that exists, or to latest"
      return 1
    fi
    # Nothing is wrong with a repository whose first release is still to come.
    check_succeeded
    STAGE_REASON="no release has been published yet"
    return 1
  fi
  tag="$(body_field .tag_name)"
  if [ "$(version release "$tag")" != "$tag" ] || [ -z "$tag" ]; then
    record_failure required "the release GitHub reports is tagged \"$(printf '%s' "$tag" | one_line)\", which is not a release name such as v1.5.0" ""
    return 1
  fi
  WANTED="$tag"
  resolve_commit
}

# An annotated tag carries the commit one object further in.
resolve_commit() {
  local kind
  gh_read "repos/$REPO/git/ref/tags/$WANTED" \
    || gh_gave_no_answer || return 1
  COMMIT="$(body_field .object.sha)"
  kind="$(body_field .object.type)"
  if [ "$kind" = tag ]; then
    gh_read "repos/$REPO/git/tags/$COMMIT" \
      || gh_gave_no_answer || return 1
    COMMIT="$(body_field .object.sha)"
  fi
  case "$COMMIT" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) return 0 ;;
    *) record_failure advisory "the last update check failed: $WANTED carries no commit" "" ;;
  esac
  return 1
}

# now ignores the bad mark, which is what a machine does after fixing the cause.
judge_release() {
  local live
  live="$(live_version)"
  if [ -n "$live" ] && [ "$(version release "$live")" = "$WANTED" ] && ! in_dev_mode; then
    TARGET="$(live_root)"
    STAGE_REASON="$WANTED is already the live version"
    return 1
  fi
  if [ -d "$RELEASES/$WANTED" ]; then
    TARGET="$RELEASES/$WANTED"
    STAGE_REASON="$WANTED is already unpacked and waiting for the next session start"
    return 1
  fi
  if [ "$MODE" != now ] && listed .bad "$WANTED"; then
    STAGE_REASON="$WANTED did not install here and is not tried again until the wanted release changes"
    return 1
  fi
  return 0
}

download() {
  timeout "$GH_SECONDS" gh api "repos/$REPO/tarball/$COMMIT" >"$WORK/archive.tgz" 2>"$WORK/gh.err" \
    && [ -s "$WORK/archive.tgz" ] && return 0
  record_failure advisory "the last update check failed: $WANTED would not download: $(one_line <"$WORK/gh.err")" ""
  return 1
}

# The commit id a git archive carries, in its pax global header. Non-zero when
# the file will not open at all, which is a question nobody answered rather than
# an archive carrying the wrong commit.
archive_commit() {
  python3 -c '
import sys
import tarfile

try:
    archive = tarfile.open(sys.argv[1])
except Exception as reason:
    print(reason, file=sys.stderr)
    sys.exit(1)
print(archive.pax_headers.get("comment", ""))' "$WORK/archive.tgz" 2>"$WORK/tar.err"
}

# On main, meaning the head of it or an ancestor of it. GitHub not answering is
# an ordinary failure: one unlucky call must never tell the user their
# repository has been tampered with.
commit_is_on_main() {
  gh_read "repos/$REPO/compare/main...$COMMIT" || gh_gave_no_answer || return 1
  case "$(body_field .status)" in
    identical | behind) return 0 ;;
    "") GH_ERROR="GitHub did not say whether ${COMMIT:0:7} is on main"; gh_gave_no_answer; return 1 ;;
  esac
  record_failure required "$WANTED names commit ${COMMIT:0:7}, which is not on main, so nothing was installed" ""
  return 1
}

# All of it before the rename that makes a release staged.
verify_and_unpack() {
  local carried declared seal
  if ! carried="$(archive_commit)"; then
    record_failure advisory "the last update check failed: $WANTED would not open as an archive: $(one_line <"$WORK/tar.err")" ""
    return 1
  fi
  if [ "$carried" != "$COMMIT" ]; then
    record_failure required "$WANTED names commit ${COMMIT:0:7} and its archive carries ${carried:0:7}, so nothing was installed" ""
    return 1
  fi
  commit_is_on_main || return 1
  if ! mkdir -p "$WORK/root" || ! tar -xzf "$WORK/archive.tgz" -C "$WORK/root" --strip-components=1 2>"$WORK/tar.err"; then
    record_failure advisory "the last update check failed: $WANTED would not unpack: $(one_line <"$WORK/tar.err")" ""
    return 1
  fi
  if ! printf '%s\n' "${COMMIT:0:7}" >"$WORK/root/REVISION"; then
    record_failure advisory "the last update check failed: $WANTED could not be stamped with its revision" "df -h ~/.claude"
    return 1
  fi
  declared="$(version root "$WORK/root")"
  if [ "$(version release "$declared")" != "$WANTED" ]; then
    record_failure required "$WANTED holds a tree declaring $(if [ -n "$declared" ]; then printf 'version %s' "$declared"; else printf 'no version'; fi), so nothing was installed: installing it would leave this machine at a version that is still not the wanted one" ""
    return 1
  fi
  seal="$(take_seal "$WORK/root")" || {
    record_failure advisory "the last update check failed: $WANTED could not be sealed, so nothing was staged: $(one_line <"$SEAL_REASON")" ""
    return 1
  }
  # Recorded and on disk before the rename, so no other session ever finds a
  # folder under a release name that nothing is known about.
  record_set '.seals[$v] = $s' --arg v "$WANTED" --arg s "$seal"
  record_write
  mv -T "$WORK/root" "$RELEASES/$WANTED" 2>/dev/null || {
    record_failure advisory "the last update check failed: $WANTED would not move into ~/.claude/agent-toolkit-releases" \
      "chmod u+rwx ~/.claude/agent-toolkit-releases"
    return 1
  }
  TARGET="$RELEASES/$WANTED"
  STAGE_REASON=""
  return 0
}

check_succeeded() {
  record_set ".succeeded_at = $(now_seconds) | del(.failure)"
}

# Nothing declares dev mode: installing from a clone is what causes it, and it is
# read from the live directory itself.
in_dev_mode() {
  local root
  root="$(live_root)"
  [ -n "$root" ] && version worktree "$root"
}

run_cycle() {
  gh_is_ready || return 1
  resolve_release || return 1
  record_set '.wanted = $w | .commit = $c' --arg w "$WANTED" --arg c "$COMMIT"
  check_succeeded
  if [ "$MODE" != now ] && in_dev_mode; then
    STAGE_REASON="this machine runs a clone, which the updater never overwrites"
    return 1
  fi
  judge_release || return 1
  download || return 1
  verify_and_unpack || return 1
}

version_reader_failed() {
  finding advisory user "the toolkit cannot read a version on this machine, so no release is checked for or installed" \
    "$INSTALL_AGAIN"
}

# ── stage ────────────────────────────────────────────────────────────────────
releases_dir() {
  local err
  err="$(mkdir -p "$RELEASES" 2>&1)" && [ -w "$RELEASES" ] && return 0
  record_failure advisory \
    "~/.claude/agent-toolkit-releases cannot be written, so nothing was downloaded: $(printf '%s' "${err:-it is not writable}" | one_line)" \
    "chmod u+rwx ~/.claude/agent-toolkit-releases"
  return 1
}

# A last check recorded in the future counts as never having happened, so a clock
# that was wrong once does not stop a machine checking for good.
check_is_due() { # epoch seconds
  local last
  [ "$MODE" = now ] && return 0
  last="$(recorded .checked_at)"
  case "$last" in "" | *[!0-9]*) return 0 ;; esac
  [ "$last" -gt "$1" ] || [ $(("$1" - last)) -ge "$THROTTLE" ]
}

do_stage() {
  if [ -z "${AGENT_TOOLKIT_STAGE_BOUNDED:-}" ] && have timeout; then
    AGENT_TOOLKIT_STAGE_BOUNDED=1 timeout -k 10 "$STAGE_SECONDS" "$ROOT/hooks/update.sh" stage
    return 0
  fi
  version_reader_works || return 0
  judge_track
  case "$TRACK_STATE" in off | bad) return 0 ;; esac
  read_record
  releases_dir || { record_write; return 0; }
  take_stage_lock || { record_lock_problem; return 0; }
  check_and_stage
  prune
  record_write
}

# Only stage prunes, so no session start ever waits on a removal.
prune() {
  local wanted previous entry real
  wanted="${WANTED:-$(recorded .wanted)}"
  # A run that never resolved a release does not know what to keep.
  [ -n "$wanted" ] || return 0
  previous="$(recorded .previous)"
  for entry in "$RELEASES"/*; do
    [ -d "$entry" ] || continue
    [ "${entry##*/}" = "$wanted" ] && continue
    real="$(real_path "$entry")"
    [ -n "$real" ] || continue
    [ "$real" = "$previous" ] && continue
    # Read for each removal rather than once: another session can activate while
    # this loop runs, and the directory it moved to has to survive.
    [ "$real" = "$(live_root)" ] && continue
    rm -rf "$entry" && record_set 'del(.seals[$v])' --arg v "${entry##*/}"
  done
  # A part-written folder is a stage that was killed. A day is long enough that
  # one still being written is never mistaken for one that was abandoned.
  find "$RELEASES" -maxdepth 1 -name '.staging.*' -type d -mtime +0 -exec rm -rf {} + 2>/dev/null
}

# TARGET names the version directory to install from when there is one.
check_and_stage() {
  local started
  started="$(now_seconds)"
  check_is_due "$started" || return 1
  record_set ".checked_at = $started | .first_check_at = (.first_check_at // $started)" || return 1
  # Written now rather than only at the end: an async stage is killed at session
  # teardown, and a check nobody recorded is a throttle and a staleness guard
  # that never arm.
  record_write
  workspace && run_cycle
}

# The archive and the tree it unpacks to, under a name no release ever has, so a
# run killed partway leaves a folder pruning knows to remove.
WORK=""
workspace() {
  WORK="$(mktemp -d "$RELEASES/.staging.XXXXXX" 2>/dev/null)" || {
    record_failure advisory "the last update check failed: ~/.claude/agent-toolkit-releases holds no room to unpack a release" \
      "df -h ~/.claude"
    return 1
  }
  SEAL_REASON="$WORK/seal.err"
  trap 'rm -rf "$WORK"' EXIT
}

# ── apply ────────────────────────────────────────────────────────────────────
RELOAD=0

take_apply_lock() {
  lock_is_takeable "$RELEASES/.apply.lock" || return 1
  exec 7<"$RELEASES/.apply.lock" 2>/dev/null || {
    LOCK_PROBLEM="~/.claude/agent-toolkit-releases/.apply.lock cannot be opened"
    return 1
  }
  flock -w 1 7 2>/dev/null
}

# A lock nobody else holds and this run still could not take is the machine's
# problem, not a second session's, and it stops updates until someone acts.
record_lock_problem() {
  local text
  [ -n "$LOCK_PROBLEM" ] || return 1
  text="the last update check failed: $LOCK_PROBLEM"
  finding advisory user "$text" "$INSTALL_AGAIN"
  record_failure advisory "$text" "$INSTALL_AGAIN"
  record_write
}

# apply makes no call of its own, so a machine following latest takes the release
# the last check recorded.
apply_wanted() {
  local named
  [ "$TRACK_STATE" = pin ] || {
    named="$(recorded .wanted)"
    # Through the same reading the track's line gets: a record is a file in a
    # directory anything running as the user can write, and a name it was not
    # asked for would resolve a path straight out of the releases directory.
    [ "$(version release "$named")" = "$named" ] && WANTED="$named"
  }
}

# Under a name no release has, so pruning never reaches it and nothing mistakes
# it for a release.
set_aside() { # the staged folder → where it was kept, or nothing
  local base kept n=0
  base="$RELEASES/.altered.$WANTED.$(now_seconds)"
  kept="$base"
  # -L as well as -e, because a dangling symlink is a name that is taken and a
  # rename onto it fails, which would leave the evidence with nowhere to go.
  while [ -e "$kept" ] || [ -L "$kept" ]; do
    n=$((n + 1))
    kept="$base.$n"
  done
  mv -T "$1" "$kept" 2>/dev/null && printf '%s' "$kept"
}

seal_holds() { # the staged folder
  local recorded taken kept
  # A directory that is already live is running, not waiting, and the seal is a
  # question about a tree that has not run yet. Never the thing this removes.
  [ "$(real_path "$1")" != "$(live_root)" ] || return 0
  recorded="$(sealed "$WANTED")"
  if [ -z "$recorded" ]; then
    # Nothing being known about a tree is not permission to run it.
    rm -rf "$1"
    finding advisory user "$WANTED was unpacked here with nothing recorded to check it against, so it was discarded rather than installed. It is staged again on its own"
    return 1
  fi
  # A tree this machine unpacked and could seal an hour ago, that will not read
  # now, has been altered as surely as one whose bytes moved.
  taken="$(take_seal "$1")"
  [ -n "$taken" ] && [ "$taken" = "$recorded" ] && return 0
  if ! kept="$(set_aside "$1")"; then
    finding required user "$WANTED was altered after this machine unpacked it, and could not be moved out of the way, so nothing was installed" \
      "rm -rf ~/.claude/agent-toolkit-releases/$(shq "$WANTED")"
    return 1
  fi
  # Only once it is somewhere the next check will not find: while the seal stands
  # against a folder still under its release name, that folder is the evidence.
  record_set 'del(.seals[$v])' --arg v "$WANTED"
  finding required user "$WANTED was altered after this machine unpacked it, so nothing was installed. The folder is kept at $(home_path "$kept"), and the release is staged again on its own" ""
  return 1
}

listed() { # the record's field, the value
  jq -e --arg v "$2" "any($1[]?; . == \$v)" <<<"$RECORD_JSON" >/dev/null 2>&1
}

# Whether any of this is printed is the record's question rather than this run's.
activate() {
  local staged line
  apply_wanted
  [ -n "$WANTED" ] || return 0
  staged="$RELEASES/$WANTED"
  [ -d "$staged" ] || return 0
  [ "$(version release "$(version root "$staged")")" = "$WANTED" ] || {
    finding required user "~/.claude/agent-toolkit-releases/$WANTED declares no version of its own, so it was not installed" \
      "rm -rf ~/.claude/agent-toolkit-releases/$(shq "$WANTED")"
    return 0
  }
  in_dev_mode && return 0
  if listed .bad "$WANTED"; then
    # Required, and said at every start: this machine is stuck until someone
    # deals with install's own reason, which is not something to mention once.
    finding required user "$WANTED did not go live, so this machine is still on $(live_version)" "$UPDATE_NOW"
    return 0
  fi
  version same "$(version root "$staged")" "$(live_version)" && return 0
  take_apply_lock || { record_lock_problem; return 0; }
  seal_holds "$staged" || return 0
  if install_from "$staged"; then
    ACTIVATED=1
  else
    finding required user "$WANTED did not go live, so nothing on this machine changed" "$UPDATE_NOW"
  fi
  while IFS= read -r line; do [ -z "$line" ] || LEAD+=("$line"); done <<<"$INSTALL_OUT"
}

# 0 when the stable link resolves to the directory afterwards, which is what
# went live means.
INSTALL_OUT=""
install_from() { # version directory
  local before after target
  target="$(real_path "$1")"
  before="$(live_root)"
  INSTALL_OUT="$("$1/install.sh" 2>&1)"
  after="$(live_root)"
  if [ -z "$target" ] || [ "$after" != "$target" ]; then
    record_set '.bad = ((.bad // []) + [$v] | unique)' --arg v "$WANTED"
    return 1
  fi
  # Install keeps no note of the directory it moved off, so the activation that
  # moved is what records it, for pruning to keep one version to fall back to.
  [ "$before" = "$after" ] || record_set '.previous = $p' --arg p "$before"
  # The del rides the .bad filter because going live is itself what changes a
  # tree: the launcher writes a bytecode cache inside it within seconds, and a
  # seal taken before that describes a tree that no longer exists.
  record_set '.bad = [.bad[]? | select(. != $v)] | del(.seals[$v])' --arg v "$WANTED"
  return 0
}

# A clone somebody is working in is told once and then left alone.
announce() {
  local live
  [ -n "$WANTED" ] || return 0
  in_dev_mode || return 0
  live="$(live_version)"
  version newer "$WANTED" "$live" || return 0
  listed .announced "$WANTED" && return 0
  finding advisory user "$WANTED is published and this machine runs a clone at $live, which the updater never overwrites. $UPDATE_NOW installs the release over it, and a track of $WANTED or of off settles it the other way" \
    "git -C $(home_path "$(live_root)") pull"
  record_set '.announced = ((.announced // []) + [$v] | unique)' --arg v "$WANTED"
}

# Off the record, not off this run: two sessions starting together are each told
# once, whichever of them caused the change.
report_change() {
  local live reported
  live="$(live_version)"
  [ -n "$live" ] || return 0
  reported="$(recorded .reported)"
  version same "$live" "$reported" && return 0
  # Nothing to announce: either whatever put this version here said so at the
  # time, or it is a clone somebody is committing to, which moves its own version
  # without a release having arrived.
  if [ "$ACTIVATED" -eq 0 ] && { [ -z "$reported" ] || in_dev_mode; }; then
    record_set '.reported = $v' --arg v "$live"
    return 0
  fi
  LEAD=("$(version release "$live") is live, from ${reported:-a version this machine never reported}" "${LEAD[@]}")
  MESSAGE+=("updated to $(version release "$live"). Restart Claude Code to load the new version")
  RELOAD=1
  record_set '.reported = $v' --arg v "$live"
}

# Said only where the report already has something to say: a machine that is
# behind on purpose is told once, by the announcement, not at every start.
report_behind() {
  local live
  [ -n "$WANTED" ] || return 0
  { [ ${#F_SEV[@]} -gt 0 ] || [ ${#LEAD[@]} -gt 0 ] || [ ${#MESSAGE[@]} -gt 0 ]; } || return 0
  live="$(live_version)"
  [ -n "$live" ] && [ "$(version release "$live")" != "$WANTED" ] || return 0
  LEAD+=("the wanted release is $WANTED and the live version is $live")
}

report_record() {
  local text since
  text="$(recorded .failure.text)"
  # A severity the record does not hold is read as required: a finding nobody can
  # grade is one nobody should be able to quieten by editing the file it came from.
  [ -z "$text" ] || case "$(recorded .failure.severity)" in
    advisory) finding advisory user "$text" "$(recorded .failure.fix)" ;;
    *) finding required user "$text" "$(recorded .failure.fix)" ;;
  esac
  [ "$(recorded .replaced)" != true ] \
    || finding advisory user "~/.claude/agent-toolkit-staging.json did not read and was replaced, so this machine has forgotten which releases it was already told about"
  # Measured from the first check this machine ever made, so a machine installed
  # an hour ago is not told that a week has gone by without one succeeding.
  since="$(recorded '.succeeded_at // .first_check_at')"
  case "$since" in "" | *[!0-9]*) return 0 ;; esac
  [ $(("$(now_seconds)" - since)) -lt "$STALE" ] \
    || finding advisory user "no update check has succeeded in seven days" "$UPDATE_NOW"
}

do_apply() {
  local required
  if ! version_reader_works; then
    version_reader_failed
    hook_report SessionStart "agent-toolkit updates:" 0
    return 0
  fi
  judge_track
  [ "$TRACK_STATE" = off ] && return 0
  read_record
  if [ "$TRACK_STATE" != bad ]; then
    activate
    announce
    report_change
    report_record
    report_behind
  fi
  required="$(count required)"
  [ "$required" -eq 0 ] || MESSAGE+=("$(plural "$required" "update problem"). Ask Claude to fix it")
  hook_report SessionStart "agent-toolkit updates:" "$RELOAD"
  [ "$(recorded .replaced)" != true ] || record_set '.replaced = false'
  record_write
  return 0
}

# ── now ──────────────────────────────────────────────────────────────────────
# One finding a line, as the terminal report prints them, because a person is
# reading this rather than a model.
print_findings() {
  local i line
  for i in "${!F_SEV[@]}"; do
    printf '%s %s\n' "$(mark "${F_SEV[i]}")" "${F_TEXT[i]}"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '    %s\n' "$line"
    done <<<"${F_FIX[i]}"
  done
}

do_now() {
  local went
  if ! version_reader_works; then
    version_reader_failed
    print_findings
    return 1
  fi
  judge_track
  if [ "$TRACK_STATE" = off ]; then
    echo "~/.claude/agent-toolkit-track says off, so this machine installs no release. Nothing changed."
    return 1
  fi
  read_record
  if [ "$TRACK_STATE" = bad ]; then
    print_findings
    return 1
  fi
  if ! releases_dir; then
    record_write
    report_record
    print_findings
    return 1
  fi
  if ! take_stage_lock; then
    record_lock_problem && print_findings \
      || echo "another session is already downloading a release. Nothing changed."
    return 1
  fi
  check_and_stage
  if [ -z "$TARGET" ]; then
    record_write
    report_record
    print_findings
    if [ -n "$STAGE_REASON" ]; then
      printf '%s. Nothing changed.\n' "$STAGE_REASON"
    elif [ ${#F_SEV[@]} -eq 0 ]; then
      # now never exits without saying why: it is the command a person runs the
      # moment updates stop working, and silence is the one answer that helps nobody.
      echo "nothing could be fetched, and nothing recorded why. Nothing changed."
    fi
    return 1
  fi
  if ! take_apply_lock; then
    record_write
    record_lock_problem && print_findings \
      || echo "another session is already installing a release. Nothing changed."
    return 1
  fi
  case "$TARGET" in
    "$RELEASES"/*)
      if ! seal_holds "$TARGET"; then
        record_write
        print_findings
        printf '%s was not installed: this machine cannot vouch for the tree it had staged.\n' "$WANTED"
        return 1
      fi
      ;;
  esac
  printf '%s is ready at %s. Installing it now.\n\n' "$WANTED" "$TARGET"
  install_from "$TARGET"
  went=$?
  record_write
  printf '%s\n' "$INSTALL_OUT"
  [ "$went" -eq 0 ] || printf '\n%s did not go live, so nothing on this machine changed.\n' "$WANTED"
  return "$went"
}

main() {
  [ $# -eq 1 ] || { usage >&2; exit 2; }
  MODE="$1"
  cd / || exit 0
  case "$MODE" in
    stage) do_stage ;;
    apply) do_apply ;;
    now) do_now; exit $? ;;
    --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
  exit 0
}

main "$@"
