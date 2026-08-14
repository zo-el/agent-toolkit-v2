# agent-toolkit

My working agreement with Claude Code, as a repo that travels between machines.

The session is the CTO: it plans, delegates, verifies, and talks to me. Agents do the work.

[`CLAUDE.md`](CLAUDE.md) is the whole agreement, and Claude Code loads it into **every custom subagent** as well as the session — only the built-in `Explore` and `Plan` skip it. So the developer is bound by the code style, the reviewer by the writing style, and every agent by the gates, without any of it being restated in their definitions. It splits into two parts for that reason: *Running the session* is the CTO's job alone, *Standards* binds everyone. Agent files carry only what is specific to that role.

## Install

```bash
./install.sh          # preview first with: ./install.sh --dry-run
```

The installer enables two plugins but cannot install them. Once per machine:

```bash
claude plugin install pr-review-toolkit@claude-plugins-official --scope user
```

Notifications come from [claude-notifications-go](https://github.com/777genius/claude-notifications-go) — install it from its README, then `/claude-notifications-go:settings`. It fires when the main agent finishes or needs you, and stays quiet for sub-agents.

The checkout can live anywhere. Device config reaches it only through the `~/.claude/agent-toolkit` symlink, so moving it is one `./install.sh` from the new location. On another machine, `git pull` is the whole upgrade — the next session start re-links everything.

## What's here

| | |
| ------------- | ---------------------------------------------------------------------- |
| `CLAUDE.md` | the agreement: the CTO loop, tasks, code and writing style, the gates |
| `agents/` | architect · developer · reviewer · project-manager · researcher |
| `skills/` | `backlog` · `toolkit` (change this repo) · `ui-review` (screenshot galleries) |
| `hooks/` | the guard, the statusline, the formatter, background process tracking |
| `install.sh` | wiring and the doctor |
| `RETRO.md` | learnings collected from sessions, reviewed on demand |
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

[`tests/run.sh`](tests/run.sh) is the regression suite for all of it.

## Statusline

[`hooks/statusline.py`](hooks/statusline.py) shows: model · effort · context bar · lines changed · rate limits · tasks · background processes · branch and PR · directory · toolkit version.

```
Opus 5 1M │ ⚡xhigh │ ▰▱▱▱▱▱▱▱ 18% 180k/1M │ +412/-96 │ ⏱ 63% 2h13m · 41% 3d2h │ ☰ 2/5 │ ⎇ main* #42 │ my-app │ ⬡ v10·12d438c
```

A segment with nothing to say takes no width, so the line stays short when little is happening. Lines changed and rate limits are the exception: neither has its data on the first renders, so they hold their slot with a dim `+0/-0` and `⏱ —` instead of letting the bar change shape mid-session. A session that never reports rate limits — an API key rather than a subscription — keeps `⏱ —` throughout.

- **`⏱ 63% 2h13m · 41% 3d2h`** — how much of each rate-limit window is used, and how long until it resets. The window's own length is deliberately not shown; a fixed `5h` label says nothing you can act on. Falls back to `5h` / `7d` labels only when the payload carries no reset time, since two bare percentages wouldn't say which is which.
- **`☰ 2/5`** — tasks done out of open, from this session's own list. The platform clears the whole list once every task completes, so this only ever shows live work.
- **`⎇ main* #42`** — branch, dirty marker, and the open PR for it, coloured by review state.
- **`⬡ v<count>·<sha>`** — the "are my changes applied?" light. A `⚠` means the repo has moved past the last install; a dim `?` means it couldn't be verified.
