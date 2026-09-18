# The publishing half, sourced by tests/run.sh after tests/update.sh, whose
# helpers these go on using. gh is a stub here too, so no case reaches GitHub and
# none of them needs a pull request to exist anywhere.

echo "release-notes.sh"

NOTES="$ROOT/.github/release-notes.sh"
export AT_PR_STATE="$TMP/pr-state"
NSTUBS="$TMP/notes-stubs"
mkdir -p "$NSTUBS" "$AT_PR_STATE"
cat >"$NSTUBS/gh" <<'SH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
case "$2" in
  */commits/*/pulls)
    sha="${2#*/commits/}"
    sha="${sha%/pulls}"
    [ -s "$AT_PR_STATE/$sha" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$AT_PR_STATE/$sha" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$NSTUBS/gh"

# A merged pull request as GitHub reports it against the commit it landed.
merged() { # commit, body
  python3 - "$AT_PR_STATE/$1" "$1" "$2" <<'PY'
import json
import sys

path, sha, body = sys.argv[1:]
json.dump([{"merged_at": "2026-09-18T00:00:00Z", "merge_commit_sha": sha, "body": body}], open(path, "w"))
PY
}
notes() { # commit → out, rc
  out="$(PATH="$NSTUBS:$PATH" GITHUB_REPOSITORY=zo-el/agent-toolkit-v2 "$NOTES" "$@" 2>&1)"
  rc=$?
}

# ── the three forms, and nothing else ────────────────────────────────────────
merged abc1 "$(printf 'The goal, and why.\n\n## Changelog\n\n- the updater takes releases on its own\n- the guard asks before a release\n')"
notes abc1
exit_is "a section holding entries answers with them" 0
same "exactly as they were written, neither shortened nor reformatted" \
  "$(printf -- '- the updater takes releases on its own\n- the guard asks before a release')" "$out"

merged abc2 "$(printf 'The goal.\n\n## Changelog\n\nnone\n')"
notes abc2
exit_is "a section saying none answers none" 3
same "and offers no line to publish" "" "$out"
merged abc3 "$(printf 'The goal.\n\n## Changelog\n\n- none\n')"
notes abc3
exit_is "written as a list item it is still none" 3

merged abc4 "$(printf 'The goal, and why it was worth doing.\n')"
notes abc4
exit_is "a body with no such section is no answer at all" 1
check "saying which commit" "abc4 carries no ## Changelog section" "$out"
merged abc5 "$(printf '## Changelog\n\n\n')"
notes abc5
exit_is "and so is a section with nothing under it" 1
notes abc6
exit_is "as is a commit that reached main without a pull request" 1
check "naming what GitHub would not say" "did not say which pull requests carried abc6" "$out"

# The section ends where the next heading begins, so the rest of a body is never
# published as a changelog line.
merged abc7 "$(printf '## Changelog\n\n- the one entry\n\n## Notes\n\nnot a changelog line\n')"
notes abc7
same "a heading after the section ends it" "- the one entry" "$out"
merged abc8 "$(printf 'goal\n\n## Changelog\n- first\n- second\n\n### Detail\n- third\n')"
notes abc8
same "and a deeper heading inside it does not" "$(printf -- '- first\n- second\n### Detail\n- third')" "$out"

# env -u rather than an empty value: a runner sets this, and the suite runs there.
out="$(PATH="$NSTUBS:$PATH" env -u GITHUB_REPOSITORY "$NOTES" abc1 2>&1)"
rc=$?
exit_is "the reader called outside a workflow exits 2" 2
check "saying what sets the repository" "GITHUB_REPOSITORY" "$out"

# ── the rule that admits the block ───────────────────────────────────────────
# The workflow reads a section CLAUDE.md has to allow, so the two are held
# together here rather than by whoever remembers both.
pr_rules="$(sed -n '/^Keep the PR itself short:/,/^$/p;/^- \*\*A `## Changelog` section\*\*/,+0p' "$ROOT/CLAUDE.md")"
check "CLAUDE.md admits one changelog section in a PR body" '`## Changelog` section' "$pr_rules"
check "and the single word none with it" "the single word \`none\`" "$pr_rules"
case "$pr_rules" in
  *"Nothing else: no change log"*) bad "and no longer forbids the block it admits" "the old line still stands" ;;
  *) ok "and no longer forbids the block it admits" ;;
esac
