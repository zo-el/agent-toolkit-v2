#!/usr/bin/env bash
# Reaper for bg.sh processes: the safety net under each agent's own cleanup.
#
# Two triggers, because neither alone is enough:
#   SessionEnd    wired directly. It reaps the ending session's own processes:
#                 it passes its session id, and at that moment the CLI is still
#                 alive by construction, so a dead-owner test would never fire.
#   install.sh    started at every session start and every install, it catches
#                 what a crashed or kill -9'd session left behind.
#
# Only entries owned by the ending session or by a CLI that is provably gone are
# touched, so one session never kills another's work. Everywhere it cannot be
# sure, it leaks a process rather than killing live work.
#
# SessionEnd hooks share a 1.5 second budget, so this signals and returns. The
# wait for exit, and the kill for whatever ignored the signal, run detached:
#
#   reap.sh --finish <pid> <start> <entry> ...
set -uo pipefail

reg="$HOME/.claude/bg-procs"
start_of() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }

# Signalling a group is only safe while the pid that names it still leads the
# process we registered, proved by its kernel start time. Anything else is
# unknown: a pid we cannot read, one the kernel will not let us signal, one that
# has gone and may have been recycled as another group's leader. Unknown leaks
# the process. It never signals, because the group id is a bare number and the
# group it names may by then be a login session, a terminal, or every process
# this user owns.
ours() { # pid, the start time recorded for it
  case "$1" in "" | *[!0-9]*) return 1 ;; esac
  # 0 is "this group" and 1 is init, so neither is ever a job of ours, and both
  # are catastrophic as the target of a group signal.
  [ "$1" -gt 1 ] || return 1
  [ -n "$2" ] || return 1
  [ -r "/proc/$1/stat" ] || return 1
  [ "$(start_of "$1")" = "$2" ]
}

if [ "${1:-}" = "--finish" ]; then
  shift
  for _ in 1 2 3 4 5 6; do
    alive=0
    for ((i = 1; i <= $#; i += 3)); do
      ours "${!i}" "${@:i+1:1}" && kill -0 -- "-${!i}" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.5
  done
  for ((i = 1; i <= $#; i += 3)); do
    ours "${!i}" "${@:i+1:1}" && { kill -KILL -- "-${!i}" 2>/dev/null || kill -KILL "${!i}" 2>/dev/null; }
    rm -f "${@:i+2:1}"
  done
  exit 0
fi

input="$(cat 2>/dev/null || true)"
[ -d "$reg" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

ending=""
signalled=()
if [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "SessionEnd" ]; then
  ending="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
fi

for e in "$reg"/*.json; do
  [ -e "$e" ] || continue
  # Cleared first, so a previous entry's values never judge this one.
  pid=""; start=""; owner=""; owner_start=""; session=""
  # An entry that will not parse may still be being written, so it is only
  # dropped once it is a minute old.
  if ! fields="$(jq -r '@sh "pid=\(.pid // "") start=\(.start // "") owner=\(.owner // "")
                     owner_start=\(.owner_start // "") session=\(.session // "")"' "$e" 2>/dev/null)"; then
    [ -n "$(find "$e" -mmin +1 2>/dev/null)" ] && rm -f "$e"
    continue
  fi
  eval "$fields"

  # The pid recycled and now belongs to someone else, or the whole group is
  # gone: drop the record, never signal.
  [ -n "$pid" ] || { rm -f "$e"; continue; }
  ours "$pid" "$start" || { rm -f "$e"; continue; }
  kill -0 -- "-$pid" 2>/dev/null || { rm -f "$e"; continue; }

  reap=0
  [ -n "$ending" ] && [ "$session" = "$ending" ] && reap=1
  if [ "$reap" -eq 0 ] && [ -n "$owner" ]; then
    if ! kill -0 "$owner" 2>/dev/null; then
      reap=1
    else
      now="$(start_of "$owner")"
      # Only a positive mismatch proves the pid was recycled. An unreadable
      # start time is uncertainty, and uncertainty must not kill.
      [ -n "$owner_start" ] && [ -n "$now" ] && [ "$owner_start" != "$now" ] && reap=1
    fi
  fi
  [ "$reap" -eq 1 ] || continue

  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  signalled+=("$pid" "$start" "$e")
done

[ "${#signalled[@]}" -gt 0 ] || exit 0
setsid "${BASH_SOURCE[0]}" --finish "${signalled[@]}" </dev/null >/dev/null 2>&1 &
exit 0
