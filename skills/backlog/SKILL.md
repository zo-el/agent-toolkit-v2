---
name: backlog
description: The project's queue of known-but-unscheduled work, one file per item under documentation/backlog/. Use when a follow-up or a "we should do X later" surfaces mid-session, when the user asks what's on the backlog or what's next, when work is being deferred rather than done, or when a sweep is due.
---

# Backlog

Work we know about and are not doing yet. It must never just grow — every item ends up resolved, deleted, or promoted into real work.

## Structure

- One file per item: `documentation/backlog/B<NN>-<short-slug>.md`. The directory is the catalog — `ls` is the list.
- Resolved or no-longer-relevant items are **deleted**. Git history is the archive; there is no done section.
- Items never reference each other. Items get deleted independently, so a pointer to another one becomes a dangling reference. State shared context in the item's own words.
- IDs are append-only. The next one is a single line in `documentation/backlog/README.md`, bumped in the same change that adds an item.

## Item shape

```markdown
# B<NN> — <one-line title>

**Status:** open | in progress | blocked on user
**Priority:** P0 | P1 | P2 | P3
**Target:** <repo and paths>
**Source:** <where it surfaced, dated>
**Owner:** agent | user

<What and why, ending with the concrete next action — the "done when".>
```

Priority at creation: **P0** blocks a release or correctness · **P1** real recurring friction · **P2** nice to have · **P3** latent, and may legitimately close as won't-fix.

## Filing

- Fixable in under ~15 minutes right now? Fix it. File nothing.
- Already covered by a spec, an open task, or a Linear issue? Fold it in there instead. The backlog is for work nothing else tracks.
- Part of what we're actively building? Decide it inside that work — fold it into the current scope or drop it explicitly. Deferring active work into the backlog is how a queue quietly grows every round.
- Surfaced by a deploy or a live issue? That belongs to the work that surfaced it, not here.
- Cap: 20 open items. Adding past the cap means running a sweep first.

## The sweep

Run at the end of a piece of work, on request, or when the cap is hit. One item at a time, verified against the current code rather than memory. Execute the clear-cut ones; anything needing a product or scope call goes to the user with a recommendation.

| The item is… | Do |
| ---------------------------- | ------------------------------------------------ |
| already done | delete it |
| superseded | delete it, with the reason |
| now owned by planned work | fold it into that work, then delete it |
| a clear fix you can make now | fix it, then delete it |
| still valid, can't act yet | refresh stale details, re-check priority, keep it |

Two standing rules: an item that has bitten three times moves up a priority level, and no P0 leaves a sweep unscheduled — it becomes work now, becomes a task, or is demoted with a written reason.

Report each sweep: deleted, folded in, fixed, re-prioritised, and the open count against the cap.
