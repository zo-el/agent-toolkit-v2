# Updater cases, sourced by tests/run.sh after tests/install.sh, whose fake home
# and helpers these go on using. Nothing here reaches the real home, and nothing
# reaches GitHub: gh is a stub these cases drive from files.

echo "update.sh"

UP="$ROOT/hooks/update.sh"
UH="$(home update)"
export AT_GH_STATE="$TMP/gh-state"
USTUBS="$TMP/update-stubs"
mkdir -p "$USTUBS" "$AT_GH_STATE"

# One stub GitHub for every case here and in tests/release.sh: it answers with
# whatever files $AT_GH_STATE holds, and records what it was asked to publish.
cat >"$USTUBS/gh" <<'SH'
#!/usr/bin/env bash
state="$AT_GH_STATE"
printf '%s\n' "$*" >>"$state/calls"
missing() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "${1:-} ${2:-}" in
  "auth token")
    [ -e "$state/token" ] || exit 1
    echo gho_stub
    exit 0 ;;
  "release view")
    [ -e "$state/release.$3" ] || exit 1
    echo "$3"
    exit 0 ;;
  "release create")
    printf '%s\n' "$*" >>"$state/created"
    : >"$state/release.$3"
    exit 0 ;;
esac
[ "${1:-}" = api ] || exit 1
shift
path="$1"
shift
filter="."
while [ $# -gt 0 ]; do
  [ "$1" = --jq ] && { filter="$2"; shift; }
  shift
done
answer() { [ -s "$state/$1" ] || missing; jq -r "$filter" "$state/$1"; }
case "$path" in
  */releases/latest) answer latest ;;
  */releases/tags/*) answer "release.${path##*/}" ;;
  */git/ref/tags/*) answer "ref.${path##*/}" ;;
  */git/tags/*) answer "annotated.${path##*/}" ;;
  */compare/main...*) answer "compare.${path##*...}" ;;
  */commits/*/pulls) sha="${path#*/commits/}"; answer "pulls.${sha%/pulls}" ;;
  */tarball/*) [ -s "$state/tarball.${path##*/}" ] || missing; cat "$state/tarball.${path##*/}" ;;
  repos/*) [ -e "$state/repo" ] || missing; printf '{"full_name":"stub"}\n' | jq -r "$filter" ;;
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
  # Always 0: Claude Code drops the plain stdout of a hook that exits non-zero,
  # so a report that arrives with a status is a report nobody reads.
  [ "$rc" = 0 ] || bad "$1" "apply exited $rc"
  said="$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null)"
  check "$1" "$2" "$said"
}
advises() { # name, expected substring of additionalContext, which says nothing is broken
  reports "$1" "$2"
  case "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null)" in
    *✗*) bad "$1, with no required finding beside it" "$out" ;;
    *) ok "$1, with no required finding beside it" ;;
  esac
}
staged() { printf '%s' "$UH/.claude/agent-toolkit-releases/$1"; }
asked() { cat "$AT_GH_STATE/calls" 2>/dev/null; }
forget_calls() { : >"$AT_GH_STATE/calls"; }
# The commit every fixture release is cut from, and the one tests/release.sh
# publishes against too.
SHA=b5df2e05bbd4f4cfffb524e25d11282ecb186db3
OLD=aaaaaaa1111111111111111111111111111aaaa

# A release as GitHub serves one: a real version directory, tarred the way git
# archives one, carrying in its pax header the commit a machine verifies against.
publish() { # tag, commit, the version its tree declares, compare status, a file to serve without
  local dir="$TMP/rel-$2"
  copy_root "$dir"
  printf '%s\n' "${3#v}" >"$dir/VERSION"
  [ -z "${5:-}" ] || rm -f "$dir/$5"
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
rc=$?
exit_is "two arguments exit 2" 2
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
recheck
says_nothing "and an empty file means what no file means"
same "so a machine with an empty one still follows latest" "" "$(kept .failure.text)"
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
keep ".checked_at += 100000"
up stage
[ "$(kept .checked_at)" -lt "$(($(date -u +%s) + 60))" ] && ok "a check recorded in the future counts as never having happened" \
  || bad "a check recorded in the future counts as never having happened" "checked_at is $(kept .checked_at)"

printf 'not json at all\n' >"$UH/.claude/agent-toolkit-staging.json"
up stage
up apply
reports "a record that will not read is replaced, and the run says so" "! ~/.claude/agent-toolkit-staging.json did not read and was replaced"
up apply
says_nothing "and the next run says nothing, because it now reads"

# ── overlapping stages ───────────────────────────────────────────────────────
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
reports "a week of checks with none succeeding is said out loud" "! no update check has succeeded in seven days"
check "with the command that tries now" "update.sh now" "$out"
keep ".succeeded_at = .checked_at + 604800"
up apply
says_nothing "and a check that did succeed inside the week is silent"

# ── checking ─────────────────────────────────────────────────────────────────
UH="$(home update-cycle)"
rm -f "$AT_GH_STATE/token" "$AT_GH_STATE/repo"

recheck
up apply
reports "a machine whose gh holds no token is told so" "! the last update check failed: gh holds no token for github.com"
check "with the command that signs it in" "gh auth login --hostname github.com" "$out"

: >"$AT_GH_STATE/token"
recheck
up apply
reports "a token that cannot see the repository is not the same as no release" "! the last update check failed: gh cannot see zo-el/agent-toolkit-v2"

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
reports "a track naming a release nobody published is a finding of its own" "✗ ~/.claude/agent-toolkit-track names v9.9.9, which nobody has published"
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

forget_calls
recheck
case "$(asked)" in
  *tarball*) bad "a release already unpacked is not fetched again" "it downloaded it again" ;;
  *) ok "a release already unpacked is not fetched again" ;;
esac
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
  "✗ v1.5.0 names commit 0000000 and its archive carries b5df2e0"

publish v1.5.0 "$SHA" v1.5.0 diverged
refuses v1.5.0 "a commit that is not on main is refused, naming the release" \
  "✗ v1.5.0 names commit b5df2e0, which is not on main"

publish v1.5.0 "$SHA" v1.5.0
rm -f "$AT_GH_STATE/compare.$SHA"
refuses v1.5.0 "and GitHub not answering is an ordinary failure, not a claim about the release" \
  "! the last update check failed"

case "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out")" in
  *"not on main"*) bad "one unlucky call never says the repository was tampered with" "it did" ;;
  *) ok "one unlucky call never says the repository was tampered with" ;;
esac

publish v1.6.0 "$SHA" v1.5.0
refuses v1.6.0 "a release whose tree declares another version is refused, naming both" \
  "✗ v1.6.0 holds a tree declaring version v1.5.0·b5df2e0"

publish v1.5.0 "$SHA" v1.5.0
printf 'not a tarball at all\n' >"$AT_GH_STATE/tarball.$SHA"
refuses v1.5.0 "an archive that will not open stages nothing" "! the last update check failed: v1.5.0 would not open as an archive"
# Half an archive still opens and still says which commit it is, so a truncated
# download is caught by the extraction rather than by the header.
publish v1.5.0 "$SHA" v1.5.0
python3 -c 'import sys
whole = open(sys.argv[1], "rb").read()
open(sys.argv[1], "wb").write(whole[: len(whole) // 2])' "$AT_GH_STATE/tarball.$SHA"
refuses v1.5.0 "and one that will not decompress whole stages nothing either" "! the last update check failed: v1.5.0 would not unpack"
publish v1.5.0 "$SHA" v1.5.0

# ── what a release folder has to be ──────────────────────────────────────────
# A release is what this machine staged, not whatever sits at the path. Anything
# under ~/.claude is writable by every process running as the user, this session
# included, so activation asks the folder to be what its name says.
UH="$(home update-planted)"
publish v1.5.0 "$SHA" v1.5.0
recheck
up apply
mkdir -p "$(staged v9.9.9)"
cp "$ROOT/install.sh" "$(staged v9.9.9)/install.sh"
keep '.wanted = "v9.9.9"'
before="$(readlink "$UH/.claude/agent-toolkit")"
up apply
same "a directory planted at a release name is not installed" "$before" "$(readlink "$UH/.claude/agent-toolkit")"
reports "and the machine says it declares no version of its own" "v9.9.9 declares no version of its own"

# A whole version directory, sitting where a relative name reaches it. The record
# is a file anything running as the user can write, so the name it holds is read
# with the same suspicion as the track's line: refused before a path is built.
copy_root "$UH/.claude/planted"
printf '1.5.0\n' >"$UH/.claude/planted/VERSION"
printf '%s\n' "${SHA:0:7}" >"$UH/.claude/planted/REVISION"
keep '.wanted = "../planted"'
up apply
same "a wanted release that is a path rather than a name reaches nothing" "$before" "$(readlink "$UH/.claude/agent-toolkit")"
says_nothing "and is refused before a path is built from it, so there is nothing to report"

# ── a home reached through a link ────────────────────────────────────────────
# The stable link resolves every component of its target and $HOME does not, so
# every path the updater compares has to be resolved on both sides.
UH="$(home update-realpath)"
LINKED="$TMP/linked-home"
rm -f "$LINKED"
ln -s "$UH" "$LINKED"
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/link-v1.4.0"
printf '1.4.0\n' >"$TMP/link-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/link-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$LINKED" "$TMP/link-v1.4.0/install.sh" >/dev/null 2>&1
publish v1.5.0 "$SHA" v1.5.0
out="$(PATH="$USTUBS:$PATH" HOME="$LINKED" "$UP" stage 2>&1)"
out="$(PATH="$USTUBS:$PATH" HOME="$LINKED" "$UP" apply 2>&1)"
said="$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null)"
case "$said" in
  *"did not go live"*) bad "an activation through a linked home is not read as a failure" "$said" ;;
  *) ok "an activation through a linked home is not read as a failure" ;;
esac
same "and the release is live" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
# Wanted moves on, so the live directory is kept by the link alone.
publish v1.6.0 ffffffff5555555555555555555555555555ffff v1.6.0
keep ".checked_at -= 21601"
out="$(PATH="$USTUBS:$PATH" HOME="$LINKED" "$UP" stage 2>&1)"
same "the wanted release moves on" "v1.6.0" "$(kept .wanted)"
[ -d "$(staged v1.5.0)" ] && ok "and pruning never takes the directory that is live" \
  || bad "pruning keeps the live directory through a linked home" "it removed it"

# ── a lock that cannot be taken at all ───────────────────────────────────────
# Held by another run is an answer. Anything else stops updates, and a machine
# that stops updating in silence never starts again.
UH="$(home update-lockless)"
publish v1.5.0 "$SHA" v1.5.0
mkdir -p "$UH/.claude/agent-toolkit-releases"
mkdir -p "$UH/.claude/agent-toolkit-releases/.stage.lock"
up stage
up apply
reports "a lock the machine cannot take at all is recorded" "cannot be written, so no update can be serialised"
check "with a fix that reinstalls the toolkit" "install.sh" "$out"
up now
check "and now says the same rather than blaming another session" "cannot be written" "$out"
exit_is "and exits 1 having changed nothing" 1
rmdir "$UH/.claude/agent-toolkit-releases/.stage.lock"
up now
exit_is "while the same machine with the lock back takes the release" 0

# ── applying ─────────────────────────────────────────────────────────────────
UH="$(home update-apply)"
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/live-v1.4.0"
printf '1.4.0\n' >"$TMP/live-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/live-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$UH" "$TMP/live-v1.4.0/install.sh" >/dev/null 2>&1
same "the machine starts at the version it installed" "v1.4.0·${OLD:0:7}" "$(cat "$UH/.claude/agent-toolkit-version")"

up apply
says_nothing "apply with nothing staged prints nothing"

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

forget_calls
up apply
says_nothing "the next session start says nothing, because this one was told"
same "and apply asked GitHub for nothing, so no session start waits on the network" "" "$(asked)"
# The folder is now both staged and live, which is the case that must cost no
# install at all: a missing skill link is what an install would put back.
rm -f "$UH/.claude/skills/toolkit"
up apply
[ ! -e "$UH/.claude/skills/toolkit" ] && ok "and a staged release equal to the live version runs no install" \
  || bad "an equal staged version runs no install" "install ran and relinked the skill"
PATH="$USTUBS:$PATH" HOME="$UH" "$(staged v1.5.0)/install.sh" >/dev/null 2>&1
keep '.reported = "v1.4.0·aaaaaaa"'
up apply
reports "and a session that finds a version it never reported says so, whoever moved it" "v1.5.0 is live, from v1.4.0·aaaaaaa"

# ── an activation that does not go live ──────────────────────────────────────
# Install writes nothing from a root that fails its checks, so the machine stays
# exactly where it was and the release is not tried again.
publish v1.6.0 cccccccc2222222222222222222222222222cccc v1.6.0 behind hooks/guard.sh
recheck
before="$(snapshot "$UH/.claude/skills")"
up apply
reports "a release that fails its root checks is a required finding" "✗ v1.6.0 did not go live"
reports "carrying install's own reason" "hooks/guard.sh is missing from the version directory"
reports "and naming both versions" "the wanted release is v1.6.0 and the live version is v1.5.0"
check "with the command that tries again" "update.sh now" "$out"
same "the stable link has not moved" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
same "and nothing under skills changed" "$before" "$(snapshot "$UH/.claude/skills")"
same "the version is marked bad" "v1.6.0" "$(kept '.bad[0]')"

up apply
reports "a version marked bad is not installed again, and is said at every start" \
  "✗ v1.6.0 did not go live, so this machine is still on v1.5.0·${SHA:0:7}"
check "with the command that tries it once the cause is dealt with" \
  "~/.claude/agent-toolkit/hooks/update.sh now" "$out"
case "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out")" in
  *"Changed"*) bad "a version marked bad runs no install" "install ran again" ;;
  *) ok "a version marked bad runs no install" ;;
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

# ── the digest ───────────────────────────────────────────────────────────────
# What the seal binds, against a tree built to hold every shape. A release tree
# carries no symlink of its own, so this is the only place the target field is
# exercised at all.
echo "seal.py"

SEALED="$TMP/sealed-tree"
rm -rf "$SEALED"
mkdir -p "$SEALED/hooks" "$SEALED/skills/one" "$SEALED/empty"
printf 'rules\n' >"$SEALED/CLAUDE.md"
printf 'run me\n' >"$SEALED/hooks/go.sh"
chmod 755 "$SEALED/hooks/go.sh"
printf 'a skill\n' >"$SEALED/skills/one/SKILL.md"
ln -s ../../CLAUDE.md "$SEALED/skills/one/rules"
seal_of() { python3 "$ROOT/hooks/lib/seal.py" "$SEALED" 2>/dev/null; }
WHOLE="$(seal_of)"
binds() { # name, the command that changes the tree, the command that puts it back
  eval "$2"
  [ "$(seal_of)" != "$WHOLE" ] && ok "$1" || bad "$1" "the digest did not move"
  eval "$3"
  [ "$(seal_of)" = "$WHOLE" ] || bad "$1" "putting it back did not restore the digest"
}
ignores() { # name, the command that changes the tree, the command that puts it back
  eval "$2"
  [ "$(seal_of)" = "$WHOLE" ] && ok "$1" || bad "$1" "the digest moved"
  eval "$3"
}

check "the digest names the algorithm that made it" "sha256:" "$WHOLE"
binds "it binds a file's bytes" 'printf "more\n" >>"$SEALED/CLAUDE.md"' 'printf "rules\n" >"$SEALED/CLAUDE.md"'
binds "and the bit that lets a file run" 'chmod 755 "$SEALED/CLAUDE.md"' 'chmod 644 "$SEALED/CLAUDE.md"'
binds "and a file added" 'printf "x\n" >"$SEALED/hooks/extra"' 'rm -f "$SEALED/hooks/extra"'
binds "and a file taken away" 'rm -f "$SEALED/hooks/go.sh"' \
  'printf "run me\n" >"$SEALED/hooks/go.sh"; chmod 755 "$SEALED/hooks/go.sh"'
binds "and a file moved to another name" 'mv "$SEALED/CLAUDE.md" "$SEALED/RULES.md"' 'mv "$SEALED/RULES.md" "$SEALED/CLAUDE.md"'
binds "and where a symlink points" \
  'ln -sfn /etc/passwd "$SEALED/skills/one/rules"' 'ln -sfn ../../CLAUDE.md "$SEALED/skills/one/rules"'
binds "and a symlink replaced by what it pointed at" \
  'rm -f "$SEALED/skills/one/rules"; printf "rules\n" >"$SEALED/skills/one/rules"' \
  'rm -f "$SEALED/skills/one/rules"; ln -s ../../CLAUDE.md "$SEALED/skills/one/rules"'
binds "and two files swapped between their names" \
  'mv "$SEALED/CLAUDE.md" "$SEALED/.swap"; mv "$SEALED/hooks/go.sh" "$SEALED/CLAUDE.md"; mv "$SEALED/.swap" "$SEALED/hooks/go.sh"' \
  'mv "$SEALED/CLAUDE.md" "$SEALED/.swap"; mv "$SEALED/hooks/go.sh" "$SEALED/CLAUDE.md"; mv "$SEALED/.swap" "$SEALED/hooks/go.sh"'
# Nothing about running the tree, so nothing the seal answers for.
ignores "it ignores a timestamp" 'touch -d "2001-02-03" "$SEALED/CLAUDE.md"' ':'
ignores "and an empty directory, which the root checks answer for" 'rmdir "$SEALED/empty"' 'mkdir "$SEALED/empty"'
python3 "$ROOT/hooks/lib/seal.py" "$TMP/no-such-tree" >/dev/null 2>&1
rc=$?
exit_is "a tree it cannot read is not a digest" 1
python3 "$ROOT/hooks/lib/seal.py" >/dev/null 2>&1
rc=$?
exit_is "and being called wrongly is neither" 2

# ── sealing ──────────────────────────────────────────────────────────────────
# Verifying asks whether the supplier gave what it said it would. The seal asks
# whether the tree apply runs is the tree stage verified, and between the two the
# folder sits on disk for hours.
UH="$(home update-seal)"
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/seal-v1.4.0"
printf '1.4.0\n' >"$TMP/seal-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/seal-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$UH" "$TMP/seal-v1.4.0/install.sh" >/dev/null 2>&1
publish v1.5.0 "$SHA" v1.5.0
aside() { find "$UH/.claude/agent-toolkit-releases" -maxdepth 1 -name '.altered.*' -type d | sort; }
aside_name=""

# Every shape an alteration takes, against a tree that was staged whole.
altered() { # name, the command that alters the staged folder
  rm -rf "$(staged v1.5.0)"
  find "$UH/.claude/agent-toolkit-releases" -maxdepth 1 -name '.altered.*' -exec rm -rf {} + 2>/dev/null
  recheck
  [ -d "$(staged v1.5.0)" ] || bad "$1" "nothing was staged, so the case proves nothing"
  eval "$2"
  before="$(readlink "$UH/.claude/agent-toolkit")"
  up apply
  reports "$1" "✗ v1.5.0 was altered after this machine unpacked it"
  same "and nothing on the machine changed" "$before" "$(readlink "$UH/.claude/agent-toolkit")"
  aside_name="$(aside | head -1)"
  aside_name="${aside_name##*/}"
}

altered "a file whose bytes changed is caught" 'printf "x\n" >>"$(staged v1.5.0)/CLAUDE.md"'
altered "and a file added to the tree" 'printf "x\n" >"$(staged v1.5.0)/hooks/extra.sh"'
altered "and a file taken out of it" 'rm -f "$(staged v1.5.0)/hooks/format.sh"'
altered "and a file that gained the bit that runs it" 'chmod 755 "$(staged v1.5.0)/CLAUDE.md"'
altered "and a symlink pointed somewhere else" \
  'rm -rf "$(staged v1.5.0)/skills/backlog"; ln -s /etc "$(staged v1.5.0)/skills/backlog"'
altered "and a file replaced by a link to another" \
  'rm -f "$(staged v1.5.0)/INSTALL.md"; ln -s README.md "$(staged v1.5.0)/INSTALL.md"'

check "the finding names the folder it kept" "${aside_name:-.altered.v1.5.0}" \
  "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out")"
check "and says the machine takes the release again on its own" "staged again on its own" "$out"
[ -n "$(aside)" ] && ok "which is kept, because it is the only evidence of what happened" \
  || bad "the altered folder is kept" "it was deleted"
[ ! -d "$(staged v1.5.0)" ] && ok "and is no longer staged under a release name" \
  || bad "the altered folder is no longer staged" "it is still there"
same "so the record holds no seal for it either" "" "$(kept '.seals["v1.5.0"]')"

# An alteration nobody can move out of the way keeps its seal and stays staged:
# dropping the seal there would hand the next apply the evidence to delete.
if [ "$(id -u)" -ne 0 ]; then
  rm -rf "$(staged v1.5.0)"
  recheck
  printf 'x\n' >>"$(staged v1.5.0)/CLAUDE.md"
  chmod a-w "$UH/.claude/agent-toolkit-releases"
  up apply
  chmod u+w "$UH/.claude/agent-toolkit-releases"
  reports "an altered tree that cannot be moved aside says so" "could not be moved out of the way"
  [ -n "$(kept '.seals["v1.5.0"]')" ] && ok "and keeps its seal, so the next run does not delete it" \
    || bad "a failed set aside keeps the seal" "the seal was dropped"
  [ -d "$(staged v1.5.0)" ] && ok "with the folder still where it was" || bad "the folder stays" "it is gone"
  rm -rf "$(staged v1.5.0)"
else
  skip "an altered tree that cannot be moved aside" "running as root, which writes into any directory"
fi

# The machine is not stuck: the next check downloads that release again.
recheck
[ -d "$(staged v1.5.0)" ] && ok "the next check stages it afresh" || bad "it is staged again" "it was not"
[ -n "$(kept '.seals["v1.5.0"]')" ] && ok "and seals it afresh" || bad "and seals it afresh" "no seal was recorded"

# A second alteration leaves a second folder, so a repeat is visible on disk.
printf 'x\n' >>"$(staged v1.5.0)/CLAUDE.md"
up apply
[ "$(aside | wc -l)" -eq 2 ] && ok "a second alteration leaves a second folder" \
  || bad "a second alteration leaves a second folder" "$(aside | wc -l) folders"
recheck
[ "$(aside | wc -l)" -eq 2 ] && ok "and pruning never takes one away" \
  || bad "pruning keeps the folders it set aside" "$(aside | wc -l) left"

# Nothing being known about a tree is not permission to run it, and deleting the
# record would otherwise be the way past the seal.
rm -rf "$(staged v1.5.0)"
recheck
keep 'del(.seals)'
before="$(readlink "$UH/.claude/agent-toolkit")"
up apply
advises "a folder the record holds no seal for is discarded, and said" \
  "! v1.5.0 was unpacked here with nothing recorded to check it against, so it was discarded rather than installed. It is staged again on its own"
same "changing nothing" "$before" "$(readlink "$UH/.claude/agent-toolkit")"
[ ! -d "$(staged v1.5.0)" ] && ok "and is not kept, because nothing happened to it" \
  || bad "an unsealed folder is discarded" "it is still staged"
recheck
up apply
same "while the one staged after it installs" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"

# The check runs after the cheap short-circuit, so a session start with nothing
# to do hashes nothing: a live folder is never set aside over its own seal.
keep '.seals["v1.5.0"] = "sha256:0000"'
up apply
says_nothing "a release already live is not checked against its seal"
[ -d "$(staged v1.5.0)" ] && ok "and is never set aside over one" || bad "the live folder is left alone" "it was set aside"

# A directory that is already live is running, not waiting. The first machine to
# take a release staged by an updater that recorded no seal, and every machine
# the guide's own bootstrap builds, has a live folder under a release name and
# nothing recorded about it.
UH="$(home update-live-unsealed)"
publish v1.5.0 "$SHA" v1.5.0
recheck
up apply
same "a release machine is live under a release name" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
keep 'del(.seals)'
up now
exit_is "now on it re-installs the wanted release" 0
[ -d "$(staged v1.5.0)" ] && ok "and the live directory is never the one discarded" \
  || bad "the live directory survives now" "it was deleted"
same "so the stable link still resolves" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
up apply
says_nothing "and a session start after it says nothing"

# now runs the same tree, so it asks the same question.
rm -rf "$(staged v1.5.0)"
publish v1.6.0 bbbbbbbb6666666666666666666666666666bbbb v1.6.0
recheck
printf 'x\n' >>"$(staged v1.6.0)/CLAUDE.md"
up now
exit_is "now refuses an altered tree too" 1
check "saying it cannot vouch for the tree it had staged" "cannot vouch for the tree it had staged" "$out"
check "and naming what happened to it above that" "was altered after this machine unpacked it" "$out"

# A tree this machine sealed an hour ago that will not read now has been altered
# as surely as one whose bytes moved, and is not an advisory to repeat for ever.
UH="$(home update-unreadable)"
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/unreadable-v1.4.0"
printf '1.4.0\n' >"$TMP/unreadable-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/unreadable-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$UH" "$TMP/unreadable-v1.4.0/install.sh" >/dev/null 2>&1
publish v1.5.0 "$SHA" v1.5.0
recheck
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$(staged v1.5.0)/CLAUDE.md"
  up apply
  reports "a staged tree that will not read is altered, not an advisory" \
    "✗ v1.5.0 was altered after this machine unpacked it"
  [ ! -d "$(staged v1.5.0)" ] && ok "so it is set aside rather than left to repeat" \
    || bad "an unreadable tree is set aside" "it is still staged"
  find "$UH/.claude/agent-toolkit-releases" -maxdepth 1 -name '.altered.*' -exec chmod -R u+rwX {} + 2>/dev/null
else
  skip "a staged tree that will not read is altered" "running as root, which reads anything"
fi

# A record that parses and holds a seals map of another shape is a record that
# did not parse: every read of it answers empty and every write fails.
UH="$(home update-badseals)"
publish v1.5.0 "$SHA" v1.5.0
recheck
printf '{"seals":"not a map"}\n' >"$UH/.claude/agent-toolkit-staging.json"
rm -rf "$(staged v1.5.0)"
up stage
[ -n "$(kept '.seals["v1.5.0"]')" ] && ok "a replaced record seals what it stages next" \
  || bad "a replaced record seals again" "nothing was sealed"
up apply
reports "and the run says the record did not read" "did not read and was replaced"

# A seal that cannot be taken stages nothing, rather than staging what it could
# not describe.
UH="$(home update-sealless)"
SEALLESS="$TMP/seal-missing"
copy_root "$SEALLESS"
publish v1.5.0 "$SHA" v1.5.0
# The same home and the same release stage from an intact root first, so nothing
# below can pass because staging was broken for another reason.
out="$(PATH="$USTUBS:$PATH" HOME="$UH" "$SEALLESS/hooks/update.sh" stage 2>&1)"
[ -d "$(staged v1.5.0)" ] && ok "this machine and this release do stage" \
  || bad "the control stages" "nothing was staged: $out"
rm -rf "$(staged v1.5.0)"
rm -f "$SEALLESS/hooks/lib/seal.py"
keep ".checked_at -= 21601"
out="$(PATH="$USTUBS:$PATH" HOME="$UH" "$SEALLESS/hooks/update.sh" stage 2>&1)"
[ ! -d "$(staged v1.5.0)" ] && ok "a machine that cannot seal a tree stages nothing" \
  || bad "a machine that cannot seal stages nothing" "it staged it anyway"
out="$(PATH="$USTUBS:$PATH" HOME="$UH" "$SEALLESS/hooks/update.sh" apply 2>&1)"
rc=$?
reports "and says why at the next session start" "! the last update check failed: v1.5.0 could not be sealed"

# Only the rename has to succeed for the release's name to be free, and a folder
# still under it is never staged again, so that is the step whose failure is said.
if [ "$(id -u)" -ne 0 ]; then
  UH="$(home update-undeletable)"
  publish v1.5.0 "$SHA" v1.5.0
  recheck
  keep 'del(.seals)'
  chmod a-w "$(staged v1.5.0)/hooks"
  up apply
  advises "an unsealed folder that will not delete whole is discarded all the same" \
    "! v1.5.0 was unpacked here with nothing recorded to check it against, so it was discarded"
  [ ! -d "$(staged v1.5.0)" ] && ok "freeing the release's name" || bad "the release's name is freed" "the folder is still there"
  left="$(find "$UH/.claude/agent-toolkit-releases" -maxdepth 1 -name '.staging.v1.5.0.*' -type d)"
  [ -n "$left" ] && ok "with what would not delete kept where pruning reaches it" \
    || bad "the remains are under a part-written name" "$(ls -a "$UH/.claude/agent-toolkit-releases")"
  find "$UH/.claude/agent-toolkit-releases" -maxdepth 2 -type d -exec chmod u+w {} + 2>/dev/null
  touch -d '2 days ago' "$left"
  recheck
  [ ! -e "$left" ] && ok "which it does once it is a day old" || bad "pruning takes the remains" "they are still there"
  [ -n "$(kept '.seals["v1.5.0"]')" ] && ok "and the release is staged and sealed afresh" \
    || bad "the discarded release is staged again" "no seal was recorded"

  keep 'del(.seals)'
  chmod a-w "$UH/.claude/agent-toolkit-releases"
  up apply
  chmod u+w "$UH/.claude/agent-toolkit-releases"
  reports "one that cannot even be moved is a required finding" \
    "✗ v1.5.0 was unpacked here with nothing recorded to check it against, and could not be moved out of the way, so nothing was installed"
  check "with the command that removes it" "rm -rf ~/.claude/agent-toolkit-releases/v1.5.0" "$out"
  case "$out" in
    *"so it was discarded"*) bad "and never says it was discarded" "$out" ;;
    *) ok "and never says it was discarded" ;;
  esac
  [ -d "$(staged v1.5.0)" ] && ok "the folder being still there" || bad "the unmovable folder stays" "it is gone"
else
  skip "an unsealed folder that cannot be removed" "running as root, which removes anything"
fi

# ── now ──────────────────────────────────────────────────────────────────────
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

publish v1.6.0 dddddddd3333333333333333333333333333dddd v1.6.0 behind hooks/guard.sh
recheck
up apply
same "a release that failed is marked bad" "v1.6.0" "$(kept '.bad[0]')"
rm -rf "$(staged v1.6.0)"
publish v1.6.0 dddddddd3333333333333333333333333333dddd v1.6.0
up now
exit_is "and now tries it regardless of the mark" 0
same "so a machine that fixed the cause moves on" "$(staged v1.6.0)" "$(readlink "$UH/.claude/agent-toolkit")"
same "and the mark is gone" "" "$(kept '.bad[0]')"

# ── dev mode ─────────────────────────────────────────────────────────────────
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
  "! v1.5.0 is published and this machine runs a clone at $CLONE_VERSION"
check "with the way to pull it" "git -C $CLONE pull" "$out"
reports "and the way to install the release over it" "update.sh now installs the release over it"
same "the clone is still live" "$CLONE" "$(readlink "$UH/.claude/agent-toolkit")"
up apply
says_nothing "and it is not told again"

# The comparison is the semantic version alone.
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

# ── bounded ──────────────────────────────────────────────────────────────────
# A hung network must not hold a session start or leave a process behind. The
# stub records what each bound was asked for and then applies it, so this proves
# the bounds without waiting any of them out.
UH="$(home update-bounded)"
BOUNDS="$TMP/bounds"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$BOUNDS" "$(command -v timeout)" >"$USTUBS/timeout"
chmod +x "$USTUBS/timeout"
publish v1.5.0 "$SHA" v1.5.0
: >"$BOUNDS"
up stage
bounds="$(cat "$BOUNDS" 2>/dev/null)"
check "the whole of stage runs under a bound" "-k 10 300 $ROOT/hooks/update.sh stage" "$bounds"
check "and so does every call that leaves the machine" "60 gh api repos/zo-el/agent-toolkit-v2/releases/latest" "$bounds"
check "the tag read with it" "60 gh api repos/zo-el/agent-toolkit-v2/git/ref/tags/v1.5.0" "$bounds"
check "the download" "60 gh api repos/zo-el/agent-toolkit-v2/tarball/$SHA" "$bounds"
check "the question of whether the commit is on main" "60 gh api repos/zo-el/agent-toolkit-v2/compare/main...$SHA" "$bounds"
check "and the token read that comes before any of them" "10 gh auth token --hostname github.com" "$bounds"
rm -f "$USTUBS/timeout"

# ── a machine that cannot read a version ─────────────────────────────────────
# One program answers every version question here, so a machine where it will not
# run is told that rather than told its own files are wrong.
UH="$(home update-readerless)"
BROKEN_ROOT="$TMP/reader-broken"
copy_root "$BROKEN_ROOT"
printf 'def broken(\n' >>"$BROKEN_ROOT/hooks/lib/version.py"
track v1.5.0
out="$(PATH="$USTUBS:$PATH" HOME="$UH" "$BROKEN_ROOT/hooks/update.sh" apply 2>&1)"
rc=$?
reports "a machine whose version reader will not run says so" "! the toolkit cannot read a version on this machine"
check "rather than saying the track it was given is wrong" "install.sh" "$out"
case "$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out")" in
  *"agent-toolkit-track holds"*) bad "a broken reader never blames the user's own file" "it did" ;;
  *) ok "a broken reader never blames the user's own file" ;;
esac
track

# ── what going live does to a seal ───────────────────────────────────────────
# Going live is itself what changes a tree: the first hook the launcher runs from
# it writes a bytecode cache inside it. A seal taken before that describes a tree
# that no longer exists, so the activation drops it.
UH="$(home update-livesealed)"
publish v1.4.0 "$OLD" v1.4.0
copy_root "$TMP/livesealed-v1.4.0"
printf '1.4.0\n' >"$TMP/livesealed-v1.4.0/VERSION"
printf '%s\n' "${OLD:0:7}" >"$TMP/livesealed-v1.4.0/REVISION"
PATH="$USTUBS:$PATH" HOME="$UH" "$TMP/livesealed-v1.4.0/install.sh" >/dev/null 2>&1
publish v1.5.0 "$SHA" v1.5.0
recheck
[ -n "$(kept '.seals["v1.5.0"]')" ] && ok "a staged release carries a seal" || bad "a staged release is sealed" "it is not"
up apply
same "and the activation that ran it drops that seal" "" "$(kept '.seals["v1.5.0"]')"
# What a live tree does to itself: the launcher sets no PYTHONDONTWRITEBYTECODE,
# so the first hook it runs writes a cache inside the folder it ran from.
mkdir -p "$(staged v1.5.0)/hooks/lib/__pycache__"
: >"$(staged v1.5.0)/hooks/lib/__pycache__/version.cpython-314.pyc"

# The case this exists for: a rollback, then the same release again. Without the
# drop, the folder would still be there, still staged, and its seal would no
# longer match the tree the launcher had written into.
publish v1.4.0 "$OLD" v1.4.0
recheck
up apply
same "a rollback takes the machine back" "$(staged v1.4.0)" "$(readlink "$UH/.claude/agent-toolkit")"
publish v1.5.0 "$SHA" v1.5.0
recheck
up apply
said="$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null)"
case "$said" in
  *altered*) bad "and rolling forward again never reads as tampering" "$said" ;;
  *) ok "and rolling forward again never reads as tampering" ;;
esac
advises "but as the discard it is" "! v1.5.0 was unpacked here with nothing recorded to check it against"
[ -z "$(find "$UH/.claude/agent-toolkit-releases" -maxdepth 1 -name '.altered.*' -print -quit)" ] \
  && ok "so nothing is set aside on a healthy machine" || bad "nothing is set aside" "a folder was"
# Unsealed rather than altered, which Activating answers by discarding it. The
# cost is the one download the next check makes.
forget_calls
recheck
case "$(asked)" in
  *tarball*) ok "the folder it kept is discarded and fetched again" ;;
  *) bad "a rolled forward release is fetched again" "it asked for no tarball" ;;
esac
up apply
same "and the release is live again" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"

# ── rolling back ─────────────────────────────────────────────────────────────
# A release marked a prerelease makes the one before it latest again, so a
# machine converges downwards at its next check and says so.
UH="$(home update-rollback)"
publish v1.5.0 "$SHA" v1.5.0
recheck
up apply
same "the machine takes the newer release first" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
publish v1.4.0 "$OLD" v1.4.0
recheck
up apply
same "and when latest goes back, so does the machine" "$(staged v1.4.0)" "$(readlink "$UH/.claude/agent-toolkit")"
reports "saying which version it came down from" "v1.4.0 is live, from v1.5.0·${SHA:0:7}"
same "and the stamp follows it down" "v1.4.0·${OLD:0:7}" "$(cat "$UH/.claude/agent-toolkit-version")"

# The folder it came down from is the fallback, unsealed since it went live, and
# pinning it reaches that folder with no check in between, so the discard has to
# be said.
[ -d "$(staged v1.5.0)" ] || bad "the release it came down from is still on disk" "it is not, so the case proves nothing"
track v1.5.0
up apply
advises "a pin on the release it came down from discards that folder, naming it" \
  "! v1.5.0 was unpacked here with nothing recorded to check it against, so it was discarded rather than installed"
[ ! -d "$(staged v1.5.0)" ] && ok "and the folder is gone" || bad "the unsealed fallback is discarded" "it is still there"
same "leaving the machine where it was" "$(staged v1.4.0)" "$(readlink "$UH/.claude/agent-toolkit")"
forget_calls
recheck
case "$(asked)" in
  *tarball*) ok "the next check stages the pinned release afresh" ;;
  *) bad "the pinned release is staged again" "it asked for no tarball" ;;
esac
[ -n "$(kept '.seals["v1.5.0"]')" ] && ok "and seals it" || bad "the release staged again is sealed" "no seal was recorded"
up apply
same "and the pin takes the machine to it" "$(staged v1.5.0)" "$(readlink "$UH/.claude/agent-toolkit")"
# now reaches the same folder, and stops there rather than installing it.
[ -d "$(staged v1.4.0)" ] || bad "the release it came from is still on disk" "it is not, so the case proves nothing"
track v1.4.0
up now
exit_is "now on a pinned unsealed fallback installs nothing" 1
check "saying it discarded that folder" \
  "! v1.4.0 was unpacked here with nothing recorded to check it against, so it was discarded rather than installed" "$out"
case "$out" in
  *altered* | *✗*) bad "and never as tampering or a required finding" "$out" ;;
  *) ok "and never as tampering or a required finding" ;;
esac
[ ! -d "$(staged v1.4.0)" ] && ok "with the folder gone" || bad "now discards the unsealed fallback" "it is still there"
up now
exit_is "so the next now downloads it afresh and installs it" 0
same "and the machine is on it" "$(staged v1.4.0)" "$(readlink "$UH/.claude/agent-toolkit")"
track

# ── nowhere to put it ────────────────────────────────────────────────────────
# The state a machine reaches on its own when a disk fills, and the fix it is
# given for it.
UH="$(home update-nowhere)"
publish v1.5.0 "$SHA" v1.5.0
mkdir -p "$UH/.claude/agent-toolkit-releases"
chmod a-w "$UH/.claude/agent-toolkit-releases"
if [ "$(id -u)" -ne 0 ]; then
  up stage
  up apply
  reports "a releases directory that cannot be written is recorded" "! ~/.claude/agent-toolkit-releases cannot be written"
  check "with the command that opens it" "chmod u+rwx ~/.claude/agent-toolkit-releases" "$out"
  up now
  exit_is "and now says the same and exits 1" 1
  check "printing the reason" "cannot be written" "$out"
else
  skip "a releases directory that cannot be written" "running as root, which writes into any directory"
fi
chmod u+rwx "$UH/.claude/agent-toolkit-releases"

# ── pruning ──────────────────────────────────────────────────────────────────
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
