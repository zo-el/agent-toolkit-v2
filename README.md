# agent-toolkit

My working agreement with Claude Code, as a repo that travels between machines.

The session is the CTO: it plans, delegates, verifies, and talks to me. Agents do the work.

[`CLAUDE.md`](CLAUDE.md) is the whole agreement, and Claude Code loads it into **every custom subagent** as well as the session — only the built-in `Explore` and `Plan` skip it. So the developer is bound by the code style, the reviewer by the writing style, and every agent by the gates, without any of it being restated in their definitions. It splits into two parts for that reason: *Running the session* is the CTO's job alone, *Standards* binds everyone. Agent files carry only what is specific to that role.

## Install

Follow [`INSTALL.md`](INSTALL.md).

## What's here

| | |
| ------------- | ---------------------------------------------------------------------- |
| `CLAUDE.md` | the agreement: the CTO loop, tasks, code and writing style, the gates |
| `agents/` | architect · developer · reviewer · project-manager · researcher |
| `skills/` | `backlog` · `toolkit` (change this repo) · `ui-review` (screenshot galleries) |
| `hooks/` | the guard, the statusline, the task line, the retro recorder, the formatter |
| `INSTALL.md` | how to install, and what install touches |
| `install.sh` | the installer, and the doctor that runs at every session start |
| `RETRO.md` | learnings written by hand, read alongside the retro digest |
| `documentation/brief.md` | what this toolkit is for |

## The agents

Each runs in its own context with a tool allowlist as its outer boundary and its definition as the role it keeps inside it.

| Agent | Effort | Cannot |
| ----------------- | ------ | ------------------------------ |
| `architect` | max | write application source |
| `developer` | xhigh | push, or touch Linear |
| `reviewer` | xhigh | write anything |
| `project-manager` | high | write anything but Linear |
| `researcher` | high | write anything |

Linear tools live only in `project-manager`. Only `developer` can edit source. Subagents nest one level deep, which is what lets the developer and reviewer run their review agents. Every agent carries `SendMessage`, so it can reach the session mid-run when it is genuinely blocked instead of finishing a long task on a wrong assumption.

## Session isolation

Sessions on this machine work on different projects and must not reach into each other. Cross-session messaging is on by default in Claude Code, so `install.sh` closes it: `crossSessionInbound: "refuse"` drops messages arriving from your other sessions, and `isolatePeerMachines: true` requires approval before any message leaves the machine. Both are scoped to the peer socket, so an agent inside a session still messages `main` normally. Agent teams stay off — they spawn whole parallel sessions as teammates, which is a different model from one session delegating to subagents.

## Enforcement

[`hooks/guard.sh`](hooks/guard.sh) is the only gate, and it fires regardless of permission mode, inside subagents too:

- **denies** posting publicly as the user — PR and issue comments, review submissions.
- **asks** before anything leaves the machine (push, PR, release, package publish), before Linear writes, before touching the device outside the workspace, and before the few git commands the reflog cannot undo.

Everything else is silent. `permissions.defaultMode` is `auto` and `~/.claude`, the scratchpad, and this checkout are approved working directories, so an agent runs unattended instead of stalling on a prompt nobody is watching. `Read` is denied on the credentials and settings files, which carry API tokens.

[`tests/run.sh`](tests/run.sh) is the regression suite for all of it. It ends in [`tests/duplication.sh`](tests/duplication.sh), which fails the suite on copy-pasted shell or python and skips itself where `jscpd` cannot be reached.

## Task line

[`hooks/taskline.py`](hooks/taskline.py) puts the session's own task list into context on every turn, so the rule to open a task before acting cannot quietly decay:

```
Tasks: 2 open · Retro — spec (in_progress, arch-retro) · Retro — build (blocked)
```

- **`(blocked)`** — pending, with a blocker that has not finished. The platform stores no such status; it is read off `blockedBy`.
- **Four tasks named**, in-progress first, then `+N more` for the rest. The count covers every open task, named or not.
- **Nothing open** prints `Tasks: none open — open a lane before acting`, and names the task tools, which are deferred: a session that never searched for their schemas cannot call them and has nothing to show that it failed. Once tasks exist the tools are demonstrably loaded and the hint drops.
- **A list read only in part** — a file being written as it is read, or one that will not open — says `(partial list)` after the count. A list that cannot be read at all prints nothing: "none open" would be a guess, and it is a guess that tells the model to open a lane that already exists.

Two separate things stand between a session and its task list, and `install.sh` settles both: `CLAUDE_CODE_ENABLE_TODO_TOOLS` opts out of the removal of the tools for this generation of models, and the hint above covers the deferral that keeps their schemas unloaded until something asks. The hook itself never blocks a turn and exits 0 on every path, including its own failure.

## Retro

[`hooks/retro.py`](hooks/retro.py) records what the toolkit is actually costing, so a retro runs off data instead of recall. It digests Claude Code's own transcripts into `~/.claude/retro/retro.db` — machine-local, never in this repo — and `hooks/retro.py review` prints the digest the `toolkit` skill judges.

The unit is the **compaction segment**, not the session: sessions here run for weeks across dozens of compactions, and a per-session row would average all of it into one number. A segment is reviewable once it is closed, and each one is reviewed exactly once.

It answers toolkit questions, not cost questions — every agent's `Retro:` line is harvested straight from its transcript, so the answer exists whether or not anyone remembered to write it down.

- **Counts and shapes only.** Never prompt text, file contents, command arguments, an agent's brief or its report. Two exceptions are deliberate: the normalised command verb (`git push`, `npm install`, and a driver's subcommand), because a recurring permission prompt cannot be recognised without it, and the agent's own `Retro:` line.
- **No backfill.** A `since` marker is stamped at install and everything written before it is invisible, permanently.
- **Four triggers, all async** — session start, compaction, session end, and a prompt at most every 15 minutes. None is load-bearing; whichever fires first catches up what the others missed, which is what keeps it off cron and out of a daemon.
- Every path degrades to silence and exits 0, and it writes nothing to stdout. Silence is therefore not evidence that it works, so the session-start doctor checks the marker and the store instead.

## Statusline

[`hooks/statusline.py`](hooks/statusline.py) shows: model · effort · context bar · lines changed · rate limits · tasks · branch and PR · directory · toolkit version.

```
Opus 5 1M │ ⚡xhigh │ ▰▱▱▱▱▱▱▱ 18% 180k/1M │ +412/-96 │ ⏱ 63% 2h13m · 41% 3d2h │ ☰ 2/5 │ ⎇ main* #42 │ my-app │ ⬡ v10·12d438c
```

A segment with nothing to say takes no width, so the line stays short when little is happening. Lines changed and rate limits are the exception — they hold their slot with a dim `+0/-0` and `⏱ —` so the bar doesn't change shape mid-session. An API-key session never reports rate limits, so it keeps `⏱ —` throughout.

- **`⏱ 63% 2h13m · 41% 3d2h`** — how much of each rate-limit window is used, and how long until it resets. The window's own length is deliberately not shown; a fixed `5h` label says nothing you can act on. Falls back to `5h` / `7d` labels only when the payload carries no reset time, since two bare percentages wouldn't say which is which.
- **`☰ 2/5`** — tasks done out of open, from this session's own list. The platform clears the whole list once every task completes, so this only ever shows live work. A `?` means part of the list would not read, and the count is of what did; green is kept for a whole list with nothing left open.
- **`⎇ main* #42`** — branch, dirty marker, and the open PR for it, coloured by review state.
- **`⬡ v<count>·<sha>`**: the "are my changes applied?" light. A `⚠` means the installed version directory is not at the version last applied; a dim `?` means that could not be verified.
