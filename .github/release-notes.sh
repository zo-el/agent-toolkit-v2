#!/usr/bin/env bash
# The changelog lines a release is published with, read from the merged pull
# request that carried a commit. One step answers for a release, so no other step
# in the workflow learns what a pull request is.
#
#   .github/release-notes.sh <commit>
#
# Exit 0: one or more entries on stdout, one a line, exactly as they were written.
# Exit 3: the section said none, so there is nothing for a user to be told about.
# Exit 1: no answer at all, with the reason on stderr. A commit that reached main
#         without a pull request, and a body carrying no such section, are both
#         this, because forgetting must not read as deciding.
# Exit 2: it was called wrongly.
set -uo pipefail

REPO="${GITHUB_REPOSITORY:-}"
commit="${1-}"
if [ -z "$REPO" ] || [ -z "$commit" ] || [ $# -ne 1 ]; then
  echo "usage: GITHUB_REPOSITORY=<owner/repo> release-notes.sh <commit>" >&2
  exit 2
fi

no_answer() { printf '%s\n' "$1" >&2; exit 1; }

pulls="$(gh api "repos/$REPO/commits/$commit/pulls" 2>&1)" \
  || no_answer "GitHub did not say which pull requests carried $commit: $(printf '%s' "$pulls" | tail -1)"

# The one whose merge landed this commit, and otherwise the first merged pull
# request that carries it, which is what a squash or a rebase leaves behind.
body="$(jq -r --arg sha "$commit" '
  [.[] | select(.merged_at != null)] as $merged
  | (($merged | map(select(.merge_commit_sha == $sha))) + $merged)[0] // {}
  | .body // ""' <<<"$pulls" 2>/dev/null)" \
  || no_answer "the pull requests for $commit did not read as GitHub's own answer"
[ -n "$body" ] || no_answer "$commit reached main without a merged pull request carrying a body"

section="$(awk '
  /^##[ \t]+Changelog[ \t]*\r?$/ { inside = 1; next }
  /^##[ \t]/ { inside = 0 }
  inside { sub(/\r$/, ""); print }
' <<<"$body" | sed '/^[[:space:]]*$/d')"
[ -n "$section" ] || no_answer "the pull request for $commit carries no ## Changelog section"

# none written as a list item is still none: a release whose only note read
# "none" would be the mistake this answer exists to avoid.
if [ "$(wc -l <<<"$section")" -eq 1 ]; then
  only="$(sed 's/^[[:space:]]*[-*][[:space:]]*//; s/[[:space:]]*$//' <<<"$section" | tr '[:upper:]' '[:lower:]')"
  [ "$only" != none ] || exit 3
fi
printf '%s\n' "$section"
