# Updater cases, sourced by tests/run.sh after tests/install.sh, whose fake home
# and stubs these go on using. Nothing here reaches the real home, and nothing
# reaches GitHub: gh is a stub these cases drive.

echo "update.sh"

UP="$ROOT/hooks/update.sh"
UH="$(home update)"

track() { # the line, or nothing for no file at all
  if [ $# -eq 0 ]; then rm -f "$UH/.claude/agent-toolkit-track"; else printf '%s' "$1" >"$UH/.claude/agent-toolkit-track"; fi
}
up() { # arguments → out, rc
  out="$(HOME="$UH" "$UP" "$@" 2>&1)"
  rc=$?
}
kept() { jq -r "$1 // empty" "$UH/.claude/agent-toolkit-staging.json" 2>/dev/null; }
keep() { # jq assignment over the record
  jq -c "$1" "$UH/.claude/agent-toolkit-staging.json" >"$TMP/record" && cp "$TMP/record" "$UH/.claude/agent-toolkit-staging.json"
}
says_nothing() { # name
  { [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "$1" || bad "$1" "exit $rc: ${out:-<empty>}"
}
reports() { # name, expected substring of additionalContext
  local said
  said="$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null)"
  check "$1" "$2" "$said"
}

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
# Each form, and the machine's behaviour under it. A line the updater will not
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
track v1.5.0
up apply
says_nothing "a track pinned to a release is read without a word"
track "  latest  "
up apply
says_nothing "and blank space around the line is not content"
track ""
up apply
says_nothing "an empty file means what no file means"
track

# ── the record ───────────────────────────────────────────────────────────────
rm -f "$UH/.claude/agent-toolkit-staging.json"
up stage
[ -n "$(kept .checked_at)" ] && ok "stage records when the check began" || bad "stage records when the check began" "$(cat "$UH/.claude/agent-toolkit-staging.json" 2>/dev/null)"
same "and when this machine first checked at all" "$(kept .checked_at)" "$(kept .first_check_at)"

# Throttled to six hours, so the ordinary session start costs nothing.
before="$(file_id "$UH/.claude/agent-toolkit-staging.json")"
up stage
same "a second check inside six hours does nothing" "$before" "$(file_id "$UH/.claude/agent-toolkit-staging.json")"
keep ".checked_at -= 21601"
up stage
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
keep ".first_check_at -= 604801 | .checked_at -= 604801"
up apply
reports "a week of checks with none succeeding is said out loud" "no update check has succeeded in seven days"
check "with the command that tries now" "update.sh now" "$out"
keep ".succeeded_at = (.checked_at + 604800)"
up apply
says_nothing "and a check that did succeed inside the week is silent"
