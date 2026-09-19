# B03: the stable link can be repointed by a plain command nothing gates

**Status:** open
**Priority:** P2
**Target:** agent-toolkit-v2: hooks/guard.sh, tests/run.sh
**Source:** the release-flow lane, 2026-09-18, a developer note at f5c7fe1
**Owner:** developer

`~/.claude/agent-toolkit` is a symlink, and `ln -sfn <any directory> ~/.claude/agent-toolkit` from Bash runs unprompted under `defaultMode: auto`, as do `mv` and `rm` of it and of `~/.claude/agent-toolkit-run`. The launcher resolves the link at call time, so the next hook runs from wherever it now points, with no install, no root checks and no seal. `--sync` from that root then applies its state, because the link does point at it.

Not critical to the release flow: the path predates the lane, and the lane closed a silent Write path into a tree that later runs, while this needs a deliberate command naming a specific link. `hooks/guard.sh` is a deny-list against accident and drift, not a defence against a shell with intent, and it never claimed otherwise.

The cheap answer is the shape the guard already uses for `gh release`: ask before `ln`, `mv`, `rm` or `cp` whose arguments name `~/.claude/agent-toolkit` or `~/.claude/agent-toolkit-run`, in any spelling of the home. Reads stay free: `readlink`, `ls -l`, `test -L`.

Done when the guard cases in `tests/run.sh` prove each of those asks, each read stays silent, and a full install still moves the link, since install runs as a process and not through the gate.
