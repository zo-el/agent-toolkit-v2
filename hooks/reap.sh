#!/usr/bin/env bash
# Reaper for bg.sh processes: the safety net under each agent's own cleanup.
#
# Two triggers, because neither alone is enough:
#   SessionEnd    is the wired one, and reaps the ending session's own
#                 processes. It passes its session id, and at that moment the
#                 CLI is still alive by construction, so a dead-owner test would
#                 never fire.
#   session start install.sh --sync runs this with no payload, which catches
#                 what a crashed or kill -9'd session left behind.
#
# Only entries owned by the ending session or by a CLI that is provably gone are
# touched, so one session never kills another's work. Everywhere it cannot be
# sure, it leaks a process rather than killing live work.
set -uo pipefail

reg="$HOME/.claude/bg-procs"
input="$(cat 2>/dev/null || true)"
[ -d "$reg" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

start_of() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }

ending=""
if [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "SessionEnd" ]; then
  ending="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
fi

for e in "$reg"/*.json; do
  [ -e "$e" ] || continue
  # Cleared first: an unreadable entry leaves eval a no-op, and the previous
  # iteration's values would then be used to judge — and kill — this one.
  pid=""; start=""; owner=""; owner_start=""; session=""
  eval "$(jq -r '@sh "pid=\(.pid // "") start=\(.start // "") owner=\(.owner // "")
                     owner_start=\(.owner_start // "") session=\(.session // "")"' "$e" 2>/dev/null)" || continue

  # Gone, or the pid was recycled and now belongs to someone else: drop the
  # record, never signal.
  [ -n "$pid" ] || { rm -f "$e"; continue; }
  kill -0 "$pid" 2>/dev/null || { rm -f "$e"; continue; }
  [ -n "$start" ] && [ "$start" = "$(start_of "$pid")" ] || { rm -f "$e"; continue; }

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
  for _ in 1 2 3; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill -0 "$pid" 2>/dev/null && { kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null; }
  rm -f "$e"
done
exit 0
