# Retro

A retro runs off recorded fact, not recall.

`hooks/retro.py` is two things behind one file: a **recorder** that hooks fire, which digests Claude Code's own transcripts into a machine-local store; and a **review** that reads the store, aggregates it, and hands the `toolkit` skill a digest to judge. Nothing depends on an agent noticing an inefficiency, remembering a convention, or transcribing a line. One file rather than two, because the review has to know the schema and a second file could only get it by duplicating it.

## Scope

The recorder answers toolkit questions, not cost questions. Every field earns its place by answering one:

| Question | What answers it |
| ------------------------------------------------------- | ----------------------------------------------------- |
| Is the session doing the work instead of delegating it? | the same tool counts split by the `agent` column |
| Is a lane going round more times than it should? | agent stops per type per segment, and their statuses |
| Is an agent spawning agents, and how deep? | `spawn_depth` from the agent meta file |
| Which permission prompt keeps firing? | denial kind × command verb, by recurrence and project |
| Which skill never fires, and which fires constantly? | skill attributions against the installed skill list |
| Is a hook slow or erroring? | hook fires, errors, durations |
| Are we burning context on the wrong things? | compaction pressure: tokens dropped, how often, how long |
| What did an agent itself say was inefficient? | the `Retro:` line from its return, harvested automatically |

## Boundaries

- **The store is machine-local and never enters the repo.** It lives under `~/.claude/retro/`. What travels between machines is what someone wrote down: the toolkit change a review produces, and the `RETRO.md` line behind it.
- **Raw facts only.** Counts, names, ids, durations, token totals, denial kinds, compaction metadata. No derived metric — no ratios, no scores, no thresholds. Interpretation happens at review time, where changing your mind costs nothing.
- **Counts and shapes only.** Never prompt text, never file contents, never command arguments, never an agent's brief or its report. Two deliberate exceptions, both narrow, both named below: the normalised command **verb**, and the agent's own `Retro:` line.
- **No backfill.** A `since` marker is stamped at install. Everything written before it is invisible, permanently.

## Why record broadly

`cleanupPeriodDays` defaults to 30 and its minimum is 1, so Claude Code deletes raw transcripts after 30 days. Past that point the store is the only surviving record. A field not captured inside the window is lost for good, which is why the schema is wide and dumb rather than narrow and clever.

## The unit is the compaction segment

A session is not a useful bucket. Sessions here run for weeks — one verified transcript spans 2026-07-03 to 2026-08-13 across 32 compactions, 62,328 lines, 29.4M cumulative dropped tokens, all under one session id in one file. A per-session row would average six weeks of unrelated work into one number.

A **segment** is the span of a transcript between two `compact_boundary` records. Segment 0 runs from the first record to the first boundary; segment *n* from boundary *n* to boundary *n+1*; the last segment is open until the transcript falls idle.

- **Identity:** `<session_id>#<ordinal>`, ordinal counting boundaries seen so far in that file. Deterministic, so re-deriving a segment produces the same key rather than a duplicate.
- **A closed segment is immutable.** Once closed it is never recomputed, so a rewound or replaced transcript can never corrupt reviewed history.
- **Closing:** `compact` when a boundary follows it; `idle` when its transcript has not been modified for 24 hours; `gone` when the transcript no longer exists.
- Only closed segments are reviewable. An open segment accumulates but stays out of every digest, which is what makes each segment reviewed exactly once with no double counting.

## Ground truth

These are verified against Claude Code 2.1.232 and the live transcript store. The design rests on them.

- **Compaction does not truncate the transcript.** History is append-only and survives compaction. `PreCompact` is a convenient trigger, not a rescue.
- **`/clear` rotates the file.** It ends the current transcript and opens a new one under a new session id; the new file records the `/clear` at its head. Verified: `46428ba4….jsonl` ends `2026-07-22T15:49:34.981Z`, `39f13024….jsonl` begins `2026-07-22T15:49:38.855Z` with `/clear` on line 4.
- **Resume appends.** A resumed session keeps its file and its session id — the six-week transcript above carries CLI versions 2.1.199 through 2.1.227 in one file. `fork` is a `SessionStart` source and produces a new file, so it needs no special handling.
- **One file, one session id.** Verified across the store.
- **Subagent work is not in the parent transcript.** No `isSidechain: true` records appear in a session transcript under 2.1.232 — only in `agent-*.jsonl`. Every main-chain `tool_use` is the session's own work.
- **An async `Agent` result carries no figures.** `toolUseResult` is `{isAsync: true, status: "async_launched", agentId, description, resolvedModel, prompt, outputFile, canReadOutputFile}` — no `agentType`, no `toolStats`, no tokens, no duration. A synchronous result carries the full set (`agentType`, `totalDurationMs`, `totalTokens`, `totalToolUseCount`, `usage`, `toolStats`, `content`). Async is this toolkit's normal mode; the harness chose it for all three agents of the session that produced this spec. Verified: `4c536ea7….jsonl` against `94aba47b….jsonl`.
- **Every agent writes its own transcript, sync or async, at any depth.** `<project>/<session>/subagents/agent-<agentId>.jsonl` alongside `agent-<agentId>.meta.json`. The meta file carries `agentType`, `description`, `toolUseId`, `spawnDepth`, `model`, and `parentAgentId` when the agent was spawned by another agent. 776 transcripts and 776 meta files exist here, against 76 session transcripts.
- **Nesting exists, and every stop notification reaches the root session transcript whatever the depth.** A `pr-review-toolkit:code-reviewer` at `spawnDepth: 2`, spawned by a `developer`, appears nowhere in the session's own records except as a stop notification — and that notification is in the session transcript, not in the developer's. Two record shapes carry the identical payload: a `queue-operation` record (`operation` of `enqueue`, `dequeue` or `remove`) with the notification in `content`, and a `user` record with `origin.kind == "task-notification"` carrying it in `message.content`. The same notification appears two or three times, and a queued one can be `remove`d without ever becoming a user turn.
- **The notification is XML** with `<task-id>`, `<tool-use-id>`, `<status>`, `<summary>`, `<result>` — the agent's whole final report — and a `<note>` stating that *the same task-id may notify more than once*: an agent that is resumed stops and notifies again.
- **A third tier exists:** `<session>/subagents/workflows/wf_*/`, written by the Workflow tool. Nothing here opens it.
- **A real user turn is `origin.kind == "human"`** on a `user` record. The other kinds observed are `task-notification`, `auto-continuation`, `peer`, `coordinator`.
- **Observed `toolDenialKind` values:** `user-rejected`, `permission-rule`, `automode-unavailable`, `automode-blocked`, `interrupted`. The set is not closed; store whatever string appears.
- **Hook stdout is context on some events.** `UserPromptSubmit` and `SessionStart` inject plain-text stdout into the conversation. The recorder therefore writes nothing to stdout, ever.
- **`SessionEnd` hooks share a 1.5 s budget.** A synchronous sweep there would be cut off.

## Delegation

Delegation is the one figure the whole mechanism exists to produce, and the session transcript alone cannot produce it: an async result names the agent and nothing else. The figures come from the agent's own transcript, opened on demand.

**A stop is the fence.** While consuming a session transcript, two things fence an agent:

- a `<task-notification>`, from either record shape, giving a `<task-id>` and a `<status>`;
- a synchronous `Agent` result, giving `agentId` and `status` — the agent has finished by the time it lands.

Either is an agent fence when `<session>/subagents/agent-<agentId>.meta.json` exists. Otherwise the notification belongs to a background command and is ignored.

**A fence opens exactly one file, by name.** `agent-<agentId>.jsonl` is read from its own cursor to end of file, under the same cursor rules as any other transcript. It is never globbed, so the 776 subagent transcripts and the workflow tier are never walked, and an agent still running is never opened — nothing points at it until it stops.

**The cursor is the deduplicator.** The same notification arrives two or three times; a resumed agent stops and notifies again, hours later. Both cases resolve the same way and need no threshold:

- New bytes since the cursor → fold that span in, and count one stop with the fence's status.
- No new bytes → a repeat delivery. Nothing is added and no stop is counted.

An agent that is resumed produces new bytes before its next fence, so it counts again — which is the honest answer, since a lane that went round twice did go round twice.

**Attribution needs no chaining.** Every fence lands in the root session transcript regardless of depth, so a subagent's work belongs to the segment that was open when its fence was consumed. `spawnDepth` is recorded because "is nesting happening, and how deep" is a toolkit question — not because attribution needs it.

**Sync and async are treated identically.** A synchronous result's `toolStats` and token figures are deliberately ignored in favour of the transcript, so there is one code path and one shape of data. The transcript also gives per-tool counts, bash verbs, denials and skills, where `toolStats` gives seven buckets.

**The extraction is the same function.** A subagent transcript yields tool counts, bash verbs, denials, skill and MCP attributions, tool errors, token sums, timestamps and the `Retro:` line exactly as a session transcript does. Only the attribution target differs, which is what the `agent` key column on the detail tables carries. The segment's own scalars and its hook records are the session chain's alone — neither has an `agent` column to hold an agent's copy.

## Store

`~/.claude/retro/`

| File | What it is |
| ---------------- | --------------------------------------------------------------------------- |
| `retro.db` | SQLite, the whole record. `PRAGMA user_version` carries the schema version |
| `since` | one ISO-8601 UTC line. Nothing earlier is ever recorded |
| `last-sweep` | its mtime is the last sweep; the interval gate reads it |
| `sweep.lock` | held for the duration of a sweep |

SQLite because a sweep must **update rather than duplicate**, and two sessions may sweep at once: an upsert keyed on the segment id gives the first, the database's own locking gives the second. It is stdlib (`sqlite3`), so it adds no runtime dependency. Journal mode WAL, `busy_timeout` 5000 ms.

**No pruning.** The store is the durable record precisely because transcripts are not. A few megabytes a year is the price of still being able to answer a question about last spring.

### `meta`

`key TEXT PRIMARY KEY, value TEXT` — integers as text, each starting at `0`: `reviewed_through`, `close_counter`, and the two all-time counters `transcripts_failed` and `segments_dropped` that say why a figure is short.

### `cursor` — one row per transcript ever seen, session or agent

| Column | Meaning |
| ----------- | ---------------------------------------------------------------------- |
| `path` PK | absolute transcript path |
| `agent_id` | NULL for a session transcript; the agent id for a subagent one |
| `inode` | `st_ino` at the last read |
| `head_len` | how many bytes of the head were hashed (`min(4096, size)` at first sight) |
| `head_sha` | sha256 of exactly those bytes |
| `offset` | bytes consumed; always sits on a newline |
| `base_offset`| a session cursor's open segment start — the offset a rebuild re-reads from. NULL on an agent cursor |
| `ordinal` | boundaries seen so far in this file; NULL on an agent cursor |
| `segment_id`| a session cursor's open segment, or the segment that last fenced an agent |
| `last_ts` | the newest record timestamp consumed |
| `last_message`, `last_skill` | the message whose usage is already summed, and the skill run still open. One response is written as one record per content block and a sweep stops at the last complete line, so it can land between two of them; without these the second half is summed again and a skill still running is counted as activated twice. Carried across a resume only — a rebuild re-reads the whole span and must sum it again, and a boundary ends both with the segment |

An agent cursor is never walked by the sweep and never idle-closed. It exists so that a re-fence knows where the last read stopped, which is what makes a repeat notification cost nothing. It is dropped once its transcript is gone: nothing else would ever remove it, and there are ten agent transcripts here for every session one.

### `segment` — one row per compaction segment

| Column | Meaning |
| --------------------------------------------------- | ----------------------------------------------------- |
| `id` PK | `<session_id>#<ordinal>` |
| `session_id`, `project`, `repo`, `ordinal` | `project` is the `~/.claude/projects` child directory; `repo` is the basename of the first record's `cwd` |
| `started_at`, `ended_at` | first and newest record timestamp in the segment |
| `cli_version`, `branch` | last `version` and `gitBranch` seen |
| `closed_seq` | NULL while open; a monotonic integer from `close_counter` on close |
| `close_trigger` | `compact` · `idle` · `gone` |
| `compact_trigger`, `pre_tokens`, `post_tokens`, `dropped_tokens`, `compact_ms` | from the boundary that closed it; NULL otherwise. `dropped_tokens` is the boundary's own running total for the whole transcript, not this segment's share |
| `user_turns` | `user` records with `origin.kind == "human"` |
| `wake_turns` | `user` records with any other `origin.kind` |
| `assistant_turns` | `assistant` records |
| `turn_ms_total`, `turn_ms_max` | from `turn_duration` records |
| `tokens_in`, `tokens_out`, `cache_read`, `cache_create` | summed `message.usage` over main-chain assistant records |
| `tool_errors` | `tool_result` blocks flagged `is_error` |
| `malformed_lines` | lines that would not parse |
| `agent_fences_lost` | fences whose agent transcript was missing |

### Child tables

Each keyed on `segment_id` plus its own key columns, each carrying `n` — except `retro_line`, which is one row per line and carries no count.

| Table | Key columns | Also carries |
| ------------ | ----------------------------------------- | ---------------------------------------------------------- |
| `tool_use` | `agent`, `tool` | `errors` |
| `bash_verb` | `agent`, `verb` | `errors` |
| `denial` | `agent`, `kind`, `signature` | — |
| `skill_use` | `agent`, `skill` | — |
| `mcp_use` | `agent`, `server` | — |
| `agent_run` | `agent_type`, `status`, `spawn_depth` | `agents`, `tokens_in`, `tokens_out`, `cache_read`, `cache_create`, `tool_uses`, `ms_total`, `ms_max` |
| `hook_run` | `hook` | `errors`, `ms_total`, `ms_max` |
| `retro_line` | `source_uuid` PK | `author`, `text`, `at` |

**`agent`.** The empty string for the session's own main chain, otherwise the `agentType` from the agent's meta file, or `unknown` when there is none. One column is what separates "the CTO did this itself" from "an agent did it", at any depth, without a second set of tables.

**`agent_run.n`** counts fenced stops, not agents; `agents` counts distinct agent ids. A resumed agent contributes two stops and one agent — the gap between the two numbers is the lane going round again.

**Verb normalisation.** The Bash command is lexed with quoting respected and split on the shell's own separators, capped at five parts. A heredoc operator ends the read — what follows is a file being written, not a command line — and a newline is not a separator, so only the first command of a multi-line script is recorded. Each part drops leading `VAR=value` assignments and shell keywords; its first token is basenamed. A **driver** keeps the word after it when that word is one of the subcommands named for it, giving `git push`, `npm install`, `cargo test`. Anything not matching `^[A-Za-z0-9._+-]{1,32}$`, or whose quoting cannot be followed, becomes `other`. This is the deliberate exception to "no command arguments": a permission prompt cannot be recognised as recurring without knowing which command it was, and `git push` is a different question from `git log`.

**A driver's subcommands are written out, one list per driver, and nothing else is ever a second word.** A rule that keeps whatever appears there stores the name whoever typed it chose: `python3 migrate_prod_secrets.py` is a filename, `make deploy-acme` is a target, `git -C <repo>` is a flag's value. The only second word that can never be one of those is a word the recorder already contains, so `make`, `python`, `python3` and `node` are not drivers at all and an unrecognised subcommand falls back to the bare driver. A missing subcommand costs the pair, which is a figure that reads low rather than one that leaks. The lists live in `hooks/retro.py`; adding to one is a decision, not a fix.

**Error attribution.** A `tool_use` is matched to its result through an in-memory map of tool-use id within a single sweep. A pair split across two sweeps is counted under `unknown` rather than persisted — the imprecision is a small fraction of a rare case, and persisting the map would cost a table with its own lifecycle.

**Denial signature.** The bash verb for `Bash`, otherwise the tool name; `unknown` when the pair was split.

**`hook_run.hook`.** The basename of the script the command starts with, or of the one after the interpreter running it; anything else is `unknown`. A label, not a command line — and deliberately not a search of the whole string, because `hookInfos[].command` sometimes carries the user's own prompt, and a path inside prose is prompt text. The cost is a hook invoked as a bare executable, which reads as `unknown`. An error message is machine-written, so a hook error is attributed by the longest path-like token anywhere in it, or to the only hook in the record when there is one. Only `stop_hook_summary` records exist to read, so hook health is observable for `Stop` hooks alone.

**`retro_line`.** Harvested from assistant text blocks — the session's own in a session transcript, the agent's in an agent transcript: the **last** line of the block matching `^\s*\*{0,2}Retro\*{0,2}\s*:\s*(.*)$`. Last, because the required line is the last thing an agent writes and a `Retro:` above it is something it quoted. The colon is required: without it `Retroactive correction: …` matches, and what follows it is arbitrary prose — the one thing a retro line may not be. `author` is `main` for the session, the `agentType` for an agent. `text` is capped at 500 characters, and is NULL when the captured text normalises to `none` — so the row still records that the field was answered. Keyed on the assistant record's `uuid`, so re-deriving cannot duplicate it, and inheriting exactly-once from the cursor that read it. This is the second deliberate exception to counts-and-shapes: the line is the agent's own statement about the toolkit, and capturing it is what removes the transcription step.

The notification's `<result>` element holds the same line, and is deliberately not the source: it arrives two or three times per stop, and parsing it would mean reading the agent's whole report where the transcript gives the same sentence exactly once.

### What is read past but never stored

These sit directly beside the fields the recorder wants, so they are named rather than left to judgement:

| Field | Where |
| ------------------------ | ------------------------------------------------- |
| `prompt` | async `Agent` result — the full brief |
| `description` | async result and the agent meta file |
| `content` | sync `Agent` result — the agent's final message |
| `<summary>`, `<result>` | the stop notification |
| `prompt_text` | anything a hook payload carries |

Only `<task-id>` and `<status>` are taken from a notification. Only `agentId`, `status` and `isAsync` are taken from an `Agent` result. Only `agentType` and `spawnDepth` are taken from a meta file. The canary test names every field in this table.

## The sweep

One idempotent pass. No trigger is load-bearing; whichever fires first catches up everything the others missed.

1. Take `sweep.lock` (`O_CREAT|O_EXCL`). Held by a live process → exit 0. Older than 10 minutes → steal it. Released on every exit path.
2. Read `since`. Missing → write it as now, and **record nothing this run**. A missing marker must never become a backfill.
3. Walk `~/.claude/projects/*/*.jsonl` — depth 1 only, which is session transcripts and nothing else. On this machine that is 76 files and 13 ms of `stat`, against 1,791 files in the tree as a whole. Subagent and workflow transcripts are never in this walk; a subagent transcript is reached only by name, from a fence.
4. For each transcript, decide from `stat` and the cursor:

   | Condition | What happens |
   | ----------------------------------------------- | ----------------------------------------- |
   | cursor exists, `inode` agrees, `size == offset` | skipped without opening |
   | cursor exists, `inode` and `head_sha` agree, `size > offset` | **resume** — read from `offset` |
   | cursor exists, `inode` and `head_sha` agree, `size < offset` but not below `base_offset` | **rebuild** — re-read the open segment from `base_offset` |
   | inode or head differs, or the file is shorter than `base_offset` | there is no span left to rebuild from: the open segments are cleared, and the rows below decide the file as first contact |
   | no cursor, mtime < `since` | pre-existing — the cursor parks at the last complete line, nothing read |
   | first record timestamp < `since`, or no timestamp in the first 64 KiB | pre-existing — parked, nothing recorded, and an ordinal already reached is kept |
   | first record timestamp ≥ `since` | **parse** from 0 |

   The mtime row is what keeps first contact cheap: a transcript untouched since before the marker cannot hold a record after it, so the head is never read for the bulk of an existing corpus. A parked cursor keeps its `segment_id`, or the next append would land in a segment that is already closed.

5. Consume **complete lines only**. A trailing fragment is left unconsumed and `offset` stops at the last newline, so a record being written as we read is counted once, on the next sweep.
6. On each fence in the span, read `agent-<task-id>.jsonl` from its own cursor to end of file and fold it into the segment that is open at that point. The read follows the same complete-lines and cursor rules; no new bytes means no stop and no counts.
7. Apply the session file's counts, every agent file it fenced, and every cursor touched **in one transaction**. A sweep killed mid-file rolls back and no cursor advances, so the span is simply redone.
8. Close what should close: a segment followed by a boundary; the open segment of a session transcript untouched for 24 hours; the open segment of a session transcript that has been deleted, whose cursor row then goes too. A closed segment never gains another row — what a transcript writes after an idle close opens the next ordinal. Agent cursors are exempt from closing: they belong to a fence, not to a segment.
9. Touch `last-sweep`. Release the lock. Exit 0.

**Resume adds; a rebuild replaces.** On resume, the newly consumed span's counts are added to the open segment's rows — correct because a record is consumed exactly once. A rebuild is any pass that re-reads bytes an open segment already counted, or replaces the file it counted from: it first clears everything those open segments took **from the session transcript**, then reads that span again. Closed segments are parsed past and discarded, because they are immutable.

**What an agent's transcript gave a segment survives its rebuild.** It came out of a different file, which has not changed, so re-deriving it is impossible — the re-delivered fence finds no new bytes — and deleting it would simply lose the delegation figures. A fence the segment already counted therefore adds nothing on a rebuild: any bytes that agent has gained since belong to a stop nobody has fenced yet, and counting them at the old fence would read as a lane that went round twice. Agents fenced by a closed segment are untouched either way.

**A rebuild that cannot reach its segment again says so.** A replaced file, or one whose records now predate the marker, leaves the open segment cleared and unrewritable: it keeps its delegation rows and loses its own counts. `segments_dropped` counts every one, and the digest prints it — a figure that is short has to be visible as short.

**A transcript that predates `since` contributes only what it gains after its first sweep.** That is the no-backfill rule working as intended: the existing 1,791-transcript, 1.1 GB corpus reaching back to 2026-07-02 was produced under the previous toolkit, its inefficiencies are already known, and letting it in would skew every future decision.

## Triggers

Four, all running the same command, all `async: true` so none can block a turn or inject stdout.

| Event | Matcher | Command |
| ------------------ | ------- | ------------------------------- |
| `SessionStart` | `""` | `hooks/retro.py record` |
| `PreCompact` | `""` | `hooks/retro.py record` |
| `SessionEnd` | `""` | `hooks/retro.py record` |
| `UserPromptSubmit` | `""` | `hooks/retro.py record --interval 900` |

`Stop` and `Notification` stay unwired — `claude-notifications-go` owns them.

`--interval N` exits immediately unless `last-sweep` is older than N seconds. That is the whole interval mechanism: no cron entry, no systemd timer, no daemon, nothing outside the repo and `~/.claude`. It rides a per-turn hook and no-ops the rest of the time.

An unattended stretch with no user prompt sweeps only at the next session or compaction event. Nothing is lost — transcripts are durable for 30 days and the sweep catches up. The interval bounds how much catching up there is to do; it does not promise freshness.

## Failure

Every path degrades to silence and exit 0. A hook must never crash a session or print a traceback.

| What goes wrong | What happens |
| ------------------------------ | ------------------------------------------------------------------------ |
| `sqlite3` unimportable | recorder is inert; the doctor reports it |
| `retro.db` corrupt | moved to `retro.db.corrupt.<timestamp>`, a fresh one created. `since` survives, so no backfill follows. Live transcripts are re-derived; their closed segments may be reviewed a second time — the honest cost of a rebuild |
| `retro.db` will not open — no permission, no space, a filesystem that will not do WAL | left exactly where it is, nothing recorded. That is a healthy store behind a temporary problem, and quarantining it would throw away the record that outlives every transcript |
| `PRAGMA user_version` is not the one this build writes | exit 0 without touching it; the review names the version it found. Another toolkit on the same machine wrote it |
| `since` missing | recreated as now, nothing recorded that run |
| `since` unreadable | left exactly as it is and nothing recorded until it is fixed; the doctor says so. Rewriting it would move the one value in the store that must never move |
| transcript unreadable | file skipped, cursor untouched, sweep continues, `transcripts_failed` incremented |
| line will not parse | skipped, `malformed_lines` incremented, file continues |
| last line partially written | not consumed; counted on the next sweep |
| two sweeps at once | the second exits 0 immediately; its work is the same work |
| sweep killed mid-file | transaction rolls back, cursor stays put, span redone |
| transcript rewound or truncated | its open segment is rebuilt from `base_offset`; closed segments are untouched, and what its agents gave it survives |
| transcript replaced under the same name | head or inode mismatch: the open segments are cleared and the file is read as first contact. What cannot be rebuilt from it is counted in `segments_dropped` |
| fence names a task with no meta file | a background command, not an agent — ignored |
| fence's agent transcript missing | `agent_fences_lost` incremented, nothing else; the stop is not counted, because there is no way to tell it from a repeat delivery |
| meta file missing but the transcript is there | folded in under `agent = unknown`, `spawn_depth` NULL |
| fence arrives two or three times | the second and third find no new bytes, so they add nothing |
| agent still running at sweep time | nothing fences it, so its file is never opened; it is counted when it stops |
| agent resumed and stops again | new bytes, so a second stop and the new span are counted — a lane that went round twice reads as twice |
| transcript deleted by the 30-day cleanup | its open segment closes as `gone`, its cursor row is dropped, its digest stays |
| anything else | caught, swallowed, exit 0 |

The recorder drains and discards stdin, so a large hook payload cannot block the writer.

## Review

`hooks/retro.py review` prints a plain-text digest over **closed segments with `closed_seq > reviewed_through`**, and changes nothing. Every row that groups a count carries `n`, the segments it spans and the projects it spans, because a slip across several projects is a toolkit problem while the same slip in one repo is usually a quirk of that repo.

The digest sections:

- **Window** — segment count, project count, date range, and the `closed_seq` an accept would advance to. Then what the recorder could not read: this window's malformed lines and lost agent fences, and the store's all-time `transcripts_failed` and `segments_dropped`, named as all-time so a failure from last spring is not read as one from the fortnight under review. A figure printed below those lines is short by an unknown amount, and saying so is what separates a low number from a missing one.
- **Delegation** — per project: the session's own `Edit`/`Write`/`Bash` counts against the same counts under `agent != ''`, and how many of that project's segments had main-chain edits at all.
- **Agents** — stops and distinct agents by type, status and spawn depth, with token, tool-use and duration totals and maxima. Depth greater than 1 is called out, since nesting is invisible anywhere else.
- **Permission friction** — denial kind × signature, split by whether it hit the session or an agent, ranked by projects then recurrence.
- **Tools** and **Bash verbs** — the top of each with its error counts, session and agents shown apart.
- **Skills** — skills seen with counts and project spread, and skills installed under `~/.claude/skills` that appear nowhere in the window. A skills directory that will not read says so: silence there would read as "every skill fired", which is the opposite of what is known.
- **Compaction** — auto against manual, with dropped tokens and durations. Its row counts segments itself, so it carries no separate segment column.
- **Hooks** — fires, errors, worst duration, by hook.
- **Retro lines** — every non-null line with author, project and date, and the count of `none` answers beside it.

`hooks/retro.py review --accept <seq>` sets `reviewed_through` to `<seq>` and says how many segments that hid. It only moves forward, and never past the last closed segment: an accept is permanent and has no undo, so a sequence nobody could have reviewed is refused instead of taken. **`review` never advances the marker on its own** — a review that was read but never judged must come back next time.

`--all` ignores `reviewed_through` and digests everything. It never writes. An empty digest ends the review — a retro with no data is not a brainstorm.

## The required retro field

An optional convention does not get filled. Every agent's return contract ends with a required line:

`Retro:` — one line, or `Retro: none`.

The session transcribes nothing: the recorder takes the line from the transcript itself.

**Two records, and a review reads both.** The store is the measured one — what this machine's sessions actually did, in figures nobody had to remember — and it is machine-local by decision, so it never leaves the machine that produced it. `RETRO.md` is the written one: a conclusion someone chose to put in words, which no transcript could have produced, and which travels with the repo to every machine that pulls it. Neither replaces the other. A digest read without `RETRO.md` beside it is missing everything that was concluded rather than counted.

## Deliberately excluded

- **No statusline segment.** Unreviewed-segment count is not something you act on mid-turn, and the bar is not free.
- **No OpenTelemetry.** Claude Code's built-in telemetry covers permission decisions, `agent.name`, `skill.name` and token usage, but every exporter needs a collector, a Prometheus listener, or the CLI's own stdout — a daemon, which is out of bounds. Its only on-disk path, `OTEL_LOG_RAW_API_BODIES=file:<dir>`, writes full request and response bodies, which is the opposite of counts-and-shapes. Its unit is the session or the prompt, not the segment, and it cannot carry a `Retro:` line. Revisit only if a collector ever becomes acceptable.
- **No third-party transcript miner.** `token-dashboard`, `claude-code-log`, `claude-usage` and `claude-code-analytics` all read the same JSONL and confirm the approach is sound, but they answer cost and usage questions, ship Node/Rust/Python dependencies against a stdlib-only rule, and have no notion of segments, a `since` marker, a `reviewed-through` marker, or our agents' retro line. Integrating one costs more than the recorder and buys none of the contract above.

## Open decisions

- **Sweep interval, 900 s.** A first guess. It lives as the `--interval` argument in `install.sh`'s `WIRING`; change it there.
- **Idle-close threshold, 24 h.** A constant in `hooks/retro.py`. Long enough that an overnight break does not close a live segment.

## Build units

Every "done when" below is a case in `tests/run.sh`, in the style already there.

### 1 — Recorder

`hooks/retro.py record` over session transcripts: store, schema, cursors, sweep, segment derivation, every failure path. stdlib only, silent on stdout, exit 0 always. The `agent` key column exists and is always `''` until unit 2.

Done when:

- A transcript newer than `since` yields one segment per boundary with the counts above.
- Re-running with no new bytes changes not one row.
- Appending and re-sweeping adds to the open segment; it does not create a second one.
- A transcript whose first timestamp precedes `since` contributes nothing.
- A missing `since` is recreated and that run records nothing.
- A malformed line is skipped and counted; the rest of the file still lands.
- A file whose head changed is rebuilt without duplicating or altering closed segments.
- A last line without a newline is not consumed, and is counted exactly once after it completes.
- A second concurrent sweep exits 0 and writes nothing.
- An unreadable transcript does not stop the sweep.
- A corrupt database is moved aside, recreated, and the sweep still exits 0.
- `record` prints nothing on stdout and exits 0 on every path, including with no `~/.claude/projects` at all.
- `--interval N` does no work twice inside N seconds.
- The sweep walks depth 1 only: a `subagents/` transcript planted under a swept project is not opened.

### 2 — Delegation

Fences, the by-name agent read, agent cursors, the `agent`-keyed detail rows, `agent_run`, and the retro line from an agent transcript.

Depends on 1. Done when:

- A fixture session transcript with an async launch and a stop notification produces an `agent_run` row with the `agentType` from the meta file, non-zero tokens, tool uses and duration — none of which the session transcript holds.
- Both notification shapes are recognised: a `queue-operation` record and a `user` record with `origin.kind == "task-notification"`.
- The same notification delivered three times yields one stop.
- An agent transcript with new bytes since its last fence yields a second stop; one without yields none.
- A `spawnDepth: 2` agent lands in the same segment as its root, with its depth recorded.
- A notification whose task id has no meta file is ignored, and no file is opened for it.
- A fence whose agent transcript is missing increments `agent_fences_lost` and counts no stop.
- A missing meta file yields `agent = unknown` rather than a skipped run.
- An agent that has not stopped is never opened.
- A rebuild of an open segment reproduces the identical delegation figures — not doubled, not lost — and does not re-count a stop it already holds.
- The session's own tool counts and an agent's are separable by the `agent` column.
- Grepping the whole database finds nothing from a canary planted in every field of the "read past but never stored" table: an async result's `prompt` and `description`, a sync result's `content`, a notification's `<summary>` and `<result>`, a meta file's `description`, and a Bash command's arguments.

### 3 — Wiring

`install.sh`: the four `WIRING` entries, creation of `~/.claude/retro/` with `since` if absent, and a doctor line when `sqlite3` will not import.

Depends on 1. Done when:

- All four events are wired, all `async`, and the existing wiring doctor accepts them.
- A fresh install creates `since`; a re-install leaves it alone.
- The install stays idempotent and every existing installer test still passes.

### 4 — Review

`hooks/retro.py review`, `--accept`, `--all`, and the digest sections above.

Depends on 1 and 2. Done when:

- `review` lists only closed segments past `reviewed_through`, and never writes.
- After `--accept <seq>` those segments are gone from the next `review` and later ones are not.
- Every grouped row shows `n`, `segments` and `projects`.
- The delegation section separates the session's own work from its agents', and the agent section names any spawn depth above 1.
- A skill installed under `~/.claude/skills` but absent from the window is named.
- An empty window prints that it is empty.

### 5 — The required retro field

`agents/*.md` return contracts, the `Retro` section of `CLAUDE.md`, and what `README.md` and `documentation/brief.md` say about where retro data lives.

Depends on 2. Done when:

- Every agent definition carries the required `Retro:` line — asserted the way `SendMessage` already is.
- A `Retro:` line in an agent transcript is captured with that agent's type as author; `Retro: none` stores a row with null text.

### 6 — The toolkit skill's review mode

`skills/toolkit/SKILL.md`: "Reviewing the retro log" becomes "Running a retro" — run the digest, read `RETRO.md` beside it, group, rank by projects then recurrence, decide rule-we-lack against rule-that-did-not-fire, checklist, then accept.

Depends on 4. Done when the skill describes only what the digest actually prints.

### 7 — README

The `hooks/` row, the `RETRO.md` row, and a short section describing the recorder and the review the way the statusline is described.

Depends on 1–6.
