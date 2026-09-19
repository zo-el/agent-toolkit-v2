#!/usr/bin/env bash
# Regression suite for the enforcement layer and the installer.
#
#   tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# An explicit template rather than $TMPDIR: install refuses a version directory
# inside the scratchpad, /tmp/claude-<uid>, and a harness that pointed TMPDIR
# there would have every install case in the suite refuse itself.
TMP="$(mktemp -d /tmp/agent-toolkit-suite.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; skipped=0

ok()   { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  ✗ %s\n    %s\n' "$1" "$2"; }
# A check that could not run says so out loud: counted as neither, never as a pass.
skip() { skipped=$((skipped + 1)); printf '  ⊘ %s\n    %s\n' "$1" "$2"; }
check() { # name, expected-substring, actual
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected '$2' in: ${3:-<empty>}" ;; esac
}
stub_path() { # dir, tools… — a PATH carrying only these
  local dir="$1" b p
  mkdir -p "$dir"
  for b in "${@:2}"; do p="$(command -v "$b")" && ln -sf "$p" "$dir/$b"; done
}

# ── guard ────────────────────────────────────────────────────────────────────
echo "guard.sh"

bash_payload() { # command, cwd
  printf '{"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' \
    "$(jq -Rn --arg d "${2:-}" '$d')" "$(jq -Rn --arg c "$1" '$c')"
}
tool_payload() { printf '{"tool_name":%s,"tool_input":{}}' "$(jq -Rn --arg t "$1" '$t')"; }

# Both PreToolUse gates answer in the same shape, so one runner drives both and
# $GATE names the one under test. Payloads go through a file rather than a pipe:
# they name the very commands the guard flags, and a shell cannot tell a mention
# from an invocation.
GATE="$ROOT/hooks/guard.sh"
# The exit status and stderr are left in files: gate runs inside a command
# substitution, so a variable it set would die with the subshell.
gate() {
  printf '%s' "$1" > "$TMP/p.json"
  "$GATE" < "$TMP/p.json" 2> "$TMP/gate.err"
  printf '%s' "$?" > "$TMP/gate.rc"
}

# No output at all is how a gate says "not my business".
decision() {
  [ -n "${1//[[:space:]]/}" ] || { echo silent; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "silent"' 2>/dev/null || echo malformed
}

expect() { # name, expected decision, payload
  local got rc err
  got="$(decision "$(gate "$3")")"
  rc="$(cat "$TMP/gate.rc" 2>/dev/null)"
  err="$(cat "$TMP/gate.err" 2>/dev/null)"
  if [ "$got" != "$2" ]; then
    bad "$1" "expected $2, got $got"
  elif [ "$rc" != 0 ]; then
    # Silence and a crash are the same empty stdout. A gate that blocks nothing
    # because it died still has to say so here.
    bad "$1" "exited $rc, and a hook must exit 0 on every path"
  elif [ -n "$err" ]; then
    bad "$1" "wrote to stderr: $(printf '%s' "$err" | tail -1)"
  else
    ok "$1"
  fi
}

expect "git push asks"                ask    "$(bash_payload 'git push origin main')"
expect "git push inside a compound"   ask    "$(bash_payload 'cd /tmp && git push --force')"
expect "gh pr create asks"            ask    "$(bash_payload 'gh pr create --title x')"
expect "cargo publish asks"           ask    "$(bash_payload 'cargo publish')"
expect "gh pr comment is denied"      deny   "$(bash_payload 'gh pr comment 12 --body hi')"
expect "gh pr review is denied"       deny   "$(bash_payload 'gh pr review 12 --approve')"
expect "sudo asks"                    ask    "$(bash_payload 'sudo systemctl restart nginx')"
expect "global npm install asks"      ask    "$(bash_payload 'npm install -g typescript')"
expect "crontab asks"                 ask    "$(bash_payload 'crontab -e')"
expect "reset --hard asks"            ask    "$(bash_payload 'git reset --hard HEAD~1')"
expect "stash drop asks"              ask    "$(bash_payload 'git stash drop')"
expect "switch --force asks"          ask    "$(bash_payload 'git switch -f main')"
expect "checkout --force asks"        ask    "$(bash_payload 'git checkout --force main')"
expect "git config write asks"        ask    "$(bash_payload 'git config --global user.name x')"
expect "git config read is free"      silent "$(bash_payload 'git config --global --get user.email')"
expect "commit is free"               silent "$(bash_payload 'git commit -m "feat: x"')"
expect "branch is free"               silent "$(bash_payload 'git switch -c feat/x')"
expect "rebase is free"               silent "$(bash_payload 'git rebase -i main')"
expect "in-repo rm is free"           silent "$(bash_payload 'rm -rf ./build')"
expect "tests are free"               silent "$(bash_payload 'cargo test --all')"
expect "reading settings is free"     silent "$(bash_payload 'jq . ~/.claude/settings.json')"
expect "linear read is free"          silent "$(tool_payload 'mcp__linear__list_issues')"
expect "linear get is free"           silent "$(tool_payload 'mcp__linear__get_issue')"
expect "linear write asks"            ask    "$(tool_payload 'mcp__linear__save_issue')"
expect "linear delete asks"           ask    "$(tool_payload 'mcp__linear__delete_comment')"
expect "non-linear mcp is free"       silent "$(tool_payload 'mcp__context7__query-docs')"

expect "gh workflow run asks"         ask    "$(bash_payload 'gh workflow run release.yml --ref main')"
expect "gh workflow disable asks"     ask    "$(bash_payload 'gh workflow disable release.yml')"
expect "gh workflow enable asks"      ask    "$(bash_payload 'gh workflow enable release.yml')"
expect "gh run rerun asks"            ask    "$(bash_payload 'gh run rerun 42 --failed')"
expect "gh run cancel asks"           ask    "$(bash_payload 'gh run cancel 42')"
expect "gh run delete asks"           ask    "$(bash_payload 'gh run delete 42')"
expect "gh release create still asks" ask    "$(bash_payload 'gh release create v1.0.0 --notes x')"
expect "and delete-asset with it"     ask    "$(bash_payload 'gh release delete-asset v1.0.0 toolkit.tar.gz')"
expect "a methoded release write asks" ask \
  "$(bash_payload 'gh api --method PATCH repos/zo-el/agent-toolkit-v2/releases/9 -f prerelease=true')"
expect "and -X is the same method"    ask    "$(bash_payload 'gh api -X DELETE repos/zo-el/agent-toolkit-v2/git/refs/tags/v1.0.0')"
expect "and a field alone implies one" ask   "$(bash_payload 'gh api repos/zo-el/agent-toolkit-v2/git/tags -f tag=v1.0.0')"
expect "listing workflows is free"    silent "$(bash_payload 'gh workflow list')"
expect "reading a run is free"        silent "$(bash_payload 'gh run view 42 --log')"
expect "reading a release is free"    silent "$(bash_payload 'gh release view v1.0.0 --json tagName,targetCommitish')"
expect "downloading one is free"      silent "$(bash_payload 'gh release download v1.0.0 --archive=tar.gz --output /tmp/t.tgz')"
expect "an unmethoded release read is free" silent \
  "$(bash_payload 'gh api repos/zo-el/agent-toolkit-v2/releases/latest --jq .tag_name')"
expect "and an unmethoded ref read"   silent "$(bash_payload 'gh api repos/zo-el/agent-toolkit-v2/git/refs/tags/v1.0.0')"
# A DELETE carries no field, so -X is the whole evidence that it mutates. Both
# flags take their value glued on as well as after a space, and gh's own docs
# use both, so a pattern needing the space is one spelling away from letting a
# deny through.
expect "-X on a comment endpoint is still denied" deny \
  "$(bash_payload 'gh api -X DELETE repos/zo-el/agent-toolkit-v2/issues/comments/9')"
expect "and glued to its method, which is the ordinary spelling" deny \
  "$(bash_payload 'gh api -XDELETE repos/zo-el/agent-toolkit-v2/issues/comments/9')"
expect "a glued field posts as the user too" deny \
  "$(bash_payload 'gh api -XPOST repos/zo-el/agent-toolkit-v2/issues/1/comments -fbody=hi')"
expect "a glued method on a release still asks" ask \
  "$(bash_payload 'gh api -XDELETE repos/zo-el/agent-toolkit-v2/releases/9')"
expect "and a lowercase one with it" ask \
  "$(bash_payload 'gh api -X delete repos/zo-el/agent-toolkit-v2/git/refs/tags/v1.0.0')"
expect "while a glued read is still free" silent \
  "$(bash_payload 'gh api -XGET repos/zo-el/agent-toolkit-v2/releases/latest')"

# ── attribution ──────────────────────────────────────────────────────────────
# Absolute in CLAUDE.md, so the verdict is deny: there is nothing to approve.
# The forbidden strings are built from $session rather than typed whole, so no
# line here holds both a writing command and a trailer the rule would refuse.
session='Claude-Session'
trailer="$session: https://claude.ai/code/session_01ABC"
coauthor='Co-Authored-By: Claude <noreply@anthropic.com>'
generated='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
commit_with() { printf 'git commit -m "feat: x\n\n%s"' "$1"; }
heredoc() { printf "%s <<'MSG'\nfeat: x\n\n%s\nMSG" "$1" "$2"; }

expect "a session trailer on a commit is denied" deny "$(bash_payload "$(commit_with "$trailer")")"
expect "a Claude co-author line too"             deny "$(bash_payload "$(commit_with "$coauthor")")"
expect "and the generated-with line"             deny "$(bash_payload "$(commit_with "$generated")")"
expect "and a bare session URL"                  deny "$(bash_payload "$(commit_with 'see https://claude.ai/code/session_01ABC')")"
expect "and the key with no URL behind it"       deny "$(bash_payload "$(commit_with "$session: 01ABC")")"
expect "an amend that adds one"                  deny "$(bash_payload "$(printf 'git commit --amend -m "x\n\n%s"' "$trailer")")"
expect "whatever the case and spacing"           deny "$(bash_payload "$(commit_with 'co-authored-by:Claude <x@y>')")"
expect "a -C repo does not hide it"              deny "$(bash_payload "$(printf 'git -C /repo commit -q -m "x\n\n%s"' "$trailer")")"
expect "a merge message carrying it"             deny "$(bash_payload "$(printf 'git merge --no-ff -m "x\n\n%s" feat/y' "$coauthor")")"
expect "an annotated tag message"                deny "$(bash_payload "$(printf 'git tag -a v1 -m "v1\n\n%s"' "$trailer")")"
expect "a PR body on create"                     deny "$(bash_payload "$(printf 'gh pr create --title x --body "goal\n\n%s"' "$trailer")")"
expect "a PR body on edit"                       deny "$(bash_payload "$(printf 'gh pr edit 12 --body "%s"' "$trailer")")"
expect "an inline heredoc message"               deny "$(bash_payload "$(heredoc 'git commit -F -' "$trailer")")"
expect "a repo named before the pr subcommand"   deny "$(bash_payload "$(printf 'gh -R o/r pr create --body "%s"' "$trailer")")"

# Neither the message nor the writing command has to come first, or be a whole
# command of its own. Reading only the message meant a heredoc, a wrapper or a
# condition anywhere ahead of the verb turned the rule off.
expect "a heredoc written before the commit"     deny "$(bash_payload "$(printf 'cat <<EOF > notes.md\nnotes\nEOF\ngit commit -am "x\n\n%s"' "$coauthor")")"
expect "a herestring before it"                  deny "$(bash_payload "$(printf 'cat <<<"x" && git commit -m "y\n%s"' "$trailer")")"
expect "a commit inside an if condition"         deny "$(bash_payload "$(printf 'if git commit -m "x\n%s"; then echo ok; fi' "$trailer")")"
expect "a negated commit"                        deny "$(bash_payload "$(printf '! git commit -m "x\n%s"' "$trailer")")"
expect "a timed commit"                          deny "$(bash_payload "$(printf 'time git commit -m "x\n%s"' "$trailer")")"
expect "a commit wrapped in env"                 deny "$(bash_payload "$(printf 'env X=1 git commit -m "x\n\n%s"' "$trailer")")"
expect "a commit wrapped in bash -c"             deny "$(bash_payload "$(printf "bash -c 'git commit -m \"x\n%s\"'" "$coauthor")")"
expect "a commit inside a backtick"              deny "$(bash_payload "$(printf '`git commit -m "x\n%s"`' "$trailer")")"
expect "a commit on its own line"                deny "$(bash_payload "$(printf 'git add -A\ngit commit -m "x\n\n%s"' "$trailer")")"
expect "a clean commit chained to a dirty PR"    deny "$(bash_payload "$(printf 'git commit -m "clean" && gh pr create --body "%s"' "$trailer")")"
expect "a separator inside the subject"          deny "$(bash_payload "$(printf 'git commit -m "a & b\n\n%s"' "$trailer")")"
expect "a pipe inside a PR body table"           deny "$(bash_payload "$(printf 'gh pr create --body "| a | b |\n\n%s"' "$trailer")")"

# What bluntness costs, pinned so it stays a decision rather than a surprise.
# Each of these is one command split in two, or one string built from a
# variable, which is how this very block is written.
expect "a fixture written beside a commit"       deny "$(bash_payload "$(printf "cat > fixture <<'EOF'\n%s\nEOF" "$(commit_with "$trailer")")")"
expect "the same quoted inside a printf"         deny "$(bash_payload "printf '%s' '$(commit_with "$trailer")' > fixture")"
expect "a grep for the words behind a commit"    deny "$(bash_payload "git commit -m 'feat: x' && grep -rn '$session:' .")"

# A command that names no commit and no pull request is data, whatever it says.
expect "grepping for the trailer is free"        silent "$(bash_payload "grep -rn '$trailer' .")"
expect "printing it is free"                     silent "$(bash_payload "printf '%s\\n' '$coauthor'")"
expect "reading history for the words is free"   silent "$(bash_payload 'git log -1 --format=%B | grep -i claude-session')"
expect "and grepping a status for them"          silent "$(bash_payload "git status | grep commit '$session:'")"
expect "a clean heredoc commit message"          silent "$(bash_payload "$(heredoc 'git commit -F -' 'The goal, and why.')")"
expect "a clean tag message"                     silent "$(bash_payload "git tag -a v1 -m 'v1'")"
expect "a clean PR still only asks"              ask    "$(bash_payload "gh pr create --title x --body 'the goal'")"

# Without jq the guard reads the payload with python3 and gives the same
# verdicts. env -i so it sees a bare environment, which is what a hook gets.
stub_path "$TMP/nojq" bash grep sed tr cat python3
bare() { # payload directory, payload → the guard's output, run with that PATH alone
  printf '%s' "$2" > "$TMP/p.json"
  env -i PATH="$1" HOME="$TMP" "$ROOT/hooks/guard.sh" < "$TMP/p.json" 2>/dev/null
}
out="$(bare "$TMP/nojq" "$(bash_payload 'git status')")"
[ -z "$out" ] && ok "without jq a read-only command passes silently" || bad "without jq a read-only command passes" "emitted: $out"
check "without jq a push still asks" ask "$(decision "$(bare "$TMP/nojq" "$(bash_payload 'git push origin main')")")"
check "without jq a public comment is still denied" deny "$(decision "$(bare "$TMP/nojq" "$(bash_payload 'gh pr comment 12 --body hi')")")"

check "without jq an attributed commit is still denied" deny \
  "$(decision "$(bare "$TMP/nojq" "$(bash_payload "$(commit_with "$trailer")")")")"

# A payload jq will not parse must not become an allow. python3 takes a lone
# surrogate where jq refuses the whole document, so the call is still judged.
lone='{"tool_name":"Bash","tool_input":{"command":"gh pr comment 12 --body \ud800"}}'
printf '%s' "$lone" | jq -e . >/dev/null 2>&1 \
  && bad "the fixture is a payload jq cannot parse" "jq parsed it" \
  || ok "the fixture is a payload jq cannot parse"
check "a payload only python3 can read is still judged" deny "$(decision "$(gate "$lone")")"

# With no reader at all, and with a tool the rules themselves need, the gate
# cannot say anything about the call, so it asks rather than waving it through.
stub_path "$TMP/noreader" bash grep sed tr cat
out="$(bare "$TMP/noreader" "$(bash_payload 'git push origin main')")"
rc=$?
{ [ "$rc" = 0 ] && [ "$(decision "$out")" = ask ]; } \
  && ok "with neither jq nor python3 the guard asks and exits 0" \
  || bad "with neither jq nor python3 the guard asks" "exit $rc: ${out:-<empty>}"
check "naming what it could not do" "neither jq nor python3 can read the payload" "$out"
stub_path "$TMP/nogrep" bash sed tr cat jq python3
check "and asks when grep, which every rule needs, is gone" ask \
  "$(decision "$(bare "$TMP/nogrep" "$(bash_payload 'git push origin main')")")"

# ── style ────────────────────────────────────────────────────────────────────
# The other gate. Every diff case runs against a real repository: the check
# reads git, so a typed fixture would prove the parser and nothing else.
echo "style.py"

GATE="$ROOT/hooks/style.py"
# The two characters as bytes: a \u escape inside $'' needs bash 4.2, and
# this suite runs on 3.2 as well.
EM="$(printf '\xe2\x80\x94')"
EN="$(printf '\xe2\x80\x93')"
# The retro format as a file publishes it. Out here because the documentation
# check at the end of the suite runs past the fixture guard below.
template() { sed -n 's/.*`\(- YYYY-MM-DD[^`]*\)`.*/\1/p' "$1"; }
# The format with its placeholders filled in, which is what an append looks
# like: the fixture below commits one, and the log's pattern is held to it.
render() {
  template "$1" | sed -e 's/YYYY-MM-DD/2026-08-30/' -e 's/<agent>/developer/' \
    -e 's/<project>/agent-toolkit/' -e 's/<what was inefficient.*>/a brief naming its sha costs a round/'
}

FX="$TMP/fixture"
mkdir -p "$FX"
git -C "$FX" init -q >/dev/null 2>&1
# Local to a throwaway repository under $TMP, so it reaches no commit of the
# user's. Without it the whole section skips wherever git has no identity, which
# is every fresh runner. Signing is off because it would wait on a passphrase.
git -C "$FX" config commit.gpgsign false
git -C "$FX" config user.name "style fixture"
git -C "$FX" config user.email "fixture@example.invalid"
fx() { bash_payload "$1" "$FX"; }
noted() { # name, expected stderr substring, payload
  local got err
  got="$(decision "$(gate "$3")")"
  err="$(cat "$TMP/gate.err" 2>/dev/null)"
  if [ "$got" != silent ]; then bad "$1" "expected silent, got $got"
  else check "$1" "$2" "$err"; fi
}
why() { printf '%s' "$(gate "$1")" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
stage() {
  git -C "$FX" add -A >/dev/null 2>&1
  git -C "$FX" diff --cached --quiet HEAD 2>/dev/null \
    && bad "the fixture staged something" "nothing is staged, so the case below would pass on an empty tree"
}
# Back to a known tree, so no case inherits the last one's history.
undo() {
  git -C "$FX" reset -q --hard base >/dev/null 2>&1
  git -C "$FX" clean -qfdx >/dev/null 2>&1
}
# The drift limit is counted in tens, so the files that reach it are generated.
comments() { # path, count, opening line, word for the comment text
  printf '%s\n' "$3" > "$1"
  awk -v n="$2" -v w="${4:-note}" 'BEGIN { for (i = 1; i <= n; i++) print "# " w " " i }' >> "$1"
}

printf 'x = 1\n' > "$FX/mod.py"
printf '# Changelog\n\n' > "$FX/CHANGELOG.md"
printf '# Doc\n\nplain line\n' > "$FX/doc.md"
stage
if ! git -C "$FX" commit -q -m base >/dev/null 2>&1 || ! git -C "$FX" tag base; then
  skip "style.py" "git will not commit here, so the fixture repository does not exist"
else

expect "a dash in the message is denied"    deny   "$(fx "git commit -m \"the parser ${EM} it dropped a token\"")"
expect "an en dash is denied too"           deny   "$(fx "git commit -m \"the parser ${EN} it dropped a token\"")"
expect "an en dash between digits is a range" silent "$(fx "git commit -m \"covers lines 10${EN}20\"")"
expect "a clean message is silent"          silent "$(fx 'git commit -m "cover the parser"')"
expect "--dry-run is silent"                silent "$(fx "git commit --dry-run -m \"a ${EM} b\"")"
expect "a command that is not a commit"     silent "$(fx 'git log --oneline -5')"
expect "a commit quoted inside another command" silent "$(fx "echo \"git commit -m 'a ${EM} b'\"")"
expect "git -C is a commit at any position" deny   "$(fx "git -C $FX commit -m \"a ${EM} b\"")"
noted "words that will not split say so" "could not split the command" \
  "$(fx 'git commit -m "unbalanced')"

expect "a Style-ack trailer clears it" silent \
  "$(fx "git commit -m \"the parser ${EM} dropped a token

Style-ack: the dash sits inside a title quoted from upstream\"")"
expect "a Style-ack with no reason clears nothing" deny \
  "$(fx "git commit -m \"the parser ${EM} dropped a token

Style-ack:\"")"

printf 'x = 1\n# a note %s with a dash\n' "$EM" > "$FX/mod.py"; stage
out="$(why "$(fx 'git commit -m "clean message"')")"
check "a dash in an added comment names its line" "mod.py:2:" "$out"
check "and quotes the offending text"             "a note $EM with a dash" "$out"
check "and names the override"                    "Style-ack:" "$out"
undo

printf 'LABEL = "an em %s dash in a UI string"\n' "$EM" > "$FX/ui.py"; stage
expect "a dash in a string literal is invisible" silent "$(fx 'git commit -m "label"')"
undo

# An added line reading "++ x" arrives as "+++ x". Read as a path, it invents a
# file the commit does not touch and numbers every line after it against that.
printf -- '++ b/phantom.py\n# note %s dash\n' "$EM" > "$FX/notes.txt"
stage
out="$(why "$(fx 'git commit -m "notes"')")"
case "$out" in
  *phantom.py*) bad "a +++ inside a hunk is content" "it reported phantom.py, which this commit does not touch" ;;
  *)           ok  "a +++ inside a hunk is content" ;;
esac
check "and the dash is filed under the real path" "notes.txt:2:" "$out"
undo

printf '# Doc\n\nplain line\n\n```\ncode %s dash\n```\n\n> quoted %s dash\n' "$EM" "$EM" > "$FX/doc.md"; stage
expect "a fenced block and a blockquote are not prose" silent "$(fx 'git commit -m "docs"')"
printf -- '---\ntitle: a %s b\n---\n\n# Doc\n\nplain line\n' "$EM" > "$FX/doc.md"; stage
expect "yaml front matter is not prose" silent "$(fx 'git commit -m "docs"')"
printf '# Doc\n\nprose %s dash\n' "$EM" > "$FX/doc.md"; stage
expect "a dash in markdown prose is denied" deny "$(fx 'git commit -m "docs"')"
undo

# A retro append is routine and correct, so it must never need the override.
# Filled in from the format CLAUDE.md publishes, so it is that one under test.
line="$(render "$ROOT/CLAUDE.md")"
case "$line" in
  ""|*"<"*) bad "the published format fills in" "CLAUDE.md yielded: ${line:-<nothing>}" ;;
  *)        ok  "the published format fills in" ;;
esac
log() { { printf '# Retro log\n\n'; [ $# -eq 0 ] || printf '%s\n' "$1"; } > "$FX/RETRO.md"; }
log; stage; git -C "$FX" commit -q -m "the log" >/dev/null 2>&1
log "$line"; stage
expect "appending it needs no override" silent "$(fx 'git commit -m "retro: a line"')"
log "- 2026-08-30 · developer · agent-toolkit $EM a brief naming its sha costs a round"; stage
expect "and the separator it replaced is denied" deny "$(fx 'git commit -m "retro: a line"')"
undo

printf 'x = 1\n# a note %s with a dash\n' "$EM" > "$FX/mod.py"
expect "nothing staged, so a plain commit is silent" silent "$(fx 'git commit -m "wip"')"
expect "commit -am reads the working tree"           deny   "$(fx 'git commit -am "wip"')"
expect "and so does commit -a -m"                    deny   "$(fx 'git commit -a -m "wip"')"
undo

printf 'x = 1\n# a note %s with a dash\n' "$EM" > "$FX/mod.py"; stage
expect "an editor commit still gets the diff checks" deny "$(fx 'git commit')"
expect "and so does --amend --no-edit"               deny "$(fx 'git commit --amend --no-edit')"
expect "and so does --fixup"                         deny "$(fx 'git commit --fixup=HEAD')"
printf 'fix it %s badly\n' "$EM" > "$TMP/msg.txt"
expect "-F reads the file it names"                  deny   "$(fx "git commit -F $TMP/msg.txt")"
printf 'fix it %s badly\n\nStyle-ack: quoting an upstream title\n' "$EM" > "$TMP/msg.txt"
expect "a Style-ack in that file clears the diff too" silent "$(fx "git commit -F $TMP/msg.txt")"
undo
# The message goes unread, so only the diff is left to speak, and it is clean.
expect "-F naming a file that is not written yet" silent "$(fx 'git commit -F not-written-yet.txt')"

printf 'x = 1\n# a note %s with a dash\n' "$EM" > "$FX/mod.py"
stage; git -C "$FX" commit -q -m "landed with a dash" >/dev/null 2>&1
expect "an amend does not re-report HEAD" silent "$(fx 'git commit --amend --no-edit')"
printf 'x = 1\n# a note %s with a dash\n# a second %s one\n' "$EM" "$EM" > "$FX/mod.py"; stage
out="$(why "$(fx 'git commit --amend --no-edit')")"
check "an amend reports what it adds" "mod.py:3:" "$out"
case "$out" in
  *"mod.py:2:"*) bad "an amend leaves HEAD alone" "it reported line 2, which is already committed" ;;
  *)             ok  "an amend leaves HEAD alone" ;;
esac
undo

printf 'y = 1\n' > "$FX/b.py"; printf 'echo hi\n' > "$FX/c.sh"; stage
git -C "$FX" commit -q -m "two more files" >/dev/null 2>&1
comments "$FX/mod.py" 7 'x = 1'
comments "$FX/b.py" 7 'y = 1'
comments "$FX/c.sh" 7 'echo hi'
stage
check "drift is counted over the whole commit" "comments: +21/-0 in b.py, c.sh, mod.py" \
  "$(why "$(fx 'git commit -m "notes"')")"
undo
comments "$FX/fresh.py" 25 'z = 1'; stage
expect "a brand new file's comments do not count" silent "$(fx 'git commit -m "new module"')"
undo

{ printf '# Changelog\n\n'; printf -- '- %s\n' one two three four five six; } > "$FX/CHANGELOG.md"; stage
check "too many changelog entries in one commit" "6 entries added in one commit" \
  "$(why "$(fx 'git commit -m "release"')")"
undo
{ printf '# Changelog\n\n- '; printf 'a long entry that keeps going %.0s' 1 2 3 4 5 6; printf '\n'; } > "$FX/CHANGELOG.md"
stage
check "a changelog entry over the length limit" "characters, over 160" \
  "$(why "$(fx 'git commit -m "release"')")"
undo

mkdir -p "$FX/node_modules/p" "$FX/.claude/worktrees/wt"
printf '// note %s dash\n' "$EM" > "$FX/node_modules/p/i.js"
printf '// note %s dash\n' "$EM" > "$FX/.claude/worktrees/wt/a.js"
printf '{"a": "b %s c"}\n' "$EM" > "$FX/package-lock.json"
stage
expect "vendored, worktree and lock paths are excluded" silent "$(fx 'git commit -m "vendor drop"')"
undo

python3 -c "import sys; open(sys.argv[1], 'w').write(''.join('# note — %d\n' % i for i in range(5000)))" \
  "$FX/big.py" && stage
expect "a diff of exactly the cap is still read" deny "$(fx 'git commit -m "import"')"
python3 -c "import sys; open(sys.argv[1], 'w').write(''.join('# note — %d\n' % i for i in range(5001)))" \
  "$FX/big.py" && stage
expect "one line more is not this change's business" silent "$(fx 'git commit -m "import"')"
undo

# Anything that leaves a stray word in the segment reads as a pathspec, and the
# check then narrows to a file that does not exist and finds nothing.
printf 'x = 1\n# a note %s with a dash\n' "$EM" > "$FX/mod.py"; stage
expect "a stderr redirect does not switch it off" deny "$(fx 'git commit -m "clean" 2>/dev/null')"
expect "nor does 2>&1"                            deny "$(fx 'git commit -m "clean" 2>&1')"
expect "nor does a line continuation"             deny "$(fx "git commit \\
  -m \"clean\"")"
expect "nor does a heredoc body"                  deny "$(fx "git commit -F - <<EOF
a clean message
EOF")"
expect "a cd after the commit does not move it"   deny "$(fx 'git commit -m "clean" && cd /tmp')"
expect "nor does a cd inside a subshell"          deny "$(fx '(cd /tmp && git pull) && git commit -m "clean"')"
undo

comments "$FX/mod.py" 15 'x = 1'; stage
expect "the include form counts a file once" silent "$(fx 'git commit -i -m "notes" mod.py')"
undo
# The index and the pathspec name different files, so both halves have to be read.
printf 'x = 1\n# a note %s dash\n' "$EM" > "$FX/mod.py"; stage
printf '# Doc\n\nprose %s dash\n' "$EM" > "$FX/doc.md"
out="$(why "$(fx 'git commit -i -m "notes" doc.md')")"
check "the include form reads the index too" "mod.py:2:" "$out"
check "and the paths it was given"           "doc.md:3:" "$out"
undo

printf '# Doc\n\n```\nold code\n```\n' > "$FX/doc.md"; stage
git -C "$FX" commit -q -m "a code block" >/dev/null 2>&1
printf '# Doc\n\n```python\nold code\nnew code %s here\n```\n' "$EM" > "$FX/doc.md"; stage
expect "a fence that gained a language tag is still a fence" silent "$(fx 'git commit -m "docs"')"
undo

# Drift is the code rule. A comment in a configuration format documents an
# option, and a page of them is an ordinary change.
printf 'a = 1\n' > "$FX/config.toml"; printf 'echo hi\n' > "$FX/run.sh"; stage
git -C "$FX" commit -q -m "config and script" >/dev/null 2>&1
comments "$FX/config.toml" 25 'a = 1'; stage
expect "a config file's comments are not drift" silent "$(fx 'git commit -m "config"')"
printf 'a = 1\n# a note %s dash\n' "$EM" > "$FX/config.toml"; stage
expect "but a dash in one is still a dash" deny "$(fx 'git commit -m "config"')"
git -C "$FX" reset -q --hard >/dev/null 2>&1
comments "$FX/run.sh" 20 'echo hi'; stage
check "a shell script's comments are drift" "comments: +20/-0 in run.sh" "$(why "$(fx 'git commit -m "script"')")"
undo

# A -F path need have nothing to do with the commit, so quoting its text would
# read a file out to the model a window at a time.
printf 'private %s notes, and a token nobody asked for\n' "$EM" > "$TMP/private.txt"
out="$(why "$(fx "git commit -F $TMP/private.txt")")"
check "a message file is reported by line" "on line 1 of the message file" "$out"
case "$out" in
  *private*|*token*) bad "and never quoted back" "the reason carried the file's text" ;;
  *)                 ok  "and never quoted back" ;;
esac

# Repository config is executable, and this runs before the commit is approved.
# Everything reachable from a config key is turned off on the command line.
HOSTILE="$TMP/hostile"
mkdir -p "$HOSTILE"
printf '#!/bin/sh\ntouch %s\nexit 1\n' "$TMP/payload-ran" > "$TMP/payload.sh"
chmod +x "$TMP/payload.sh"
git -C "$HOSTILE" init -q >/dev/null 2>&1
git -C "$HOSTILE" config commit.gpgsign false
git -C "$HOSTILE" config user.name "style fixture"
git -C "$HOSTILE" config user.email "fixture@example.invalid"
git -C "$HOSTILE" config core.fsmonitor "$TMP/payload.sh"
git -C "$HOSTILE" config diff.external "$TMP/payload.sh"
printf 'x = 1\n' > "$HOSTILE/a.py"
git -C "$HOSTILE" add -A >/dev/null 2>&1
rm -f "$TMP/payload-ran"
# -am with no HEAD is what reaches the fallback: diff HEAD fails, and the
# arguments are rebuilt.
gate "$(bash_payload 'git commit -am first' "$HOSTILE")" >/dev/null
[ -e "$TMP/payload-ran" ] && bad "the no-HEAD fallback cannot run a program" "repository config ran it" \
                          || ok "the no-HEAD fallback cannot run a program"
git -C "$HOSTILE" -c core.fsmonitor= commit -q -m base >/dev/null 2>&1
printf 'x = 1\n# note\n' > "$HOSTILE/a.py"
git -C "$HOSTILE" -c core.fsmonitor= add -A >/dev/null 2>&1
rm -f "$TMP/payload-ran"
gate "$(bash_payload 'git commit -m "second"' "$HOSTILE")" >/dev/null
[ -e "$TMP/payload-ran" ] && bad "nor can the ordinary one" "repository config ran it" \
                          || ok "nor can the ordinary one"

# A combined diff numbers nothing the way a two-way one does. Its header is not
# "diff --git", so no record opens and no invented position is reported.
combined="$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/hooks")
import style
text = "diff --cc f.txt\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,1 -1,1 +1,5 @@@\n++both sides\n"
print(len(style.parse_diff(text)))
PY
)"
check "a combined diff yields no records" "0" "$combined"

printf 'x = 1\n# one %s dash\n# two %s dash\n' "$EM" "$EM" > "$FX/mod.py"
printf '# Doc\n\nprose %s dash\n' "$EM" > "$FX/doc.md"
stage
out="$(why "$(fx "git commit -m \"a ${EM} b\"")")"
for want in "4 findings" "message:" "doc.md:3:" "mod.py:2:" "mod.py:3:"; do
  check "one block carries $want" "$want" "$out"
done
undo

# Committing the removal of a dash must be silent, or the fix the deny reason
# just asked for is itself blocked and the loop has no way out.
printf 'x = 1\n# an old note %s dash\n' "$EM" > "$FX/mod.py"; stage
git -C "$FX" commit -q -m "landed a dash" >/dev/null 2>&1
printf 'x = 1\n' > "$FX/mod.py"; stage
expect "removing a dash line is silent" silent "$(fx 'git commit -m "cut the dash"')"
undo

printf 'x = 1\n# a note %s dash\n' "$EM" > "$FX/mod.py"
printf '# Doc\n\nplain line\n' > "$FX/doc.md"
expect "a pathspec commit reads only its own paths" silent "$(fx 'git commit -m "wip" doc.md')"
expect "and still reads the ones it names"          deny   "$(fx 'git commit -m "wip" mod.py')"
undo

FRESH="$TMP/fresh-repo"
mkdir -p "$FRESH"
git -C "$FRESH" init -q >/dev/null 2>&1
git -C "$FRESH" config user.name "style fixture"
git -C "$FRESH" config user.email "fixture@example.invalid"
printf 'x = 1\n# a note %s dash\n' "$EM" > "$FRESH/mod.py"
git -C "$FRESH" add -A >/dev/null 2>&1
expect "the first commit of a repository is checked" deny \
  "$(bash_payload 'git commit -m "first"' "$FRESH")"
expect "and so is its -a form"                       deny \
  "$(bash_payload 'git commit -am first' "$FRESH")"

comments "$FX/mod.py" 19 'x = 1'; stage
expect "nineteen comments is under the drift limit" silent "$(fx 'git commit -m "notes"')"
comments "$FX/mod.py" 20 'x = 1'; stage
check "twenty reaches it" "comments: +20/-0 in mod.py (limit +20 net)" \
  "$(why "$(fx 'git commit -m "notes"')")"
undo

comments "$FX/mod.py" 25 'x = 1' note; stage
git -C "$FX" commit -q -m "a page of comments" >/dev/null 2>&1
comments "$FX/mod.py" 25 'x = 1' reworded; stage
expect "rewriting comments is not drift" silent "$(fx 'git commit -m "reword"')"
comments "$FX/mod.py" 50 'x = 1' reworded; stage
check "adding more than it removes is" "comments: +50/-25" "$(why "$(fx 'git commit -m "more"')")"
undo

{ printf '# Changelog\n\n'; printf -- '- %s\n' one two three four five; } > "$FX/CHANGELOG.md"; stage
expect "five changelog entries is under the limit" silent "$(fx 'git commit -m "release"')"
undo
{ printf '# Changelog\n\n- '; python3 -c "print('x' * 160)"; } > "$FX/CHANGELOG.md"; stage
expect "an entry of exactly the limit passes" silent "$(fx 'git commit -m "release"')"
{ printf '# Changelog\n\n- '; python3 -c "print('x' * 161)"; } > "$FX/CHANGELOG.md"; stage
check "one character more does not" "is 161 characters, over 160" "$(why "$(fx 'git commit -m "release"')")"
undo
{ printf '# Changelog\n\n- '; python3 -c "print('y' * 200)"; } > "$FX/CHANGELOG.md"; stage
out="$(why "$(fx 'git commit -m "release"')")"
case "$out" in
  *"$(python3 -c "print('y' * 61)")"*) bad "a long entry is quoted short" "the whole entry came back" ;;
  *)                                   ok  "a long entry is quoted short" ;;
esac
undo
{ printf '# Changelog\n\n'; printf -- '    - %s\n' one two three four five six seven; } > "$FX/CHANGELOG.md"; stage
expect "indented continuation is not an entry" silent "$(fx 'git commit -m "release"')"
undo

mkdir -p "$FX/vendor" "$FX/dist" "$FX/target"
for f in vendor/v.js dist/d.js target/t.js a.min.js; do
  printf '// note %s dash\n' "$EM" > "$FX/$f"
done
stage
expect "vendor, dist, target and minified paths are excluded" silent "$(fx 'git commit -m "drop"')"
undo
excluded="$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/hooks")
import style
paths = ["Cargo.lock", "package-lock.json", "t.snap", "icon.svg", "a.min.js",
         "node_modules/p/i.js", "vendor/v.js", "dist/d.js", "target/t.js",
         "build/b.js", ".claude/worktrees/wt/a.js"]
print(",".join(p for p in paths if not style.excluded(p)))
PY
)"
[ -z "$excluded" ] && ok "every named exclusion holds" \
                   || bad "every named exclusion holds" "not excluded: $excluded"

printf '// a note %s dash\n' "$EM" > "$FX/a.js"
printf -- '-- a note %s dash\n' "$EM" > "$FX/b.sql"
printf '<!-- a note %s dash -->\n' "$EM" > "$FX/c.html"
printf '; a note %s dash\n' "$EM" > "$FX/d.el"
stage
out="$(why "$(fx 'git commit -m "many languages"')")"
for want in "a.js:1:" "b.sql:1:" "c.html:1:" "d.el:1:"; do
  check "the marker table covers $want" "$want" "$out"
done
undo

printf '#!/usr/bin/env python3\n# a note %s dash\n' "$EM" > "$FX/s.py"; stage
check "the line under a shebang is prose" "s.py:2:" "$(why "$(fx 'git commit -m "script"')")"
undo
comments "$FX/mod.py" 19 '#!/usr/bin/env python3'; stage
expect "a shebang is not a comment it can count" silent "$(fx 'git commit -m "make it a script"')"
undo
printf '#!/usr/bin/env run %s dash\nx = 1\n' "$EM" > "$FX/s.py"; stage
expect "nor is it prose" silent "$(fx 'git commit -m "script"')"
undo

printf 'x = 1\ny = 2  # a trailing %s note\n' "$EM" > "$FX/mod.py"; stage
check "a trailing comment is prose" "mod.py:2:" "$(why "$(fx 'git commit -m "trailing"')")"
printf 'x = 1\ny = "s"  # a trailing %s note\n' "$EM" > "$FX/mod.py"; stage
expect "unless the line carries a quote" silent "$(fx 'git commit -m "trailing"')"
undo

printf '# Doc\n\n~~~\ncode %s dash\n~~~\n' "$EM" > "$FX/doc.md"; stage
expect "a tilde fence is a fence" silent "$(fx 'git commit -m "docs"')"
printf '# Doc\n\nplain line\n\n    indented code %s dash\n' "$EM" > "$FX/doc.md"; stage
expect "an indented code block is not prose" silent "$(fx 'git commit -m "docs"')"
undo

printf 'notes %s dash\n' "$EM" > "$FX/n.txt"
printf 'notes %s dash\n' "$EM" > "$FX/n.rst"
stage
out="$(why "$(fx 'git commit -m "docs"')")"
check "txt is a document" "n.txt:1:" "$out"
check "rst is too"        "n.rst:1:" "$out"
undo

printf '# Doc\n\nan old line %s with a dash\nplain line\n' "$EM" > "$FX/doc.md"; stage
git -C "$FX" commit -q -m "a dash already landed" >/dev/null 2>&1
printf '# Doc\n\nan old line %s with a dash\nplain line\nand a new one\n' "$EM" > "$FX/doc.md"; stage
expect "a document's context lines are not prose" silent "$(fx 'git commit -m "add a line"')"
undo

# The fence restarts at each hunk, so an edit deep inside a block whose opening
# fence is out of view reads as prose. Deliberate, and stated in the spec.
python3 - "$FX/big.md" <<'PY'
import sys
lines = ["# Doc", "", "```"] + ["code line %d" % i for i in range(60)] + ["```", ""]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
stage; git -C "$FX" commit -q -m "a long code block" >/dev/null 2>&1
python3 - "$FX/big.md" "$EM" <<'PY'
import sys
text = open(sys.argv[1]).read()
open(sys.argv[1], "w").write(text.replace("code line 40", "code line 40 %s edited" % sys.argv[2]))
PY
stage
expect "a hunk that cannot see its opening fence reads as prose" deny "$(fx 'git commit -m "docs"')"
undo

expect "a second -m is read too" deny "$(fx "git commit -m clean -m \"and a ${EM} dash\"")"
expect "--message= is read"      deny "$(fx "git commit --message=\"a ${EM} b\"")"
expect "a trailer can carry the override" silent \
  "$(fx "git commit -m \"a ${EM} b\" --trailer \"Style-ack: quoting an upstream title\"")"
expect "--short is a dry run"    silent "$(fx "git commit --short -m \"a ${EM} b\"")"
expect "--porcelain is too"      silent "$(fx "git commit --porcelain -m \"a ${EM} b\"")"
printf 'x = 1\n# a note %s dash\n' "$EM" > "$FX/mod.py"; stage
expect "a cd before the commit moves the check" deny \
  "$(bash_payload "cd $FX && git commit -m \"clean message\"" "$TMP")"
expect "and without it there is no repository to read" silent \
  "$(bash_payload 'git commit -m "clean message"' "$TMP")"
undo
expect "an absolute path to git still is" deny "$(fx "/usr/bin/git commit -m \"a ${EM} b\"")"

# Named in the spec as uncaught, and worth pinning so it stays a decision.
expect "a double hyphen is not a dash"   silent "$(fx 'git commit -m "end of options -- is not punctuation"')"
expect "another interpreter is not read" silent "$(fx "bash -c \"git commit -m 'a ${EM} b'\"")"
{ printf '# Changelog\n\n'; printf -- '- %s\n' one two three four five six; } > "$FX/changelog.md"; stage
check "a lower case changelog counts" "6 entries added in one commit" "$(why "$(fx 'git commit -m "release"')")"
undo

printf 'binary\000\001 %s here\n' "$EM" > "$FX/blob.bin"; stage
expect "a binary file has no prose" silent "$(fx 'git commit -m "blob"')"
undo

python3 - "$FX/many.py" "$EM" <<'PY'
import sys
open(sys.argv[1], "w").write("".join("# note %s %d\n" % (sys.argv[2], i) for i in range(45)))
PY
stage
out="$(why "$(fx 'git commit -m "many"')")"
check "past the shown cap the rest are counted" "and 5 more not shown" "$out"
check "and the count is of all of them" "45 findings" "$out"
undo

# A commit has one drift finding and can have a file's worth of dashes, so the
# cut is what decides whether the one is ever read. A message fills the report
# on its own just as well.
comments "$FX/mod.py" 45 'x = 1' "note $EM"
stage
out="$(why "$(fx 'git commit -m "many notes"')")"
check "drift survives a report that is cut" "comments: +45/-0 in mod.py" "$out"
check "and the cut says only how many"      "and 6 more not shown" "$out"
check "and every finding is counted"        "46 findings" "$out"
python3 - "$TMP/msg.txt" "$EM" <<'PY'
import sys
open(sys.argv[1], "w").write("".join("note %s line %d\n" % (sys.argv[2], i) for i in range(50)))
PY
out="$(why "$(fx "git commit -F $TMP/msg.txt")")"
check "drift leads a report the message fills" "comments: +45/-0 in mod.py" "$out"
check "and that report is still whole"         "96 findings" "$out"
check "and it counts what it dropped"          "and 56 more not shown" "$out"
undo

# At exactly the cap nothing is hidden, so the report must not say it is.
comments "$FX/mod.py" 39 'x = 1' "note $EM"
stage
out="$(why "$(fx 'git commit -m "at the cap"')")"
check "a report of exactly the cap is whole" "40 findings" "$out"
case "${out:-<nothing>}" in
  *"more not shown"*|"<nothing>") bad "and says nothing is hidden" "$out" ;;
  *)                              ok  "and says nothing is hidden" ;;
esac
undo

quoted="$(why "$(fx "git commit -m \"first line
second ${EM} line\"")" | grep 'message: em dash')"
case "$quoted" in
  *"first line second"*) ok "a multi line message is quoted on one line" ;;
  *) bad "a multi line message is quoted on one line" "got: $quoted" ;;
esac
[ "$(printf '%s' "$quoted" | wc -l)" = "0" ] \
  && ok "and the quote carries no newline of its own" \
  || bad "and the quote carries no newline of its own" "the finding spans lines"

# A heredoc body is prose, and an apostrophe in it opens a quote that never
# closes, which takes the whole command with it.
printf 'x = 1\n# a note %s dash\n' "$EM" > "$FX/mod.py"; stage
expect "an apostrophe in a heredoc body" deny "$(fx "git commit -F- <<'EOF'
the user's fix
EOF")"
# Check then commit is an ordinary pattern, and the dry run does not answer for
# the commit beside it.
expect "a dry run does not disarm the commit after it" deny \
  "$(fx 'git commit --dry-run && git commit -m "clean"')"
undo
expect "every commit in the command is read" deny \
  "$(fx "git commit -m clean && git commit --amend -m \"a ${EM} b\"")"

expect "--template with a readable -m is read" deny "$(fx "git commit -t tmpl.txt -m \"a ${EM} b\"")"
expect "and so is --squash with one"           deny "$(fx "git commit --squash=HEAD -m \"a ${EM} b\"")"

mkdir -p "$FX/node_modules/p"
python3 -c "import sys; open(sys.argv[1], 'w').write(''.join('// line %d\n' % i for i in range(6000)))" \
  "$FX/node_modules/p/i.js"
printf '# Doc\n\nreal prose %s dash\n' "$EM" > "$FX/doc.md"
stage
check "an excluded path does not spend the cap" "doc.md:3:" "$(why "$(fx 'git commit -m "npm install"')")"
undo

SUB="$TMP/sub-repo"
mkdir -p "$SUB"
git -C "$SUB" init -q >/dev/null 2>&1
git -C "$SUB" config user.name "style fixture"
git -C "$SUB" config user.email "fixture@example.invalid"
printf 'y = 1\n' > "$SUB/seed.py"
git -C "$SUB" add -A >/dev/null 2>&1
git -C "$SUB" commit -q -m base >/dev/null 2>&1
printf 'y = 1\n# a note %s dash\n' "$EM" > "$SUB/seed.py"
git -C "$SUB" add -A >/dev/null 2>&1
expect "a cd inside the commit's own subshell moves it" deny \
  "$(bash_payload "(cd $SUB && git commit -m clean)" "$TMP")"

UNBORN="$TMP/unborn-repo"
mkdir -p "$UNBORN"
git -C "$UNBORN" init -q >/dev/null 2>&1
git -C "$UNBORN" config user.name "style fixture"
git -C "$UNBORN" config user.email "fixture@example.invalid"
printf 'a = 1\n' > "$UNBORN/wanted.py"
printf '# unrelated %s dash\n' "$EM" > "$UNBORN/other.py"
git -C "$UNBORN" add -A >/dev/null 2>&1
expect "an unborn HEAD keeps the pathspec" silent \
  "$(bash_payload 'git commit -m "only wanted" wanted.py' "$UNBORN")"
printf 'a = 1\n# wanted %s dash\n' "$EM" > "$UNBORN/wanted.py"
git -C "$UNBORN" add -A >/dev/null 2>&1
expect "and still reads the path it names" deny \
  "$(bash_payload 'git commit -m "only wanted" wanted.py' "$UNBORN")"

expect "a directory that is not a repository is silent" silent \
  "$(bash_payload 'git commit -m clean' "$TMP")"
BROKEN="$TMP/broken-repo"
mkdir -p "$BROKEN"
git -C "$BROKEN" init -q >/dev/null 2>&1
git -C "$BROKEN" config user.name "style fixture"
git -C "$BROKEN" config user.email "fixture@example.invalid"
printf 'x = 1\n' > "$BROKEN/mod.py"
git -C "$BROKEN" add -A >/dev/null 2>&1
git -C "$BROKEN" commit -q -m base >/dev/null 2>&1
printf 'GARBAGE NOT AN INDEX' > "$BROKEN/.git/index"
noted "a repository it cannot read says so" "git diff failed in a repository" \
  "$(bash_payload 'git commit -m clean' "$BROKEN")"

# A missing binary reaches the same handler a timeout does, without spending
# ten seconds to get there.
stub_path "$TMP/nogit" bash python3 env
printf '%s' "$(bash_payload 'git commit -m clean' "$FX")" > "$TMP/p.json"
nogit_err="$(PATH="$TMP/nogit" "$ROOT/hooks/style.py" < "$TMP/p.json" 2>&1 >/dev/null)"
check "git out of reach says so" "git diff" "$nogit_err"

expect "a Style-ack outside the trailers clears nothing" deny \
  "$(fx "git commit -m \"a ${EM} b

Style-ack: this paragraph is documentation, not a trailer

and another paragraph follows it\"")"
expect "and in the last paragraph it clears" silent \
  "$(fx "git commit -m \"a ${EM} b

Style-ack: quoting an upstream title\"")"

printf 'not json at all' > "$TMP/p.json"
out="$("$GATE" < "$TMP/p.json" 2>/dev/null)"
[ -z "$out" ] && ok "input it cannot parse is silent" || bad "input it cannot parse is silent" "$out"

fi
GATE="$ROOT/hooks/guard.sh"

# ── installer ────────────────────────────────────────────────────────────────
. "$ROOT/tests/install.sh"

# ── updater ──────────────────────────────────────────────────────────────────
. "$ROOT/tests/update.sh"

# ── release ──────────────────────────────────────────────────────────────────
. "$ROOT/tests/release.sh"

# ── statusline ───────────────────────────────────────────────────────────────
echo "statusline.py"

# Placeholders have to be inert next to the populated form, so these assertions
# pin the escape sequences rather than the bare text.
dim() { printf '\033[2m%s\033[0m' "$1"; }
sep=$'\033[2m│\033[0m'

# Reset times are relative to now, so the fixture computes them rather than
# pinning epochs that would go stale and silently stop exercising the branch.
# The extra 30s absorbs the seconds that pass before the script reads the clock:
# remaining time is floored, so a bare 2h14m would render as 2h13m.
in2h=$(( $(date +%s) + 2*3600 + 14*60 + 30 ))
in4d=$(( $(date +%s) + 4*86400 + 3*3600 + 30 ))
# The task directory is named for the full session id with agent teams off, and
# session-<first8> with them on. Both layouts must be found.
mkdir -p "$FAKE/.claude/tasks/abc12345-dead-beef"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/abc12345-dead-beef/1.json"
printf '{"id":"2","status":"in_progress"}' > "$FAKE/.claude/tasks/abc12345-dead-beef/2.json"
printf '{"id":"3","status":"pending"}' > "$FAKE/.claude/tasks/abc12345-dead-beef/3.json"

payload='{"model":{"display_name":"Opus 5","id":"claude-opus-5[1m]"},
  "cwd":"'"$ROOT"'","effort":{"level":"xhigh"},"session_id":"abc12345-dead-beef",
  "context_window":{"total_input_tokens":120000,"used_percentage":12},
  "cost":{"total_cost_usd":1.5,"total_lines_added":10,"total_lines_removed":2},
  "pr":{"number":42,"review_state":"approved"},
  "rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'"$in2h"'},
                 "seven_day":{"used_percentage":12,"resets_at":'"$in4d"'}}}'
out="$(printf '%s' "$payload" | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "renders the model"    "Opus 5" "$out"
check "renders 1M marker"    "1M"     "$out"
check "renders the effort"   "xhigh"  "$out"
check "renders the context"  "12%"    "$out"
check "renders lines changed" "$(printf '\033[32m+10\033[0m\033[2m/\033[0m\033[31m-2\033[0m')" "$out"
check "renders hours left"   "$(printf '\033[2m⏱ 30%% 2h14m')" "$out"
check "renders days left"    "4d3h"   "$out"
check "renders task progress" "1/3"   "$out"
check "renders the PR"       "#42"    "$out"
case "$out" in
  *'$'*)  bad "never renders a dollar amount" "printed: $out" ;;
  *'5h'*) bad "no fixed window label when a reset time is known" "printed: $out" ;;
  *)      ok "no dollar amount, no fixed window label" ;;
esac

# The opening of a session: the line counters are still 0, and the CLI omits
# rate_limits until it has a window to report — on an API key, never. Both
# segments hold their slot dim, in order, so the bar keeps its shape throughout.
out="$(printf '%s' '{"cwd":"/","cost":{"total_cost_usd":0,"total_lines_added":0,"total_lines_removed":0}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "zero lines hold the slot"      "$(dim '+0/-0')" "$out"
check "absent limits hold the slot"   "$(dim '⏱ —')"   "$out"
check "placeholders keep their order" "$(dim '+0/-0') $sep $(dim '⏱ —')" "$out"

# A rate_limits key carrying nothing usable is the same not-yet-known state.
out="$(printf '%s' '{"cwd":"/","rate_limits":{"five_hour":{}}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "unusable limits hold the slot" "$(dim '⏱ —')" "$out"

# Without resets_at the labels have to come back, or two bare percentages give
# no way to tell the windows apart.
out="$(printf '%s' '{"cwd":"/","rate_limits":{"five_hour":{"used_percentage":30},"seven_day":{"used_percentage":12}}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "falls back to window labels" "5h 30%" "$out"
check "labels both windows"         "7d 12%" "$out"

# The team-derived layout must be found too, so the segment survives whichever
# way the platform names the directory.
mkdir -p "$FAKE/.claude/tasks/session-99999999"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/session-99999999/1.json"
printf '{"id":"2","status":"pending"}' > "$FAKE/.claude/tasks/session-99999999/2.json"
out="$(printf '%s' '{"cwd":"/","session_id":"99999999-aaaa-bbbb"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "finds the team-named task dir" "1/2" "$out"

out="$(printf '%s' '{"cwd":"/","session_id":"no-such-session-at-all"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
case "$out" in *☰*) bad "no task dir renders nothing" "printed: $out" ;; *) ok "no task dir renders nothing" ;; esac

# The session's own empty directory must not win over the team-named one that
# holds the list; and a file that is valid JSON but not an object costs its own
# entry plus the claim that the count is the whole list — the ? says so, and the
# green "everything is done" is withheld because it would not be true.
mkdir -p "$FAKE/.claude/tasks/slteam77-aaaa-bbbb" "$FAKE/.claude/tasks/session-slteam77"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/session-slteam77/1.json"
printf '[1,2]' > "$FAKE/.claude/tasks/session-slteam77/2.json"
out="$(printf '%s' '{"cwd":"/","session_id":"slteam77-aaaa-bbbb"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "an empty directory does not hide the team-named list" "$(dim '☰ 1/1?')" "$out"

# A list read whole, with nothing left open, is the one case that renders green.
mkdir -p "$FAKE/.claude/tasks/sldone-aaaa-bbbb"
printf '{"id":"1","status":"completed"}' > "$FAKE/.claude/tasks/sldone-aaaa-bbbb/1.json"
printf '{"id":"2","status":"completed"}' > "$FAKE/.claude/tasks/sldone-aaaa-bbbb/2.json"
out="$(printf '%s' '{"cwd":"/","session_id":"sldone-aaaa-bbbb"}' | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "a whole list with nothing open renders green" "$(printf '\033[32m☰ 2/2\033[0m')" "$out"

# A reset time already in the past must not render a negative or absurd span: the
# window drops back to its label. Asserted as the exact segment, since a glob for
# a stray minus also matches the lines placeholder.
past=$(( $(date +%s) - 500 ))
out="$(printf '%s' '{"cwd":"/","rate_limits":{"five_hour":{"used_percentage":9,"resets_at":'"$past"'}}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
check "stale reset time renders the label, not a negative span" "$(dim '⏱ 5h 9%')" "$out"

# With no payload, every segment fed by it must drop out rather than guess —
# except the two placeholders, which hold width without claiming a measurement.
# Segments read from disk (directory, toolkit stamp) legitimately stay.
for label in "empty stdin" "malformed stdin" "non-object stdin"; do
  case "$label" in
    "empty stdin")  data="" ;;
    "malformed stdin") data="not json" ;;
    *)              data="[1,2]" ;;   # parses, then breaks every .get()
  esac
  out="$(printf '%s' "$data" | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
  case "$out" in
    *Traceback*)             bad "$label never crashes" "$out" ;;
    *%*|*'$'*|*⚡*|*▰*|*▱*)  bad "$label invents no payload segment" "printed: $out" ;;
    *)                       ok "$label degrades safely" ;;
  esac
  check "$label keeps the placeholders" "$(dim '+0/-0') $sep $(dim '⏱ —')" "$out"
done

# Every payload field is read for its type before it is used: a workspace or a
# transcript path of the wrong shape raises where no segment guard reaches, and
# would cost the whole line instead of the segment that read it.
check "payload fields of the wrong type cost their segment, not the line" "Opus 5" \
  "$(printf '%s' '{"cwd":"/","model":{"display_name":"Opus 5"},"workspace":"nope","transcript_path":["nope"]}' \
    | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"

# An ascii output encoding raises on the first separator, and an unguarded write
# puts the traceback in the bar. PYTHONIOENCODING stands in for the C-locale
# machine that does the same.
out="$(printf '%s' '{"cwd":"/","model":{"display_name":"Opus 5"}}' \
  | HOME="$FAKE" PYTHONIOENCODING=ascii python3 "$ROOT/hooks/statusline.py" 2>&1)"
case "$out" in
  *Traceback*) bad "an ascii output encoding never crashes" "$out" ;;
  *)           ok "an ascii output encoding never crashes" ;;
esac
check "an ascii output encoding keeps the separators" "$sep" "$out"

# ...and where stdout cannot be forced to utf-8 at all, the glyph is what
# degrades, not the line: everything else on it still reads.
cat > "$TMP/degrade.py" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from lib.out import print_line

print_line("Opus 5 │ main")
PY
check "a stream that will not take utf-8 degrades the glyph, not the line" "Opus 5 ? main" \
  "$(PYTHONIOENCODING=ascii python3 "$TMP/degrade.py" "$ROOT/hooks" 2>&1)"

# Writing the line is the one thing both hooks share, so its own guard is
# asserted here rather than through a caller that ends in os._exit either way.
python3 "$TMP/degrade.py" "$ROOT/hooks" >&- 2>"$TMP/degrade.err"
{ [ $? = 0 ] && [ ! -s "$TMP/degrade.err" ]; } \
  && ok "printing to a closed stdout is silent, not an error" \
  || bad "printing to a closed stdout is silent, not an error" "stderr: $(cat "$TMP/degrade.err")"

# The bar's own shutdown: a reader that went away must not turn the interpreter's
# final flush into a failed hook.
printf '%s' '{"cwd":"/","model":{"display_name":"Opus 5"}}' > "$TMP/sl.payload"
HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" < "$TMP/sl.payload" 2>"$TMP/sl.err" | true
sl_rc=${PIPESTATUS[0]}
{ [ "$sl_rc" = 0 ] && [ ! -s "$TMP/sl.err" ]; } \
  && ok "the bar survives a closed pipe" \
  || bad "the bar survives a closed pipe" "exit $sl_rc, stderr: $(cat "$TMP/sl.err")"

# The other way the bar used to carry a traceback: a working directory deleted
# under the session, which raises where no segment guard reaches. It costs the
# segments read from disk and nothing else.
out="$(mkdir -p "$TMP/gone" && cd "$TMP/gone" && rmdir "$TMP/gone" \
  && printf '%s' '{"model":{"display_name":"Opus 5"}}' \
  | HOME="$FAKE" python3 "$ROOT/hooks/statusline.py" 2>&1)"
case "$out" in
  *Traceback*) bad "a deleted working directory never crashes" "$out" ;;
  *)           ok "a deleted working directory never crashes" ;;
esac
check "a deleted working directory costs its segment, not the line" "Opus 5" "$out"

# ── taskline ─────────────────────────────────────────────────────────────────
echo "taskline.py"

# The contract is: exactly one line, on stdout, only when it is true, and never
# a failed turn. stdout and stderr are captured apart — the harness injects only
# stdout, so a line written to stderr would kill the feature while looking fine.
HINT='Tasks: none open. Open a lane before acting. Tools are deferred: ToolSearch "select:TaskCreate,TaskUpdate,TaskGet,TaskList"'
SPEC='Retro: spec (in_progress, arch-retro)'
# The whole line, because README.md publishes this one verbatim and the check at
# the end of the suite holds the two to the same string.
BLOCKED_LINE="Tasks: 2 open · $SPEC · Retro: build (blocked)"

tl_with() { # environment assignments, payload → tl_out, tl_err, tl_rc
  tl_out="$(printf '%s' "$2" | env HOME="$FAKE" $1 python3 "$ROOT/hooks/taskline.py" 2>"$TMP/tl.err")"; tl_rc=$?
  tl_err="$(cat "$TMP/tl.err")"
}
tl() { tl_with "" "$1"; }
prompt() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"go"}' "$1"; }
task() { mkdir -p "$1" && printf '%s' "$3" > "$1/$2"; }   # dir, file, json

clean() { # name → true when the turn survived: exit 0, nothing on stderr
  { [ "$tl_rc" = 0 ] && [ -z "$tl_err" ]; } && return 0
  bad "$1" "exit $tl_rc, stderr: ${tl_err:-<none>}"; return 1
}
survives() { clean "$1" && ok "$1"; }
is_line() { # name — one non-empty line on stdout
  clean "$1" || return
  [ -n "$tl_out" ] || { bad "$1" "printed nothing"; return; }
  [ "$(printf '%s\n' "$tl_out" | wc -l)" = 1 ] && ok "$1" || bad "$1" "not one line: $tl_out"
}
exact() { # name, expected stdout
  clean "$1" || return
  [ "$tl_out" = "$2" ] && ok "$1" || bad "$1" "expected '$2', got '${tl_out:-<empty>}'"
}
quiet() { tl "$2"; exact "$1" ""; }   # name, payload

OPEN="$FAKE/.claude/tasks/tl-open"
task "$OPEN" 1.json '{"id":"1","subject":"Retro: audit","status":"completed","blocks":[],"blockedBy":[]}'
task "$OPEN" 2.json '{"id":"2","subject":"Retro: spec","status":"in_progress","owner":"arch-retro","blocks":["3"],"blockedBy":[]}'
task "$OPEN" 3.json '{"id":"3","subject":"Retro: build","status":"pending","blocks":[],"blockedBy":["2"]}'
tl "$(prompt tl-open)"
is_line "an open list is one line"
exact "names every open task with status and owner" "$BLOCKED_LINE"

# An ascii output encoding would raise on the first separator and lose the whole
# line. PYTHONIOENCODING stands in for the C-locale machine that does the same.
tl_with "PYTHONIOENCODING=ascii" "$(prompt tl-open)"
exact "an ascii output encoding keeps the line whole" "$BLOCKED_LINE"

# The line sits in a block buffer until the process ends, so a reader that
# closed the pipe turns the interpreter's own shutdown flush into a failed turn
# — after every guard in the hook has gone out of scope.
printf '%s' "$(prompt tl-open)" > "$TMP/tl.payload"
HOME="$FAKE" python3 "$ROOT/hooks/taskline.py" < "$TMP/tl.payload" 2>"$TMP/tl.err" | true
tl_rc=${PIPESTATUS[0]}
{ [ "$tl_rc" = 0 ] && [ ! -s "$TMP/tl.err" ]; } \
  && ok "a closed pipe is still a clean exit" \
  || bad "a closed pipe is still a clean exit" "exit $tl_rc, stderr: $(cat "$TMP/tl.err")"

# stdout closed outright, where python hands the hook no stream at all. The line
# has nowhere to go, which is not a bug and must not be reported as one.
HOME="$FAKE" python3 "$ROOT/hooks/taskline.py" < "$TMP/tl.payload" >&- 2>"$TMP/tl.err"
tl_rc=$?
{ [ "$tl_rc" = 0 ] && [ ! -s "$TMP/tl.err" ]; } \
  && ok "closed stdout is still a clean exit" \
  || bad "closed stdout is still a clean exit" "exit $tl_rc, stderr: $(cat "$TMP/tl.err")"

# hooks/lib/__init__.py is a comment and nothing else, and it is load-bearing:
# without it, any lib package on PYTHONPATH takes over the import.
mkdir -p "$TMP/shadow/lib"
: > "$TMP/shadow/lib/__init__.py"
cat > "$TMP/shadow/lib/tasks.py" <<'PY'
from collections import namedtuple

TaskList = namedtuple("TaskList", "tasks complete")


def load_tasks(_):
    return TaskList([{"id": "1", "subject": "HIJACKED", "status": "pending"}], True)
PY
tl_with "PYTHONPATH=$TMP/shadow" "$(prompt tl-open)"
exact "a lib on PYTHONPATH cannot hijack the import" "$BLOCKED_LINE"

# blocked is derived, so every way of not being blocked must read as pending: a
# blocker that finished, one that is not in the list at all, and a field of the
# wrong type — which must cost the derivation and not the line.
task "$OPEN" 3.json '{"id":"3","subject":"Retro: build","status":"pending","blocks":[],"blockedBy":["1"]}'
tl "$(prompt tl-open)"
exact "a finished blocker does not block" "Tasks: 2 open · $SPEC · Retro: build (pending)"
task "$OPEN" 3.json '{"id":"3","subject":"Retro: build","status":"pending","blocks":[],"blockedBy":["99"]}'
tl "$(prompt tl-open)"
exact "a dangling blocker does not block" "Tasks: 2 open · $SPEC · Retro: build (pending)"
task "$OPEN" 3.json '{"id":"3","subject":"Retro: build","status":"pending","blocks":[],"blockedBy":7}'
tl "$(prompt tl-open)"
exact "an unusable blockedBy costs the derivation only" "Tasks: 2 open · $SPEC · Retro: build (pending)"
# Ids are strings on disk today; integers must derive the same answer. Both the
# id and the blocker are integers here, or the comparison passes on one side.
task "$OPEN" 2.json '{"id":2,"subject":"Retro: spec","status":"in_progress","owner":"arch-retro","blocks":[3],"blockedBy":[]}'
task "$OPEN" 3.json '{"id":3,"subject":"Retro: build","status":"pending","blocks":[],"blockedBy":[2]}'
tl "$(prompt tl-open)"
exact "integer ids still derive blocked" "$BLOCKED_LINE"
# Every field on the line is free text on the same line, so every field is cut.
task "$OPEN" 3.json "{\"id\":\"3\",\"subject\":\"Retro: build\",\"status\":\"pending\",\"owner\":\"$(printf 'o%.0s' $(seq 40))\",\"blockedBy\":[]}"
tl "$(prompt tl-open)"
exact "a long owner is cut too" "Tasks: 2 open · $SPEC · Retro: build (pending, $(printf 'o%.0s' $(seq 23))…)"
task "$OPEN" 3.json "{\"id\":\"3\",\"subject\":\"Retro: build\",\"status\":\"$(printf 's%.0s' $(seq 40))\",\"blockedBy\":[]}"
tl "$(prompt tl-open)"
exact "a long status is cut too" "Tasks: 2 open · $SPEC · Retro: build ($(printf 's%.0s' $(seq 15))…)"

# The tools are deferred, so a session that never searched for their schemas
# cannot open a task at all — which is exactly the session this line lands in.
tl "$(prompt tl-no-such-session)"
is_line "an empty list is one line"
exact "no task dir names the deferred tools" "$HINT"

task "$FAKE/.claude/tasks/tl-all-done" 1.json '{"id":"1","subject":"Lane: build","status":"completed","blocks":[],"blockedBy":[]}'
tl "$(prompt tl-all-done)"
exact "an all-complete list counts as none open" "$HINT"

# Agent teams name the directory session-<first8>, and the session's own empty
# directory sits beside it. The decoy must not win, or the list goes quiet.
mkdir -p "$FAKE/.claude/tasks/tlteam99-aaaa-bbbb"
TEAM="$FAKE/.claude/tasks/session-tlteam99"
task "$TEAM" 1.json '{"id":"1","subject":"Lane: spec","status":"completed","blocks":[],"blockedBy":[]}'
task "$TEAM" 2.json '{"id":"2","status":"pending","blocks":[],"blockedBy":[]}'
tl "$(prompt tlteam99-aaaa-bbbb)"
exact "an empty dir does not hide the team-named list" 'Tasks: 1 open · untitled (pending)'

# A list read in part says so. A bare count would read as the whole truth, and
# task files are written while this hook reads them on every prompt. Nesting
# deep enough to exhaust the stack is a file that will not parse like any other.
MAL="$FAKE/.claude/tasks/tl-malformed"
task "$MAL" 1.json 'not json at all'
task "$MAL" 2.json '[1,2]'
task "$MAL" 4.json "$(python3 -c "import sys; sys.stdout.write('[' * 200000)")"
task "$MAL" 3.json '{"id":"3","subject":"Lane: sane\nsecond line","status":"pending","blocks":[],"blockedBy":[]}'
tl "$(prompt tl-malformed)"
is_line "a partly read list is one line"
exact "an unparsable entry marks the line partial" \
  'Tasks: 1 open (partial list) · Lane: sane second line (pending)'
rm -f "$MAL/3.json"
quiet "a list that will not parse at all says nothing" "$(prompt tl-malformed)"

# Root reads a chmod 000 file regardless, so the assertions that depend on the
# read failing are skipped there rather than inverted.
UNREAD="$FAKE/.claude/tasks/tl-unreadable"
task "$UNREAD" 1.json '{"id":"1","subject":"Lane: build","status":"pending","blocks":[],"blockedBy":[]}'
task "$UNREAD" 2.json '{"id":"2","subject":"Lane: hidden","status":"pending","blocks":[],"blockedBy":[]}'
chmod 000 "$UNREAD/2.json"
tl "$(prompt tl-unreadable)"
survives "an unreadable file never fails the turn"
[ "$(id -u)" -eq 0 ] || exact "an unreadable file marks the line partial" \
  'Tasks: 1 open (partial list) · Lane: build (pending)'
chmod 644 "$UNREAD/2.json"

# A task file that is already gone is not one that would not read: the platform
# deletes the whole list when the last task completes, and a read that races it
# is still a whole read of what is there. A dangling symlink stands in for the
# file that disappears between the listing and the open.
GONE="$FAKE/.claude/tasks/tl-gone"
task "$GONE" 1.json '{"id":"1","subject":"Lane: build","status":"pending","blocks":[],"blockedBy":[]}'
ln -sfn /nonexistent-task-file "$GONE/2.json"
tl "$(prompt tl-gone)"
exact "a task file already gone is not an unreadable one" 'Tasks: 1 open · Lane: build (pending)'

# A directory that will not list is not an empty one, and saying "none open"
# there would instruct the model to open a lane that already exists.
BLOCKED="$FAKE/.claude/tasks/tl-blocked-dir"
task "$BLOCKED" 1.json '{"id":"1","subject":"Lane: build","status":"pending","blocks":[],"blockedBy":[]}'
chmod 000 "$BLOCKED"
tl "$(prompt tl-blocked-dir)"
survives "an unlistable task dir never fails the turn"
[ "$(id -u)" -eq 0 ] || exact "an unlistable task dir says nothing rather than guessing" ""
chmod 755 "$BLOCKED"

# Whichever layout answered first, an unlistable one beside it means the list
# may not be the whole list — the flag has to survive the early answer. This is
# the agent-teams shape: a stale directory found first, the real one refusing.
ASYM="$FAKE/.claude/tasks/tlasym01-aaaa-bbbb"
task "$ASYM" 1.json '{"id":"1","subject":"Lane: stale","status":"pending","blocks":[],"blockedBy":[]}'
TEAMDIR="$FAKE/.claude/tasks/session-tlasym01"
task "$TEAMDIR" 9.json '{"id":"9","subject":"Lane: real","status":"in_progress","blocks":[],"blockedBy":[]}'
chmod 000 "$TEAMDIR"
tl "$(prompt tlasym01-aaaa-bbbb)"
survives "an unlistable second layout never fails the turn"
[ "$(id -u)" -eq 0 ] || exact "an unlistable second layout still marks the line partial" \
  'Tasks: 1 open (partial list) · Lane: stale (pending)'
chmod 755 "$TEAMDIR"

# Over a partial list an unknown blocker is more likely a file that would not
# read than a dangling reference, and "pending" is the one wrong answer that
# gets the task picked up while something else owns it.
PART="$FAKE/.claude/tasks/tl-part-blocker"
task "$PART" 1.json '{"id":"1","subject":"Lane: spec","status":"in_progress","blocks":["2"],"blockedBy":[]}'
task "$PART" 2.json '{"id":"2","subject":"Lane: build","status":"pending","blocks":[],"blockedBy":["1"]}'
chmod 000 "$PART/1.json"
tl "$(prompt tl-part-blocker)"
[ "$(id -u)" -eq 0 ] || exact "a blocker that would not read still blocks" \
  'Tasks: 1 open (partial list) · Lane: build (blocked)'
chmod 644 "$PART/1.json"

# Sizing. At the cap every task is named and nothing is elided; past it the
# count stays true to every open task and what was dropped is stated.
MANY="$FAKE/.claude/tasks/tl-many"
for i in 1 2 3 4; do
  task "$MANY" "$i.json" "{\"id\":\"$i\",\"subject\":\"Lane: step $i\",\"status\":\"pending\",\"blocks\":[],\"blockedBy\":[]}"
done
tl "$(prompt tl-many)"
exact "at the cap nothing is elided" \
  'Tasks: 4 open · Lane: step 1 (pending) · Lane: step 2 (pending) · Lane: step 3 (pending) · Lane: step 4 (pending)'
case "$tl_out" in
  *ToolSearch*) bad "no tool hint while tasks are open" "printed: $tl_out" ;;
  *)            ok "no tool hint while tasks are open" ;;
esac

# Ids are numbers written as text, and a lane is past 9 quickly: a string sort
# would name 1, 10, 11, 2 and drop the steps actually in front of the user.
for i in 10 11; do
  task "$MANY" "$i.json" "{\"id\":\"$i\",\"subject\":\"Lane: step $i\",\"status\":\"pending\",\"blocks\":[],\"blockedBy\":[]}"
done
tl "$(prompt tl-many)"
exact "ids sort as numbers, not as text" \
  'Tasks: 6 open · Lane: step 1 (pending) · Lane: step 2 (pending) · Lane: step 3 (pending) · Lane: step 4 (pending) · +2 more'

# One line for the rest of the sizing contract: the running work is named first
# however late its id, a subject is cut to a fixed width with the cut visible,
# and the elided count covers everything that did not fit.
task "$MANY" 12.json "{\"id\":\"12\",\"subject\":\"Lane: $(printf 'x%.0s' $(seq 70))\",\"status\":\"in_progress\",\"owner\":\"dev-x\",\"blocks\":[],\"blockedBy\":[]}"
tl "$(prompt tl-many)"
is_line "a long list is still one line"
exact "running work first, subject cut, remainder counted" \
  "Tasks: 7 open · Lane: $(printf 'x%.0s' $(seq 53))… (in_progress, dev-x) · Lane: step 1 (pending) · Lane: step 2 (pending) · Lane: step 3 (pending) · +3 more"

# Nothing to say beats a guess: without a session there is no list to speak for.
quiet "no session id prints nothing"    '{"hook_event_name":"UserPromptSubmit","prompt":"go"}'
quiet "empty stdin prints nothing"      ''
quiet "malformed stdin prints nothing"  'not json'
quiet "non-object stdin prints nothing" '[1,2]'

# Both hooks import a shared module inside their own guards, so a broken one
# degrades quietly by design — the doctor is what says it out loud. Run against
# a copy of the tree, never the checkout itself.
COPY="$TMP/copy"
mkdir -p "$COPY"
tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$COPY"
printf '%s' "$(prompt tl-open)" > "$TMP/tl.payload"
for module in tasks out; do
  tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$COPY"
  rm -f "$COPY/hooks/lib/$module.py"
  check "the doctor flags lib/$module.py missing" "hooks/lib does not import" \
    "$(HOME="$TMP/home-copy" "$COPY/install.sh" --dry-run 2>&1)"
  # Quietly to the model, loudly to the debug log: no line, and a reason on
  # stderr, which a zero exit keeps out of the context.
  HOME="$FAKE" python3 "$COPY/hooks/taskline.py" < "$TMP/tl.payload" \
    > "$TMP/tl.out" 2>"$TMP/tl.err"
  tl_rc=$?
  { [ "$tl_rc" = 0 ] && [ ! -s "$TMP/tl.out" ] && [ -s "$TMP/tl.err" ]; } \
    && ok "lib/$module.py missing costs the line and says why" \
    || bad "lib/$module.py missing costs the line and says why" \
       "exit $tl_rc, stdout: $(cat "$TMP/tl.out"), stderr: $(cat "$TMP/tl.err")"
  # The task line has nothing to say without its list, so losing it is the whole
  # feature. The bar is different: every segment but the glyphs still has an
  # answer, so a checkout missing a shared module costs the polish and not the
  # line the user reads all day.
  out="$(printf '%s' '{"model":{"display_name":"Opus 5"},"cwd":"/"}' \
    | HOME="$FAKE" python3 "$COPY/hooks/statusline.py" 2>/dev/null)"
  check "lib/$module.py missing still renders the bar" "Opus 5" "$out"
done
tar --exclude=.git --exclude=__pycache__ -cf - -C "$ROOT" . | tar -xf - -C "$COPY"
printf '\ndef broken(\n' >> "$COPY/hooks/taskline.py"
check "the doctor flags a hook that will not compile" "does not compile" \
  "$(HOME="$TMP/home-copy" "$COPY/install.sh" --dry-run 2>&1)"

# ── retro ────────────────────────────────────────────────────────────────────
# The recorder reads Claude Code's own transcripts, so every fixture here lives
# in a fake home: HOME is the only thing that says where it looks and where it
# writes. Timestamps are literals, and `since` is set far enough back that every
# fixture is after it — a fixture dated before it is then unambiguously old.
echo "retro.py"

RH="$TMP/retro-home"
RP="$RH/.claude/projects"
mkdir -p "$RP/alpha/s-main/subagents" "$RP/beta/s-agents/subagents" "$RH/.claude/retro" \
         "$RH/.claude/skills/never-fired"
printf '2026-01-01T00:00:00Z\n' > "$RH/.claude/retro/since"

cat > "$TMP/dbq.py" <<'PY'
import os, sqlite3, sys

db = sqlite3.connect(os.path.join(os.path.expanduser("~"), ".claude", "retro", "retro.db"))
for row in db.execute(sys.argv[1]):
    print("|".join("" if v is None else str(v) for v in row))
PY

cat > "$TMP/tz.py" <<'PY2'
import sys

source = open(sys.argv[1] + "/retro.py").read()
ns = {}
exec(compile(source.replace('if __name__ == "__main__":', "if False:"), "retro", "exec"), ns)
naive, zulu = "2026-08-14T12:00:00", "2026-08-14T12:00:00Z"
print("same" if ns["parse_iso"](naive) == ns["parse_iso"](zulu) else "moved")
PY2
retro() { HOME="$RH" python3 "$ROOT/hooks/retro.py" "$@" </dev/null 2>"$TMP/retro.err"; }
dbq()   { HOME="$RH" python3 "$TMP/dbq.py" "$1" 2>/dev/null; }
eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '${3:-<empty>}'"; }
sql()   { eq "$1" "$2" "$(dbq "$3")"; }

# The two ways a transcript stops being the file its cursor was reading: a head
# rewrite makes it a different file under the same name, and dropping the last
# record rewinds it. Both force a rebuild, and which one it is decides whether
# the open segment can be re-derived.
cat > "$TMP/edit.py" <<'PY2'
import sys

path, mode = sys.argv[1], sys.argv[2]
if mode == "head":
    lines = open(path).read().splitlines(True)
    lines[0] = lines[0].replace(sys.argv[3], sys.argv[4])
    open(path, "w").write("".join(lines))
else:
    lines = open(path, "rb").read().splitlines(True)
    open(path, "wb").write(b"".join(lines[:-1]))
PY2
rewrite_head() { python3 "$TMP/edit.py" "$1" head "$2" "$3"; }   # file, old, new
drop_last()    { python3 "$TMP/edit.py" "$1" tail; }             # file
# Every row of every table, read from the schema rather than from a list here:
# what "changes not one row" means, and a table or column added tomorrow is
# covered the day it lands rather than the day someone remembers.
cat > "$TMP/dbstate.py" <<'PY'
import os, sqlite3, sys

skip = set(sys.argv[1:])
db = sqlite3.connect(os.path.join(os.path.expanduser("~"), ".claude", "retro", "retro.db"))
tables = [r[0] for r in db.execute(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
for table in tables:
    if table in skip:
        continue
    cols = [c[1] for c in db.execute("PRAGMA table_info(%s)" % table)]
    cols = [c for c in cols if c != "inode"]   # changes with every fixture rewrite
    rows = db.execute("SELECT %s FROM %s ORDER BY %s" % (",".join(cols), table, ",".join(cols)))
    for row in rows:
        print(table, "|".join("" if v is None else str(v) for v in row))
PY
state()   { HOME="$RH" python3 "$TMP/dbstate.py" 2>/dev/null; }
# Everything but the cursor, for the cases where the transcript itself was
# rewritten and the cursor is supposed to move.
figures() { HOME="$RH" python3 "$TMP/dbstate.py" cursor 2>/dev/null; }

# A session that does its own work: two Bash verbs in one command, a failed Edit
# a denial refers back to, an MCP call, a hook summary, a boundary, and a retro
# line after it. m1 is written twice with one message id, which is how the CLI
# writes one response with two content blocks.
cat > "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T10:00:00.000Z","version":"2.1.232","gitBranch":"main","cwd":"/repo/alpha","message":{"role":"user","content":"go"}}
{"type":"assistant","uuid":"a1","timestamp":"2026-08-14T10:00:01.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git status && npm install -g typescript"}}]}}
{"type":"assistant","uuid":"a1b","timestamp":"2026-08-14T10:00:01.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40},"content":[{"type":"text","text":"still thinking"}]}}
{"type":"user","timestamp":"2026-08-14T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}
{"type":"assistant","uuid":"a2","timestamp":"2026-08-14T10:00:03.000Z","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/repo/alpha/x.py"}}]}}
{"type":"user","timestamp":"2026-08-14T10:00:04.000Z","toolDenialKind":"user-rejected","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"denied"}]}}
{"type":"assistant","uuid":"a2b","isSidechain":true,"timestamp":"2026-08-14T10:00:04.500Z","message":{"id":"m2b","usage":{"input_tokens":999,"output_tokens":999},"content":[{"type":"tool_use","id":"t2b","name":"Bash","input":{"command":"echo sidechain"}}]}}
{"type":"assistant","uuid":"a2c","timestamp":"2026-08-14T10:00:04.600Z","message":{"id":"m2c","content":[{"type":"tool_use","id":"t2c","name":"Bash","input":{"command":"git push origin main"}}]}}
{"type":"user","timestamp":"2026-08-14T10:00:04.700Z","toolDenialKind":"permission-rule","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2c","is_error":true,"content":"blocked"}]}}
{"type":"assistant","uuid":"a3","timestamp":"2026-08-14T10:00:05.000Z","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"mcp__linear__save_issue","input":{}}]}}
{"type":"user","timestamp":"2026-08-14T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]}}
{"type":"system","subtype":"turn_duration","durationMs":1200,"timestamp":"2026-08-14T10:00:07.000Z"}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T10:00:08.000Z","hookInfos":[{"command":"sh /home/x/.claude/agent-toolkit/hooks/taskline.py","durationMs":30}],"hookErrors":[]}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T10:00:09.000Z","hookInfos":[{"command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/notify.sh\"","durationMs":8}],"hookErrors":["Failed with non-blocking status code: /bin/sh: 1: /home/x/.claude/agent-toolkit/hooks/notify.sh: not found"]}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T10:00:10.000Z","hookInfos":[{"command":"Implement the CANARYHOOKPROSE feature end to end and prove it","durationMs":4}],"hookErrors":[]}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T10:00:11.000Z","hookInfos":[{"command":"\"$HOME/.claude/agent-toolkit-run\" PreToolUse hooks/guard.sh","durationMs":12},{"command":"\"$HOME/.claude/agent-toolkit-run\" SessionStart install.sh --sync","durationMs":40}],"hookErrors":[]}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-14T10:06:00.000Z","compactMetadata":{"trigger":"auto","preTokens":1000,"postTokens":100,"cumulativeDroppedTokens":900,"durationMs":5000}}
{"type":"assistant","uuid":"a9","timestamp":"2026-08-14T10:07:00.000Z","message":{"id":"m9","content":[{"type":"text","text":"Retro: the session did the edits itself"}]}}
{"type":"assistant","uuid":"a8","timestamp":"2026-08-14T10:07:30.000Z","message":{"id":"m8","content":[{"type":"text","text":"**Retroactive correction:** CANARYRETROPROSE, which is not a retro line\nRetrospective aside — CANARYRETROPROSE either"}]}}
JSON

out="$(retro record)"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$TMP/retro.err" ]; } \
  && ok "record says nothing on stdout and exits 0" \
  || bad "record says nothing on stdout and exits 0" "exit $rc, out '$out', err $(cat "$TMP/retro.err")"

sql "a boundary closes the segment it ends" "compact|auto|900|5000" \
  "SELECT close_trigger,compact_trigger,dropped_tokens,compact_ms FROM segment WHERE id='s-main#0'"
sql "records after the boundary open the next segment" "s-main#1|1" \
  "SELECT id,ordinal FROM segment WHERE session_id='s-main' AND closed_seq IS NULL"
sql "the segment carries where and when it ran" "alpha|main|2.1.232|2026-08-14T10:00:00.000Z" \
  "SELECT repo,branch,cli_version,started_at FROM segment WHERE id='s-main#0'"
sql "turns are split by who took them" "1|0|5|1200|1200" \
  "SELECT user_turns,wake_turns,assistant_turns,turn_ms_total,turn_ms_max FROM segment WHERE id='s-main#0'"
# One response is written as one record per content block, all with the same
# message id and the same usage: summing per record would double every figure.
sql "usage is summed once per message, not per record" "11|22|30|40" \
  "SELECT tokens_in,tokens_out,cache_read,cache_create FROM segment WHERE id='s-main#0'"
sql "failed results are counted" "3" "SELECT tool_errors FROM segment WHERE id='s-main#0'"
sql "a tool use carries its own errors" "1|1" \
  "SELECT n,errors FROM tool_use WHERE segment_id='s-main#0' AND agent='' AND tool='Edit'"
sql "a driver keeps its subcommand" "1|1" \
  "SELECT n,errors FROM bash_verb WHERE segment_id='s-main#0' AND agent='' AND verb='git status'"
sql "a compound command counts every part" "1|1" \
  "SELECT n,errors FROM bash_verb WHERE segment_id='s-main#0' AND agent='' AND verb='npm install'"
sql "a denial names the tool it was for" "1" \
  "SELECT n FROM denial WHERE segment_id='s-main#0' AND kind='user-rejected' AND signature='Edit'"
# "Which permission prompt keeps firing" is a question about commands, so a
# denied Bash is signed with its verb rather than with the word Bash.
sql "a denied command is signed with its verb" "1" \
  "SELECT n FROM denial WHERE segment_id='s-main#0' AND kind='permission-rule' AND signature='git push'"
# A sidechain record in a session transcript is an agent's own work, counted in
# the agent's transcript. Counting it here too would read as delegation that
# never happened — and its tokens are deliberately absurd so a leak is obvious.
sql "a sidechain record in a session transcript is skipped" "0" \
  "SELECT count(*) FROM bash_verb WHERE segment_id='s-main#0' AND verb='echo'"
sql "and its tokens stay out of the segment" "11" \
  "SELECT tokens_in FROM segment WHERE id='s-main#0'"
sql "an mcp call names its server" "1" \
  "SELECT n FROM mcp_use WHERE segment_id='s-main#0' AND server='linear'"
sql "a hook is labelled, not quoted" "1|30|30" \
  "SELECT n,ms_total,ms_max FROM hook_run WHERE segment_id='s-main#0' AND hook='taskline.py'"
# The error message names the same hook with a colon stuck to it, and the
# command names it inside quotes: both have to land on the one label, or a
# hook's failures sit in a row of their own where nobody joins them up.
sql "a hook's errors land on the same label as its runs" "1|1|8" \
  "SELECT n,errors,ms_total FROM hook_run WHERE segment_id='s-main#0' AND hook='notify.sh'"
# hookInfos does not always hold a command — this store has records where it
# holds the user's prompt. A label taken from the first word of prose would be
# prompt text, which nothing here may store.
sql "a hook command that is not a command is labelled unknown" "1" \
  "SELECT n FROM hook_run WHERE segment_id='s-main#0' AND hook='unknown'"
# Every toolkit hook runs through the launcher, so the entry point after the
# caller is the only name in the command, with or without a directory.
sql "a hook run through the launcher is labelled by its entry point" "1|1" \
  "SELECT (SELECT n FROM hook_run WHERE segment_id='s-main#0' AND hook='guard.sh'),
          (SELECT n FROM hook_run WHERE segment_id='s-main#0' AND hook='install.sh')"
sql "the session's own retro line is captured" "main|the session did the edits itself" \
  "SELECT author,text FROM retro_line WHERE source_uuid='a9'"
# "Retroactive" and "Retrospective" start with the word and are followed by
# ordinary prose. Without the colon they would both be harvested, which puts
# arbitrary assistant text into a store that holds counts and shapes.
sql "prose that merely starts with Retro is not a retro line" "0" \
  "SELECT count(*) FROM retro_line WHERE source_uuid='a8'"

state > "$TMP/retro.before"
retro record >/dev/null
state > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "a sweep with no new bytes changes not one row" \
  || bad "a sweep with no new bytes changes not one row" "$(diff "$TMP/retro.before" "$TMP/retro.after" | head -5)"

# Appending adds to the open segment. A trailing fragment is a record still
# being written: it must wait rather than be counted half-read.
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a10","timestamp":"2026-08-14T10:08:00.000Z","message":{"id":"m10","usage":{"input_tokens":5,"output_tokens":5},"content":[{"type":"tool_use","id":"t10","name":"Write","input":{}}]}}
JSON
printf '{"type":"assistant","uuid":"a11","timestamp":"2026-08-14T10:09:00.000Z","message":{"id":"m11","content":[{"type":"tool' >> "$RP/alpha/s-main.jsonl"
retro record >/dev/null
sql "an append lands in the open segment" "3|5" \
  "SELECT assistant_turns,tokens_in FROM segment WHERE id='s-main#1'"
sql "appending creates no second segment" "2" \
  "SELECT count(*) FROM segment WHERE session_id='s-main'"
sql "a half-written last line is not consumed" "1" \
  "SELECT count(*) FROM tool_use WHERE segment_id='s-main#1'"

printf '_use","id":"t11","name":"Glob","input":{}}]}}\n' >> "$RP/alpha/s-main.jsonl"
retro record >/dev/null
sql "the completed line is counted exactly once" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Glob'"

# One response is written as one record per content block, all carrying the same
# usage, and the trailing-fragment rule makes a sweep land between two of them.
# A figure counted twice here is wrong for good: nothing ever re-derives it.
tokens_before="$(dbq "SELECT tokens_in FROM segment WHERE id='s-main#1'")"
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a14","timestamp":"2026-08-14T10:11:00.000Z","message":{"id":"m14","usage":{"input_tokens":70,"output_tokens":7},"content":[{"type":"text","text":"first block"}]}}
JSON
retro record >/dev/null
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a14b","timestamp":"2026-08-14T10:11:00.000Z","message":{"id":"m14","usage":{"input_tokens":70,"output_tokens":7},"content":[{"type":"tool_use","id":"t14","name":"Grep","input":{}}]}}
JSON
retro record >/dev/null
sql "a message split across two sweeps is summed once" "$(( tokens_before + 70 ))" \
  "SELECT tokens_in FROM segment WHERE id='s-main#1'"
sql "and its second half still counts its own tool use" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Grep'"

# A line that will not parse costs itself and nothing else.
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a12",
{"type":"assistant","uuid":"a13","timestamp":"2026-08-14T10:10:00.000Z","message":{"id":"m13","content":[{"type":"tool_use","id":"t13","name":"Read","input":{}}]}}
JSON
retro record >/dev/null
sql "a malformed line is counted, not fatal" "1|1" \
  "SELECT malformed_lines,(SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Read') FROM segment WHERE id='s-main#1'"

# A transcript whose head changed is a different file under the same name: the
# open segment is rebuilt from scratch, and the closed one is left alone.
figures > "$TMP/retro.before"
rewrite_head "$RP/alpha/s-main.jsonl" '"go"' '"go on then"'
retro record >/dev/null
sql "a reparse leaves the closed segment untouched" "compact|1|5|11" \
  "SELECT close_trigger,user_turns,assistant_turns,tokens_in FROM segment WHERE id='s-main#0'"
sql "a reparse rebuilds the open segment without doubling it" "7|1" \
  "SELECT assistant_turns,(SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Write') FROM segment WHERE id='s-main#1'"

# A transcript is created before it holds anything, so first contact often finds
# it empty — and a head of no bytes hashes the same for every file there has
# ever been. What is written at that path next is a new file, and reading it as
# a continuation would splice two transcripts into one segment.
: > "$RP/alpha/s-empty.jsonl"
retro record >/dev/null
sql "an empty transcript stores no head worth the name" "0" \
  "SELECT head_len FROM cursor WHERE path LIKE '%s-empty.jsonl'"
cat > "$RP/alpha/s-empty.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T20:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"first"}}
{"type":"assistant","uuid":"e1","timestamp":"2026-08-14T20:00:01.000Z","message":{"id":"em1","content":[{"type":"tool_use","id":"e1t","name":"Read","input":{}}]}}
JSON
retro record >/dev/null
sql "and what arrives after it is read whole" "1|1" \
  "SELECT user_turns,(SELECT n FROM tool_use WHERE segment_id='s-empty#0' AND tool='Read')
   FROM segment WHERE id='s-empty#0'"
sql "with a head that fingerprints something" "1" \
  "SELECT CASE WHEN head_len > 0 THEN 1 ELSE 0 END FROM cursor WHERE path LIKE '%s-empty.jsonl'"

# The head is what says a file was replaced rather than appended to, so it has
# to keep pace with the file: one taken when the transcript was shorter can be
# matched by a replacement that only has to agree with the little that was
# stored.
head_before="$(dbq "SELECT head_len FROM cursor WHERE path LIKE '%s-empty.jsonl'")"
cat >> "$RP/alpha/s-empty.jsonl" <<'JSON'
{"type":"assistant","uuid":"e2","timestamp":"2026-08-14T20:00:02.000Z","message":{"id":"em2","content":[{"type":"tool_use","id":"e2t","name":"Glob","input":{}}]}}
JSON
retro record >/dev/null
head_after="$(dbq "SELECT head_len FROM cursor WHERE path LIKE '%s-empty.jsonl'")"
[ "${head_after:-0}" -gt "${head_before:-0}" ] \
  && ok "a head grows with the file it fingerprints" \
  || bad "a head grows with the file it fingerprints" "stayed at $head_before"

# No backfill, two ways: a transcript whose first record predates the marker,
# and one whose mtime does. Neither may contribute a single row.
cat > "$RP/alpha/s-ancient.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2025-11-01T10:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"old"}}
{"type":"assistant","uuid":"o1","timestamp":"2025-11-01T10:00:01.000Z","message":{"id":"mo1","content":[{"type":"tool_use","id":"o","name":"Bash","input":{"command":"ls"}}]}}
JSON
cat > "$RP/alpha/s-untouched.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T10:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"new text, old file"}}
JSON
touch -d '2025-06-01T00:00:00Z' "$RP/alpha/s-untouched.jsonl"
retro record >/dev/null
sql "a transcript older than the marker contributes nothing" "0" \
  "SELECT count(*) FROM segment WHERE session_id IN ('s-ancient','s-untouched')"
sql "but its cursor is parked at the end, so later work is caught" "2" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%s-ancient.jsonl' OR path LIKE '%s-untouched.jsonl'"
cat >> "$RP/alpha/s-ancient.jsonl" <<'JSON'
{"type":"assistant","uuid":"o2","timestamp":"2026-08-14T11:00:00.000Z","message":{"id":"mo2","content":[{"type":"tool_use","id":"o2t","name":"Bash","input":{"command":"cargo test"}}]}}
JSON
retro record >/dev/null
# A live pre-marker transcript can be caught mid-write with a record longer than
# the window a cursor is parked by. Answering "no complete line here" would park
# it at the start of the file, and the next sweep would read the whole thing —
# the backfill the marker exists to prevent.
cat > "$RP/alpha/s-bigtail.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2025-07-01T10:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"old work"}}
{"type":"assistant","uuid":"bt1","timestamp":"2025-07-01T10:00:01.000Z","message":{"id":"btm1","content":[{"type":"tool_use","id":"bt1t","name":"Bash","input":{"command":"terraform destroy"}}]}}
JSON
python3 - "$RP/alpha/s-bigtail.jsonl" <<'PY'
import sys

# A partial record larger than the chunk the parking search reads.
with open(sys.argv[1], "a") as f:
    f.write('{"type":"assistant","uuid":"bt2","text":"' + "x" * (1 << 21) + '"')
PY
retro record >/dev/null
# The parked cursor is only proved by what the sweep after it reads: parking at
# the start looks identical until the next sweep resumes from there.
retro record >/dev/null
sql "a huge unfinished record never parks a cursor at the start" "0" \
  "SELECT count(*) FROM segment WHERE session_id='s-bigtail'"
sql "and nothing of it is recorded" "0" \
  "SELECT count(*) FROM bash_verb WHERE verb='terraform destroy'"

sql "an old transcript contributes only what it gains after first contact" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-ancient#0' AND verb='cargo test'"
sql "and nothing it held before it" "0" \
  "SELECT count(*) FROM bash_verb WHERE segment_id='s-ancient#0' AND verb='ls'"
# The mtime shortcut parks a cursor without reading a byte, so the proof that it
# parked at the end rather than the start is what the next sweep does.
cat >> "$RP/alpha/s-untouched.jsonl" <<'JSON'
{"type":"assistant","uuid":"u2","timestamp":"2026-08-14T11:30:00.000Z","message":{"id":"mu2","content":[{"type":"tool_use","id":"u2t","name":"Bash","input":{"command":"terraform apply"}}]}}
JSON
retro record >/dev/null
sql "a transcript parked by its mtime gains only what comes after" "1|0" \
  "SELECT (SELECT n FROM bash_verb WHERE segment_id='s-untouched#0' AND verb='terraform apply'),
          (SELECT count(*) FROM segment WHERE id='s-untouched#0' AND user_turns > 0)"

# A second sweep, while one is running, is the same work: it must not do it
# twice. $$ is this shell, which is alive, so the lock is not stale.
printf '%s' "$$" > "$RH/.claude/retro/sweep.lock"
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a20","timestamp":"2026-08-14T10:20:00.000Z","message":{"id":"m20","content":[{"type":"tool_use","id":"t20","name":"Task","input":{}}]}}
JSON
state > "$TMP/retro.before"
retro record >/dev/null; rc=$?
state > "$TMP/retro.after"
{ [ "$rc" = 0 ] && cmp -s "$TMP/retro.before" "$TMP/retro.after"; } \
  && ok "a second concurrent sweep exits 0 and writes nothing" \
  || bad "a second concurrent sweep exits 0 and writes nothing" "exit $rc"
# A sweep that was killed leaves its lock behind, and nothing else ever removes
# it: without both steals the recorder goes silent for good, exit 0, no output.
printf '%s' "$$" > "$RH/.claude/retro/sweep.lock"
touch -d '30 minutes ago' "$RH/.claude/retro/sweep.lock"
retro record >/dev/null
sql "a lock older than ten minutes is stolen" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Task'"
[ ! -e "$RH/.claude/retro/sweep.lock" ] && ok "and the sweep that stole it cleans up" \
  || bad "and the sweep that stole it cleans up" "the lock is still there"
# A pid that no longer exists is the same condition, whatever the mtime says.
printf '4294967295' > "$RH/.claude/retro/sweep.lock"
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a21","timestamp":"2026-08-14T10:21:00.000Z","message":{"id":"m21","content":[{"type":"tool_use","id":"t21","name":"Monitor","input":{}}]}}
JSON
retro record >/dev/null
sql "a lock naming a dead process is stolen" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='Monitor'"
# Zero is not a process: signal 0 sent to it goes to this process's own group,
# so a lock holding it reads as held by something alive and every sweep no-ops
# until the lock is old enough to steal.
printf '0' > "$RH/.claude/retro/sweep.lock"
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a23","timestamp":"2026-08-14T10:23:00.000Z","message":{"id":"m23","content":[{"type":"tool_use","id":"t23","name":"NotebookEdit","input":{}}]}}
JSON
retro record >/dev/null
sql "a lock naming no process at all is stolen" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='NotebookEdit'"
rm -f "$RH/.claude/retro/sweep.lock"

# --interval is the whole scheduling mechanism, so it has to actually gate.
cat >> "$RP/alpha/s-main.jsonl" <<'JSON'
{"type":"assistant","uuid":"a22","timestamp":"2026-08-14T10:22:00.000Z","message":{"id":"m22","content":[{"type":"tool_use","id":"t22","name":"WebSearch","input":{}}]}}
JSON
state > "$TMP/retro.before"
retro record --interval 3600 >/dev/null
state > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "--interval does no work twice inside its window" \
  || bad "--interval does no work twice inside its window" "it swept anyway"
retro record >/dev/null
sql "and the next sweep past the window catches up" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-main#1' AND tool='WebSearch'"

# One transcript that will not open must not cost the rest of the sweep. Root
# reads a chmod 000 file regardless, so the assertion is skipped there.
cat > "$RP/alpha/s-locked.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T12:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"hi"}}
JSON
chmod 000 "$RP/alpha/s-locked.jsonl"
cat > "$RP/alpha/s-after.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T12:30:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"hi"}}
JSON
retro record >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "an unreadable transcript never fails the sweep" \
             || bad "an unreadable transcript never fails the sweep" "exit $rc"
sql "the sweep carries on past it" "1" \
  "SELECT count(*) FROM segment WHERE session_id='s-after'"
[ "$(id -u)" -eq 0 ] || sql "and the file it could not read is not recorded" "0" \
  "SELECT count(*) FROM segment WHERE session_id='s-locked'"
chmod 644 "$RP/alpha/s-locked.jsonl"

# ── delegation ───────────────────────────────────────────────────────────────
# The session transcript names an agent and nothing else. Every figure below is
# read from the agent's own transcript, opened by name at its stop.
SUB="$RP/beta/s-agents/subagents"
cat > "$SUB/agent-dev1.meta.json" <<'JSON'
{"agentType":"developer","description":"CANARYMETADESC","toolUseId":"tu1","spawnDepth":1}
JSON
# A skill's run is several records long and not every one of them is
# attributed, so an activation is counted where the run starts and nowhere
# else. The retro line is longer than the cap it is stored under.
cat > "$SUB/agent-dev1.jsonl" <<JSON
{"type":"assistant","uuid":"d1","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:00.000Z","message":{"id":"n1","usage":{"input_tokens":100,"output_tokens":200},"content":[{"type":"tool_use","id":"u1","name":"Edit","input":{}}]}}
{"type":"assistant","uuid":"d1b","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:10.000Z","message":{"id":"n1b","content":[{"type":"text","text":"still in the skill"}]}}
{"type":"assistant","uuid":"d1c","isSidechain":true,"timestamp":"2026-08-14T13:00:20.000Z","message":{"id":"n1c","content":[{"type":"text","text":"a turn the skill did not attribute"}]}}
{"type":"assistant","uuid":"d1d","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:25.000Z","message":{"id":"n1d","content":[{"type":"text","text":"and back inside it"}]}}
{"type":"assistant","uuid":"d2","isSidechain":true,"timestamp":"2026-08-14T13:00:30.000Z","message":{"id":"n2","content":[{"type":"tool_use","id":"u2","name":"Bash","input":{"command":"cargo test --all CANARYBASHARG"}}]}}
{"type":"assistant","uuid":"d2b","isSidechain":true,"attributionSkill":"backlog","timestamp":"2026-08-14T13:00:40.000Z","message":{"id":"n2b","content":[{"type":"text","text":"a different skill"}]}}
{"type":"assistant","uuid":"d2c","isSidechain":true,"attributionSkill":"ui-review","timestamp":"2026-08-14T13:00:50.000Z","message":{"id":"n2c","content":[{"type":"text","text":"and the first one again"}]}}
{"type":"assistant","uuid":"d4","isSidechain":true,"timestamp":"2026-08-14T13:00:55.000Z","message":{"id":"n4","content":[{"type":"text","text":"Retro: $(printf 'w%.0s' $(seq 600))"}]}}
{"type":"assistant","uuid":"d3","isSidechain":true,"timestamp":"2026-08-14T13:01:00.000Z","message":{"id":"n3","content":[{"type":"text","text":"Retro: none"}]}}
JSON
cat > "$SUB/agent-rev2.meta.json" <<'JSON'
{"agentType":"pr-review-toolkit:code-reviewer","description":"nested","toolUseId":"tu2","parentAgentId":"dev1","spawnDepth":2}
JSON
cat > "$SUB/agent-rev2.jsonl" <<'JSON'
{"type":"assistant","uuid":"r1","isSidechain":true,"timestamp":"2026-08-14T13:02:00.000Z","message":{"id":"p1","usage":{"input_tokens":7,"output_tokens":8},"content":[{"type":"tool_use","id":"v1","name":"Read","input":{}}]}}
JSON
cat > "$SUB/agent-lost.meta.json" <<'JSON'
{"agentType":"reviewer","description":"its transcript is gone","toolUseId":"tu3","spawnDepth":1}
JSON
cat > "$SUB/agent-nometa.jsonl" <<'JSON'
{"type":"assistant","uuid":"q1","isSidechain":true,"timestamp":"2026-08-14T13:03:00.000Z","message":{"id":"q1m","content":[{"type":"tool_use","id":"w1","name":"Grep","input":{}}]}}
JSON
cat > "$SUB/agent-sync3.meta.json" <<'JSON'
{"agentType":"researcher","description":"finished before the result landed","toolUseId":"tu5","spawnDepth":1}
JSON
cat > "$SUB/agent-sync3.jsonl" <<'JSON'
{"type":"assistant","uuid":"y1","isSidechain":true,"timestamp":"2026-08-14T13:04:00.000Z","message":{"id":"y1m","usage":{"input_tokens":3,"output_tokens":4},"content":[{"type":"tool_use","id":"x1","name":"WebFetch","input":{}}]}}
JSON
cat > "$SUB/agent-running.meta.json" <<'JSON'
{"agentType":"architect","description":"has not stopped","toolUseId":"tu6","spawnDepth":1}
JSON
# A transcript that stats fine and will not open. A directory stands in for it,
# because root reads a chmod 000 file and the assertion would invert there.
mkdir -p "$SUB/agent-broken.jsonl"
cat > "$SUB/agent-broken.meta.json" <<'JSON'
{"agentType":"project-manager","description":"its transcript will not open","toolUseId":"tu7","spawnDepth":1}
JSON
# The whole path an id could traverse, laid out and readable: a real agent-x
# directory to climb out of, and a transcript and meta file at the far end,
# outside anything the sweep walks. Only the check on the id itself is between
# the notification below and this file.
mkdir -p "$SUB/agent-x"
cat > "$RP/escaped.jsonl" <<'JSON'
{"type":"assistant","uuid":"esc","isSidechain":true,"timestamp":"2026-08-14T13:02:55.000Z","message":{"id":"escm","content":[{"type":"tool_use","id":"esct","name":"Bash","input":{"command":"whoami"}}]}}
JSON
printf '{"agentType":"escaped","spawnDepth":1}\n' > "$RP/escaped.meta.json"
cat > "$SUB/agent-running.jsonl" <<'JSON'
{"type":"assistant","uuid":"z1","isSidechain":true,"timestamp":"2026-08-14T13:05:00.000Z","message":{"id":"z1m","content":[{"type":"tool_use","id":"zz","name":"Read","input":{}}]}}
JSON

cat > "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T13:00:00.000Z","version":"2.1.232","gitBranch":"main","cwd":"/repo/beta","message":{"role":"user","content":"delegate it"}}
{"type":"assistant","uuid":"s1","timestamp":"2026-08-14T13:00:01.000Z","message":{"id":"sm1","content":[{"type":"tool_use","id":"tu1","name":"Agent","input":{}}]}}
{"type":"user","timestamp":"2026-08-14T13:00:02.000Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"dev1","description":"CANARYDESCASYNC","prompt":"CANARYPROMPT","outputFile":"/tmp/x"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"launched"}]}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:01:10.000Z","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n<summary>CANARYSUMMARY</summary>\n<result>CANARYRESULT</result>\n</task-notification>"}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:01:11.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n<summary>CANARYSUMMARY</summary>\n<result>CANARYRESULT</result>\n</task-notification>"}}
{"type":"queue-operation","operation":"remove","timestamp":"2026-08-14T13:01:12.000Z","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n<summary>CANARYSUMMARY</summary>\n<result>CANARYRESULT</result>\n</task-notification>"}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:02:10.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>rev2</task-id>\n<status>completed</status>\n</task-notification>"}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:02:20.000Z","content":"<task-notification>\n<task-id>bgcmd</task-id>\n<status>completed</status>\n</task-notification>"}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:02:30.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>lost</task-id>\n<status>failed</status>\n</task-notification>"}}
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T13:02:40.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>broken</task-id>\n<status>completed</status>\n</task-notification>"}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:02:50.000Z","content":"<task-notification>\n<task-id>x/../../../../escaped</task-id>\n<status>completed</status>\n</task-notification>"}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T13:03:10.000Z","content":"<task-notification>\n<task-id>nometa</task-id>\n<status>completed</status>\n</task-notification>"}
{"type":"user","timestamp":"2026-08-14T13:04:10.000Z","toolUseResult":{"agentId":"sync3","status":"completed","agentType":"researcher","totalTokens":99,"content":"CANARYSYNCCONTENT"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu5","content":"done"}]}}
{"type":"assistant","uuid":"s9","timestamp":"2026-08-14T13:05:00.000Z","message":{"id":"sm9","content":[{"type":"tool_use","id":"tu9","name":"Bash","input":{"command":"git commit -m CANARYCOMMITMSG"}}]}}
{"type":"assistant","uuid":"s11","timestamp":"2026-08-14T13:05:02.000Z","message":{"id":"sm11","content":[{"type":"tool_use","id":"tu11","name":"Bash","input":{"command":"grep -F '|' /home/x/CANARYPIPEARG.csv"}}]}}
{"type":"assistant","uuid":"s12","timestamp":"2026-08-14T13:05:03.000Z","message":{"id":"sm12","content":[{"type":"tool_use","id":"tu12","name":"Bash","input":{"command":"cat > cfg.rs << 'EOF'\n  let key = CANARYHEREDOC;\n  run(); other();\nEOF"}}]}}
{"type":"assistant","uuid":"s13","timestamp":"2026-08-14T13:05:06.000Z","message":{"id":"sm13","content":[{"type":"tool_use","id":"tu13","name":"Bash","input":{"command":"find . -name x -exec rm {} \\; CANARYESCAPED.txt"}}]}}
{"type":"assistant","uuid":"s14","timestamp":"2026-08-14T13:05:07.000Z","message":{"id":"sm14","content":[{"type":"tool_use","id":"tu14","name":"Bash","input":{"command":"git -C CANARYFLAGVAL status"}}]}}
{"type":"assistant","uuid":"s15","timestamp":"2026-08-14T13:05:08.000Z","message":{"id":"sm15","content":[{"type":"tool_use","id":"tu15","name":"Bash","input":{"command":"case \"$f\" in ;; CANARYCASEPAT.png) cp a b ;; esac"}}]}}
{"type":"assistant","uuid":"s16","timestamp":"2026-08-14T13:05:09.000Z","message":{"id":"sm16","content":[{"type":"text","text":"Here is what it printed:\n\n    Retro: CANARYQUOTEDLINE, which is pasted output and not mine\n\nRetro: the pasted line above is not the answer"}]}}
{"type":"assistant","uuid":"s17","timestamp":"2026-08-14T13:05:10.000Z","message":{"id":"sm17","content":[{"type":"tool_use","id":"tu17","name":"Bash","input":{"command":"grep -nE \"alpha|[\\\\\"x\\\\\"]|CANARYDESYNC|beta\" src/app.ts"}}]}}
{"type":"assistant","uuid":"s18","timestamp":"2026-08-14T13:05:11.000Z","message":{"id":"sm18","content":[{"type":"tool_use","id":"tu18","name":"Bash","input":{"command":"kits=\"2026-01-01-CANARYDATEID other\"; echo done"}}]}}
{"type":"assistant","uuid":"s19","timestamp":"2026-08-14T13:05:12.000Z","message":{"id":"sm19","content":[{"type":"tool_use","id":"tu19","name":"Bash","input":{"command":"python3 CANARYSCRIPTNAME.py --once"}}]}}
{"type":"assistant","uuid":"s20","timestamp":"2026-08-14T13:05:13.000Z","message":{"id":"sm20","content":[{"type":"tool_use","id":"tu20","name":"Bash","input":{"command":"make CANARYTARGET"}}]}}
{"type":"assistant","uuid":"s21","timestamp":"2026-08-14T13:05:14.000Z","message":{"id":"sm21","content":[{"type":"tool_use","id":"tu21","name":"Bash","input":{"command":"node CANARYENTRY.js"}}]}}
{"type":"assistant","uuid":"s22","timestamp":"2026-08-14T13:05:15.000Z","message":{"id":"sm22","content":[{"type":"tool_use","id":"tu22","name":"Bash","input":{"command":"git CANARYALIAS --flag"}}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T13:05:04.000Z","hookInfos":[{"command":"please audit /srv/reports/CANARYPROSEPATH.py and report back","durationMs":3}],"hookErrors":[]}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T13:05:05.000Z","hookInfos":[{"command":"bash /opt/a/first.sh","durationMs":2},{"command":"bash /opt/b/second.sh","durationMs":2}],"hookErrors":["/opt/b/second.sh: not found"]}
{"type":"user","timestamp":"2026-08-14T13:05:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu9","content":"ok"}]}}
JSON
retro record >/dev/null

sql "an async launch plus a stop yields the agent's own figures" "1|1|100|200|2" \
  "SELECT n,agents,tokens_in,tokens_out,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
sql "the agent's duration comes from its transcript" "60000" \
  "SELECT ms_total FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
sql "three deliveries of one notification are one stop" "1" \
  "SELECT n FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
# The two record shapes carry the identical payload, and either is a fence:
# rev2 is announced by a user record alone, nometa by a queue-operation alone.
sql "a user record with a task-notification origin fences" "1|2" \
  "SELECT n,spawn_depth FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='pr-review-toolkit:code-reviewer'"
sql "a queue-operation record fences too" "1" \
  "SELECT n FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='unknown'"
sql "a synchronous result is a fence like any other" "1|1" \
  "SELECT n,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='researcher'"
sql "a task with no meta file and no transcript is a background command" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%bgcmd%'"
sql "an agent id that is a path is not an id" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%escaped%'"
sql "and it fences nothing" "0" \
  "SELECT count(*) FROM agent_run WHERE agent_type='escaped'"
# One fence whose transcript is missing, one whose transcript will not open.
# Neither may cost the session file it was named in.
sql "a fence with no readable transcript is counted as lost" "2" \
  "SELECT agent_fences_lost FROM segment WHERE id='s-agents#0'"
sql "and the session file it was named in still lands" "12" \
  "SELECT n FROM tool_use WHERE segment_id='s-agents#0' AND agent='' AND tool='Bash'"
sql "and it counts no stop" "0" \
  "SELECT count(*) FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='reviewer'"
sql "a transcript with no meta file is still folded in" "1|1" \
  "SELECT n,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='unknown'"
sql "an agent that has not stopped is never opened" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%agent-running%'"
sql "the session's own work and its agents' are separable" "|Agent|1" \
  "SELECT agent,tool,n FROM tool_use WHERE segment_id='s-agents#0' AND tool='Agent'"
sql "an agent's edits are attributed to it" "developer|1" \
  "SELECT agent,n FROM tool_use WHERE segment_id='s-agents#0' AND tool='Edit'"
sql "an agent's retro line carries its type as author" "developer|" \
  "SELECT author,IFNULL(text,'') FROM retro_line WHERE source_uuid='d3'"
# Two activations, not four: the run survives a turn it did not attribute, and
# starts again only when another skill has been in between.
sql "a skill an agent loaded is recorded against it" "2" \
  "SELECT n FROM skill_use WHERE segment_id='s-agents#0' AND agent='developer' AND skill='ui-review'"
sql "and the skill that interrupted it is its own" "1" \
  "SELECT n FROM skill_use WHERE segment_id='s-agents#0' AND agent='developer' AND skill='backlog'"
# A retro line is a line, not a report: the cap is what keeps it one.
sql "a long retro line is cut to the cap" "500" \
  "SELECT length(text) FROM retro_line WHERE source_uuid='d4'"

# The privacy boundary. Every field named in the spec's "read past but never
# stored" table is planted with a canary; a driver's subcommand is captured by
# design, so the bash canary sits where an argument sits.
# Every canary sits where a real leak was found or would hide: a separator
# inside a quoted argument, a heredoc body, a path inside prompt prose, and
# every field of the spec's "read past but never stored" table.
leaked=""
for c in CANARYPROMPT CANARYDESCASYNC CANARYSYNCCONTENT CANARYSUMMARY CANARYRESULT \
         CANARYMETADESC CANARYBASHARG CANARYCOMMITMSG CANARYHOOKPROSE CANARYRETROPROSE \
         CANARYPIPEARG CANARYHEREDOC CANARYPROSEPATH CANARYESCAPED CANARYFLAGVAL \
         CANARYCASEPAT CANARYQUOTEDLINE CANARYDESYNC CANARYDATEID \
         CANARYSCRIPTNAME CANARYTARGET CANARYENTRY CANARYALIAS; do
  grep -qa "$c" "$RH"/.claude/retro/retro.db* 2>/dev/null && leaked="$leaked $c"
done
[ -z "$leaked" ] && ok "no prompt, brief, report or argument reaches the store" \
                 || bad "no prompt, brief, report or argument reaches the store" "found:$leaked"

# ── the verb column is a closed set ───────────────────────────────────────────
# Twice a leak shipped because the canary tested the cases its author thought
# of, and twice it passed while the store held a filename. This asserts the
# property instead: every verb the recorder writes is drawn from a set spelled
# out in its own source, so no input can put a name there the source does not
# already contain. The corpus below is hostile rather than representative — the
# invariant, not the list, is what does the work — and the same check runs over
# every row the suite's own fixtures produced, which covers the inputs nobody
# thought to write a case for.
cat > "$TMP/closed.py" <<'PY2'
import json
import os
import sqlite3
import sys

hooks = sys.argv[1]
source = open(os.path.join(hooks, "retro.py")).read()
ns = {}
exec(compile(source.replace('if __name__ == "__main__":', "if False:"), "retro", "exec"), ns)
bash_verbs, known = ns["bash_verbs"], ns["KNOWN_VERBS"]

SECRET = "acmepayroll"
HOSTILE = [
    "./deploy_%s.sh --force", "time ./migrate_%s.py", "/opt/bin/rotate-%s-keys.sh",
    "../%s.py", "~/bin/%s", "VAR=1 ./%s.sh", "env FOO=1 ./%s.sh", "nice -n 5 ./%s.sh",
    "nohup ./%s.sh &", "`./%s.sh`", "$(./%s.sh)", "cat x | ./%s.sh", "true && ./%s.sh",
    "true || ./%s.sh", "cd /tmp; ./%s.sh", "for f in *; do ./%s.sh; done",
    "if true; then ./%s.sh; fi", "case $x in a) ./%s.sh ;; esac",
    "grep -F '|' /home/%s.csv", "grep -F \\| /home/%s.csv", "python3 %s.py",
    "node %s.js", "make %s", "git -C %s status", "kubectl -n %s get pods",
    "sudo ./%s.sh", "docker run %s", "cat > f << 'EOF'\n./%s.sh\nEOF", "%s",
    "%s --flag", "'%s'", '"%s" arg', "2026-01-01-%s", "./%s", "x=1 y=2 ./%s.sh",
    "eval ./%s.sh", "echo 'unbalanced ./%s.sh",
]
verdict = {"unknown": [], "leaked": [], "stored": []}
for shape in HOSTILE:
    command = shape % SECRET if "%s" in shape else shape
    for verb in bash_verbs(command):
        if verb not in known:
            verdict["unknown"].append([command, verb])
        if SECRET in verb:
            verdict["leaked"].append([command, verb])

db = sqlite3.connect(os.path.join(os.path.expanduser("~"), ".claude", "retro", "retro.db"))
# A denial signature is the verb for a Bash command and the tool's own name
# otherwise, and a tool name is the platform's word rather than the user's.
tools = {row[0] for row in db.execute("SELECT DISTINCT tool FROM tool_use")}
allowed = known | tools | {"unknown"}
verdict["stored"] = sorted(
    {row[0] for row in db.execute("SELECT DISTINCT verb FROM bash_verb")} - known
) + sorted({row[0] for row in db.execute("SELECT DISTINCT signature FROM denial")} - allowed)
print(json.dumps(verdict))
PY2
closed="$(HOME="$RH" python3 "$TMP/closed.py" "$ROOT/hooks")"
check "every verb a hostile corpus produces is one the source names" '"unknown": []' "$closed"
check "and none of them carries a name from the input" '"leaked": []' "$closed"
check "and every verb the store already holds is one too" '"stored": []' "$closed"

# A separator that is itself the argument — quoted or escaped — must not split
# the line, or the filename after it becomes a command of its own. A heredoc
# body is a file being written, and a case pattern is a filename, not a command.
sql "a quoted separator is an argument, not a split" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='grep'"
sql "an escaped separator is too" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='find'"
sql "a heredoc body is not a command" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='cat'"
sql "a case pattern is not a command" "0" \
  "SELECT count(*) FROM bash_verb WHERE segment_id='s-agents#0' AND verb LIKE '%CANARY%'"
# A quote escaped inside a quoted string is past what a lexer without a shell's
# grammar can follow, so the command is not normalised at all rather than
# normalised into the fragments of its own argument.
sql "a command whose quoting cannot be followed is not guessed at" "2" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='other'"
# The one argument the store keeps, stated rather than assumed: a driver's
# subcommand, which is what tells a read from a publish. A flag's value looks
# the same and is not one.
sql "a driver's subcommand is kept, by design" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='git commit'"
# The second word of an interpreter is the user's filename, and of make its
# target: both are theirs. A subcommand is only kept when it is one the recorder
# already knows, so what it stores can never be a name the user chose.
sql "an interpreter's filename is not a subcommand" "1|1" \
  "SELECT (SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND verb='python3'),
          (SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND verb='node')"
sql "nor is a make target" "1" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND verb='make'"
sql "nor a git subcommand nobody has heard of" "2" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='git'"
sql "a driver flag's value is not a subcommand" "2" \
  "SELECT n FROM bash_verb WHERE segment_id='s-agents#0' AND agent='' AND verb='git'"
# The required line is the last thing an agent writes; a Retro: above it is
# something it quoted.
sql "a quoted retro line loses to the agent's own" "the pasted line above is not the answer" \
  "SELECT text FROM retro_line WHERE source_uuid='s16'"
# hookInfos sometimes holds the user's prompt. A path inside prose is still
# prompt text, so only a script name is ever a label.
sql "a path inside prompt prose is not a hook label" "0" \
  "SELECT count(*) FROM hook_run WHERE segment_id='s-agents#0' AND hook LIKE '%CANARY%'"
# With one hook in the record the attribution is certain; with two, only the
# error message names which failed.
sql "an error among several hooks lands on the one it names" "0|1" \
  "SELECT (SELECT errors FROM hook_run WHERE segment_id='s-agents#0' AND hook='first.sh'),
          (SELECT errors FROM hook_run WHERE segment_id='s-agents#0' AND hook='second.sh')"

# A stdin payload is drained and discarded, never read.
printf '{"session_id":"x","prompt_text":"CANARYSTDIN"}' > "$TMP/retro.payload"
HOME="$RH" python3 "$ROOT/hooks/retro.py" record < "$TMP/retro.payload" >/dev/null 2>&1
grep -qa CANARYSTDIN "$RH"/.claude/retro/retro.db* 2>/dev/null \
  && bad "a hook payload never reaches the store" "CANARYSTDIN found" \
  || ok "a hook payload never reaches the store"

# Draining to EOF never ends on a stdin nobody closes, and the hook is wired
# async: a wait with no bound leaves a process alive after the session. The
# fifo's writer holds its end open and writes nothing, which is the shape a
# hand-run recorder meets.
finishes_on_open_stdin() {   # name, extra record arguments
  local name="$1"; shift
  local fifo="$TMP/drain.$$.fifo"
  mkfifo "$fifo"
  sleep 20 > "$fifo" &
  local writer=$! start took rc
  start=$(date +%s)
  timeout 10 env HOME="$RH" python3 "$ROOT/hooks/retro.py" record "$@" < "$fifo" >/dev/null 2>&1
  rc=$?
  took=$(( $(date +%s) - start ))
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null
  rm -f "$fifo"
  { [ "$rc" = 0 ] && [ "$took" -lt 5 ]; } \
    && ok "$name" || bad "$name" "exit $rc after ${took}s"
}
finishes_on_open_stdin "a stdin that stays open does not hold the recorder"

# The drain exists to spare the writer, so what proves it ran is the writer:
# a payload past a pipe buffer blocks in write() until something reads it, and
# a recorder that returns first hands it EPIPE instead. --interval no-ops on
# nearly every prompt and UserPromptSubmit is the trigger that carries it, so a
# drain behind that gate is a drain that never runs where it is needed most.
frees_the_writer() {   # name, extra record arguments
  local name="$1"; shift
  local fifo="$TMP/payload.$$.fifo"
  mkfifo "$fifo"
  ( python3 -c 'import sys; sys.stdout.write("{\"p\":\"" + "z" * (1 << 20) + "\"}")' \
      > "$fifo" 2>/dev/null ) &
  local writer=$! rc
  timeout 10 env HOME="$RH" python3 "$ROOT/hooks/retro.py" record "$@" < "$fifo" >/dev/null 2>&1
  wait "$writer"; rc=$?
  rm -f "$fifo"
  [ "$rc" = 0 ] && ok "$name" || bad "$name" "the writer exited $rc"
}
frees_the_writer "a payload past a pipe buffer is read away"
frees_the_writer "and an interval that skips the sweep still reads it" --interval 3600

# Rebuilding a segment must re-read every agent it fenced, from where that
# segment first found it: not doubled, and not lost.
figures > "$TMP/retro.before"
rewrite_head "$RP/beta/s-agents.jsonl" '"delegate it"' '"delegate all of it"'
retro record >/dev/null
figures > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "a reparse reproduces the identical delegation figures" \
  || bad "a reparse reproduces the identical delegation figures" \
         "$(diff "$TMP/retro.before" "$TMP/retro.after" | head -6)"

# An agent that is resumed stops again. New bytes are a second stop; a repeat
# delivery with none is not.
cat >> "$SUB/agent-dev1.jsonl" <<'JSON'
{"type":"assistant","uuid":"d4","isSidechain":true,"timestamp":"2026-08-14T14:00:00.000Z","message":{"id":"n4","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"u4","name":"Write","input":{}}]}}
JSON
cat >> "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-08-14T14:00:10.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n</task-notification>"}}
JSON
retro record >/dev/null
sql "new bytes since the last fence are a second stop, by one agent" "2|1|3" \
  "SELECT n,agents,tool_uses FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
cat >> "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-14T14:01:00.000Z","content":"<task-notification>\n<task-id>dev1</task-id>\n<status>completed</status>\n</task-notification>"}
JSON
retro record >/dev/null
sql "a fence with no new bytes adds nothing" "2|1" \
  "SELECT n,agents FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"

# A rebuild re-delivers fences this segment already counted. An agent that has
# run on since — resumed, still going, not yet fenced again — has bytes that
# belong to a stop nobody has seen. Counting them at the old fence would read as
# a lane that went round again.
cat >> "$SUB/agent-dev1.jsonl" <<'JSON'
{"type":"assistant","uuid":"d5","isSidechain":true,"timestamp":"2026-08-14T14:30:00.000Z","message":{"id":"n5","content":[{"type":"tool_use","id":"u5","name":"Glob","input":{}}]}}
JSON
drop_last "$RP/beta/s-agents.jsonl"
retro record >/dev/null
sql "a rebuild does not re-count a stop it already has" "2|1" \
  "SELECT n,agents FROM agent_run WHERE segment_id='s-agents#0' AND agent_type='developer'"
sql "and the still-running agent's work waits for its own fence" "0" \
  "SELECT count(*) FROM tool_use WHERE segment_id='s-agents#0' AND agent='developer' AND tool='Glob'"

# Only the session transcripts are walked, one level deep. A subagent transcript
# is opened by name at a fence and never by the walk, or the whole subagent tree
# would be swept — 1,791 files here against 76 session transcripts.
mkdir -p "$RP/alpha/subagents"
cat > "$RP/alpha/subagents/agent-planted.jsonl" <<'JSON'
{"type":"assistant","uuid":"pl1","isSidechain":true,"timestamp":"2026-08-14T13:30:00.000Z","message":{"id":"pl","content":[{"type":"tool_use","id":"pl","name":"Bash","input":{"command":"whoami"}}]}}
JSON
retro record >/dev/null
sql "the walk goes one level deep and no further" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%agent-planted%'"
sql "and never opens an unfenced subagent transcript" "0" \
  "SELECT count(*) FROM cursor WHERE agent_id IS NULL AND path LIKE '%subagents%'"

# ── review ───────────────────────────────────────────────────────────────────
# Only closed segments are reviewable, so this closes the delegation segment
# first: everything above it is open except s-main#0.
cat >> "$RP/beta/s-agents.jsonl" <<'JSON'
{"type":"assistant","uuid":"s10","timestamp":"2026-08-14T14:30:00.000Z","message":{"id":"sm10","content":[{"type":"text","text":"Retro: the brief left the interval open"}]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-14T15:00:00.000Z","compactMetadata":{"trigger":"manual","preTokens":500,"postTokens":50,"cumulativeDroppedTokens":450,"durationMs":900}}
JSON
retro record >/dev/null
sql "a notification is a wake, not a user turn" "1|5" \
  "SELECT user_turns,wake_turns FROM segment WHERE id='s-agents#0'"
state > "$TMP/retro.before"
digest="$(retro review)"
state > "$TMP/retro.after"
cmp -s "$TMP/retro.before" "$TMP/retro.after" \
  && ok "review writes nothing" \
  || bad "review writes nothing" "the store changed"

# Column widths move with the data, so the digest is read with runs of spaces
# squeezed: these assert what a row says, not how wide it is.
flat="$(printf '%s' "$digest" | tr -s ' ')"
check "the digest names its window"        "segments 2 · projects 2" "$digest"
check "every grouped row carries n, segments and projects" "n segments projects" "$flat"
check "delegation separates the session"   "alpha session" "$flat"
check "delegation separates the agents"    "beta agents"   "$flat"
check "nesting above depth 1 is called out" "nested: pr-review-toolkit:code-reviewer at depth 2" "$digest"
check "an installed skill that never fired is named" "never fired: never-fired" "$digest"
# A ranked table stops at twelve rows. The Window section is careful to say when
# a figure is short, and a table that quietly truncates reads as the whole list
# — which is the one thing a reviewer ranking by recurrence must not believe.
verbs_in_window="$(dbq "SELECT COUNT(*) FROM (SELECT b.verb, b.agent='' FROM bash_verb b
  JOIN segment w ON w.id=b.segment_id WHERE w.closed_seq IS NOT NULL GROUP BY 1,2)")"
[ "${verbs_in_window:-0}" -gt 12 ] \
  && check "a table that shows only its top says so" \
       "and $(( verbs_in_window - 12 )) more, not shown" "$digest" \
  || bad "the verb table is long enough to truncate" "only $verbs_in_window rows"
# A skills directory that will not read is not one holding nothing: saying
# nothing there reads as "every skill fired", which is the opposite of what is
# known. Root reads it regardless, so the assertion is skipped there.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$RH/.claude/skills"
  check "a skills list that will not read says so, in the digest's voice" \
    "never fired: not known — the installed skills could not be read" "$(retro review)"
  chmod 755 "$RH/.claude/skills"
fi
check "permission friction is grouped"     "user-rejected" "$digest"
check "compaction is split auto from manual" "manual" "$digest"
check "retro lines are listed with author and date" "main beta 2026-08-14 the brief left the interval open" "$flat"
check "the count of none answers is beside them" "answered none: 1" "$digest"
# A figure that is short because something would not read has to say so, or the
# digest reads as complete when it is not.
check "the digest owns up to what it could not read" \
  "incomplete: 2 agent stops had no readable transcript" "$digest"
# Only closed segments are reviewable, and the store has open ones: the count
# the digest names has to be the closed count and not the total.
eq "the window holds closed segments only" \
  "$(dbq "SELECT count(*) FROM segment WHERE closed_seq IS NOT NULL")" \
  "$(printf '%s' "$digest" | sed -n 's/.*segments \([0-9]*\) · projects.*/\1/p')"
[ "$(dbq "SELECT count(*) FROM segment WHERE closed_seq IS NULL")" -gt 0 ] \
  && ok "with open segments in the store to leave out" \
  || bad "with open segments in the store to leave out" "every segment is closed, so this proves nothing"

# Reading the digest through a pager closes the pipe early, and the flush the
# interpreter does after every guard has gone out of scope must not raise.
HOME="$RH" python3 "$ROOT/hooks/retro.py" review </dev/null 2>"$TMP/retro.err" | head -2 >/dev/null
{ [ "${PIPESTATUS[0]}" = 0 ] && [ ! -s "$TMP/retro.err" ]; } \
  && ok "a digest read through a pager is a clean exit" \
  || bad "a digest read through a pager is a clean exit" \
         "exit ${PIPESTATUS[0]}, stderr: $(cat "$TMP/retro.err")"

# Accepting is what hides a window, permanently and with no undo, so a value
# nobody could have reviewed is refused rather than taken.
seq="$(dbq "SELECT MAX(closed_seq) FROM segment")"
out="$(retro review --accept 999999 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ "$(dbq "SELECT count(*) FROM meta WHERE key='reviewed_through'")" = 0 ]; } \
  && ok "a sequence past the last closed segment is refused" \
  || bad "a sequence past the last closed segment is refused" "exit $rc, marker moved"
out="$(retro review --accept "$seq")"
check "accepting says how much it hid" "accepted 2 segments · reviewed_through 0 → $seq" "$out"
out="$(retro review --accept "$seq" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "accepting the same window twice is refused" \
              || bad "accepting the same window twice is refused" "exit $rc"
retro review --accept "$seq" >/dev/null 2>&1
check "an accepted window comes back empty" "no closed segments to review" "$(retro review)"
check "--all still digests everything"      "segments 2" "$(retro review --all)"
sql "accepting moves the marker and nothing else" "$seq" \
  "SELECT value FROM meta WHERE key='reviewed_through'"

# A segment closed after the accept is the next review's window, and only it.
cat > "$RP/alpha/s-later.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T16:00:00.000Z","cwd":"/repo/gamma","message":{"role":"user","content":"more"}}
{"type":"assistant","uuid":"L1","timestamp":"2026-08-14T16:00:01.000Z","message":{"id":"lm1","content":[{"type":"tool_use","id":"l1","name":"Bash","input":{"command":"git push origin main"}}]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-14T16:01:00.000Z","compactMetadata":{"trigger":"auto","preTokens":9,"postTokens":1,"cumulativeDroppedTokens":8,"durationMs":10}}
JSON
retro record >/dev/null
digest="$(retro review)"
check "a later segment is the next window"  "segments 1 · projects 1" "$digest"
check "and it is the one that closed last"  "git push" "$digest"

# ── closing a segment nothing compacted ──────────────────────────────────────
# A transcript that has fallen idle closes its open segment: 24 hours is long
# enough that an overnight break does not.
cat > "$RP/alpha/s-idle.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T18:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"work"}}
{"type":"assistant","uuid":"i1","timestamp":"2026-08-14T18:00:01.000Z","message":{"id":"im1","content":[{"type":"tool_use","id":"i1t","name":"Read","input":{}}]}}
JSON
retro record >/dev/null
sql "a live transcript's segment stays open" "" \
  "SELECT IFNULL(close_trigger,'') FROM segment WHERE id='s-idle#0'"
touch -d '3 days ago' "$RP/alpha/s-idle.jsonl"
retro record >/dev/null
sql "a transcript left alone for a day closes its segment" "idle" \
  "SELECT close_trigger FROM segment WHERE id='s-idle#0'"
# A closed segment is immutable, so a session that wakes up again starts a new
# one rather than adding to a segment that may already have been reviewed.
cat >> "$RP/alpha/s-idle.jsonl" <<'JSON'
{"type":"assistant","uuid":"i2","timestamp":"2026-08-17T09:00:00.000Z","message":{"id":"im2","content":[{"type":"tool_use","id":"i2t","name":"Write","input":{}}]}}
{"type":"assistant","uuid":"i3","timestamp":"2026-08-17T09:01:00.000Z","message":{"id":"im3","content":[{"type":"tool_use","id":"i3t","name":"Glob","input":{}}]}}
JSON
retro record >/dev/null
sql "a resumed transcript opens the next segment instead" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-idle#1' AND tool='Write'"
sql "and the closed one is left exactly as it was" "1|idle" \
  "SELECT assistant_turns,close_trigger FROM segment WHERE id='s-idle#0'"

# An ordinal that came from an idle close exists only in the cursor — no
# boundary in the file produced it — so a rebuild that re-derived it from the
# bytes would land back on the closed segment and discard everything after it.
# The rewind drops the last record and leaves the one before it whole.
drop_last "$RP/alpha/s-idle.jsonl"
retro record >/dev/null
sql "a rewound transcript rebuilds its reopened segment" "1|1" \
  "SELECT (SELECT n FROM tool_use WHERE segment_id='s-idle#1' AND tool='Write'),
          (SELECT assistant_turns FROM segment WHERE id='s-idle#1')"
sql "without the record the rewind took" "0" \
  "SELECT count(*) FROM tool_use WHERE segment_id='s-idle#1' AND tool='Glob'"
sql "and the closed segment is still untouched" "1|idle" \
  "SELECT assistant_turns,close_trigger FROM segment WHERE id='s-idle#0'"
sql "so nothing had to be given up" "0" \
  "SELECT IFNULL((SELECT value FROM meta WHERE key='segments_dropped'),'0')"

# A transcript whose head changed is a different file under an old name. Its
# open segment has no source any more, so what came from the session's own chain
# goes — and the count is what stops that being silent.
rewrite_head "$RP/alpha/s-idle.jsonl" '"work"' '"work now"'
retro record >/dev/null
sql "a segment a replaced file cannot rebuild is counted, not hidden" "1" \
  "SELECT value FROM meta WHERE key='segments_dropped'"
digest_all="$(retro review --all)"
check "and the digest owns it" "1 segments could not be rebuilt" "$digest_all"
# Both all-time figures share the line, and it says which store they are from:
# a transcript that failed last spring is not a fault of the window under
# review, and the toolkit skill reads this line as the reason a figure is short.
check "under a heading that scopes them to the store" \
  "store, all time: 1 transcripts would not sweep, 1 segments could not be rebuilt" \
  "$digest_all"

# A file replaced by one that predates the marker may not be read at all. Its
# open segment cannot survive that, and the cursor has to keep the segment id or
# the next append lands in a closed segment and is discarded in silence.
python3 - "$RP/alpha/s-idle.jsonl" <<'PY'
import sys

path = sys.argv[1]
open(path, "w").write(
    '{"type":"user","origin":{"kind":"human"},"timestamp":"2025-05-05T10:00:00.000Z",'
    '"cwd":"/repo/alpha","message":{"role":"user","content":"someone else\'s old file"}}\n'
)
PY
retro record >/dev/null
sql "a replaced pre-marker file gives up its open segment, and says so" "2" \
  "SELECT value FROM meta WHERE key='segments_dropped'"
sql "and records nothing of the file it now is" "0" \
  "SELECT count(*) FROM segment WHERE id='s-idle#2'"
# Every one of these is written with IFNULL, so a rebuild that leaves them
# standing keeps the replaced file's repo and dates and reports a window that
# never happened.
sql "a rebuilt segment describes no file but the one it read" "|||" \
  "SELECT IFNULL(repo,'')||'|'||IFNULL(started_at,'')||'|'||IFNULL(branch,'')||'|'||IFNULL(cli_version,'')
   FROM segment WHERE id='s-idle#1'"
cat >> "$RP/alpha/s-idle.jsonl" <<'JSON'
{"type":"assistant","uuid":"i9","timestamp":"2026-08-18T09:00:00.000Z","message":{"id":"im9","content":[{"type":"tool_use","id":"i9t","name":"Task","input":{}}]}}
JSON
retro record >/dev/null
sql "what it gains after that is still recorded" "1" \
  "SELECT n FROM tool_use WHERE segment_id='s-idle#1' AND tool='Task'"

# The 30-day cleanup deletes transcripts. The digest is the only record left, so
# it stays; the cursor pointing at a file that is gone does not.
cat > "$RP/alpha/s-deleted.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T19:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"work"}}
{"type":"assistant","uuid":"g1","timestamp":"2026-08-14T19:00:01.000Z","message":{"id":"gm1","content":[{"type":"tool_use","id":"g1t","name":"Grep","input":{}}]}}
JSON
retro record >/dev/null
rm -f "$RP/alpha/s-deleted.jsonl"
retro record >/dev/null
# Ten agent transcripts exist for every session one, and the 30-day cleanup
# takes them all. Nothing walks an agent cursor and nothing idle-closes one, so
# without a prune the table is the only thing in the store that grows forever.
agent_cursors_before="$(dbq "SELECT count(*) FROM cursor WHERE agent_id IS NOT NULL")"
rm -f "$SUB/agent-rev2.jsonl"
retro record >/dev/null
sql "a cursor whose agent transcript is gone is pruned" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%agent-rev2.jsonl'"
eq "and the cursors still pointing at a file stay" "$(( agent_cursors_before - 1 ))" \
  "$(dbq "SELECT count(*) FROM cursor WHERE agent_id IS NOT NULL")"

sql "a deleted transcript closes its segment as gone" "gone|1" \
  "SELECT close_trigger,assistant_turns FROM segment WHERE id='s-deleted#0'"
sql "and its cursor goes with it" "0" \
  "SELECT count(*) FROM cursor WHERE path LIKE '%s-deleted%'"

# ── the recorder's own failure paths ─────────────────────────────────────────
# A missing marker must never become a backfill: it is recreated, and the run it
# was missing on records nothing at all.
rm -f "$RH/.claude/retro/since"
cat > "$RP/alpha/s-nomarker.jsonl" <<'JSON'
{"type":"user","origin":{"kind":"human"},"timestamp":"2026-08-14T17:00:00.000Z","cwd":"/repo/alpha","message":{"role":"user","content":"hi"}}
JSON
retro record >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ -s "$RH/.claude/retro/since" ]; } \
  && ok "a missing since marker is recreated" \
  || bad "a missing since marker is recreated" "exit $rc"
sql "and that run records nothing" "0" \
  "SELECT count(*) FROM segment WHERE session_id='s-nomarker'"
# The marker is the one value that must never move, and a stamp that lost its Z
# read as local time moves it by up to a day — in the direction of recording
# what it exists to exclude. Read under a zone that is not UTC, or the two
# readings would agree whatever the code did.
naive="$(TZ=America/New_York python3 "$TMP/tz.py" "$ROOT/hooks")"
eq "a marker that lost its zone is still read as UTC" "same" "$naive"

# A marker that is there but will not parse is a different condition from one
# that is absent: it is the one value in the store that must never move, so it
# is left exactly as it is and nothing is recorded until someone looks.
printf 'not a timestamp' > "$RH/.claude/retro/since"
retro record >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ "$(cat "$RH/.claude/retro/since")" = "not a timestamp" ]; } \
  && ok "an unreadable marker is left exactly as it is" \
  || bad "an unreadable marker is left exactly as it is" "exit $rc, now: $(cat "$RH/.claude/retro/since")"
check "and the doctor is what says so" "retro/since is not a timestamp" \
  "$(HOME="$RH" "$ROOT/install.sh" --dry-run 2>&1)"

# Put the fixtures back inside the window; the marker it wrote is now, which
# would make every one of them older than the store.
printf '2026-01-01T00:00:00Z\n' > "$RH/.claude/retro/since"

# A store another toolkit wrote is left alone rather than adopted or destroyed.
HOME="$RH" python3 -c "
import os, sqlite3
db = sqlite3.connect(os.path.expanduser('~/.claude/retro/retro.db'))
db.execute('PRAGMA user_version=99')
db.close()"
segments="$(dbq "SELECT count(*) FROM segment")"
retro record >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ "$(dbq "SELECT count(*) FROM segment")" = "$segments" ]; } \
  && ok "a store from a newer toolkit is not touched" \
  || bad "a store from a newer toolkit is not touched" "exit $rc"
retro review >/dev/null
check "and the review says which version it is" "schema version 99" "$(cat "$TMP/retro.err")"
ls "$RH"/.claude/retro/retro.db.corrupt.* >/dev/null 2>&1 \
  && bad "a newer schema is not treated as corruption" "it was moved aside" \
  || ok "a newer schema is not treated as corruption"
HOME="$RH" python3 -c "
import os, sqlite3
db = sqlite3.connect(os.path.expanduser('~/.claude/retro/retro.db'))
db.execute('PRAGMA user_version=1')
db.close()"

# A store that will not open is a store behind a problem, not a broken one:
# moving it aside would throw away the record that outlives every transcript.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$RH/.claude/retro/retro.db"
  retro record >/dev/null; rc=$?
  chmod 644 "$RH/.claude/retro/retro.db"
  { [ "$rc" = 0 ] && ! ls "$RH"/.claude/retro/retro.db.corrupt.* >/dev/null 2>&1; } \
    && ok "a store that will not open is left where it is" \
    || bad "a store that will not open is left where it is" "exit $rc, it was quarantined"
  sql "and everything in it survives" "$segments" "SELECT count(*) FROM segment"
fi

# A corrupt store is moved aside and rebuilt. This is last, because a rebuild
# re-derives every live transcript from scratch.
segments="$(dbq "SELECT count(*) FROM segment")"
printf 'this is not a database' > "$RH/.claude/retro/retro.db"
rm -f "$RH/.claude/retro/retro.db-wal" "$RH/.claude/retro/retro.db-shm"
retro record >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "a corrupt store still exits 0" || bad "a corrupt store still exits 0" "exit $rc"
ls "$RH"/.claude/retro/retro.db.corrupt.* >/dev/null 2>&1 \
  && ok "the corrupt store is kept, not deleted" \
  || bad "the corrupt store is kept, not deleted" "no retro.db.corrupt.* file"
retro record >/dev/null
rebuilt="$(dbq "SELECT count(*) FROM segment")"
[ "${rebuilt:-0}" -gt 0 ] && ok "the store is rebuilt from the live transcripts" \
                          || bad "the store is rebuilt from the live transcripts" "$rebuilt segments"

# Nothing to read at all is a first session on a new machine.
EMPTY="$TMP/retro-empty"
mkdir -p "$EMPTY"
out="$(HOME="$EMPTY" python3 "$ROOT/hooks/retro.py" record </dev/null 2>"$TMP/retro.err")"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$TMP/retro.err" ]; } \
  && ok "no ~/.claude/projects at all is still a clean exit" \
  || bad "no ~/.claude/projects at all is still a clean exit" "exit $rc, err $(cat "$TMP/retro.err")"
check "an empty store reviews as empty" "no closed segments to review" \
  "$(HOME="$EMPTY" python3 "$ROOT/hooks/retro.py" record </dev/null >/dev/null 2>&1; \
     HOME="$EMPTY" python3 "$ROOT/hooks/retro.py" review </dev/null 2>&1)"

# The retro line is a required field, so every agent's return contract states it.
missing=""
for a in "$ROOT"/agents/*.md; do
  grep -q '`Retro: none`' "$a" || missing="$missing $(basename "$a")"
done
[ -z "$missing" ] && ok "every agent must answer Retro" || bad "every agent must answer Retro" "missing in:$missing"

# The statuses an agent may write and the ones CLAUDE.md routes on are one list,
# and a status counts as routed only where an action follows it. The output goes
# through a file because bash 3.2 ends a $( ) by scanning for the closing paren,
# which the backticks in the heredoc below would carry to the end of the suite.
python3 - "$ROOT" > "$TMP/statuses" <<'PY'
import glob
import re
import sys

home = sys.argv[1]
routed = set(re.findall(r"^- `Status: ([^`]+)` →", open(home + "/CLAUDE.md", encoding="utf-8").read(), re.M))
drift = [] if routed else ["CLAUDE.md routes on no status at all"]
for definition in sorted(glob.glob(home + "/agents/*.md")):
    agent = definition.rsplit("/", 1)[-1]
    contract = open(definition, encoding="utf-8").read().split("## What you return")[-1]
    returned = [line for line in contract.splitlines() if line.startswith("- ")]
    first = returned[0] if returned else ""
    if not first.startswith("- `Status:`"):
        drift.append(agent + " does not open its report with a status")
    elif "first line:" not in first:
        drift.append(agent + " does not name its statuses after 'first line:'")
    else:
        offered = set(re.findall(r"`([^`]+)`", first.split("first line:")[-1]))
        if offered != routed:
            drift.append("%s offers %s" % (agent, ", ".join(sorted(offered)) or "nothing"))
print("; ".join(drift))
PY
unrouted="$(cat "$TMP/statuses")"
[ -z "$unrouted" ] && ok "every report opens with a status the CTO routes on" \
  || bad "every report opens with a status the CTO routes on" "$unrouted"

# One wording in both homes, no dash in it, and every line already written
# matching: a dash there would ask for an override on every append.
published="$(template "$ROOT/CLAUDE.md")"
{ [ -n "$published" ] && [ "$published" = "$(template "$ROOT/RETRO.md")" ]; } \
  && ok "the retro format is one wording in both homes" \
  || bad "the retro format is one wording in both homes" \
         "CLAUDE.md has '${published:-<nothing>}', RETRO.md has '$(template "$ROOT/RETRO.md")'"
case "$published" in
  *"$EM"*|*"$EN"*|*--*) bad "and carries no dash of its own" "$published" ;;
  *)                    ok  "and carries no dash of its own" ;;
esac

# A lane's steps are named many times a session, and only the example teaches
# the separator, so a dash there is the rule breaking itself all day.
lanes="$(grep 'Payments rework' "$ROOT/CLAUDE.md")"
steps="$(printf '%s\n' "$lanes" | grep -c 'Payments rework: [a-z]')"
[ "${steps:-0}" -ge 2 ] && ok "a lane's steps are named with a colon" \
  || bad "a lane's steps are named with a colon" "${steps:-0} lines in CLAUDE.md carry the form"
case "${lanes:-<nothing>}" in
  *"$EM"*|*"$EN"*|*--*|"<nothing>") bad "and the example carries no dash" "$lanes" ;;
  *)                                ok  "and the example carries no dash" ;;
esac

# README.md quotes the task line verbatim, and nothing else holds the two to the
# same wording. An empty expected string would match any file, so it is refused.
for want in "$BLOCKED_LINE" "${HINT%%. Tools*}"; do
  case "$want" in "") bad "README publishes the task line" "the expected string is empty"; continue ;; esac
  grep -qF "$want" "$ROOT/README.md" && ok "README publishes: $want" \
    || bad "README publishes: $want" "README.md does not carry it"
done

# Install links a skill whether or not the README names it, so the row is the
# half that goes stale, in both directions. An absent row matches every name, so
# it fails. find at any depth, because that is what install.sh links, and the
# link carries the directory name while the Skill tool answers to the other one.
row="$(grep -F '| `skills/` |' "$ROOT/README.md")"
installed=" "; unlisted=""; misnamed=""; unbuilt=""
while IFS= read -r s; do
  name="$(basename "$(dirname "$s")")"
  installed="$installed$name "
  case "$row" in *"\`$name\`"*) ;; *) unlisted="$unlisted $name" ;; esac
  [ "$(sed -n 's/^name: //p' "$s" | head -1)" = "$name" ] || misnamed="$misnamed $name"
done <<EOF
$(find "$ROOT/skills" -name SKILL.md | sort)
EOF
for want in $(printf '%s\n' "$row" | grep -o '`[a-z][a-z-]*`' | tr -d '`'); do
  case "$installed" in *" $want "*) ;; *) unbuilt="$unbuilt $want" ;; esac
done
if [ -z "$row" ] || [ "$installed" = " " ]; then
  bad "the README names every skill" "no skills row, or no skill under skills/"
elif [ -n "$unlisted" ]; then
  bad "the README names every skill" "not named:$unlisted"
else
  ok "the README names every skill"
fi
[ -z "$unbuilt" ] && ok "and every name in the row is a skill" \
  || bad "and every name in the row is a skill" "no skill behind:$unbuilt"
[ -z "$misnamed" ] && ok "and a skill's frontmatter name is its directory" \
  || bad "and a skill's frontmatter name is its directory" "disagreeing in:$misnamed"

# An agent CLAUDE.md gives no row is one the session never reaches for, and a
# roster row with no definition behind it sends it after nothing. A row is any
# whose first cell is a backticked lowercase name, so a new effort level joins
# the roster rather than dropping out of it, and padding the table changes
# nothing.
rowless=""; unnamed=""; misfiled=""; ghost=""; efforts=""; rows=0
for a in "$ROOT"/agents/*.md; do
  agent="$(basename "$a" .md)"
  grep -qE "^\| *\`$agent\` *\|" "$ROOT/README.md" || rowless="$rowless $agent"
  grep -qE "^\| *\`$agent\` *\|" "$ROOT/CLAUDE.md" || unnamed="$unnamed $agent"
  # The file name is what install links and every check here reads; the
  # frontmatter name is what the session spawns. They have to be one name.
  [ "$(sed -n 's/^name: //p' "$a" | head -1)" = "$agent" ] || misfiled="$misfiled $agent"
done
while read -r want level; do
  [ -n "$want" ] || continue
  rows=$((rows + 1))
  if [ ! -f "$ROOT/agents/$want.md" ]; then
    ghost="$ghost $want"
  elif [ "$level" != "$(sed -n 's/^effort: //p' "$ROOT/agents/$want.md" | head -1)" ]; then
    efforts="$efforts $want"
  fi
done <<EOF
$(sed -n 's/^| *`\([a-z][a-z-]*\)` *| *\([a-z]*\) *|.*/\1 \2/p' "$ROOT/README.md")
EOF
[ -z "$rowless" ] && ok "every agent has a row in the README roster" \
  || bad "every agent has a row in the README roster" "no row for:$rowless"
if [ "$rows" -eq 0 ]; then
  bad "and every row in it has a definition" "the roster holds no row"
elif [ -n "$ghost" ]; then
  bad "and every row in it has a definition" "no definition behind:$ghost"
else
  ok "and every row in it has a definition"
fi
[ -z "$efforts" ] && ok "and the effort it publishes is the one the definition sets" \
  || bad "and the effort it publishes is the one the definition sets" "disagreeing for:$efforts"
[ -z "$unnamed" ] && ok "and CLAUDE.md gives every agent a row of its own" \
  || bad "and CLAUDE.md gives every agent a row of its own" "no row for:$unnamed"
[ -z "$misfiled" ] && ok "and an agent's frontmatter name is its file name" \
  || bad "and an agent's frontmatter name is its file name" "disagreeing in:$misfiled"

# A definition naming a skill is a reference like any other, so retiring one
# breaks something rather than leaving an instruction pointing at nothing.
referenced="$(grep -ho '`[a-z][a-z-]*` skill' "$ROOT/CLAUDE.md" "$ROOT"/agents/*.md "$ROOT"/skills/*/SKILL.md \
  | tr -d '`' | sed 's/ skill$//' | sort -u)"
dangling=""
for want in $referenced; do
  case "$installed" in *" $want "*) ;; *) dangling="$dangling $want" ;; esac
done
if [ -z "$referenced" ]; then
  bad "every skill a definition names exists" "no definition names one, so nothing was checked"
elif [ -n "$dangling" ]; then
  bad "every skill a definition names exists" "named but not installed:$dangling"
else
  ok "every skill a definition names exists"
fi

# The published template, filled in, against the pattern the log is held to. An
# emptied log is where a retro leaves it, so without this nothing exercises the
# pattern and the two drift apart in silence.
SHAPE='^- [0-9-]+ · [^ ·]+ · [^ ·]+: '
filled="$(render "$ROOT/CLAUDE.md")"
printf '%s\n' "$filled" | grep -qE "$SHAPE" \
  && ok "the published format satisfies the shape the log is held to" \
  || bad "the published format satisfies the shape the log is held to" "${filled:-<nothing>}"
printf '%s\n' "${filled%%·*}" | grep -qE "$SHAPE" \
  && bad "and the shape turns down a line missing its fields" "${filled%%·*}" \
  || ok "and the shape turns down a line missing its fields"

# Every bullet, not every dated one: a line that lost its date is what this
# catches, and counting only dated lines would read it as an empty log.
unshaped() { grep '^- ' "$1" | grep -cvE "$SHAPE"; }
strays="$(unshaped "$ROOT/RETRO.md")"
[ "$strays" -eq 0 ] && ok "every line in the log carries it" \
                   || bad "every line in the log carries it" "$strays lines do not"
printf '# Retro log\n\n- 2026-08-30 developer agent-toolkit: the separators are gone\n' >"$TMP/loose-log.md"
[ "$(unshaped "$TMP/loose-log.md")" -eq 1 ] \
  && ok "and a line that lost them would not" \
  || bad "and a line that lost them would not" "the shape took it"

# Each threshold is a judgement the spec argues for, so the two must not drift.
drifted="$(python3 - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]
code = open(root + "/hooks/style.py", encoding="utf-8").read()
spec = open(root + "/documentation/specs/style-checks.md", encoding="utf-8").read()
rows = re.findall(r"^\| `([A-Z_]+)` \| (\S+) \|", spec, re.M)
said = []
for name, documented in rows:
    found = re.search(r"^%s = (\S+)$" % name, code, re.M)
    if not found:
        said.append("%s is documented but not in the hook" % name)
    elif found.group(1) != documented:
        said.append("%s is %s in the hook and %s in the spec" % (name, found.group(1), documented))
print("; ".join(said) if said else ("" if rows else "the spec states no thresholds at all"))
PY
)"
[ -z "$drifted" ] && ok "the spec's thresholds are the hook's" \
                  || bad "the spec's thresholds are the hook's" "$drifted"

# ── duplication ──────────────────────────────────────────────────────────────
# Both directions of the gate: the checkout as it stands is clean, and a
# function pasted into a second file is not.
echo "duplication.sh"

dup() { "$ROOT/tests/duplication.sh" "$1" > "$TMP/dup.out" 2>&1; }
verdict() { # name, expected exit, actual exit
  [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected exit $2, got $3: $(cat "$TMP/dup.out")"
}

dup "$ROOT"; rc=$?
case "$rc" in
  0) ok   "the checkout has no duplicated blocks" ;;
  2) skip "the checkout has no duplicated blocks" "$(cat "$TMP/dup.out")" ;;
  *) bad  "the checkout has no duplicated blocks" "$(cat "$TMP/dup.out")" ;;
esac

# Without jscpd there is nothing to prove, and the skip above already says so.
if [ "$rc" -ne 2 ]; then
  # The fixture lives under a .claude path because that is where an agent's
  # worktree runs this suite from, and an ignore glob that floats rather than
  # anchoring at the root swallows the whole checkout there.
  DUP="$TMP/.claude/worktrees/wt"
  mkdir -p "$DUP/hooks/lib"
  cp "$ROOT/hooks/lib/tasks.py" "$DUP/hooks/lib/tasks.py"
  cp "$ROOT/hooks/taskline.py" "$DUP/hooks/taskline.py"
  awk '/^def load_tasks/,0' "$ROOT/hooks/lib/tasks.py" >> "$DUP/hooks/taskline.py"
  dup "$DUP"; verdict "a pasted function fails the suite" 1 "$?"
  cp "$ROOT/hooks/taskline.py" "$DUP/hooks/taskline.py"
  dup "$DUP"; verdict "removing it passes again" 0 "$?"

  # Shell is half of what ships here, and a clone this size is the floor the
  # thresholds claim: retuning them past it has to fail a test, not go unnoticed.
  for f in one two; do
    cat > "$DUP/hooks/$f.sh" <<'SH'
#!/usr/bin/env bash
prune_registry() {
  local reg="$1" pid
  for entry in "$reg"/*.json; do
    [ -f "$entry" ] || continue
    pid="$(basename "$entry" .json)"
    kill -0 "$pid" 2>/dev/null || rm -f "$entry"
  done
}
SH
  done
  dup "$DUP"; verdict "a pasted shell function fails it too" 1 "$?"
  rm -f "$DUP/hooks/one.sh" "$DUP/hooks/two.sh"

  # A worktree nested inside the checkout is a whole copy of it, and stays out.
  mkdir -p "$DUP/.claude/worktrees/inner/hooks/lib"
  cp "$ROOT/hooks/lib/tasks.py" "$DUP/.claude/worktrees/inner/hooks/lib/tasks.py"
  cp "$ROOT/hooks/taskline.py" "$DUP/.claude/worktrees/inner/hooks/taskline.py"
  dup "$DUP"; verdict "a nested worktree copy is ignored" 0 "$?"

  # jscpd exits 0 over a tree it never read — a bad path, an unknown format, an
  # ignore that swallowed everything. A gate that cannot say it looked is a
  # failure, not a pass.
  mkdir -p "$TMP/dup-empty"
  dup "$TMP/dup-empty"; verdict "a tree it did not read is not a pass" 3 "$?"
fi

# The skip itself: without jscpd and without npx the gate says so and asks for
# neither a pass nor a failure.
stub_path "$TMP/nonpx" bash env mktemp rm python3
PATH="$TMP/nonpx" "$ROOT/tests/duplication.sh" "$ROOT" > "$TMP/dup.out" 2>&1
verdict "no jscpd and no npx is a skip, not a verdict" 2 "$?"
check "the skip names the install" "npm i -g jscpd@" "$(cat "$TMP/dup.out")"

# ── result ───────────────────────────────────────────────────────────────────
echo
summary="$pass passed"
[ "$skipped" -eq 0 ] || summary="$summary, $skipped skipped"
if [ "$fail" -eq 0 ]; then
  echo "$summary"
else
  echo "$summary, $fail failed"
  exit 1
fi
