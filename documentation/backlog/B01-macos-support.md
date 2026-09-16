# B01: macOS support

**Status:** open
**Priority:** P3
**Target:** agent-toolkit-v2: `install.sh`, `hooks/sync.sh`, `tests/run.sh`, `tests/install.sh`
**Source:** install flow spec, 2026-09-14
**Owner:** user

The installer and hooks run on Linux only. On macOS:

- `hooks/sync.sh` resolves paths with `realpath -m`, a GNU option, and `install.sh` switches links and files with GNU `mv -T` and bounds `gh`, plugin fetches and the notifications CLI with `timeout`.
- `tests/run.sh` bounds two recorder runs with GNU `timeout`, and `tests/install.sh` reads file state with GNU `stat -c` and `find -printf`.
- The installer's package line covers `apt-get`, `dnf` and `pacman` only.

Done when the suite passes on macOS and install ends with no required finding there. Next action: the user decides whether macOS is wanted. If it is, replace the GNU-only options with portable equivalents and run the suite under the bash 3.2 macOS ships.
