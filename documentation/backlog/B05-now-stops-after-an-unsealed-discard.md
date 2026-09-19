# B05: now stops after discarding an unsealed folder instead of fetching it again

**Status:** open
**Priority:** P3
**Target:** agent-toolkit-v2: hooks/update.sh, tests/update.sh
**Source:** the release-flow lane, 2026-09-18, a test review of unit G
**Owner:** developer

`hooks/update.sh now` with the track pinned to a release whose folder is still on disk but unsealed, the fallback an earlier activation left, reaches that folder through `judge_release` as already unpacked. `seal_holds` discards it and says so, and `now` then ends with `v<version> was not installed: this machine cannot vouch for the tree it had staged` and exit 1. A second `now` downloads it afresh and installs it.

Nothing is lost and nothing is misreported: the advisory names the discard, and the next `now` or the next due check stages it again. It costs the user a second command, where `now` is meant to be the whole cycle at once.

The fix: when `seal_holds` discards for want of a seal rather than setting a tree aside as altered, `now` stages that release again in the same run, under the locks it already holds, and continues to the install. The altered case keeps stopping.

Done when the case in `tests/update.sh` under rolling back, pinning the fallback and running `now`, exits 0 on the first `now` with the machine on the pinned release and the discard advisory still printed.
