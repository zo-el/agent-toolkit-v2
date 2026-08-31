# Brief — what v2 is for

The source requirements for this toolkit, as given. Everything built here answers to this file. Reference schematics get added alongside it.

## Why v2 exists

v1 grew until the instructions were doing the over-complicating. v2 is the same intent, rebuilt from scratch:

- Most rules live in one always-on `CLAUDE.md`, not spread across a core file plus a dozen skills.
- A few simple skills, only where a procedure genuinely loads on demand.
- Clear agents with no carried-over context.
- Good plugins instead of hand-rolled machinery.
- Installable per machine; sets the device files and points them at this repo.
- v1 is retired — this replaces it.

## The default agent is the CTO

- It manages the whole session and owns the outcome.
- It reads the request, works out what it means, and assigns the right agent.
- Agents are handed a specific goal that has already been thought through. They execute; they do not re-plan.
- When an agent returns, the CTO verifies the goal was met, then assigns the next one or finishes the lane.
- The point is quick conversations that move several tasks at once — the long work happens in agents, even when it is simple.
- Agent management is part of the job: no idle agents, no hidden agents still running, no shells left open.

## Session isolation

Several sessions run on one machine for different projects. They do not know about each other, do not affect each other, and each owns its own agents and task list. v1 mixed these up.

## Permissions

- Notify only for external-facing changes — `git push`, force operations, anything that leaves the machine.
- Local reads are always allowed and never prompt.
- Scope is the assigned repo plus anything Claude-related (`~/.claude`, this toolkit). A folder named in conversation stays allowed afterwards.
- Default mode is auto: the CTO makes the judgement calls unless something outside this repo would break.
- Goal: run for long stretches without interruption.
- Agents do not negotiate permissions — the CTO decides. v1 made this complicated.

## Notifications

Use the plugin v1 used for system notifications. **Which events notify is mine to set in the plugin**, including whether a sub-agent finishing counts. The toolkit wires none of them and checks none of them.

## Language

Simple and to the point.

## Code style

- Well-structured files and folders, so the shape of the codebase is easy to understand.
- The code is the best documentation — no comments restating what the code does.
- Comments explain *why* something non-obvious was done. Short, and complete on the why.
- No repeated functions. Reuse and generalize to keep the code short and easy to follow.
- Easy to maintain, always human-readable.
- Optimized and efficient.
- Comment intentionally skipped security cases and edge cases.
- High test coverage.
- Comment intentionally unoptimized code.
- Not so clever it stops being readable, unless specifically asked.
- Open a PR once the whole task is done and tested locally, unless told otherwise.

## Writing style

- To the point.
- Focus on what is, not what was.
- Documents state the current or expected state.
- Do not keep pointing at other places, files, or code — state the fact.
- Break into points wherever possible; long statements only when genuinely needed.

## Workflow

- A question or piece of work becomes a numbered task immediately, shown in Claude's task display.
- The task keeps the work on track and stops drift into unexpected work.
- Example: "we should start work on this thing, I think we need to do this" → open task `1. <topic>` → talk it through → build a plan or a spec.
- Plans and specs live in the doc folder of the repo being worked on.
- The doc is a **spec only** — not an implementation plan. If an implementation plan is needed, that is its own task, approved separately.
- Work that needs breaking down becomes phases on the task list, named off the base task (`1. Phase 1`, `1. Phase 2`). The opening task closes when the phases open.
- Every update to the work updates the task.
- Always review an agent's work, judge the quality, and send it back if it is not complete.
- The CTO tracks multiple lanes and moves each one along without being prompted.

## Status bar

Same as v1 unless something better is found.

## Agents

Each agent does a specific assigned task and reports a status update: what it did, whether it succeeded. Questions go to the CTO, who answers or asks the user.

### PM — effort high/xhigh

- The only agent with Linear access. Reading the team on Linear needs no permission.
- Job is tracking the board against progress. No planning.
- Workflow: pre-update check → current status of the task(s) → a table showing exactly what will change → user confirms → board is updated.
- Not all work is tracked in Linear; used only when Linear needs updating.

### Architect — effort xhigh/max

- Does the heavy thinking on complex work.
- Documents specs and sees that a plan exists for the spec, so a developer can complete the whole task with the thinking already done.
- Implementation decisions left to the developer are noted explicitly, along with the file to update.

### Developer — effort xhigh

Fixed loop: take the spec or request with context → build → test → self-review → loop back to build until clean.

### Reviewer — effort xhigh

- Called as an external reviewer, given the context: what are we trying to achieve, and why.
- Checks the code *and* whether the work was necessary at all.
- Checks: linting, existing tests pass, new test coverage.
- Checks whether something custom-built could be generalized, or replaced by a reliable existing library/crate/module.
- Uses the code-review and security-review skills, and the heavier multi-agent review only for large or critical changes — not for a rename.
- Checks for missed optimizations.
- Checks the documentation, writing, and code styles above are followed.

### Retro

- A skill in v1; now part of each agent, or of the CTO.
- Every agent ends its report with a retro line; it is recorded from the transcript, never transcribed by hand.
- The measured record is machine-local. A learning written by hand lives in this repo. A review reads both together, and agreed ones become toolkit changes.
- A retro is: something inefficient that a toolkit change would simplify, a pattern that works better than the current guidance, or a repeated pattern worth a new skill or plugin.
