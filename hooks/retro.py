#!/usr/bin/env python3
"""A retro runs off recorded fact, not recall.

    hooks/retro.py record [--interval N]
    hooks/retro.py review [--all] [--accept N]

`record` digests Claude Code's own transcripts into ~/.claude/retro/retro.db;
`review` reads that store back as a plain-text digest for the `toolkit` skill to
judge. One file, because the review has to know the schema and a second file
could only get it by duplicating it. Every path hangs off $HOME, so the suite
points it at a fake home the way it does for the statusline.

The recorder degrades to silence and exits 0 on every path, and writes nothing to
stdout: UserPromptSubmit and SessionStart inject a hook's stdout as context.

Counts and shapes only — never prompt text, file contents, command arguments, an
agent's brief or its report. The two deliberate exceptions are the normalised
command verb and the agent's own `Retro:` line, both of which the spec names.

Contract: documentation/specs/retro.md.
"""

import hashlib
import json
import os
import re
import stat
import sys
import time
from datetime import datetime

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
PROJECTS = os.path.join(CLAUDE, "projects")
SKILLS = os.path.join(CLAUDE, "skills")
STORE = os.path.join(CLAUDE, "retro")
DB_PATH = os.path.join(STORE, "retro.db")
SINCE_PATH = os.path.join(STORE, "since")
SWEPT_PATH = os.path.join(STORE, "last-sweep")
LOCK_PATH = os.path.join(STORE, "sweep.lock")

SCHEMA_VERSION = 1
HEAD_BYTES = 4096
FIRST_TS_BYTES = 64 * 1024
CHUNK = 1 << 20
IDLE_SECONDS = (
    24 * 3600
)  # long enough that an overnight break does not close a live segment
LOCK_STALE_SECONDS = 600
RETRO_TEXT_CHARS = 500
VERB_PARTS = 5
TOP_ROWS = 12  # per ranked digest table

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE IF NOT EXISTS cursor(
  path TEXT PRIMARY KEY,
  agent_id TEXT,
  inode INTEGER,
  head_len INTEGER,
  head_sha TEXT,
  "offset" INTEGER NOT NULL DEFAULT 0,
  base_offset INTEGER,
  ordinal INTEGER,
  segment_id TEXT,
  last_ts TEXT);

CREATE TABLE IF NOT EXISTS segment(
  id TEXT PRIMARY KEY,
  session_id TEXT, project TEXT, repo TEXT, ordinal INTEGER,
  started_at TEXT, ended_at TEXT, cli_version TEXT, branch TEXT,
  closed_seq INTEGER, close_trigger TEXT,
  compact_trigger TEXT, pre_tokens INTEGER, post_tokens INTEGER,
  dropped_tokens INTEGER, compact_ms INTEGER,
  user_turns INTEGER NOT NULL DEFAULT 0,
  wake_turns INTEGER NOT NULL DEFAULT 0,
  assistant_turns INTEGER NOT NULL DEFAULT 0,
  turn_ms_total INTEGER NOT NULL DEFAULT 0,
  turn_ms_max INTEGER NOT NULL DEFAULT 0,
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0,
  cache_read INTEGER NOT NULL DEFAULT 0,
  cache_create INTEGER NOT NULL DEFAULT 0,
  tool_errors INTEGER NOT NULL DEFAULT 0,
  malformed_lines INTEGER NOT NULL DEFAULT 0,
  agent_fences_lost INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS segment_session ON segment(session_id, closed_seq);

CREATE TABLE IF NOT EXISTS tool_use(
  segment_id TEXT, agent TEXT, tool TEXT,
  n INTEGER NOT NULL DEFAULT 0, errors INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(segment_id, agent, tool));

CREATE TABLE IF NOT EXISTS bash_verb(
  segment_id TEXT, agent TEXT, verb TEXT,
  n INTEGER NOT NULL DEFAULT 0, errors INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(segment_id, agent, verb));

CREATE TABLE IF NOT EXISTS denial(
  segment_id TEXT, agent TEXT, kind TEXT, signature TEXT,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(segment_id, agent, kind, signature));

CREATE TABLE IF NOT EXISTS skill_use(
  segment_id TEXT, agent TEXT, skill TEXT,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(segment_id, agent, skill));

CREATE TABLE IF NOT EXISTS mcp_use(
  segment_id TEXT, agent TEXT, server TEXT,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(segment_id, agent, server));

CREATE TABLE IF NOT EXISTS agent_run(
  segment_id TEXT, agent_type TEXT, status TEXT, spawn_depth INTEGER,
  n INTEGER NOT NULL DEFAULT 0, agents INTEGER NOT NULL DEFAULT 0,
  tokens_in INTEGER NOT NULL DEFAULT 0, tokens_out INTEGER NOT NULL DEFAULT 0,
  cache_read INTEGER NOT NULL DEFAULT 0, cache_create INTEGER NOT NULL DEFAULT 0,
  tool_uses INTEGER NOT NULL DEFAULT 0,
  ms_total INTEGER NOT NULL DEFAULT 0, ms_max INTEGER NOT NULL DEFAULT 0);
-- spawn_depth is NULL when no meta file named it, and SQLite holds NULLs
-- distinct in a unique index, so the key coalesces it or every unknown-depth
-- fence would insert a new row instead of adding to the one already there.
CREATE UNIQUE INDEX IF NOT EXISTS agent_run_key
  ON agent_run(segment_id, agent_type, status, IFNULL(spawn_depth, -1));

CREATE TABLE IF NOT EXISTS hook_run(
  segment_id TEXT, hook TEXT,
  n INTEGER NOT NULL DEFAULT 0, errors INTEGER NOT NULL DEFAULT 0,
  ms_total INTEGER NOT NULL DEFAULT 0, ms_max INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(segment_id, hook));

CREATE TABLE IF NOT EXISTS retro_line(
  source_uuid TEXT PRIMARY KEY,
  segment_id TEXT, author TEXT, text TEXT, at TEXT);
"""

# The deliberate exception to "no command arguments": a permission prompt cannot
# be recognised as recurring without knowing which command it was.
DRIVERS = {
    "git",
    "gh",
    "npm",
    "pnpm",
    "yarn",
    "bun",
    "cargo",
    "docker",
    "kubectl",
    "systemctl",
    "apt",
    "apt-get",
    "brew",
    "pip",
    "pip3",
    "python",
    "python3",
    "node",
    "make",
    "go",
    "terraform",
    "aws",
    "gcloud",
    "sudo",
    "nix",
}
VERB_OK = re.compile(r"^[A-Za-z0-9._+-]{1,32}$")
LABEL_OK = re.compile(r"^[A-Za-z0-9._+-]{1,64}$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SPLIT_PARTS = re.compile(r"&&|\|\||;|\|")
# The colon is required. Without it "Retroactive correction: …" and a bold
# "**Retro** ← …" both match, and the line after them is arbitrary assistant
# prose — which is the one thing a retro line may not be. Verified against the
# live store, where a colon-optional pattern harvested two such lines in nine.
RETRO_LINE = re.compile(r"^\s*\*{0,2}Retro\*{0,2}\s*:\s*(.*)$")
TASK_ID = re.compile(r"<task-id>([^<]*)</task-id>")
TASK_STATUS = re.compile(r"<status>([^<]*)</status>")
# An agent id is read out of transcript text and then spells a filename, so it
# is checked before it is one. Real ids are hex; anything with a separator in it
# is not an id, and a fence naming one is not a fence.
AGENT_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


# ── small shared helpers ─────────────────────────────────────────────────────


def num(value):
    """An integer, or 0 for anything that is not a plain number. Transcript
    fields are whatever the writer put there."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return int(value)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def parse_iso(ts):
    if not isinstance(ts, str) or not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def bash_verbs(command):
    """Every verb a Bash command runs, normalised. `git push`, `npm install`,
    `cargo test` — a driver keeps its subcommand, because the driver alone
    cannot tell a read from a publish."""
    if not isinstance(command, str) or not command.strip():
        return []
    verbs = []
    for part in SPLIT_PARTS.split(command)[:VERB_PARTS]:
        tokens = part.split()
        while tokens and ASSIGNMENT.match(tokens[0]):
            tokens.pop(0)
        if not tokens:
            continue
        head = os.path.basename(tokens[0].rstrip("/")) or tokens[0]
        if not VERB_OK.match(head):
            verbs.append("other")
            continue
        verb = head
        if head in DRIVERS:
            for token in tokens[1:]:
                if token.startswith("-"):
                    continue
                # A subcommand is a bare word; a path or a quoted string is an
                # argument, and arguments are never recorded.
                if VERB_OK.match(token):
                    verb = head + " " + token
                break
        verbs.append(verb)
    return verbs


def hook_label(command):
    """A label for a hook, not a command line: the last component of the longest
    path-like token.

    A command with no path in it at all is `unknown` rather than its first word.
    `hookInfos[].command` is not always a command — in this store it sometimes
    carries the user's prompt instead — and a first word taken from prose is
    prompt text, which nothing here may store.
    """
    paths = [t for t in str(command or "").split() if "/" in t]
    if not paths:
        return "unknown"
    label = max(paths, key=len).rstrip("/").rsplit("/", 1)[-1].strip("\"'`,;:()[]")
    return label if LABEL_OK.match(label) else "unknown"


def sha_head(f, length):
    f.seek(0)
    return hashlib.sha256(f.read(length)).hexdigest()


def read_lines(f, start):
    """(line, offset-after-it) for every complete line from `start`. A trailing
    fragment is left unconsumed, so a record being written as we read is counted
    once, on the next sweep."""
    f.seek(start)
    consumed = start
    buf = b""
    while True:
        chunk = f.read(CHUNK)
        if not chunk:
            return
        buf += chunk
        while True:
            cut = buf.find(b"\n")
            if cut < 0:
                break
            line, buf = buf[:cut], buf[cut + 1 :]
            consumed += cut + 1
            yield line, consumed


def read_json(path):
    try:
        with open(path, "rb") as f:
            value = json.loads(f.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


# ── the store ────────────────────────────────────────────────────────────────


def quarantine():
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    for suffix in ("", "-wal", "-shm"):
        try:
            os.replace(DB_PATH + suffix, "%s.corrupt.%s%s" % (DB_PATH, stamp, suffix))
        except OSError:
            pass


def open_store(create=True):
    """The database with its schema applied, or None when the store cannot be
    used. A corrupt file is moved aside and rebuilt — `since` survives it, so no
    backfill follows. A `user_version` this code does not know belongs to a
    newer toolkit on the same machine and is left untouched."""
    try:
        import sqlite3
    except ImportError:
        return None
    if not create and not os.path.exists(DB_PATH):
        return None
    for attempt in (0, 1):
        db = None
        try:
            os.makedirs(STORE, exist_ok=True)
            db = sqlite3.connect(DB_PATH, timeout=10)
            # Transactions are ours to open and close: a sweep killed mid-file
            # must roll back the whole file, which the driver's own implicit
            # transactions would cut across.
            db.isolation_level = None
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA busy_timeout=5000")
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version == 0:
                db.executescript(SCHEMA)
                db.execute("PRAGMA user_version=%d" % SCHEMA_VERSION)
            elif version != SCHEMA_VERSION:
                db.close()
                return None
            db.execute("SELECT count(*) FROM segment").fetchone()
            return db
        except Exception:
            if db is not None:
                try:
                    db.close()
                except Exception:
                    pass
            if attempt or not create:
                return None
            quarantine()
    return None


def meta_get(db, key, default=0):
    row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    try:
        return int(row[0]) if row else default
    except (TypeError, ValueError):
        return default


def meta_set(db, key, value):
    db.execute(
        "INSERT INTO meta(key, value) VALUES(?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, str(value)),
    )


# Every child table, once: its key columns after segment_id, the columns a
# second sweep adds to, the columns it takes the larger of, and the conflict
# target when it is not just the key columns. The accumulator, the merge and the
# write all read this, so a table cannot be described two ways.
CHILD_TABLES = (
    ("tools", "tool_use", ("agent", "tool"), ("n", "errors"), (), None),
    ("verbs", "bash_verb", ("agent", "verb"), ("n", "errors"), (), None),
    ("denials", "denial", ("agent", "kind", "signature"), ("n",), (), None),
    ("skills", "skill_use", ("agent", "skill"), ("n",), (), None),
    ("mcps", "mcp_use", ("agent", "server"), ("n",), (), None),
    ("hooks", "hook_run", ("hook",), ("n", "errors", "ms_total"), ("ms_max",), None),
    (
        "runs",
        "agent_run",
        ("agent_type", "status", "spawn_depth"),
        (
            "n",
            "agents",
            "tokens_in",
            "tokens_out",
            "cache_read",
            "cache_create",
            "tool_uses",
            "ms_total",
        ),
        ("ms_max",),
        "segment_id, agent_type, status, IFNULL(spawn_depth, -1)",
    ),
)


def as_key(key):
    return key if isinstance(key, tuple) else (key,)


def bump(mapping, key, values, maxes=0):
    """Fold one row's values into an accumulator. The last `maxes` of them take
    the larger value rather than the sum, the way their columns do."""
    entry = mapping.setdefault(key, [0] * len(values))
    cut = len(values) - maxes
    for i, value in enumerate(values):
        entry[i] = entry[i] + value if i < cut else max(entry[i], value)
    return entry


def upsert(db, table, keys, sums, maxes, values, target=None):
    cols = list(keys) + list(sums) + list(maxes)
    sets = ["%s=%s+excluded.%s" % (c, c, c) for c in sums]
    sets += ["%s=MAX(%s, excluded.%s)" % (c, c, c) for c in maxes]
    db.execute(
        "INSERT INTO %s(%s) VALUES(%s) ON CONFLICT(%s) DO UPDATE SET %s"
        % (
            table,
            ",".join(cols),
            ",".join("?" * len(cols)),
            target or ",".join(keys),
            ",".join(sets),
        ),
        values,
    )


# ── extraction ───────────────────────────────────────────────────────────────


class Span:
    """What one contiguous run of records in one transcript contributes: the
    session's own main chain, or one agent's file folded in at its fence."""

    def __init__(self):
        # Keyed the way its table is, minus the agent column the bucket adds.
        self.tools = {}  # tool -> [n, errors]
        self.verbs = {}  # verb -> [n, errors]
        self.denials = {}  # (kind, signature) -> [n]
        self.skills = {}  # skill -> [n]
        self.mcps = {}  # server -> [n]
        self.hooks = {}  # hook -> [n, errors, ms_total, ms_max]
        self.retro = []  # (uuid, text, at)
        self.pending = {}  # tool_use id -> (tool, verbs)
        self.messages = set()  # message ids whose usage is already summed
        self.skill_now = None
        self.user_turns = 0
        self.wake_turns = 0
        self.assistant_turns = 0
        self.turn_ms_total = 0
        self.turn_ms_max = 0
        self.tokens = [0, 0, 0, 0]  # in, out, cache read, cache create
        self.tool_uses = 0
        self.tool_errors = 0
        self.malformed = 0
        self.first_ts = None
        self.last_ts = None
        self.version = None
        self.branch = None
        self.repo = None

    def duration_ms(self):
        first, last = parse_iso(self.first_ts), parse_iso(self.last_ts)
        if first is None or last is None or last < first:
            return 0
        return int((last - first) * 1000)


def feed(span, rec, main_chain):
    """Fold one record into the span. Returns ("boundary", metadata) or
    ("fence", agent id, status) when the caller has to act on it."""
    if main_chain and rec.get("isSidechain"):
        # An older layout's copy of an agent's own work. The agent's transcript
        # is where it is counted, and counting it twice would read as delegation
        # that never happened.
        return None
    kind = rec.get("type")
    if kind == "system" and rec.get("subtype") == "compact_boundary":
        meta = rec.get("compactMetadata")
        return ("boundary", meta if isinstance(meta, dict) else {})

    ts = rec.get("timestamp")
    if isinstance(ts, str) and ts:
        if span.first_ts is None:
            span.first_ts = ts
        if span.last_ts is None or ts > span.last_ts:
            span.last_ts = ts
    for field, attr in (("version", "version"), ("gitBranch", "branch")):
        value = rec.get(field)
        if isinstance(value, str) and value:
            setattr(span, attr, value)
    cwd = rec.get("cwd")
    if span.repo is None and isinstance(cwd, str) and cwd:
        span.repo = os.path.basename(cwd.rstrip("/")) or cwd

    if kind == "system":
        sub = rec.get("subtype")
        if sub == "turn_duration":
            ms = num(rec.get("durationMs"))
            span.turn_ms_total += ms
            span.turn_ms_max = max(span.turn_ms_max, ms)
        elif sub == "stop_hook_summary":
            feed_hooks(span, rec)
        return None
    if kind == "assistant":
        return feed_assistant(span, rec)
    if kind == "user":
        return feed_user(span, rec)
    if kind == "queue-operation":
        return fence_of(rec.get("content"))
    return None


def feed_hooks(span, rec):
    infos = rec.get("hookInfos")
    infos = infos if isinstance(infos, list) else []
    labels = []
    for info in infos:
        if not isinstance(info, dict):
            continue
        label = hook_label(info.get("command"))
        labels.append(label)
        ms = num(info.get("durationMs"))
        bump(span.hooks, label, (1, 0, ms, ms), maxes=1)
    errors = rec.get("hookErrors")
    for error in errors if isinstance(errors, list) else []:
        # hookErrors is a list of messages, not of hooks. With one hook in the
        # record the attribution is certain; otherwise the message's own path is
        # the only thing that names which hook failed.
        label = labels[0] if len(labels) == 1 else hook_label(error)
        bump(span.hooks, label, (0, 1, 0, 0), maxes=1)


def feed_assistant(span, rec):
    span.assistant_turns += 1
    msg = rec.get("message")
    msg = msg if isinstance(msg, dict) else {}
    usage = msg.get("usage")
    message_id = msg.get("id") or rec.get("requestId") or rec.get("uuid")
    if isinstance(usage, dict) and message_id not in span.messages:
        # One API response is written as one record per content block, every one
        # carrying the same message id and the same usage block: summing per
        # record would roughly double every token figure.
        span.messages.add(message_id)
        span.tokens[0] += num(usage.get("input_tokens"))
        span.tokens[1] += num(usage.get("output_tokens"))
        span.tokens[2] += num(usage.get("cache_read_input_tokens"))
        span.tokens[3] += num(usage.get("cache_creation_input_tokens"))
    invoked = None
    content = msg.get("content")
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            harvest_retro(span, rec, block.get("text"))
        elif block.get("type") == "tool_use":
            invoked = feed_tool_use(span, block) or invoked
    # A skill fires either through the Skill tool or by being loaded for the
    # model, which shows only as attributionSkill on the records that follow.
    # Counting the start of each run counts one activation for both, where
    # counting records would count a skill once per turn it stayed loaded.
    attributed = rec.get("attributionSkill")
    current = invoked or (
        attributed if isinstance(attributed, str) and attributed else None
    )
    if current and current != span.skill_now:
        bump(span.skills, current, (1,))
    span.skill_now = current
    return None


def feed_tool_use(span, block):
    """Returns the skill a `Skill` block invoked, else None."""
    name = block.get("name")
    if not isinstance(name, str) or not name:
        name = "unknown"
    span.tool_uses += 1
    bump(span.tools, name, (1, 0))
    args = block.get("input")
    args = args if isinstance(args, dict) else {}
    verbs = []
    if name == "Bash":
        verbs = bash_verbs(args.get("command"))
        for verb in verbs:
            bump(span.verbs, verb, (1, 0))
    elif name.startswith("mcp__"):
        parts = name.split("__")
        server = parts[1] if len(parts) > 2 and parts[1] else "unknown"
        bump(span.mcps, server, (1,))
    use_id = block.get("id")
    if isinstance(use_id, str) and use_id:
        span.pending[use_id] = (name, verbs)
    if name == "Skill":
        skill = args.get("skill") or args.get("name")
        return skill if isinstance(skill, str) and skill else None
    return None


def feed_user(span, rec):
    origin = rec.get("origin")
    kind = (origin or {}).get("kind") if isinstance(origin, dict) else None
    if kind == "human":
        span.user_turns += 1
    elif isinstance(kind, str) and kind:
        span.wake_turns += 1

    msg = rec.get("message")
    content = (msg if isinstance(msg, dict) else {}).get("content")
    first_result = None
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        use_id = block.get("tool_use_id")
        if first_result is None:
            first_result = use_id
        if block.get("is_error"):
            span.tool_errors += 1
            mark_error(span, use_id)
    denial = rec.get("toolDenialKind")
    if isinstance(denial, str) and denial:
        bump(span.denials, (denial, signature(span, first_result)), (1,))

    if kind == "task-notification":
        return fence_of(content)
    result = rec.get("toolUseResult")
    if isinstance(result, dict) and result.get("agentId") and not result.get("isAsync"):
        # A synchronous Agent result: the agent has finished by the time it
        # lands. Its own toolStats and token figures are deliberately ignored in
        # favour of its transcript, so sync and async have one code path.
        return ("fence", str(result["agentId"]), str(result.get("status") or "unknown"))
    return None


def mark_error(span, use_id):
    tool, verbs = span.pending.get(use_id, (None, ()))
    if tool is None:
        # The tool_use landed in an earlier sweep. Persisting the map would cost
        # a table with its own lifecycle for a small slice of a rare case.
        bump(span.tools, "unknown", (0, 1))
        return
    bump(span.tools, tool, (0, 1))
    for verb in verbs:
        bump(span.verbs, verb, (0, 1))


def signature(span, use_id):
    tool, verbs = span.pending.get(use_id, (None, ()))
    if tool is None:
        return "unknown"
    if tool == "Bash":
        return verbs[0] if verbs else "other"
    return tool


def harvest_retro(span, rec, text):
    """The agent's own statement about the toolkit, keyed on the record's uuid so
    re-deriving cannot duplicate it."""
    if not isinstance(text, str) or "Retro" not in text:
        return
    uuid = rec.get("uuid")
    if not isinstance(uuid, str) or not uuid:
        return
    for line in text.splitlines():
        hit = RETRO_LINE.match(line)
        if not hit:
            continue
        body = hit.group(1).strip().strip("*").strip()[:RETRO_TEXT_CHARS]
        # A row is written either way: that the field was answered "none" is
        # itself the fact, and it is what separates none from never asked.
        if body.strip(" .").lower() in ("", "none"):
            body = None
        span.retro.append((uuid, body, rec.get("timestamp")))
        return


def fence_of(content):
    """The ("fence", agent id, status) a stop notification carries. Only the task
    id and the status are read; the summary and the result are not."""
    if isinstance(content, list):
        content = "".join(
            b.get("text") or ""
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    if not isinstance(content, str) or "<task-notification>" not in content:
        return None
    task = TASK_ID.search(content)
    if not task or not task.group(1).strip():
        return None
    status = TASK_STATUS.search(content)
    return (
        "fence",
        task.group(1).strip(),
        (status.group(1).strip() if status else "") or "unknown",
    )


# ── the segment accumulator ──────────────────────────────────────────────────


class Bucket:
    """Everything one compaction segment gained in this sweep, keyed the way the
    tables are: the `agent` column is what separates the session's own work from
    an agent's, at any depth, without a second set of tables."""

    def __init__(self):
        # One mapping per child table, keyed and valued exactly as CHILD_TABLES
        # declares it, so writing them out is one loop over that list.
        for attr, _, _, _, _, _ in CHILD_TABLES:
            setattr(self, attr, {})
        self.retro = []  # (uuid, author, text, at)
        self.scalars = dict.fromkeys(
            (
                "user_turns",
                "wake_turns",
                "assistant_turns",
                "turn_ms_total",
                "turn_ms_max",
                "tokens_in",
                "tokens_out",
                "cache_read",
                "cache_create",
                "tool_errors",
                "malformed_lines",
                "agent_fences_lost",
            ),
            0,
        )
        self.started_at = None
        self.ended_at = None
        self.version = None
        self.branch = None
        self.repo = None
        self.touched = False

    def absorb(self, span, agent, author):
        # A span that consumed no record leaves the bucket untouched, or every
        # sweep would write a segment row for a transcript that gained nothing.
        if span.first_ts or span.malformed:
            self.touched = True
        for attr in ("tools", "verbs", "denials", "skills", "mcps"):
            for key, values in getattr(span, attr).items():
                bump(getattr(self, attr), (agent,) + as_key(key), values)
        for uuid, text, at in span.retro:
            self.retro.append((uuid, author, text, at))
        # A malformed line has nowhere else to be counted, whichever transcript
        # it was in.
        self.scalars["malformed_lines"] += span.malformed
        if span.first_ts and (
            self.started_at is None or span.first_ts < self.started_at
        ):
            self.started_at = span.first_ts
        if span.last_ts and (self.ended_at is None or span.last_ts > self.ended_at):
            self.ended_at = span.last_ts

    def absorb_main(self, span):
        """The session's own chain also carries the segment's scalars and the
        hook records — an agent transcript has neither."""
        self.absorb(span, "", "main")
        self.scalars["user_turns"] += span.user_turns
        self.scalars["wake_turns"] += span.wake_turns
        self.scalars["assistant_turns"] += span.assistant_turns
        self.scalars["turn_ms_total"] += span.turn_ms_total
        self.scalars["turn_ms_max"] = max(self.scalars["turn_ms_max"], span.turn_ms_max)
        self.scalars["tool_errors"] += span.tool_errors
        for i, name in enumerate(
            ("tokens_in", "tokens_out", "cache_read", "cache_create")
        ):
            self.scalars[name] += span.tokens[i]
        for label, values in span.hooks.items():
            bump(self.hooks, (label,), values, maxes=1)
        self.version = span.version or self.version
        self.branch = span.branch or self.branch
        self.repo = self.repo or span.repo

    def absorb_agent(self, span, agent_type, status, depth, first_seen):
        self.absorb(span, agent_type, agent_type)
        self.touched = True
        ms = span.duration_ms()
        # n counts fenced stops, not agents; a resumed agent contributes two
        # stops and one agent, and the gap between them is the lane going round.
        bump(
            self.runs,
            (agent_type, status, depth),
            (1, 1 if first_seen else 0) + tuple(span.tokens) + (span.tool_uses, ms, ms),
            maxes=1,
        )


# ── the sweep ────────────────────────────────────────────────────────────────


def get_cursor(db, path):
    return db.execute(
        'SELECT agent_id, inode, head_len, head_sha, "offset", base_offset, '
        "ordinal, segment_id, last_ts FROM cursor WHERE path=?",
        (path,),
    ).fetchone()


def put_cursor(db, path, row):
    db.execute(
        'INSERT INTO cursor(path, agent_id, inode, head_len, head_sha, "offset", '
        "base_offset, ordinal, segment_id, last_ts) VALUES(?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(path) DO UPDATE SET agent_id=excluded.agent_id, "
        "inode=excluded.inode, head_len=excluded.head_len, head_sha=excluded.head_sha, "
        '"offset"=excluded."offset", base_offset=excluded.base_offset, '
        "ordinal=excluded.ordinal, segment_id=excluded.segment_id, last_ts=excluded.last_ts",
        (path,) + row,
    )


def unchanged(st, cur):
    """A transcript that has gained nothing since its cursor, decided from stat
    alone so the bulk of a corpus is never opened."""
    return cur is not None and cur[1] == st.st_ino and cur[4] == st.st_size


def plan(f, st, cur, since_epoch):
    """(mode, start offset, head) for a transcript. head is (length, sha) when
    the cursor's head has to be written, None when it stands."""
    size = st.st_size
    if cur is not None:
        _, inode, head_len, head_sha, offset, _, _, _, _ = cur
        if inode == st.st_ino and size > offset:
            if sha_head(f, min(head_len or 0, size)) == head_sha:
                return "resume", offset, None
        return "reparse", 0, (min(HEAD_BYTES, size), sha_head(f, min(HEAD_BYTES, size)))
    head = (min(HEAD_BYTES, size), sha_head(f, min(HEAD_BYTES, size)))
    if st.st_mtime < since_epoch:
        # A transcript untouched since before the marker cannot hold a record
        # after it, so first contact stays cheap over an existing corpus.
        return "preexisting", size, head
    first = first_timestamp(f)
    if first is None or first < since_epoch:
        return "preexisting", size, head
    return "parse", 0, head


def first_timestamp(f):
    f.seek(0)
    for line in f.read(FIRST_TS_BYTES).split(b"\n"):
        if b'"timestamp"' not in line:
            continue
        try:
            rec = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue
        if isinstance(rec, dict):
            at = parse_iso(rec.get("timestamp"))
            if at is not None:
                return at
    return None


def next_close_seq(db):
    seq = meta_get(db, "close_counter") + 1
    meta_set(db, "close_counter", seq)
    return seq


def close_segment(db, segment_id, trigger, compact=None):
    row = db.execute(
        "SELECT closed_seq FROM segment WHERE id=?", (segment_id,)
    ).fetchone()
    if row is None or row[0] is not None:
        return
    fields = "closed_seq=?, close_trigger=?"
    values = [next_close_seq(db), trigger]
    if compact is not None:
        fields += (
            ", compact_trigger=?, pre_tokens=?, post_tokens=?, "
            "dropped_tokens=?, compact_ms=?"
        )
        values += [
            str(compact.get("trigger") or "unknown"),
            num(compact.get("preTokens")),
            num(compact.get("postTokens")),
            # The boundary's own figure, which counts everything dropped in this
            # transcript so far. Differencing it is the review's job.
            num(compact.get("cumulativeDroppedTokens")),
            num(compact.get("durationMs")),
        ]
    values.append(segment_id)
    db.execute("UPDATE segment SET " + fields + " WHERE id=?", values)


def purge(db, segment_ids):
    """Everything a segment owns, so a rebuild starts from nothing."""
    tables = [table for _, table, _, _, _, _ in CHILD_TABLES] + ["retro_line"]
    for segment_id in segment_ids:
        for table in tables:
            db.execute("DELETE FROM %s WHERE segment_id=?" % table, (segment_id,))
        db.execute("DELETE FROM segment WHERE id=?", (segment_id,))


def rewind_agents(db, segment_ids):
    """An agent cursor records the segment that last fenced it and the offset at
    which that segment first found it, so rebuilding the segment reads the same
    spans again exactly once. Agents fenced by a closed segment stay put."""
    for segment_id in segment_ids:
        db.execute(
            'UPDATE cursor SET "offset"=base_offset WHERE agent_id IS NOT NULL '
            "AND segment_id=? AND base_offset IS NOT NULL",
            (segment_id,),
        )


def write_bucket(db, segment_id, bucket, session, project, ordinal, compact=None):
    if not bucket.touched and compact is None:
        return
    scalars = bucket.scalars
    columns = [
        "id",
        "session_id",
        "project",
        "repo",
        "ordinal",
        "started_at",
        "ended_at",
        "cli_version",
        "branch",
    ] + list(scalars)
    values = [
        segment_id,
        session,
        project,
        bucket.repo,
        ordinal,
        bucket.started_at,
        bucket.ended_at,
        bucket.version,
        bucket.branch,
    ] + [scalars[k] for k in scalars]
    sets = [
        "started_at=IFNULL(segment.started_at, excluded.started_at)",
        "ended_at=NULLIF(MAX(IFNULL(segment.ended_at,''), IFNULL(excluded.ended_at,'')),'')",
        "cli_version=IFNULL(excluded.cli_version, segment.cli_version)",
        "branch=IFNULL(excluded.branch, segment.branch)",
        "repo=IFNULL(segment.repo, excluded.repo)",
        "turn_ms_max=MAX(segment.turn_ms_max, excluded.turn_ms_max)",
    ] + ["%s=segment.%s+excluded.%s" % (c, c, c) for c in scalars if c != "turn_ms_max"]
    db.execute(
        "INSERT INTO segment(%s) VALUES(%s) ON CONFLICT(id) DO UPDATE SET %s"
        % (",".join(columns), ",".join("?" * len(columns)), ",".join(sets)),
        values,
    )
    for attr, table, keys, sums, maxes, target in CHILD_TABLES:
        for key, values in getattr(bucket, attr).items():
            upsert(
                db,
                table,
                ("segment_id",) + keys,
                sums,
                maxes,
                (segment_id,) + key + tuple(values),
                target,
            )
    for uuid, author, text, at in bucket.retro:
        db.execute(
            "INSERT OR IGNORE INTO retro_line(source_uuid, segment_id, author, text, at) "
            "VALUES(?,?,?,?,?)",
            (uuid, segment_id, author, text, at),
        )
    if compact is not None:
        close_segment(db, segment_id, "compact", compact)


def fold_fence(db, session_path, segment_id, bucket, agent_id, status):
    """One fence opens exactly one file, by name. Nothing is globbed, so an agent
    still running is never opened — nothing points at it until it stops."""
    if not AGENT_ID.match(agent_id):
        return
    base = os.path.join(os.path.splitext(session_path)[0], "subagents")
    meta = read_json(os.path.join(base, "agent-%s.meta.json" % agent_id))
    path = os.path.join(base, "agent-%s.jsonl" % agent_id)
    try:
        st = os.stat(path)
    except OSError:
        # No transcript and no meta file is a background command, not an agent.
        if meta is not None:
            bucket.scalars["agent_fences_lost"] += 1
        return
    agent_type = meta.get("agentType") if meta else None
    agent_type = agent_type if isinstance(agent_type, str) and agent_type else "unknown"
    depth = meta.get("spawnDepth") if meta else None
    depth = (
        num(depth) if isinstance(depth, int) and not isinstance(depth, bool) else None
    )

    cur = get_cursor(db, path)
    start, base_offset, head = 0, 0, None
    first_seen = True
    if cur is not None:
        _, inode, head_len, head_sha, offset, cur_base, _, cur_segment, _ = cur
        with open(path, "rb") as f:
            same = (
                inode == st.st_ino
                and sha_head(f, min(head_len or 0, st.st_size)) == head_sha
            )
        if same and st.st_size >= offset:
            head = (head_len, head_sha)
            start = offset
            # base_offset is the offset at which this segment first found this
            # agent, so rebuilding the segment reads the same span again.
            if cur_segment == segment_id:
                base_offset = cur_base if cur_base is not None else offset
                first_seen = offset == base_offset
            else:
                base_offset = offset
    if head is None:
        with open(path, "rb") as f:
            head = (
                min(HEAD_BYTES, st.st_size),
                sha_head(f, min(HEAD_BYTES, st.st_size)),
            )

    span = Span()
    consumed = start
    with open(path, "rb") as f:
        for line, at in read_lines(f, start):
            consumed = at
            rec = parse_record(line)
            if rec is None:
                if line.strip():
                    span.malformed += 1
                continue
            # A nested agent's fence reaches the root session transcript, not
            # this one, so a fence here would be a second delivery of a stop the
            # root already counted.
            feed(span, rec, False)
    put_cursor(
        db,
        path,
        (
            agent_id,
            st.st_ino,
            head[0],
            head[1],
            consumed,
            base_offset,
            None,
            segment_id,
            span.last_ts,
        ),
    )
    if consumed <= start:
        # A repeat delivery of the same notification. Nothing is added and no
        # stop is counted.
        return
    bucket.absorb_agent(span, agent_type, status, depth, first_seen)


def parse_record(line):
    try:
        rec = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return None
    return rec if isinstance(rec, dict) else None


def sweep_transcript(db, path, project, since_epoch):
    st = os.stat(path)
    if not stat.S_ISREG(st.st_mode):
        return
    cur = get_cursor(db, path)
    if unchanged(st, cur):
        return
    session = os.path.splitext(os.path.basename(path))[0]
    with open(path, "rb") as f:
        mode, start, head = plan(f, st, cur, since_epoch)
        db.execute("BEGIN IMMEDIATE")
        try:
            ordinal = (cur[6] or 0) if cur is not None and mode == "resume" else 0
            if mode == "preexisting":
                put_cursor(
                    db,
                    path,
                    (
                        None,
                        st.st_ino,
                        head[0],
                        head[1],
                        st.st_size,
                        None,
                        0,
                        None,
                        None,
                    ),
                )
                db.execute("COMMIT")
                return
            closed = {
                row[0]
                for row in db.execute(
                    "SELECT id FROM segment WHERE session_id=? AND closed_seq IS NOT NULL",
                    (session,),
                )
            }
            if mode == "reparse":
                open_ids = [
                    row[0]
                    for row in db.execute(
                        "SELECT id FROM segment WHERE session_id=? AND closed_seq IS NULL",
                        (session,),
                    )
                ]
                purge(db, open_ids)
                rewind_agents(db, open_ids)
            consumed = scan_session(
                db, f, path, session, project, start, ordinal, closed
            )
            last_ts, ordinal, segment_id = consumed[1:]
            put_cursor(
                db,
                path,
                (
                    None,
                    st.st_ino,
                    head[0] if head else cur[2],
                    head[1] if head else cur[3],
                    consumed[0],
                    None,
                    ordinal,
                    segment_id,
                    last_ts or (cur[8] if cur is not None else None),
                ),
            )
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            raise


def scan_session(db, f, path, session, project, start, ordinal, closed):
    """Consume a span of a session transcript. Returns (offset, last timestamp,
    ordinal, open segment id)."""
    consumed = start
    last_ts = None
    segment_id = "%s#%d" % (session, ordinal)
    active = segment_id not in closed
    span, bucket = Span(), Bucket()
    for line, at in read_lines(f, start):
        consumed = at
        rec = parse_record(line)
        if rec is None:
            if line.strip():
                span.malformed += 1
            continue
        event = feed(span, rec, True)
        if span.last_ts and (last_ts is None or span.last_ts > last_ts):
            last_ts = span.last_ts
        if event is None:
            continue
        if event[0] == "boundary":
            if active:
                bucket.absorb_main(span)
                write_bucket(
                    db, segment_id, bucket, session, project, ordinal, event[1]
                )
            ordinal += 1
            segment_id = "%s#%d" % (session, ordinal)
            active = segment_id not in closed
            span, bucket = Span(), Bucket()
        elif active:
            try:
                fold_fence(db, path, segment_id, bucket, event[1], event[2])
            except Exception:
                # One agent transcript that will not read costs its own fence,
                # not the session file it was named in. Nothing is written for
                # it, so the count is what says the figure is short.
                bucket.scalars["agent_fences_lost"] += 1
    if active:
        bucket.absorb_main(span)
        write_bucket(db, segment_id, bucket, session, project, ordinal)
    # A segment closed by idle leaves its id behind: the records that follow it
    # belong to a new one, or a reviewed segment would gain rows after the fact.
    while segment_id in closed:
        ordinal += 1
        segment_id = "%s#%d" % (session, ordinal)
    return consumed, last_ts, ordinal, segment_id


def close_stale(db, now):
    rows = db.execute(
        "SELECT path, segment_id, ordinal FROM cursor WHERE agent_id IS NULL"
    ).fetchall()
    for path, segment_id, ordinal in rows:
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            db.execute("BEGIN IMMEDIATE")
            try:
                if segment_id:
                    close_segment(db, segment_id, "gone")
                db.execute("DELETE FROM cursor WHERE path=?", (path,))
                db.execute("COMMIT")
            except Exception:
                db.execute("ROLLBACK")
            continue
        if not segment_id or now - mtime < IDLE_SECONDS:
            continue
        db.execute("BEGIN IMMEDIATE")
        try:
            row = db.execute(
                "SELECT closed_seq FROM segment WHERE id=?", (segment_id,)
            ).fetchone()
            if row is not None and row[0] is None:
                close_segment(db, segment_id, "idle")
                db.execute(
                    "UPDATE cursor SET ordinal=?, segment_id=? WHERE path=?",
                    (
                        (ordinal or 0) + 1,
                        "%s#%d" % (segment_id.rsplit("#", 1)[0], (ordinal or 0) + 1),
                        path,
                    ),
                )
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")


def sweep(db, since_epoch):
    try:
        projects = sorted(os.listdir(PROJECTS))
    except OSError:
        projects = []
    for project in projects:
        directory = os.path.join(PROJECTS, project)
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            # Depth 1 only: session transcripts and nothing else. A subagent
            # transcript is reached by name, from a fence.
            if not name.endswith(".jsonl"):
                continue
            try:
                sweep_transcript(
                    db, os.path.join(directory, name), project, since_epoch
                )
            except Exception:
                continue
    close_stale(db, time.time())


# ── record ───────────────────────────────────────────────────────────────────


def lock_held():
    """True when another sweep owns the lock. A lock older than ten minutes, or
    one whose process is gone, is stolen."""
    try:
        age = time.time() - os.path.getmtime(LOCK_PATH)
        with open(LOCK_PATH) as f:
            pid = f.read().strip()
    except OSError:
        return False
    if age > LOCK_STALE_SECONDS:
        return False
    return bool(pid) and pid.isdigit() and os.path.exists("/proc/%s" % pid)


def take_lock():
    for _ in (0, 1):
        try:
            fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            if lock_held():
                return False
            try:
                os.unlink(LOCK_PATH)
            except OSError:
                return False
            continue
        except OSError:
            return False
        try:
            os.write(fd, str(os.getpid()).encode())
        finally:
            os.close(fd)
        return True
    return False


def read_since():
    """(epoch, fresh). A missing marker is written as now and that run records
    nothing — a missing marker must never become a backfill."""
    try:
        with open(SINCE_PATH) as f:
            at = parse_iso(f.read().strip())
        if at is not None:
            return at, False
    except OSError:
        pass
    try:
        os.makedirs(STORE, exist_ok=True)
        with open(SINCE_PATH, "w") as f:
            f.write(now_iso() + "\n")
    except OSError:
        pass
    return None, True


def touch(path):
    try:
        with open(path, "a"):
            pass
        os.utime(path, None)
    except OSError:
        pass


def drain_stdin():
    """A large hook payload must not block the writer, and nothing in it is
    read: the transcripts are the source."""
    try:
        if sys.stdin is None or sys.stdin.isatty():
            return
        while sys.stdin.buffer.read(CHUNK):
            pass
    except Exception:
        pass


def record(args):
    interval = 0
    if "--interval" in args:
        try:
            interval = int(args[args.index("--interval") + 1])
        except (IndexError, ValueError):
            interval = 0
    if interval > 0:
        try:
            if time.time() - os.path.getmtime(SWEPT_PATH) < interval:
                return 0
        except OSError:
            pass
    drain_stdin()
    try:
        # The lock lives in the store, so the store has to exist before anyone
        # can hold it. install.sh creates it too; neither may depend on the other.
        os.makedirs(STORE, exist_ok=True)
    except OSError:
        return 0
    if not take_lock():
        return 0
    try:
        since_epoch, fresh = read_since()
        db = open_store()
        if db is not None and not fresh:
            try:
                sweep(db, since_epoch)
            finally:
                db.close()
        elif db is not None:
            db.close()
        touch(SWEPT_PATH)
    finally:
        try:
            os.unlink(LOCK_PATH)
        except OSError:
            pass
    return 0


# ── review ───────────────────────────────────────────────────────────────────


def table(out, title, headers, rows):
    if title:
        out.append(title)
    if not rows:
        out.append("    (none)")
        return
    body = [[("" if c is None else str(c)) for c in row] for row in rows]
    widths = [
        max(len(headers[i]), max(len(r[i]) for r in body)) for i in range(len(headers))
    ]
    numeric = [
        all(r[i].replace("-", "").isdigit() or r[i] == "" for r in body)
        for i in range(len(headers))
    ]

    def line(cells):
        return (
            "    "
            + "  ".join(
                cells[i].rjust(widths[i]) if numeric[i] else cells[i].ljust(widths[i])
                for i in range(len(headers))
            ).rstrip()
        )

    out.append(line(headers))
    for row in body:
        out.append(line(row))


def grouped(db, sql, params=()):
    return db.execute(sql, params).fetchall()


def short(project, keep=30):
    """A project is the whole cwd with its slashes flattened, which is 80
    columns of prefix and a few of difference. The tail is the part that
    distinguishes them, so that is the end kept."""
    text = str(project or "")
    return text if len(text) <= keep else "…" + text[-keep:]


def with_short(rows, column=0):
    return [r[:column] + (short(r[column]),) + r[column + 1 :] for r in rows]


def digest(db, everything):
    through = meta_get(db, "reviewed_through")
    where = "closed_seq IS NOT NULL" + (
        "" if everything else " AND closed_seq > %d" % through
    )
    db.execute("CREATE TEMP VIEW win AS SELECT * FROM segment WHERE " + where)
    out = []
    counts = db.execute(
        "SELECT count(*), count(DISTINCT project), MIN(started_at), MAX(ended_at), "
        "MAX(closed_seq) FROM win"
    ).fetchone()
    if not counts or not counts[0]:
        return ["Retro: no closed segments to review."]
    segments, projects, first, last, highest = counts
    out.append("Window")
    out.append(
        "    segments %d · projects %d · %s → %s"
        % (segments, projects, (first or "?")[:10], (last or "?")[:10])
    )
    out.append(
        "    reviewed_through %d; accepting this digest advances it to %d"
        % (through, highest)
    )
    # What the recorder could not read. Silent, these would make a figure look
    # smaller than it is with nothing to say why.
    short_of = db.execute(
        "SELECT SUM(malformed_lines), SUM(agent_fences_lost) FROM win"
    ).fetchone()
    parts = []
    if short_of and short_of[0]:
        parts.append("%d lines would not parse" % short_of[0])
    if short_of and short_of[1]:
        parts.append("%d agent stops had no transcript" % short_of[1])
    if parts:
        out.append("    incomplete: " + ", ".join(parts))

    out.append("")
    out.append("Delegation")
    rows = grouped(
        db,
        """
        SELECT w.project,
               CASE WHEN t.agent='' THEN 'session' ELSE 'agents' END AS scope,
               SUM(t.n), COUNT(DISTINCT t.segment_id), COUNT(DISTINCT w.project),
               SUM(CASE WHEN t.tool='Edit' THEN t.n ELSE 0 END),
               SUM(CASE WHEN t.tool='Write' THEN t.n ELSE 0 END),
               SUM(CASE WHEN t.tool='Bash' THEN t.n ELSE 0 END)
        FROM tool_use t JOIN win w ON w.id=t.segment_id
        WHERE t.tool IN ('Edit','Write','Bash')
        GROUP BY w.project, scope ORDER BY w.project, scope DESC""",
    )
    table(
        out,
        None,
        ["project", "scope", "n", "segments", "projects", "Edit", "Write", "Bash"],
        with_short(rows),
    )
    edited = grouped(
        db,
        """
        SELECT w.project, COUNT(DISTINCT w.id),
               COUNT(DISTINCT CASE WHEN t.segment_id IS NOT NULL THEN w.id END)
        FROM win w LEFT JOIN tool_use t
          ON t.segment_id=w.id AND t.agent='' AND t.tool IN ('Edit','Write')
        GROUP BY w.project ORDER BY w.project""",
    )
    for project, total, with_edits in edited:
        out.append(
            "    %s — segments with main-chain edits: %d of %d"
            % (short(project), with_edits, total)
        )

    out.append("")
    rows = grouped(
        db,
        """
        SELECT a.agent_type, a.status, IFNULL(a.spawn_depth,-1), SUM(a.n),
               COUNT(DISTINCT a.segment_id), COUNT(DISTINCT w.project), SUM(a.agents),
               SUM(a.tokens_in+a.tokens_out+a.cache_read+a.cache_create),
               SUM(a.tool_uses), SUM(a.ms_total)/1000, MAX(a.ms_max)/1000
        FROM agent_run a JOIN win w ON w.id=a.segment_id
        GROUP BY a.agent_type, a.status, IFNULL(a.spawn_depth,-1)
        ORDER BY SUM(a.n) DESC""",
    )
    table(
        out,
        "Agents",
        [
            "type",
            "status",
            "depth",
            "n",
            "segments",
            "projects",
            "agents",
            "tokens",
            "tool uses",
            "s total",
            "s max",
        ],
        rows,
    )
    nested = [r for r in rows if r[2] > 1]
    if nested:
        out.append(
            "    nested: "
            + ", ".join("%s at depth %d (%d)" % (r[0], r[2], r[3]) for r in nested)
        )

    out.append("")
    rows = grouped(
        db,
        """
        SELECT d.kind, d.signature,
               CASE WHEN d.agent='' THEN 'session' ELSE 'agent' END,
               SUM(d.n), COUNT(DISTINCT d.segment_id), COUNT(DISTINCT w.project)
        FROM denial d JOIN win w ON w.id=d.segment_id
        GROUP BY d.kind, d.signature, 3 ORDER BY 6 DESC, 4 DESC LIMIT %d"""
        % TOP_ROWS,
    )
    table(
        out,
        "Permission friction",
        ["kind", "signature", "who", "n", "segments", "projects"],
        rows,
    )

    out.append("")
    rows = grouped(
        db,
        """
        SELECT t.tool, CASE WHEN t.agent='' THEN 'session' ELSE 'agents' END,
               SUM(t.n), COUNT(DISTINCT t.segment_id), COUNT(DISTINCT w.project), SUM(t.errors)
        FROM tool_use t JOIN win w ON w.id=t.segment_id
        GROUP BY t.tool, 2 ORDER BY 3 DESC LIMIT %d"""
        % TOP_ROWS,
    )
    table(out, "Tools", ["tool", "who", "n", "segments", "projects", "errors"], rows)
    rows = grouped(
        db,
        """
        SELECT b.verb, CASE WHEN b.agent='' THEN 'session' ELSE 'agents' END,
               SUM(b.n), COUNT(DISTINCT b.segment_id), COUNT(DISTINCT w.project), SUM(b.errors)
        FROM bash_verb b JOIN win w ON w.id=b.segment_id
        GROUP BY b.verb, 2 ORDER BY 3 DESC LIMIT %d"""
        % TOP_ROWS,
    )
    out.append("")
    table(
        out, "Bash verbs", ["verb", "who", "n", "segments", "projects", "errors"], rows
    )

    out.append("")
    rows = grouped(
        db,
        """
        SELECT s.skill, SUM(s.n), COUNT(DISTINCT s.segment_id), COUNT(DISTINCT w.project)
        FROM skill_use s JOIN win w ON w.id=s.segment_id
        GROUP BY s.skill ORDER BY 2 DESC""",
    )
    table(out, "Skills", ["skill", "n", "segments", "projects"], rows)
    seen = {r[0] for r in rows}
    try:
        installed = sorted(n for n in os.listdir(SKILLS) if not n.startswith("."))
    except OSError:
        installed = []
    unused = [n for n in installed if n not in seen]
    if unused:
        out.append("    never fired: " + ", ".join(unused))

    out.append("")
    rows = grouped(
        db,
        """
        SELECT IFNULL(compact_trigger,'?'), COUNT(*), COUNT(DISTINCT project),
               SUM(dropped_tokens), SUM(compact_ms)/1000, MAX(compact_ms)/1000
        FROM win WHERE close_trigger='compact'
        GROUP BY 1 ORDER BY 2 DESC""",
    )
    table(
        out,
        "Compaction",
        ["trigger", "n", "projects", "dropped (cumulative)", "s total", "s max"],
        rows,
    )

    out.append("")
    rows = grouped(
        db,
        """
        SELECT h.hook, SUM(h.n), COUNT(DISTINCT h.segment_id), COUNT(DISTINCT w.project),
               SUM(h.errors), MAX(h.ms_max)
        FROM hook_run h JOIN win w ON w.id=h.segment_id
        GROUP BY h.hook ORDER BY 2 DESC LIMIT %d"""
        % TOP_ROWS,
    )
    table(out, "Hooks", ["hook", "n", "segments", "projects", "errors", "ms max"], rows)

    out.append("")
    rows = grouped(
        db,
        """
        SELECT r.author, w.project, substr(IFNULL(r.at,''),1,10), r.text
        FROM retro_line r JOIN win w ON w.id=r.segment_id
        WHERE r.text IS NOT NULL ORDER BY r.at""",
    )
    table(
        out, "Retro lines", ["author", "project", "date", "line"], with_short(rows, 1)
    )
    nones = db.execute(
        "SELECT count(*) FROM retro_line r JOIN win w ON w.id=r.segment_id "
        "WHERE r.text IS NULL"
    ).fetchone()[0]
    out.append("    answered none: %d" % nones)
    return out


def review(args):
    db = open_store(create=False)
    if db is None:
        sys.stderr.write("retro: no store at %s\n" % DB_PATH)
        return 1
    try:
        if "--accept" in args:
            try:
                seq = int(args[args.index("--accept") + 1])
            except (IndexError, ValueError):
                sys.stderr.write("retro: --accept needs a closed_seq\n")
                return 2
            meta_set(db, "reviewed_through", seq)
            sys.stdout.write("reviewed_through = %d\n" % seq)
            return 0
        try:
            for line in digest(db, "--all" in args):
                sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            # `review | head` is a normal way to read this. Point the stream at
            # nothing so the interpreter's own shutdown flush cannot raise again
            # where no guard is left to catch it.
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    finally:
        db.close()


def main(argv):
    if argv and argv[0] == "record":
        try:
            return record(argv[1:])
        except Exception:
            return 0
    if argv and argv[0] == "review":
        return review(argv[1:])
    sys.stderr.write(
        "usage: retro.py record [--interval N] | review [--all] [--accept N]\n"
    )
    return 2


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    sys.exit(main(sys.argv[1:]))
