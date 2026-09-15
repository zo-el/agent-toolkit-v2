# B01: macOS support

**Status:** open
**Priority:** P3
**Target:** agent-toolkit-v2: `install.sh`, `hooks/bg.sh`, `hooks/reap.sh`, `hooks/sync.sh`, `hooks/statusline.py`, `tests/run.sh`
**Source:** install flow spec, 2026-09-14
**Owner:** user

The installer and hooks run on Linux only. On macOS:

- `hooks/bg.sh` starts background processes with `setsid`, which macOS does not ship.
- `hooks/bg.sh` and `hooks/reap.sh` read a process's start time and parent from `/proc`, and the background process segment of `hooks/statusline.py` reads `/proc` too. macOS has no `/proc`.
- `hooks/sync.sh` resolves paths with `realpath -m`, a GNU option.
- `tests/run.sh` bounds two recorder runs with GNU `timeout`.
- The installer's package line covers `apt-get`, `dnf` and `pacman` only.

Done when the suite passes on macOS and install ends with no required finding there. Next action: the user decides whether macOS is wanted. If it is, replace the `/proc` reads and `setsid` with portable equivalents, cover process identity without `/proc` with a test, and run the suite under the bash 3.2 macOS ships.
