# B06: a refused worktree is told to mv when git cannot name its checkout

**Status:** open
**Priority:** P3
**Target:** agent-toolkit-v2: install.sh, tests/install.sh
**Source:** the release-flow lane, 2026-09-18, a silent-failure review of unit F
**Owner:** developer

`check_location` refuses a version directory under `~/.claude/worktrees`, and `names_a_checkout` names the checkout a linked worktree belongs to so the fix is `cd <checkout> && ./install.sh`. When git cannot answer (it timed out, `timeout` is missing, or it refuses the repository for dubious ownership), the finding falls back to `mv -T <root> <a directory of your own>`.

The refusal holds in every one of those cases, so nothing installs from the wrong place. The advice is what is wrong: moving a registered linked worktree with `mv` leaves the main repository's `.git/worktrees/<name>/gitdir` pointing at the old path, and a later `git worktree prune` deletes that metadata.

The fix: when `$ROOT/.git` is a file, the fallback says git could not name the checkout and offers `git worktree move` rather than `mv -T`.

Done when a case in `tests/install.sh` with a linked worktree and git unable to answer asserts that fix line and no `mv -T`.
