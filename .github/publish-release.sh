#!/usr/bin/env bash
# Publish the release a commit on main earns, or say why there is none.
#
#   .github/publish-release.sh <commit>
#
# Exit 0: released, or there is nothing to release and that is an answer someone
#         gave. Exit 1: the run must be loud, because main moved past a gate.
# Exit 2: it was called wrongly.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
. "$ROOT/.github/lib.sh"

REPO="${GITHUB_REPOSITORY:-}"
commit="${1-}"
called_for_a_commit "$@" || {
  echo "usage: GITHUB_REPOSITORY=<owner/repo> publish-release.sh <commit>" >&2
  exit 2
}

notes="$(mktemp)"
reason="$(mktemp)"
trap 'rm -f "$notes" "$reason"' EXIT

# The reader fails for four distinct reasons and says which on stderr, so the run
# carries that sentence rather than guessing which of them it was.
"$ROOT/.github/release-notes.sh" "$commit" >"$notes" 2>"$reason"
case $? in
  0) ;;
  3)
    say "no release: the pull request that carried ${commit:0:7} says none"
    exit 0
    ;;
  *)
    say "no release: $(tr '\n' ' ' <"$reason" | cut -c1-300)"
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
if gh release view "$name" --repo "$REPO" >/dev/null 2>&1; then
  if ! at="$(gh api "repos/$REPO/git/ref/tags/$name" --jq .object.sha)"; then
    say "no release: $name is published and GitHub would not say which commit it names"
    exit 1
  fi
  if [ "$at" = "$commit" ]; then
    say "no release: $name is already published, at this commit"
    exit 0
  fi
  say "no release: $name is already published at ${at:0:7}, and this commit is ${commit:0:7}"
  exit 1
fi

# --target puts a lightweight tag on the released commit, so one API call gives a
# machine the exact commit a release names.
if ! gh release create "$name" --repo "$REPO" --target "$commit" --title "$name" --notes-file "$notes"; then
  say "no release: publishing $name failed"
  exit 1
fi
say "released $name at ${commit:0:7}"
