#!/usr/bin/env bash
# Publish the release a commit on main earns, or say why there is none.
#
#   .github/publish-release.sh <commit>
#
# Exit 0: released, or there is nothing to release and that is an answer someone
#         gave. Exit 1: the run must be loud, because main moved past a gate.
#
# The notes come from one place, which is the only step here that knows what a
# pull request is. The version comes from the released commit's own VERSION, read
# through the same rule every machine reads a version by.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO="${GITHUB_REPOSITORY:-}"
commit="${1-}"
if [ -z "$REPO" ] || [ $# -ne 1 ] || [ -z "$commit" ]; then
  echo "usage: GITHUB_REPOSITORY=<owner/repo> publish-release.sh <commit>" >&2
  exit 2
fi

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT

# Every run writes one line saying what it did, where the run's summary shows it.
say() {
  printf '%s\n' "$1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
}

"$ROOT/.github/release-notes.sh" "$commit" >"$notes"
case $? in
  0) ;;
  3)
    say "no release: the pull request that carried ${commit:0:7} says none"
    exit 0
    ;;
  *)
    say "no release: ${commit:0:7} carries no changelog section to publish"
    exit 1
    ;;
esac

if ! name="$(python3 "$ROOT/hooks/lib/version.py" release "v$(head -c 64 "$ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')")"; then
  say "no release: VERSION is missing, or is not three dot separated numbers"
  exit 1
fi

# A version publishes once. The same commit is a re-run of work already
# published, so the run succeeds; a different one means the product changed and
# the bump was forgotten, which is the failure this gate exists to prevent.
if gh release view "$name" >/dev/null 2>&1; then
  at="$(gh api "repos/$REPO/git/ref/tags/$name" --jq .object.sha 2>/dev/null)"
  if [ "$at" = "$commit" ]; then
    say "no release: $name is already published, at this commit"
    exit 0
  fi
  say "no release: $name is already published at ${at:0:7}, and this commit is ${commit:0:7}"
  exit 1
fi

# --target puts a lightweight tag on the released commit, so one API call gives a
# machine the exact commit a release names.
if ! gh release create "$name" --target "$commit" --title "$name" --notes-file "$notes"; then
  say "no release: publishing $name failed"
  exit 1
fi
say "released $name at ${commit:0:7}"
