# Updater cases, sourced by tests/run.sh after tests/install.sh, whose fake home
# and helpers these go on using. Nothing here reaches the real home, and nothing
# reaches GitHub: gh is a stub these cases drive from files.

echo "update.sh"

UP="$ROOT/hooks/update.sh"
UH="$(home update)"
export AT_GH_STATE="$TMP/gh-state"
USTUBS="$TMP/update-stubs"
mkdir -p "$USTUBS" "$AT_GH_STATE"

cat >"$USTUBS/gh" <<'SH'
#!/usr/bin/env bash
state="$AT_GH_STATE"
[ "$1 $2" = "auth token" ] && { [ -e "$state/token" ] && { echo gho_stub; exit 0; }; exit 1; }
[ "$1" = api ] || exit 1
shift
path=""
for a in "$@"; do case "$a" in -*) ;; *) path="$a"; break ;; esac; done
missing() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
answer() { [ -s "$state/$1" ] || missing; cat "$state/$1"; }
case "$path" in
  */releases/latest) answer latest ;;
  */releases/tags/*) answer "release.${path##*/}" ;;
  */git/ref/tags/*) answer "ref.${path##*/}" ;;
  */git/tags/*) answer "annotated.${path##*/}" ;;
  */compare/main...*) answer "compare.${path##*...}" ;;
  */tarball/*) answer "tarball.${path##*/}" ;;
  repos/*) [ -e "$state/repo" ] || missing; echo '{"full_name":"stub"}' ;;
  *) missing ;;
esac
SH
chmod +x "$USTUBS/gh"

track() { # the line, or nothing for no file at all
  if [ $# -eq 0 ]; then rm -f "$UH/.claude/agent-toolkit-track"; else printf '%s' "$1" >"$UH/.claude/agent-toolkit-track"; fi
}
up() { # arguments → out, rc, with the stub GitHub ahead of every other
  out="$(PATH="$USTUBS:$PATH" HOME="$UH" "$UP" "$@" 2>&1)"
  rc=$?
}
kept() { jq -r "$1 // empty" "$UH/.claude/agent-toolkit-staging.json" 2>/dev/null; }
keep() { # jq assignment over the record, then jq arguments
  local filter="$1"
  shift
  jq -c "$@" "$filter" "$UH/.claude/agent-toolkit-staging.json" >"$TMP/record" 2>/dev/null \
    && cp "$TMP/record" "$UH/.claude/agent-toolkit-staging.json"
}
# Six hours is the throttle, and a case that wants a check wants it now.
recheck() {
  keep ".checked_at -= 21601"
  up stage
}
says_nothing() { # name
  { [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "$1" || bad "$1" "exit $rc: ${out:-<empty>}"
}
reports() { # name, expected substring of additionalContext
  local said
  said="$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null)"
  check "$1" "$2" "$said"
}
staged() { printf '%s' "$UH/.claude/agent-toolkit-releases/$1"; }

# A release as GitHub serves one: a real version directory, tarred the way git
# archives one, carrying in its pax header the commit a machine verifies against.
publish() { # tag, commit, the version its tree declares, compare status
  local dir="$TMP/rel-$2"
  copy_root "$dir"
  printf '%s\n' "${3#v}" >"$dir/VERSION"
  python3 - "$dir" "$2" "$AT_GH_STATE/tarball.$2" <<'PY'
import sys
import tarfile

root, sha, out = sys.argv[1:]
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT, pax_headers={"comment": sha}) as archive:
    archive.add(root, arcname="zo-el-agent-toolkit-v2-" + sha[:7])
PY
  : >"$AT_GH_STATE/repo"
  : >"$AT_GH_STATE/token"
  printf '{"tag_name":"%s"}\n' "$1" >"$AT_GH_STATE/latest"
  printf '{"tag_name":"%s"}\n' "$1" >"$AT_GH_STATE/release.$1"
  printf '{"object":{"sha":"%s","type":"commit"}}\n' "$2" >"$AT_GH_STATE/ref.$1"
  printf '{"status":"%s"}\n' "${4:-behind}" >"$AT_GH_STATE/compare.$2"
}

# The ordinary machine every case below starts from: a repository it can see,
# with nothing published yet, so a check succeeds and says nothing.
: >"$AT_GH_STATE/repo"
: >"$AT_GH_STATE/token"

# ── modes ────────────────────────────────────────────────────────────────────
before="$(snapshot "$UH")"
out="$(HOME="$UH" "$UP" --dry-run 2>&1 >/dev/null)"
rc=$?
exit_is "an unknown argument exits 2" 2
check "and prints usage on stderr" "usage: update.sh" "$out"
same "and writes nothing" "$before" "$(snapshot "$UH")"
HOME="$UH" "$UP" stage apply >/dev/null 2>&1
exit_is "two arguments exit 2" "$?"
up --help
check "--help prints the usage" "stage   find a release" "$out"
exit_is "and exits 0" 0

up apply
says_nothing "apply on a machine with nothing to say prints nothing"
up stage
says_nothing "and stage never prints, whatever it did"

# ── the track ────────────────────────────────────────────────────────────────
# Each form, and what the machine does under it. A line the updater will not
# read stops it, because guessing what was meant is worse than saying so.
track off
rm -f "$UH/.claude/agent-toolkit-staging.json"
up apply
says_nothing "a machine tracking off is told nothing at all"
up now
exit_is "and now on it exits 1" 1
check "saying why" "says off" "$out"
up stage
[ ! -e "$UH/.claude/agent-toolkit-staging.json" ] && ok "and neither mode checks anything" \
  || bad "and neither mode checks anything" "$(cat "$UH/.claude/agent-toolkit-staging.json")"

track v42
up apply
reports "a track holding a bare number is refused" '✗ ~/.claude/agent-toolkit-track holds "v42"'
reports "naming the three forms it does read" "It holds latest, a release such as v1.5.0, or off"
check "with the fix against the file" "edit or remove ~/.claude/agent-toolkit-track" "$out"
check "and a message the user sees" '"systemMessage":"agent-toolkit: 1 update problem' "$out"
track "$(printf 'latest\nv1.5.0')"
up apply
reports "and so is a second line under a good one" '✗ ~/.claude/agent-toolkit-track holds'
track "  latest  "
up apply
says_nothing "blank space around the line is not content"
track ""
up apply
says_nothing "and an empty file means what no file means"
track

# ── the record ───────────────────────────────────────────────────────────────
rm -f "$UH/.claude/agent-toolkit-staging.json"
up stage
[ -n "$(kept .checked_at)" ] && ok "stage records when the check began" \
  || bad "stage records when the check began" "$(cat "$UH/.claude/agent-toolkit-staging.json" 2>/dev/null)"
same "and when this machine first checked at all" "$(kept .checked_at)" "$(kept .first_check_at)"

before="$(file_id "$UH/.claude/agent-toolkit-staging.json")"
up stage
same "a second check inside six hours does nothing" "$before" "$(file_id "$UH/.claude/agent-toolkit-staging.json")"
recheck
[ "$(kept .checked_at)" -gt "$(($(date -u +%s) - 60))" ] && ok "and one after it runs" \
  || bad "and one after it runs" "checked_at is still $(kept .checked_at)"
# A clock that was wrong once must not stop a machine checking for good.
keep ".checked_at += 100000"
up stage
[ "$(kept .checked_at)" -lt "$(($(date -u +%s) + 60))" ] && ok "a check recorded in the future counts as never having happened" \
  || bad "a check recorded in the future counts as never having happened" "checked_at is $(kept .checked_at)"

printf 'not json at all\n' >"$UH/.claude/agent-toolkit-staging.json"
up stage
up apply
reports "a record that will not read is replaced, and the run says so" "did not read and was replaced"
up apply
says_nothing "and the next run says nothing, because it now reads"

# ── overlapping stages ───────────────────────────────────────────────────────
# The second takes no lock and exits, so staging never queues behind itself.
keep ".checked_at -= 21601"
before="$(kept .checked_at)"
lock_holder "$UH/.claude/agent-toolkit-releases/.stage.lock"
up stage
same "a second stage takes no lock and exits" "$before" "$(kept .checked_at)"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
up stage
[ "$(kept .checked_at)" != "$before" ] && ok "and the next one takes it" || bad "and the next one takes it" "checked_at did not move"

# ── a machine nobody has heard from ──────────────────────────────────────────
# Measured from the first check it ever made, so a fresh install is not told a
# week has gone by without one succeeding.
keep ".first_check_at -= 604801 | .checked_at -= 604801 | del(.succeeded_at)"
up apply
reports "a week of checks with none succeeding is said out loud" "no update check has succeeded in seven days"
check "with the command that tries now" "update.sh now" "$out"
keep ".succeeded_at = .checked_at + 604800"
up apply
says_nothing "and a check that did succeed inside the week is silent"

# ── checking ─────────────────────────────────────────────────────────────────
UH="$(home update-cycle)"
SHA=b5df2e05bbd4f4cfffb524e25d11282ecb186db3
rm -f "$AT_GH_STATE/token" "$AT_GH_STATE/repo"

recheck
up apply
reports "a machine whose gh holds no token is told so" "gh holds no token for github.com"
check "with the command that signs it in" "gh auth login --hostname github.com" "$out"

: >"$AT_GH_STATE/token"
recheck
up apply
reports "a token that cannot see the repository is not the same as no release" "gh cannot see zo-el/agent-toolkit-v2"

: >"$AT_GH_STATE/repo"
recheck
says_nothing "and a repository that reads with nothing published says nothing at all"
up apply
says_nothing "at the session start after it, too"
[ -n "$(kept .succeeded_at)" ] && ok "because being told there is no release is a check that succeeded" \
  || bad "a repository with no release is a successful check" "nothing was recorded as succeeding"

track v9.9.9
recheck
up apply
reports "a track naming a release nobody published is a finding of its own" "names v9.9.9, which nobody has published"
check "with the fix against the track" "edit ~/.claude/agent-toolkit-track to a release that exists" "$out"
track

# ── staging ──────────────────────────────────────────────────────────────────
publish v1.5.0 "$SHA" v1.5.0
rm -f "$UH/.claude/agent-toolkit-staging.json"
up stage
says_nothing "staging a release prints nothing"
[ -d "$(staged v1.5.0)" ] && ok "and leaves it unpacked under its release name" \
  || bad "a release is unpacked under its name" "$(ls "$UH/.claude/agent-toolkit-releases" 2>&1)"
same "with the revision the updater wrote beside the VERSION the archive carried" \
  "${SHA:0:7}" "$(cat "$(staged v1.5.0)/REVISION" 2>/dev/null)"
same "so the folder holds one whole version" "v1.5.0·${SHA:0:7}" \
  "$(python3 "$ROOT/hooks/lib/version.py" root "$(staged v1.5.0)")"
same "and the record names the release and its commit" "v1.5.0 $SHA" "$(kept .wanted) $(kept .commit)"
[ -z "$(find "$UH/.claude/agent-toolkit-releases" -maxdepth 1 -name '.staging.*' -print -quit)" ] \
  && ok "and no part-written folder is left behind" || bad "no part-written folder is left" "one was"

before="$(file_id "$(staged v1.5.0)")"
recheck
same "a release already unpacked is not fetched again" "$before" "$(file_id "$(staged v1.5.0)")"
rm -rf "$(staged v1.5.0)"
recheck
[ -d "$(staged v1.5.0)" ] && ok "and one deleted by hand is staged again at the next check" \
  || bad "a staged folder deleted by hand is staged again" "it was not"

rm -rf "$(staged v1.5.0)"
printf '{"object":{"sha":"deadbeefdeadbeef","type":"tag"}}\n' >"$AT_GH_STATE/ref.v1.5.0"
printf '{"object":{"sha":"%s"}}\n' "$SHA" >"$AT_GH_STATE/annotated.deadbeefdeadbeef"
recheck
same "an annotated tag is followed to the commit it points at" "$SHA" "$(kept .commit)"

# ── verifying ────────────────────────────────────────────────────────────────
# A release this machine will not run, and the reason said out loud rather than
# unpacked, installed, and repeated at every session start after that.
refuses() { # release, name, expected finding text
  rm -rf "$(staged "$1")"
  recheck
  up apply
  reports "$2" "$3"
  [ ! -d "$(staged "$1")" ] && ok "and it is not staged" || bad "and it is not staged" "$1 was staged anyway"
}

publish v1.5.0 0000000000000000000000000000000000000000 v1.5.0
cp "$AT_GH_STATE/tarball.$SHA" "$AT_GH_STATE/tarball.0000000000000000000000000000000000000000"
refuses v1.5.0 "an archive carrying another commit is refused, naming both" \
  "names commit 0000000 and its archive carries b5df2e0"

publish v1.5.0 "$SHA" v1.5.0 diverged
refuses v1.5.0 "a commit that is not on main is refused, naming the release" \
  "v1.5.0 names commit b5df2e0, which is not on main"

publish v1.5.0 "$SHA" v1.5.0
rm -f "$AT_GH_STATE/compare.$SHA"
refuses v1.5.0 "and GitHub not answering is an ordinary failure, not a claim about the release" \
  "the last update check failed"
case "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out")" in
  *"not on main"*) bad "one unlucky call never says the repository was tampered with" "it did" ;;
  *) ok "one unlucky call never says the repository was tampered with" ;;
esac

publish v1.6.0 "$SHA" v1.5.0
refuses v1.6.0 "a release whose tree declares another version is refused, naming both" \
  "v1.6.0 holds a tree declaring version v1.5.0·b5df2e0"

publish v1.5.0 "$SHA" v1.5.0
printf 'not a tarball at all\n' >"$AT_GH_STATE/tarball.$SHA"
refuses v1.5.0 "an archive that will not decompress stages nothing" "would not unpack"
publish v1.5.0 "$SHA" v1.5.0

# ── applying ─────────────────────────────────────────────────────────────────
# A session start takes the release that is waiting, or costs nothing at all.
UH="$(home update-apply)"
OLD=aaaaaaa1111111111111111111111111111aaaa
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/live-v1.4.0"
printf '1.4.0\n' >"$TMP/live-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/live-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$UH" "$TMP/live-v1.4.0/install.sh" >/dev/null 2>&1
same "the machine starts at the version it installed" "v1.4.0·${OLD:0:7}" "$(cat "$UH/.claude/agent-toolkit-version")"

up apply
says_nothing "apply with nothing staged prints nothing"
publish v1.4.0 "$OLD" v1.4.0
recheck
up apply
says_nothing "and a staged release equal to the live version installs nothing"

publish v1.5.0 "$SHA" v1.5.0
recheck
[ -d "$(staged v1.5.0)" ] && ok "a newer release is staged and left waiting" || bad "a newer release is staged" "it was not"
same "and nothing has gone live yet" "v1.4.0·${OLD:0:7}" "$(cat "$UH/.claude/agent-toolkit-version")"
up apply
reports "the session start after it says what went live, and what it came from" "v1.5.0 is live, from v1.4.0·${OLD:0:7}"
check "with the one line the user sees" '"systemMessage":"agent-toolkit: updated to v1.5.0. Restart Claude Code to load the new version"' "$out"
check "and a rescan, because every skill link moved" '"reloadSkills":true' "$out"
same "the stable link points at the release" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
same "and the stamp is its version" "v1.5.0·${SHA:0:7}" "$(cat "$UH/.claude/agent-toolkit-version")"
same "with the directory it moved off recorded, for pruning to keep" "$TMP/live-v1.4.0" "$(kept .previous)"
reports "and install's own report travels with it" "agent-toolkit → $(staged v1.5.0)"

up apply
says_nothing "the next session start says nothing, because this one was told"
keep '.reported = "v1.4.0·aaaaaaa"'
up apply
reports "and a session that finds a version it never reported says so, whoever moved it" "v1.5.0 is live, from v1.4.0·aaaaaaa"

# ── an activation that does not go live ──────────────────────────────────────
# Install writes nothing from a root that fails its checks, so the machine stays
# exactly where it was and the release is not tried again.
publish v1.6.0 cccccccc2222222222222222222222222222cccc v1.6.0
recheck
rm -f "$(staged v1.6.0)/hooks/guard.sh"
before="$(snapshot "$UH/.claude/skills")"
up apply
reports "a release that fails its root checks is a required finding" "v1.6.0 did not go live"
reports "carrying install's own reason" "hooks/guard.sh is missing from the version directory"
reports "and naming both versions" "the wanted release is v1.6.0 and the live version is v1.5.0"
check "with the command that tries again" "update.sh now" "$out"
same "the stable link has not moved" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
same "and nothing under skills changed" "$before" "$(snapshot "$UH/.claude/skills")"
same "the version is marked bad" "v1.6.0" "$(kept '.bad[0]')"

up apply
case "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out")" in
  *"install.sh"*) bad "a version marked bad is not installed again" "it ran install again" ;;
  *) ok "a version marked bad is not installed again" ;;
esac

# ── one activation at a time ─────────────────────────────────────────────────
rm -rf "$(staged v1.6.0)"
keep 'del(.bad)'
publish v1.6.0 cccccccc2222222222222222222222222222cccc v1.6.0
recheck
lock_holder "$UH/.claude/agent-toolkit-releases/.apply.lock"
up apply
same "a session that cannot take the activation lock installs nothing" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
up apply
same "and the next one activates" "$(staged v1.6.0)" "$(readlink "$UH/.claude/agent-toolkit")"

# ── now ──────────────────────────────────────────────────────────────────────
# The whole cycle in the foreground, which is what a person runs the moment
# updates stop working.
UH="$(home update-now)"
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/now-v1.4.0"
printf '1.4.0\n' >"$TMP/now-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/now-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$UH" "$TMP/now-v1.4.0/install.sh" >/dev/null 2>&1

up now
exit_is "now on a machine already at the wanted release exits 0" 0
check "having re-installed it" "Nothing to change" "$out"
same "and left it live" "$TMP/now-v1.4.0" "$(readlink "$UH/.claude/agent-toolkit")"

publish v1.5.0 "$SHA" v1.5.0
up now
exit_is "now on a machine behind a release installs it and exits 0" 0
check "saying what it fetched" "v1.5.0 is ready at" "$out"
check "then printing install's own report" "~/.claude/agent-toolkit → $(staged v1.5.0)" "$out"
same "and the release is live" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
# The throttle is for a session start, never for a person who has just asked.
before="$(kept .checked_at)"
up now
[ "$(kept .checked_at)" != "$before" ] && ok "and now never waits out the throttle" \
  || bad "now ignores the throttle" "checked_at did not move"

rm -f "$AT_GH_STATE/token"
before="$(readlink "$UH/.claude/agent-toolkit") $(cat "$UH/.claude/agent-toolkit-version") $(snapshot "$UH/.claude/skills")"
up now
exit_is "now that could fetch nothing exits 1" 1
check "printing the reason" "gh holds no token for github.com" "$out"
check "with its fix" "gh auth login --hostname github.com" "$out"
same "and leaving the live version exactly where it was" "$before" \
  "$(readlink "$UH/.claude/agent-toolkit") $(cat "$UH/.claude/agent-toolkit-version") $(snapshot "$UH/.claude/skills")"
: >"$AT_GH_STATE/token"

# A version apply will not touch again is exactly what now is for.
publish v1.6.0 dddddddd3333333333333333333333333333dddd v1.6.0
recheck
rm -f "$(staged v1.6.0)/hooks/guard.sh"
up apply
same "a release that failed is marked bad" "v1.6.0" "$(kept '.bad[0]')"
rm -rf "$(staged v1.6.0)"
publish v1.6.0 dddddddd3333333333333333333333333333dddd v1.6.0
up now
exit_is "and now tries it regardless of the mark" 0
same "so a machine that fixed the cause moves on" "$(staged v1.6.0)" "$(readlink "$UH/.claude/agent-toolkit")"
same "and the mark is gone" "" "$(kept '.bad[0]')"

# ── dev mode ─────────────────────────────────────────────────────────────────
# A clone is somebody's work in progress: the updater reads it and leaves it be.
UH="$(home update-dev)"
CLONE="$TMP/dev-clone"
copy_root "$CLONE"
printf '1.4.0\n' >"$CLONE/VERSION"
git -C "$CLONE" init -q && git -C "$CLONE" add -A >/dev/null 2>&1 && git -C "$CLONE" commit -q -m clone
PATH="$USTUBS:$PATH" HOME="$UH" "$CLONE/install.sh" >/dev/null 2>&1
CLONE_VERSION="v1.4.0·$(git -C "$CLONE" rev-parse --short HEAD)"
same "the clone is live, at the version it declares and the tree it holds" "$CLONE_VERSION" \
  "$(cat "$UH/.claude/agent-toolkit-version")"

publish v1.5.0 "$SHA" v1.5.0
up stage
[ ! -d "$(staged v1.5.0)" ] && ok "a release is not downloaded onto a machine running a clone" \
  || bad "dev mode downloads nothing" "it was staged"
same "though the check still happens, so the machine knows what is out there" "v1.5.0" "$(kept .wanted)"
up apply
reports "and the clone is told once, naming both versions" \
  "v1.5.0 is published and this machine runs a clone at $CLONE_VERSION"
check "with the way to pull it" "git -C $CLONE pull" "$out"
reports "and the way to install the release over it" "update.sh now installs the release over it"
same "the clone is still live" "$CLONE" "$(readlink "$UH/.claude/agent-toolkit")"
up apply
says_nothing "and it is not told again"

# The comparison is the semantic version alone, so a clone carrying work of its
# own is not news, and one already at the release is not either.
printf '1.5.0\n' >"$CLONE/VERSION"
git -C "$CLONE" commit -qam bump
keep 'del(.announced)'
recheck
up apply
says_nothing "a clone at the released version is told nothing"
printf '1.6.0\n' >"$CLONE/VERSION"
git -C "$CLONE" commit -qam ahead
recheck
up apply
says_nothing "and one holding a bump nobody has released is told nothing either"

up now
exit_is "now installs the release over a clone" 0
same "so the machine leaves dev mode" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
[ -d "$CLONE/.git" ] && ok "and the clone is left on disk, untouched" || bad "the clone is left alone" "it is gone"

# ── pruning ──────────────────────────────────────────────────────────────────
# Three directories are worth keeping: the one that is live, the one that is
# wanted, and the one the machine fell off, which is what it falls back to.
UH="$(home update-prune)"
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/prune-v1.4.0"
printf '1.4.0\n' >"$TMP/prune-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/prune-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$UH" "$TMP/prune-v1.4.0/install.sh" >/dev/null 2>&1
publish v1.5.0 "$SHA" v1.5.0
recheck
up apply
same "the machine is on the release, off the directory it recorded" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"

mkdir -p "$(staged v1.1.0)" "$(staged v1.2.0)" "$(staged v1.3.0)"
cp -r "$TMP/prune-v1.4.0" "$(staged v1.4.0)"
keep '.previous = $p' --arg p "$(staged v1.4.0)"
publish v1.6.0 eeeeeeee4444444444444444444444444444eeee v1.6.0
recheck
[ ! -d "$(staged v1.1.0)" ] && [ ! -d "$(staged v1.2.0)" ] && [ ! -d "$(staged v1.3.0)" ] \
  && ok "a release that is none of the three is removed" || bad "old releases are pruned" "$(ls "$UH/.claude/agent-toolkit-releases")"
[ -d "$(staged v1.5.0)" ] && ok "the live one stays" || bad "the live one stays" "it went"
[ -d "$(staged v1.6.0)" ] && ok "the wanted one stays" || bad "the wanted one stays" "it went"
[ -d "$(staged v1.4.0)" ] && ok "and the one live before it stays" || bad "the previous one stays" "it went"

# A stage that was killed leaves a folder under a name no release ever has.
mkdir -p "$UH/.claude/agent-toolkit-releases/.staging.old" "$UH/.claude/agent-toolkit-releases/.staging.new"
touch -d '2 days ago' "$UH/.claude/agent-toolkit-releases/.staging.old"
recheck
[ ! -d "$UH/.claude/agent-toolkit-releases/.staging.old" ] && ok "a part-written folder more than a day old is removed" \
  || bad "an old part-written folder is removed" "it stayed"
[ -d "$UH/.claude/agent-toolkit-releases/.staging.new" ] && ok "and a fresh one is left, because a stage may still be writing it" \
  || bad "a fresh part-written folder is left" "it went"

mkdir -p "$(staged v1.0.0)"
up apply
[ -d "$(staged v1.0.0)" ] && ok "apply prunes nothing, so no session start waits on a removal" \
  || bad "apply prunes nothing" "it removed one"
