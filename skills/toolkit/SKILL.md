---
name: toolkit
description: Change the agent toolkit itself, and run a retro. Use when the user says "add this to the toolkit", "remember this globally", "make this a rule everywhere", when editing anything in the agent-toolkit repo (CLAUDE.md, agents/, skills/, hooks/, install.sh), when running a retro or asking what the toolkit should learn, or when the session-start doctor reports the toolkit broken.
---

# Toolkit

The toolkit is the instruction set every future session on every machine runs on. Change it with the same discipline as production code.

Find the checkout with `readlink ~/.claude/agent-toolkit`.

## Where a change goes

| The change is… | It goes in… |
| ------------------------------------------------- | ------------------------ |
| a rule that is true for every task | `CLAUDE.md` — one line |
| one agent's role, loop, or boundary | `agents/<name>.md` |
| a procedure that should load only when relevant | a new `skills/<name>/SKILL.md` |
| something that must hold even if the model forgets | `hooks/` + a case in `tests/run.sh` |
| what `settings.json` points at | `install.sh` only |

One home. Never state the same rule in two places.

`CLAUDE.md` loads in every session and every agent, so it stays short. If a rule needs a paragraph to explain itself, it is a skill.

## Running a retro

`hooks/retro.py review` prints a digest of every compaction segment closed since the last accepted retro. It reads a machine-local store, writes nothing, and `--all` digests everything ever recorded. The recorder behind it rides hooks and never needs running by hand.

An empty digest ends the review. A retro with no data is not a brainstorm.

1. Run the digest. Read `RETRO.md` alongside it for the hand-written lines it cannot know about.
2. Group what the digest shows into candidate toolkit changes. Several rows that are the same underlying problem are one candidate.
3. Rank by projects first, then recurrence — the same slip across several projects is a toolkit problem, the same slip in one repo is usually a quirk of that repo.
4. For each candidate, decide: is this a rule we don't have, or a rule we have that didn't fire? A rule that didn't fire needs sharper wording, not a second rule beside it.
5. Present the candidates to the user as a checklist. Only ticked ones land.
6. Then, and only then, `hooks/retro.py review --accept <seq>` with the sequence the digest named, so the same segments do not come back. Delete the `RETRO.md` lines you acted on.

An `incomplete:` line in the window means the recorder could not read something, so a figure below it is short by an unknown amount. Say so when you rank, rather than reading it as a low number.

## Verifying a change

- **Skill added or renamed** — `ls -l ~/.claude/skills/<name>` shows the symlink. The session-start and on-edit hooks sync it automatically.
- **Agent added or renamed** — agents are copied, not linked. Run `./install.sh`, then `ls ~/.claude/agents/`.
- **Hook changed** — add the case to `tests/run.sh` and run the suite. All green before committing.
- **Wiring changed**: add the command's case to the launcher loop in `tests/install.sh`, which fails on any wired command it does not check. `./install.sh --dry-run` shows the exact device-config diff. Then `./install.sh`.
- **Anything renamed** — grep the whole repo for the old name. README and `CLAUDE.md` are the usual stragglers.

## Probing a guard by hand

Guards read their payload from stdin. Write it to a file and redirect — `hooks/guard.sh < payload.json`. Piping the payload inline puts the dangerous-looking text on the command line, where the guard flags it as data it can't distinguish from a real invocation.

## Landing it

Commit in the toolkit repo. Then ask the user to approve the push — other machines only get the change once it's on origin.

On another machine, `git pull` brings the change in, and the next session start applies it and says when to restart. A new machine follows `INSTALL.md`.
