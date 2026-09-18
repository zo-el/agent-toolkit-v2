#!/usr/bin/env bash
# The suite, and the verdict over its summary. A skipped check is not a passed
# one: the runner is meant to satisfy every check, so a skip is a broken runner
# rather than a tolerated gap, and a gate that read a list of accepted skips
# would stop meaning anything.
#
#   .github/suite-gate.sh [command…]
#
# With no command it runs tests/run.sh, which is the whole gate. Exit 0 when the
# summary counts passes and nothing else, 1 with the reason on stderr otherwise.
# The one line it writes lands where the run's own summary shows it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/suite-gate.txt"

say() {
  printf '%s\n' "$1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
}

if [ $# -eq 0 ]; then set -- "$ROOT/tests/run.sh"; fi
"$@" >"$log" 2>&1
status=$?
cat "$log"
summary="$(tail -1 "$log" 2>/dev/null)"

# A count that begins at zero is a suite that ran nothing, which is not a pass
# either: jscpd and a bad path both exit 0 having read none of the tree.
if [ "$status" -ne 0 ]; then
  say "no release: the suite exited $status, reporting \"${summary:-nothing at all}\""
  exit 1
fi
case "$summary" in
  [1-9]*' passed') say "the suite: $summary" ;;
  *)
    say "no release: the suite reported \"${summary:-nothing at all}\", and the gate is no failures and no skips"
    exit 1
    ;;
esac
