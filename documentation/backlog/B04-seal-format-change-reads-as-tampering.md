# B04: a seal in a format the updater no longer produces reads as tampering

**Status:** open
**Priority:** P2
**Target:** agent-toolkit-v2: hooks/lib/seal.py, hooks/update.sh, tests/update.sh
**Source:** the release-flow lane, 2026-09-18, a developer note at f5c7fe1
**Owner:** developer

`seal_holds` in `hooks/update.sh` compares the recorded seal to a fresh digest as two strings, and any difference is treated as the tree having been altered: the folder is set aside and a required finding says it was tampered with. A change to `hooks/lib/seal.py`'s record layout or algorithm would therefore, on the day it shipped, quarantine every folder staged by the previous version on every machine, with a finding that accuses the machine of something that did not happen.

`documentation/specs/release.md`, Sealing, now says a recorded seal the updater cannot read is no seal: the folder is discarded, said as an advisory, and staged afresh. The code does not yet draw that line, so spec and code differ until this lands. It bites only when the format moves, which is a future decision, so it is not critical now.

The guard: `seal.py` stamps its output with a format marker, the algorithm name or a version, and `seal_holds` treats a recorded seal that does not carry the current marker as absent rather than as a mismatch. A seal that carries the marker and still differs is the alteration case, unchanged.

Done when a test in `tests/update.sh` stages a release under one marker and applies it under another, and proves the folder was discarded with an advisory, not set aside, and no required finding was raised.
