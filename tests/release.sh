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

# ── the gate over the suite's summary ────────────────────────────────────────
# A skipped check is not a passed one, and a suite that ran nothing is not one
# either. The gate takes the command to judge, so these cases judge the gate.
echo "suite-gate.sh"

GATE_SH="$ROOT/.github/suite-gate.sh"
summarised() { # the suite's last line → out, rc, with the run's summary in $TMP/step
  : >"$TMP/step"
  printf '#!/bin/sh\nprintf "  ✓ a case\\n%%s\\n" "$1"\nexit "${2:-0}"\n' >"$TMP/fake-suite"
  chmod +x "$TMP/fake-suite"
  out="$(GITHUB_STEP_SUMMARY="$TMP/step" "$GATE_SH" "$TMP/fake-suite" "$1" "${2:-0}" 2>&1)"
  rc=$?
}

summarised "1068 passed"
exit_is "a summary of passes alone is the release gate open" 0
check "and the run says what it did" "the suite: 1068 passed" "$(cat "$TMP/step")"
summarised "1068 passed, 1 skipped"
exit_is "one skip closes it" 1
check "saying the gate is no failures and no skips" "no failures and no skips" "$(cat "$TMP/step")"
summarised "1068 passed, 1 skipped, 2 failed"
exit_is "and so does a failure" 1
summarised "0 passed"
exit_is "a suite that ran nothing is not a pass" 1
summarised ""
exit_is "nor is one that said nothing at all" 1
check "which the run says out loud" "nothing at all" "$(cat "$TMP/step")"
summarised "1068 passed" 1
exit_is "nor one that counted passes and still exited non-zero" 1

# ── publishing ───────────────────────────────────────────────────────────────
echo "publish-release.sh"

PUBLISH="$ROOT/.github/publish-release.sh"
export AT_RELEASE_STATE="$TMP/release-state"
mkdir -p "$AT_RELEASE_STATE"
cat >"$NSTUBS/gh" <<'SH'
#!/usr/bin/env bash
state="$AT_RELEASE_STATE"
case "$1 $2" in
  "release view")
    [ -e "$state/release.$3" ] || exit 1
    echo "$3" ;;
  "release create")
    printf '%s\n' "$*" >>"$state/created"
    : >"$state/release.$3" ;;
  "api "*)
    shift
    path="$1"
    shift
    filter="."
    while [ $# -gt 0 ]; do
      [ "$1" = --jq ] && { filter="$2"; shift; }
      shift
    done
    case "$path" in
      */commits/*/pulls)
        sha="${path#*/commits/}"
        sha="${sha%/pulls}"
        [ -s "$AT_PR_STATE/$sha" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        jq -r "$filter" "$AT_PR_STATE/$sha" ;;
      */git/ref/tags/*)
        tag="${path##*/}"
        [ -s "$state/tag.$tag" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        jq -r "$filter" "$state/tag.$tag" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$NSTUBS/gh"

publish() { # commit → out, rc, with the run's summary in $TMP/step
  : >"$TMP/step"
  out="$(PATH="$NSTUBS:$PATH" GITHUB_REPOSITORY=zo-el/agent-toolkit-v2 GITHUB_STEP_SUMMARY="$TMP/step" "$PUBLISH" "$@" 2>&1)"
  rc=$?
}
created() { cat "$AT_RELEASE_STATE/created" 2>/dev/null; }

DECLARED="v$(head -1 "$ROOT/VERSION")"
rm -f "$AT_RELEASE_STATE/created"
merged ffff1111 "$(printf 'goal\n\n## Changelog\n\n- the updater takes releases on its own\n')"
publish ffff1111
exit_is "a commit with entries and a version nobody has published is released" 0
check "named for the version its own tree declares" "release create $DECLARED --target ffff1111" "$(created)"
check "and the run says what it did" "released $DECLARED at ffff111" "$(cat "$TMP/step")"

rm -f "$AT_RELEASE_STATE/created"
merged ffff2222 "$(printf 'goal\n\n## Changelog\n\nnone\n')"
publish ffff2222
exit_is "a pull request saying none succeeds without a release" 0
same "publishing nothing" "" "$(created)"
check "and says so" "says none" "$(cat "$TMP/step")"

merged ffff3333 "$(printf 'no section here\n')"
publish ffff3333
exit_is "and a commit with no changelog section fails the run" 1
check "loudly, because main moved without the gate" "carries no changelog section" "$(cat "$TMP/step")"

# A version publishes once, and how the run ends depends on the commit the
# release that already holds the name was cut from.
printf '{"object":{"sha":"ffff1111"}}\n' >"$AT_RELEASE_STATE/tag.$DECLARED"
rm -f "$AT_RELEASE_STATE/created"
publish ffff1111
exit_is "the same commit again is a re-run, and succeeds" 0
same "publishing nothing a second time" "" "$(created)"
check "saying it is already out" "already published, at this commit" "$(cat "$TMP/step")"
merged ffff4444 "$(printf 'goal\n\n## Changelog\n\n- something a user sees\n')"
publish ffff4444
exit_is "a different commit under a published version fails" 1
check "because the product changed and the bump was forgotten" \
  "already published at ffff111, and this commit is ffff444" "$(cat "$TMP/step")"

rm -f "$AT_RELEASE_STATE/release.$DECLARED" "$AT_RELEASE_STATE/tag.$DECLARED"
BADVERSION="$TMP/bad-version-root"
copy_root "$BADVERSION"
printf '1.5\n' >"$BADVERSION/VERSION"
out="$(PATH="$NSTUBS:$PATH" GITHUB_REPOSITORY=zo-el/agent-toolkit-v2 GITHUB_STEP_SUMMARY="$TMP/step" "$BADVERSION/.github/publish-release.sh" ffff4444 2>&1)"
rc=$?
exit_is "a VERSION that is not three dot separated numbers fails the run" 1
check "saying which file is wrong" "VERSION is missing, or is not three dot separated numbers" "$out"

# ── the workflows ────────────────────────────────────────────────────────────
# What only a run can prove is the run's own, but what the file says is not.
echo "workflows"

RELEASE_YML="$ROOT/.github/workflows/release.yml"
check "a push to main is what makes a release" "$(printf 'on:\n  push:\n    branches: [main]')" "$(cat "$RELEASE_YML")"
check "runs are serialised, so releases go out in the order they were merged" \
  "$(printf 'concurrency:\n  group: release\n  cancel-in-progress: false')" "$(cat "$RELEASE_YML")"
check "the workflow may write the repository's contents, and nothing more" \
  "$(printf 'permissions:\n  contents: write')" "$(cat "$RELEASE_YML")"
check "it publishes as the repository's own token, so it starts no further run" \
  'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$(cat "$RELEASE_YML")"
check "the checkout is a work tree at no depth behind the commit" "fetch-depth: 1" "$(cat "$RELEASE_YML")"
checkouts="$(grep -h 'uses: actions/checkout@' "$ROOT/.github/workflows"/*.yml | sort -u)"
same "on the checkout whose node runtime GitHub still runs" "      - uses: actions/checkout@v7" "$checkouts"
check "the suite is the gate, through the gate the suite tests" ".github/suite-gate.sh" "$(cat "$RELEASE_YML")"
check "and publishing is the script the suite tests" '.github/publish-release.sh "$GITHUB_SHA"' "$(cat "$RELEASE_YML")"
check "the same suite runs against a pull request" "$(printf 'on:\n  pull_request:\n    branches: [main]')" \
  "$(cat "$ROOT/.github/workflows/tests.yml")"
runners="$(grep -h 'runs-on:' "$ROOT/.github/workflows"/*.yml | sort -u)"
same "on a runner that is not root and reaches npx, which is what leaves no skip" \
  "    runs-on: ubuntu-latest" "$runners"
for f in "$ROOT/.github"/*.sh; do
  [ -x "$f" ] || bad "every script a workflow runs is executable" "${f##*/} is not"
done
ok "every script a workflow runs is executable"
