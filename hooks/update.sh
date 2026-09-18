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

version() { python3 "$ROOT/hooks/lib/version.py" "$@" 2>/dev/null; }

live_root() { (cd "$STABLE" 2>/dev/null && pwd -P); }

# ── the track ────────────────────────────────────────────────────────────────
# latest, off, pin, or bad. WANTED carries the release name a pin names.
TRACK_STATE=""
WANTED=""

# Surrounding blank space is not content, and a file with nothing in it says
# nothing to misread, so it means what no file means. Everything else is
# returned as written, for the finding that quotes it.
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
  RECORD_JSON="$(jq -ce 'select(type == "object")' "$RECORD" 2>/dev/null)" && return 0
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
  local tmp="$RECORD.$$"
  [ "$RECORD_DIRTY" -eq 1 ] || return 0
  mkdir -p "$CLAUDE_DIR" 2>/dev/null || return 1
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
# The updater's own, so staging never delays an install. flock missing is a
# required finding of install's own requirement list, which is where it belongs:
# a second report of it at every session start would say nothing new.
take_stage_lock() {
  : >>"$RELEASES/.stage.lock" 2>/dev/null || return 1
  exec 8<"$RELEASES/.stage.lock" 2>/dev/null || return 1
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

# gh is the whole of the machine's reach, so a machine without it, or without a
# token, is told rather than left checking nothing in silence.
gh_is_ready() {
  have gh || {
    record_failure advisory "the last update check failed: gh is not on PATH" "~/.claude/agent-toolkit/install.sh"
    return 1
  }
  timeout 10 gh auth token --hostname github.com >/dev/null 2>&1 && return 0
  record_failure advisory "the last update check failed: gh holds no token for github.com" "$GH_LOGIN"
  return 1
}

# ── the cycle ────────────────────────────────────────────────────────────────
COMMIT=""
TARGET=""        # the version directory now should install from
STAGE_REASON=""  # what now prints when there is nothing to install
PREVIOUS_ROOT="" # the version directory live before an activation moved off it
ACTIVATED=0      # this run installed a release and it went live

# A 404 is not an answer on its own: the repository is private, so a token that
# cannot see it 404s exactly as a repository with no release does.
resolve_release() {
  local path tag
  case "$TRACK_STATE" in
    pin) path="repos/$REPO/releases/tags/$WANTED" ;;
    *) path="repos/$REPO/releases/latest" ;;
  esac
  if ! gh_read "$path"; then
    [ "$GH_404" -eq 1 ] || { record_failure advisory "the last update check failed: $GH_ERROR" ""; return 1; }
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
    || { record_failure advisory "the last update check failed: $GH_ERROR" ""; return 1; }
  COMMIT="$(body_field .object.sha)"
  kind="$(body_field .object.type)"
  if [ "$kind" = tag ]; then
    gh_read "repos/$REPO/git/tags/$COMMIT" \
      || { record_failure advisory "the last update check failed: $GH_ERROR" ""; return 1; }
    COMMIT="$(body_field .object.sha)"
  fi
  case "$COMMIT" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) return 0 ;;
    *) record_failure advisory "the last update check failed: $WANTED carries no commit" "" ;;
  esac
  return 1
}

# Live, already staged, or marked bad: three ways there is nothing to download.
# now ignores the bad mark, which is what a machine does after fixing the cause.
judge_release() {
  local live
  live="$(version root "$(live_root)")"
  if [ -n "$live" ] && [ "$(version release "$live")" = "$WANTED" ]; then
    TARGET="$(live_root)"
    STAGE_REASON="$WANTED is already the live version"
    return 1
  fi
  if [ -d "$RELEASES/$WANTED" ]; then
    TARGET="$RELEASES/$WANTED"
    STAGE_REASON="$WANTED is already unpacked and waiting for the next session start"
    return 1
  fi
  if [ "$MODE" != now ] && jq -e --arg v "$WANTED" 'any(.bad[]?; . == $v)' <<<"$RECORD_JSON" >/dev/null 2>&1; then
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

# The commit id a git archive carries, in its pax global header.
archive_commit() {
  python3 -c 'import sys, tarfile; print(tarfile.open(sys.argv[1]).pax_headers.get("comment", ""))' \
    "$WORK/archive.tgz" 2>/dev/null
}

# On main, meaning the head of it or an ancestor of it. GitHub not answering is
# an ordinary failure: one unlucky call must never tell the user their
# repository has been tampered with.
commit_is_on_main() {
  gh_read "repos/$REPO/compare/main...$COMMIT" \
    || { record_failure advisory "the last update check failed: $GH_ERROR" ""; return 1; }
  case "$(body_field .status)" in
    identical | behind) return 0 ;;
  esac
  record_failure required "$WANTED names commit ${COMMIT:0:7}, which is not on main, so nothing was installed" ""
  return 1
}

# Four things, all of them before the rename that makes a release staged.
verify_and_unpack() {
  local carried declared
  if ! mkdir -p "$WORK/root" || ! tar -xzf "$WORK/archive.tgz" -C "$WORK/root" --strip-components=1 2>"$WORK/tar.err"; then
    record_failure advisory "the last update check failed: $WANTED would not unpack: $(one_line <"$WORK/tar.err")" ""
    return 1
  fi
  carried="$(archive_commit)"
  if [ "$carried" != "$COMMIT" ]; then
    record_failure required "$WANTED names commit ${COMMIT:0:7} and its archive carries ${carried:0:7}, so nothing was installed" ""
    return 1
  fi
  commit_is_on_main || return 1
  printf '%s\n' "${COMMIT:0:7}" >"$WORK/root/REVISION" || return 1
  declared="$(version root "$WORK/root")"
  if [ "$(version release "$declared")" != "$WANTED" ]; then
    record_failure required "$WANTED holds a tree declaring $(if [ -n "$declared" ]; then printf 'version %s' "$declared"; else printf 'no version'; fi), so nothing was installed: installing it would leave this machine at a version that is still not the wanted one" ""
    return 1
  fi
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

# 0 when the wanted release is here to install, 1 when there is nothing to do.
run_cycle() {
  gh_is_ready || return 1
  resolve_release || return 1
  record_set '.wanted = $w | .commit = $c' --arg w "$WANTED" --arg c "$COMMIT"
  check_succeeded
  judge_release || return 1
  download || return 1
  verify_and_unpack || return 1
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

# Never inside the throttle, always for now, and always when the last check is
# recorded in the future, so a clock that was wrong once does not stop a machine
# checking for good.
check_is_due() { # now
  local last
  [ "$MODE" = now ] && return 0
  last="$(recorded .checked_at)"
  case "$last" in "" | *[!0-9]*) return 0 ;; esac
  [ "$last" -gt "$1" ] || [ $(("$1" - last)) -ge "$THROTTLE" ]
}

do_stage() {
  local started
  if [ -z "${AGENT_TOOLKIT_STAGE_BOUNDED:-}" ] && have timeout; then
    AGENT_TOOLKIT_STAGE_BOUNDED=1 timeout -k 10 "$STAGE_SECONDS" "$ROOT/hooks/update.sh" stage
    return 0
  fi
  judge_track
  case "$TRACK_STATE" in off | bad) return 0 ;; esac
  read_record
  releases_dir || { record_write; return 0; }
  take_stage_lock || return 0
  check_and_stage
  record_write
}

# The check and the download, under whatever lock the caller took. TARGET names
# the version directory to install from when there is one.
check_and_stage() {
  local started
  started="$(now_seconds)"
  check_is_due "$started" || return 1
  record_set ".checked_at = $started | .first_check_at = (.first_check_at // $started)" || return 1
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
  trap 'rm -rf "$WORK"' EXIT
}

# ── apply ────────────────────────────────────────────────────────────────────
RELOAD=0

take_apply_lock() {
  : >>"$RELEASES/.apply.lock" 2>/dev/null || return 1
  exec 7<"$RELEASES/.apply.lock" 2>/dev/null || return 1
  flock -w 1 7 2>/dev/null
}

# apply makes no call of its own, so a machine following latest takes the release
# the last check recorded.
apply_wanted() {
  [ "$TRACK_STATE" = pin ] || WANTED="$(recorded .wanted)"
}

marked_bad() { jq -e --arg v "$1" 'any(.bad[]?; . == $v)' <<<"$RECORD_JSON" >/dev/null 2>&1; }

# Install from the staged folder, or leave the machine exactly as it is. Nothing
# here is a report: whether anything is printed is the record's question, not
# this run's.
activate() {
  local staged before after out line
  apply_wanted
  [ -n "$WANTED" ] || return 0
  staged="$RELEASES/$WANTED"
  [ -d "$staged" ] || return 0
  [ "$MODE" = now ] || ! marked_bad "$WANTED" || return 0
  before="$(version root "$(live_root)")"
  version same "$(version root "$staged")" "$before" && return 0
  take_apply_lock || return 0
  out="$("$staged/install.sh" 2>&1)"
  after="$(live_root)"
  if [ "$after" = "$staged" ]; then
    ACTIVATED=1
    # Install keeps no note of the directory it moved off, so the activation that
    # moved is what records it, for pruning to keep one version to fall back to.
    record_set '.previous = $p | .bad = [.bad[]? | select(. != $v)]' --arg p "$PREVIOUS_ROOT" --arg v "$WANTED"
  else
    record_set '.bad = ((.bad // []) + [$v] | unique)' --arg v "$WANTED"
    finding required user "$WANTED did not go live, so nothing on this machine changed" "$UPDATE_NOW"
  fi
  while IFS= read -r line; do [ -z "$line" ] || LEAD+=("$line"); done <<<"$out"
}

# Off the record, not off this run: two sessions starting together are each told
# once, whichever of them caused the change.
report_change() {
  local live reported
  live="$(version root "$(live_root)")"
  [ -n "$live" ] || return 0
  reported="$(recorded .reported)"
  version same "$live" "$reported" && return 0
  # A machine that has never reported anything and changed nothing this run has
  # no change to announce: whatever put this version here said so at the time.
  if [ -z "$reported" ] && [ "$ACTIVATED" -eq 0 ]; then
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
  live="$(version root "$(live_root)")"
  [ -n "$live" ] && [ "$(version release "$live")" != "$WANTED" ] || return 0
  LEAD+=("the wanted release is $WANTED and the live version is $live")
}

# Every finding the record holds about a run nobody was there to hear.
report_record() {
  local text since
  text="$(recorded .failure.text)"
  [ -z "$text" ] || finding "$(recorded .failure.severity)" user "$text" "$(recorded .failure.fix)"
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
  judge_track
  [ "$TRACK_STATE" = off ] && return 0
  read_record
  if [ "$TRACK_STATE" != bad ]; then
    PREVIOUS_ROOT="$(live_root)"
    activate
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
    echo "another session is already downloading a release. Nothing changed."
    return 1
  fi
  check_and_stage
  record_write
  if [ -n "$TARGET" ]; then
    printf '%s is ready at %s\n' "$WANTED" "$TARGET"
    return 1
  fi
  report_record
  print_findings
  [ -z "$STAGE_REASON" ] || printf '%s. Nothing changed.\n' "$STAGE_REASON"
  return 1
}

main() {
  [ $# -eq 1 ] || { usage >&2; exit 2; }
  MODE="$1"
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
