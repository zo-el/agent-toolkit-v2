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
  RECORD_JSON="$next"
}

record_write() {
  local tmp="$RECORD.$$"
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
  started="$(now_seconds)"
  check_is_due "$started" || return 0
  record_set ".checked_at = $started | .first_check_at = (.first_check_at // $started)" || return 0
  record_write
}

# ── apply ────────────────────────────────────────────────────────────────────
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
  [ "$TRACK_STATE" = bad ] || report_record
  required="$(count required)"
  [ "$required" -eq 0 ] || MESSAGE+=("$(plural "$required" "update problem"). Ask Claude to fix it")
  hook_report SessionStart "agent-toolkit updates:" 0
  if [ "$(recorded .replaced)" = true ]; then
    record_set '.replaced = false' && record_write
  fi
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
  [ "$TRACK_STATE" = bad ] || report_record
  print_findings
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
