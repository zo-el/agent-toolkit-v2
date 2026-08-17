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

Contract: documentation/specs/retro.md. Three mechanisms here differ from the
one it describes, each because the spec's own acceptance criteria could not hold
otherwise, and each named at the code that does it: a session cursor's
`base_offset` rather than an agent's, a rebuild that keeps an agent's rows
instead of rewinding to re-read them, and a verb split that respects quoting.
"""

import hashlib
import json
import os
import re
import select
import shlex
import stat
import sys
import time
from collections import namedtuple
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
PROJECTS = os.path.join(CLAUDE, "projects")
SKILLS = os.path.join(CLAUDE, "skills")
STORE = os.path.join(CLAUDE, "retro")
DB_PATH = os.path.join(STORE, "retro.db")
SINCE_PATH = os.path.join(STORE, "since")
SWEPT_PATH = os.path.join(STORE, "last-sweep")
LOCK_PATH = os.path.join(STORE, "sweep.lock")

SCHEMA_VERSION = 2
HEAD_BYTES = 4096
FIRST_TS_BYTES = 64 * 1024
CHUNK = 1 << 20
DRAIN_SECONDS = 0.5
DRAIN_BYTES = 4 << 20
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
  last_ts TEXT,
  last_message TEXT,
  last_skill TEXT);

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

CREATE TABLE IF NOT EXISTS retro_line(
  source_uuid TEXT PRIMARY KEY,
  segment_id TEXT, author TEXT, text TEXT, at TEXT);
"""

# The deliberate exception to "no command arguments": a permission prompt cannot
# be recognised as recurring without knowing which command it was. `git push` is
# a different question from `git log`, and only the second word says which.
#
# Written out rather than matched, because a pattern admits whatever the user
# typed: `python3 migrate_prod_secrets.py` and `make deploy-acme` are a filename
# and a target, which are theirs. The only second word that can never be one is
# a word this file already contains. A subcommand missing from a list below
# costs the pair and keeps the driver, which is a figure that reads low rather
# than one that leaks.
SUBCOMMANDS = {
    "git": frozenset(
        (
            "add",
            "am",
            "apply",
            "archive",
            "bisect",
            "blame",
            "branch",
            "checkout",
            "cherry-pick",
            "clean",
            "clone",
            "commit",
            "config",
            "describe",
            "diff",
            "fetch",
            "fsck",
            "gc",
            "grep",
            "init",
            "log",
            "ls-files",
            "ls-remote",
            "merge",
            "mv",
            "notes",
            "pull",
            "push",
            "rebase",
            "reflog",
            "remote",
            "reset",
            "restore",
            "revert",
            "rev-list",
            "rev-parse",
            "rm",
            "shortlog",
            "show",
            "stash",
            "status",
            "submodule",
            "switch",
            "tag",
            "worktree",
        )
    ),
    "gh": frozenset(
        (
            "api",
            "auth",
            "browse",
            "cache",
            "codespace",
            "extension",
            "gist",
            "issue",
            "label",
            "org",
            "pr",
            "project",
            "release",
            "repo",
            "ruleset",
            "run",
            "search",
            "secret",
            "status",
            "variable",
            "workflow",
        )
    ),
    "npm": frozenset(
        (
            "audit",
            "cache",
            "ci",
            "config",
            "dedupe",
            "exec",
            "init",
            "install",
            "link",
            "login",
            "ls",
            "outdated",
            "pack",
            "publish",
            "run",
            "start",
            "test",
            "uninstall",
            "update",
            "version",
            "view",
            "whoami",
        )
    ),
    "cargo": frozenset(
        (
            "add",
            "bench",
            "build",
            "check",
            "clean",
            "clippy",
            "doc",
            "fetch",
            "fmt",
            "install",
            "new",
            "publish",
            "remove",
            "run",
            "test",
            "tree",
            "update",
            "vendor",
        )
    ),
    "docker": frozenset(
        (
            "build",
            "compose",
            "cp",
            "exec",
            "images",
            "inspect",
            "kill",
            "load",
            "login",
            "logs",
            "ps",
            "pull",
            "push",
            "restart",
            "rm",
            "rmi",
            "run",
            "save",
            "start",
            "stop",
            "tag",
            "volume",
        )
    ),
    "kubectl": frozenset(
        (
            "apply",
            "config",
            "cordon",
            "create",
            "delete",
            "describe",
            "drain",
            "edit",
            "exec",
            "get",
            "logs",
            "patch",
            "port-forward",
            "rollout",
            "scale",
            "top",
        )
    ),
    "systemctl": frozenset(
        (
            "daemon-reload",
            "disable",
            "enable",
            "is-active",
            "list-units",
            "mask",
            "reload",
            "restart",
            "start",
            "status",
            "stop",
            "unmask",
        )
    ),
    "pip": frozenset(("download", "freeze", "install", "list", "show", "uninstall")),
    "go": frozenset(
        (
            "build",
            "clean",
            "doc",
            "fmt",
            "generate",
            "get",
            "install",
            "list",
            "mod",
            "run",
            "test",
            "tool",
            "vet",
            "work",
        )
    ),
    "terraform": frozenset(
        (
            "apply",
            "destroy",
            "fmt",
            "import",
            "init",
            "output",
            "plan",
            "providers",
            "refresh",
            "show",
            "state",
            "validate",
            "workspace",
        )
    ),
    "brew": frozenset(
        (
            "cleanup",
            "doctor",
            "info",
            "install",
            "link",
            "list",
            "outdated",
            "reinstall",
            "search",
            "services",
            "tap",
            "uninstall",
            "update",
            "upgrade",
        )
    ),
    "nix": frozenset(
        (
            "build",
            "develop",
            "flake",
            "profile",
            "run",
            "shell",
            "store",
        )
    ),
    "aws": frozenset(
        (
            "cloudformation",
            "cloudwatch",
            "ec2",
            "ecr",
            "ecs",
            "iam",
            "lambda",
            "logs",
            "rds",
            "route53",
            "s3",
            "s3api",
            "secretsmanager",
            "sts",
        )
    ),
    "gcloud": frozenset(
        (
            "artifacts",
            "auth",
            "compute",
            "config",
            "container",
            "functions",
            "iam",
            "projects",
            "run",
            "secrets",
            "sql",
            "storage",
        )
    ),
}
# The same vocabulary under the names that share it.
for _driver, _alias in (
    ("npm", "pnpm"),
    ("npm", "yarn"),
    ("npm", "bun"),
    ("pip", "pip3"),
    ("kubectl", "k9s"),
):
    SUBCOMMANDS.setdefault(_alias, SUBCOMMANDS[_driver])
for _apt in ("apt", "apt-get"):
    SUBCOMMANDS[_apt] = frozenset(
        (
            "autoremove",
            "install",
            "list",
            "purge",
            "remove",
            "search",
            "show",
            "update",
            "upgrade",
        )
    )
# What follows sudo is another command, not an argument, so the drivers name
# themselves. Anything else it runs is a path the user chose.
SUBCOMMANDS["sudo"] = frozenset(SUBCOMMANDS) | frozenset(
    (
        "apt",
        "apt-get",
        "systemctl",
        "docker",
        "kubectl",
        "nix",
        "make",
        "reboot",
        "shutdown",
        "mount",
        "umount",
        "chown",
        "chmod",
        "tee",
        "sysctl",
    )
)

# Every bare command this file will name, and with SUBCOMMANDS the whole of what
# `bash_verb.verb` can ever hold. The store may name a command it already
# contains and nothing else: a first word that is not here is a path or a name
# the user chose — `./deploy_prod_secrets.sh`, `migrate_acme_payroll.py` — and
# its basename is still their filename. An unusual command losing its name costs
# resolution, which is a figure that reads low; keeping it costs the boundary
# the whole store sits inside.
COMMANDS = frozenset(
    """
    alias at awk base64 basename bats break brew bundle bzip2 cargo cat cd chgrp
    chmod chown clang clear cmake cmp code comm command composer continue convert
    cp crontab curl cut date dd declare deno df diff dig dirname dnf docker
    docker-compose dotnet dpkg du echo egrep emacs env eval exec exit export
    false ffmpeg fgrep file find flake8 flatpak g++ gcc gem getent gh git gofmt
    go gpg gradle grep gunzip gzip head helm host hostname hyperfine iconv id
    ifconfig import install ip java jest jobs join journalctl jq julia k6 keychain
    kill kotlin launchctl less ln local locale lsof ls ltrace lua make man mkdir
    mktemp mocha mongo more mount mv mvn mypy mysql nano netstat nice ninja nix
    nix-build nix-env nix-shell node nohup npm npx nslookup nvim od open openssl
    osascript paste patch php ping pip pip3 pgrep pkill playwright pnpm poetry
    printenv printf ps psql pwd pytest python python3 R rails read readlink
    realpath redis-cli rg rm rmdir rsync ruby ruff rustc rustfmt rustup sbt scala
    scp screen sed seq service set sftp sha1sum sha256sum shellcheck shfmt shift
    sleep snap sort source split ss ssh stat strace strings swift sync systemctl
    tail tar tee tempfile terraform test timeout tmux top touch tput tr trap true
    tsc type ulimit umask umount uname uniq unset unzip uv vagrant vim vitest wait
    watch wc wget whereis which whoami wmctrl xargs xdg-open xdotool xz yarn yes
    yq yum zip
    """.split()
) | frozenset(SUBCOMMANDS)  # a driver is a command before it is a driver
# A command that runs a file, where the file is not named. The two placeholders
# are what an unknown shape becomes, and both carry no name at all.
SCRIPT = "script"
OTHER = "other"
SCRIPT_LIKE = re.compile(r"\.[A-Za-z0-9]{1,10}$")

SEPARATORS = frozenset(("&&", "||", ";", ";;", "|", "|&", "&"))
# A keyword is not the command; the command is the word after it.
KEYWORDS = frozenset(
    (
        "do",
        "done",
        "then",
        "else",
        "elif",
        "fi",
        "esac",
        "while",
        "until",
        "if",
        "function",
        "time",
        "{",
        "}",
        "!",
        "[[",
        "]]",
    )
)
# These introduce a variable or a pattern rather than a command, so nothing in
# the rest of that part is a verb — and a case pattern is often a filename.
NOT_COMMANDS = frozenset(("for", "select", "case", "in"))
HOOK_LABEL = re.compile(
    r"^[A-Za-z0-9._+-]{1,64}\.(sh|bash|zsh|py|js|mjs|cjs|ts|rb|pl)$"
)
INTERPRETERS = frozenset(
    ("sh", "bash", "zsh", "dash", "env", "python", "python3", "node", "ruby", "perl")
)
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
ESCAPED_QUOTE = re.compile(r"\\+[\"']")
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
    """The moment an ISO-8601 stamp names, as a UTC epoch.

    A stamp with no zone is read as UTC rather than as local time. Transcripts
    are written in UTC and the marker is stamped in UTC, so a naive stamp is one
    whose Z was lost — and reading it locally moves the marker by up to a day in
    the direction of recording things it must never record.
    """
    if not isinstance(ts, str) or not ts:
        return None
    try:
        at = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (at if at.tzinfo else at.replace(tzinfo=timezone.utc)).timestamp()


KNOWN_VERBS = (
    COMMANDS
    | frozenset(
        "%s %s" % (driver, sub) for driver, subs in SUBCOMMANDS.items() for sub in subs
    )
    | frozenset((SCRIPT, OTHER))
)


def command_parts(command):
    """The command split into the commands it runs, quoting respected.

    Lexed with quotes left on the token, so a separator that is an argument —
    `grep -F '|' payroll.csv`, `find . -exec rm {} \\;` — cannot split the line
    and promote the filename after it to a command. Everything from a heredoc
    operator on is dropped outright: that is a file being written, not a command
    line, and its contents are not ours to read.

    A newline is not a separator here, so only the first command of a multi-line
    script is recorded. Splitting on one would take every line of a multi-line
    quoted argument for a command of its own, which puts source code in the
    store — and an undercounted verb costs less than that.
    """
    cut = command.find("<<")
    if cut >= 0:
        command = command[:cut]
    if ESCAPED_QUOTE.search(command):
        # A quote escaped inside a quoted string — `grep -nE "a|[\\"x\\"]|b"` —
        # is one thing a lexer without a shell's grammar cannot follow: it takes
        # the escaped quote for a real one and every fragment after it for a
        # word of its own. Those fragments are argument text, so a command
        # holding one is not normalised at all.
        raise ValueError("escaped quote")
    lexer = shlex.shlex(command, posix=False, punctuation_chars=True)
    lexer.whitespace_split = True
    parts, current, escaped, pattern = [], [], False, False
    for token in lexer:
        if pattern:
            # A `case` arm: what follows `;;` is a pattern to match, not a
            # command, and a pattern is often a filename.
            pattern = token != ")"
            continue
        if token == "\\":
            escaped = True
            continue
        if token in SEPARATORS and not escaped:
            parts.append(current)
            current = []
            pattern = token == ";;"
            if len(parts) >= VERB_PARTS:
                return parts[:VERB_PARTS]
            continue
        escaped = False
        current.append(token)
    parts.append(current)
    return parts[:VERB_PARTS]


def unquote(token):
    return token.strip("'\"")


def bash_verbs(command):
    """Every verb a Bash command runs, normalised. `git push`, `npm install`,
    `cargo test` — a driver keeps its subcommand, because the driver alone
    cannot tell a read from a publish."""
    if not isinstance(command, str) or not command.strip():
        return []
    try:
        parts = command_parts(command)
    except ValueError:
        # An unbalanced quote: nothing about this line can be tokenised, so
        # nothing about it can be normalised safely either.
        return [OTHER]
    verbs = []
    for tokens in parts:
        while tokens and (ASSIGNMENT.match(tokens[0]) or tokens[0] in KEYWORDS):
            tokens.pop(0)
        if not tokens or tokens[0] in NOT_COMMANDS:
            continue
        if tokens[1:2] == ["()"] or tokens[1:3] == ["(", ")"]:
            # A function being defined, not a command being run.
            continue
        first = unquote(tokens[0])
        head = os.path.basename(first.rstrip("/")) or first
        if head not in COMMANDS:
            # Whatever this is, its name is the user's. Saying which of the two
            # it looked like is all that is kept: a file they ran, or a shape
            # this file does not recognise.
            verbs.append(SCRIPT if "/" in first or SCRIPT_LIKE.search(head) else OTHER)
            continue
        verb = head
        if head in SUBCOMMANDS and len(tokens) > 1:
            # The subcommand is the very next word, and only when it is one this
            # file names. A bare word further along is a flag's value — `git -C
            # <repo>`, `kubectl -n <namespace>` — and a word that is not in the
            # list is a filename or a target, which are arguments. Either is the
            # one thing a verb may never carry.
            second = unquote(tokens[1])
            if second in SUBCOMMANDS[head]:
                verb = head + " " + second
        verbs.append(verb)
    return verbs


def script_name(token):
    """The script a token names, or None when it does not name one."""
    label = token.rstrip("/").rsplit("/", 1)[-1].strip("\"'`,;:()[]")
    return label if "/" in token and HOOK_LABEL.match(label) else None


def hook_label(command):
    """A label for a hook, from the only place a command names its script: the
    word it starts with, or the word after the interpreter that runs it.

    `hookInfos[].command` is not always a command — in this store it sometimes
    carries the user's prompt — and any rule that searches the whole string will
    find the script a prompt happens to mention. A prompt does not begin with a
    script path; a hook command always does. The cost is a hook invoked as a
    bare executable, which reads as `unknown`.
    """
    tokens = str(command or "").split()
    if tokens and unquote(tokens[0]).rsplit("/", 1)[-1] in INTERPRETERS:
        tokens = tokens[1:]
    return (script_name(tokens[0]) if tokens else None) or "unknown"


def hook_error_label(message):
    """The hook a runner's error message names. Unlike a command this is
    machine-written, so the path can be anywhere in it."""
    for token in sorted(str(message or "").split(), key=len, reverse=True):
        label = script_name(token)
        if label:
            return label
    return "unknown"


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
        # An index rather than a re-slice per line: a transcript is tens of
        # thousands of lines and re-slicing the buffer for each is quadratic.
        at = 0
        while True:
            cut = buf.find(b"\n", at)
            if cut < 0:
                break
            consumed += cut + 1 - at
            yield buf[at:cut], consumed
            at = cut + 1
        buf = buf[at:]


def last_newline(f, size):
    """The offset just past the last complete line at or before `size`. A cursor
    always sits on a newline, so parking one mid-record would make the next
    sweep read the tail of that record as a line of its own.

    Searches backwards a chunk at a time, and gives up at `size` rather than at
    0: this parks a cursor that must never be rewound, and answering 0 for a
    file whose last record is simply longer than one chunk would read the whole
    thing from the start — the backfill the marker exists to prevent.
    """
    at = size
    while at > 0:
        window = min(at, CHUNK)
        f.seek(at - window)
        cut = f.read(window).rfind(b"\n")
        if cut >= 0:
            return at - window + cut + 1
        at -= window
    return 0 if size == 0 else size


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
                db.executescript(child_ddl())
                db.execute("PRAGMA user_version=%d" % SCHEMA_VERSION)
            elif version != SCHEMA_VERSION:
                db.close()
                return None
            db.execute("SELECT count(*) FROM segment").fetchone()
            return db
        except Exception as failure:
            if db is not None:
                try:
                    db.close()
                except Exception:
                    pass
            # Only a file that is not a database is moved aside. A store that
            # cannot be opened — no permission, no space, a filesystem that will
            # not do WAL — is a healthy store behind a temporary problem, and
            # quarantining it would throw away the record that outlives every
            # transcript.
            corrupt = isinstance(failure, sqlite3.DatabaseError) and not isinstance(
                failure, sqlite3.OperationalError
            )
            if attempt or not create or not corrupt:
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


# The segment's own counters, once: the accumulator, the write and the clearing
# a rebuild does all read this list.
# What a segment says about itself rather than counts. Every one is written with
# IFNULL, so a rebuild blanks them or the replaced file's answer outlives it.
SEGMENT_DERIVED = ("repo", "started_at", "ended_at", "cli_version", "branch")

# What a segment counts. A sweep adds to these, so a rebuild zeroes them; a new
# counter belongs here and a new description belongs above.
SEGMENT_SCALARS = (
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


# Every key column holds text but this one, which holds a number or nothing.
# SQLite's affinity is not decoration: text affinity would store the depth as
# "2" and IFNULL(spawn_depth, -1) would stop comparing.
INTEGER_KEYS = frozenset(("spawn_depth",))


def child_ddl():
    """The child tables, from the one place that describes them.

    Written out beside CHILD_TABLES instead, the two would have to agree by eye,
    and a column added to one and not the other fails at the first write rather
    than at review.
    """
    statements = []
    for _, table, keys, sums, maxes, target in CHILD_TABLES:
        columns = ["segment_id TEXT"]
        columns += [
            "%s %s" % (key, "INTEGER" if key in INTEGER_KEYS else "TEXT")
            for key in keys
        ]
        columns += [
            "%s INTEGER NOT NULL DEFAULT 0" % column
            for column in tuple(sums) + tuple(maxes)
        ]
        if target:
            # A key with a NULL in it: SQLite holds NULLs distinct in a unique
            # index, so the target coalesces and the table carries no primary
            # key of its own.
            statements.append(
                "CREATE TABLE IF NOT EXISTS %s(%s);" % (table, ", ".join(columns))
            )
            statements.append(
                "CREATE UNIQUE INDEX IF NOT EXISTS %s_key ON %s(%s);"
                % (table, table, target)
            )
        else:
            columns.append("PRIMARY KEY(segment_id, %s)" % ", ".join(keys))
            statements.append(
                "CREATE TABLE IF NOT EXISTS %s(%s);" % (table, ", ".join(columns))
            )
    return "\n".join(statements)


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
        # A message's content blocks are written as one record each, and a
        # sweep can land between two of them. Both of these carry across that
        # boundary on the cursor, or the second half of a message is summed a
        # second time and a skill still running is activated twice.
        self.messages = set()  # message ids whose usage is already summed
        self.last_message = None  # the newest of them, which the cursor keeps
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
        label = labels[0] if len(labels) == 1 else hook_error_label(error)
        bump(span.hooks, label, (0, 1, 0, 0), maxes=1)


def feed_assistant(span, rec):
    span.assistant_turns += 1
    msg = rec.get("message")
    msg = msg if isinstance(msg, dict) else {}
    usage = msg.get("usage")
    # A transcript field is whatever the writer put there, and this one is a
    # set key: anything unhashable in it would take the whole file down.
    message_id = next(
        (
            v
            for v in (msg.get("id"), rec.get("requestId"), rec.get("uuid"))
            if isinstance(v, str) and v
        ),
        None,
    )
    if isinstance(usage, dict) and message_id not in span.messages:
        # One API response is written as one record per content block, every one
        # carrying the same message id and the same usage block: summing per
        # record would roughly double every token figure.
        span.messages.add(message_id)
        span.last_message = message_id
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
    # A record with no attribution does not end the run: a skill's own turns are
    # not all attributed, and treating a gap as the end counts one activation
    # several times over.
    if current:
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
    re-deriving cannot duplicate it.

    Read from the end: the required line is the last thing an agent writes, and
    a `Retro:` earlier in the same block is something it quoted — a code fence,
    a pasted digest — rather than something it said.
    """
    if not isinstance(text, str) or "Retro" not in text:
        return
    uuid = rec.get("uuid")
    if not isinstance(uuid, str) or not uuid:
        return
    for line in reversed(text.splitlines()):
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
        self.scalars = dict.fromkeys(SEGMENT_SCALARS, 0)
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
        hook records.

        Hook records are the session's alone deliberately. `hook_run` has no
        agent column, so a rebuild clears it whole and re-derives it from the
        session file — and an agent transcript is never re-read on a rebuild, so
        anything of its own in that table could never come back.
        """
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


# The cursor row by name. Eleven fields positionally is a mistake waiting for
# the twelfth.
Cursor = namedtuple(
    "Cursor",
    "agent_id inode head_len head_sha offset base_offset ordinal segment_id"
    " last_ts last_message last_skill",
)
CURSOR_COLUMNS = ", ".join('"%s"' % f for f in Cursor._fields)


def get_cursor(db, path):
    row = db.execute(
        "SELECT %s FROM cursor WHERE path=?" % CURSOR_COLUMNS, (path,)
    ).fetchone()
    return Cursor(*row) if row else None


def put_cursor(db, path, cursor):
    columns = ", ".join(['"path"'] + ['"%s"' % f for f in Cursor._fields])
    sets = ", ".join('"%s"=excluded."%s"' % (f, f) for f in Cursor._fields)
    db.execute(
        "INSERT INTO cursor(%s) VALUES(%s) ON CONFLICT(path) DO UPDATE SET %s"
        % (columns, ",".join("?" * (len(Cursor._fields) + 1)), sets),
        (path,) + tuple(cursor),
    )


def unchanged(st, cur):
    """A transcript that has gained nothing since its cursor, decided from stat
    alone so the bulk of a corpus is never opened."""
    return cur is not None and cur.inode == st.st_ino and cur.offset == st.st_size


def same_file(f, st, cur):
    """Whether this is still the transcript the cursor was reading.

    The inode, and the head as far as it can speak. A head of no bytes hashes
    the same for every file there has ever been, so a cursor first taken of an
    empty transcript says nothing about the one at that path now; and a file
    shorter than the stored head has nothing to compare against, which under one
    inode is the rewind a rebuild exists for.
    """
    if cur.inode != st.st_ino:
        return False
    stored = cur.head_len or 0
    if stored == 0:
        return st.st_size == 0
    if st.st_size < stored:
        return True
    return sha_head(f, stored) == cur.head_sha


def head_of(f, size):
    length = min(HEAD_BYTES, size)
    return length, sha_head(f, length)


def plan(f, st, cur, since_epoch):
    """What to do with a transcript, as (mode, start, ordinal, base, head).

    `base` is the offset the open segment began at, which is what a reparse
    rewinds to. `head` is (length, sha) when the cursor's head has to be
    written, None when the stored one stands.
    """
    size = st.st_size
    if cur is not None:
        same = same_file(f, st, cur)
        # A stored head that is not the length this file would give now was
        # taken when the file was another size — smaller, or longer before a
        # rewind. Either way the next sweep has nothing it can compare, so it is
        # restated here while the file is in hand.
        fresh = (
            head_of(f, size) if (cur.head_len or 0) != min(HEAD_BYTES, size) else None
        )
        if same and size > cur.offset:
            return "resume", cur.offset, cur.ordinal or 0, cur.base_offset, fresh
        if same and cur.base_offset is not None and size >= cur.base_offset:
            # Rewound or truncated, but the same file: the open segment starts
            # where it always did, so only it is rebuilt. Closed segments are
            # never re-derived, which is what makes them immutable in fact and
            # not just by convention.
            return (
                "reparse",
                cur.base_offset,
                cur.ordinal or 0,
                cur.base_offset,
                fresh,
            )
    head = head_of(f, size)
    # An ordinal already reached is kept even when nothing here may be read: it
    # is what the records this file gains next belong to, and starting again
    # from 0 would put them in a segment that has already been closed.
    reached = (cur.ordinal or 0) if cur is not None else 0
    if cur is None and st.st_mtime < since_epoch:
        # A transcript untouched since before the marker cannot hold a record
        # after it, so first contact stays cheap over an existing corpus.
        return "preexisting", last_newline(f, size), reached, None, head
    first = first_timestamp(f)
    if first is None or first < since_epoch:
        # Everything this file holds predates the marker. That is true whether
        # this is first contact or a replaced file being reparsed: reading it
        # from the start would be the backfill the marker exists to prevent.
        return "preexisting", last_newline(f, size), reached, None, head
    return "parse", 0, 0, 0, head


def rebuilding(mode, cur):
    """A rebuild is any pass that re-reads bytes an open segment already
    counted, or replaces a file it counted from. Both have to clear what that
    segment holds first, or the second pass doubles the first."""
    return mode == "reparse" or (mode in ("parse", "preexisting") and cur is not None)


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


def drop_segments(db, segment_ids):
    """Count segments whose own counts are gone for good. A segment cleared for
    a rebuild that never reached it was derived from bytes no file holds any
    more; the delegation rows survive, and this is what says the rest did not."""
    if segment_ids:
        meta_set(
            db, "segments_dropped", meta_get(db, "segments_dropped") + len(segment_ids)
        )


def open_segments(db, session):
    return [
        row[0]
        for row in db.execute(
            "SELECT id FROM segment WHERE session_id=? AND closed_seq IS NULL",
            (session,),
        )
    ]


def clear_open(db, segment_ids):
    """Everything an open segment derived from the session transcript, so a
    rebuild starts from nothing.

    What an agent's own transcript contributed is kept: it was read from a
    different file, which has not changed, and the fences that produced it find
    no new bytes on the rebuild — so re-deriving it is impossible and deleting
    it would simply lose the delegation figures. Everything else the segment
    holds goes back to what it was before it read anything, counters and
    description alike — SEGMENT_SCALARS and SEGMENT_DERIVED say which is which.
    """
    blanked = ", ".join(
        ["%s=0" % c for c in SEGMENT_SCALARS] + ["%s=NULL" % c for c in SEGMENT_DERIVED]
    )
    for segment_id in segment_ids:
        for _, table, keys, _, _, _ in CHILD_TABLES:
            if "agent" in keys:
                db.execute(
                    "DELETE FROM %s WHERE segment_id=? AND agent=''" % table,
                    (segment_id,),
                )
            elif table != "agent_run":
                db.execute("DELETE FROM %s WHERE segment_id=?" % table, (segment_id,))
        db.execute(
            "DELETE FROM retro_line WHERE segment_id=? AND author='main'", (segment_id,)
        )
        db.execute("UPDATE segment SET " + blanked + " WHERE id=?", (segment_id,))


def write_bucket(db, segment_id, bucket, session, project, ordinal, compact=None):
    """True when the segment gained a row, which is what says a rebuild reached
    it."""
    if not bucket.touched and compact is None:
        return False
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
    return True


def fold_fence(db, session_path, segment_id, bucket, agent_id, status, rebuild):
    """One fence opens exactly one file, by name. Nothing is globbed, so an agent
    still running is never opened — nothing points at it until it stops."""
    if not AGENT_ID.match(agent_id):
        return
    base = os.path.join(os.path.splitext(session_path)[0], "subagents")
    meta_path = os.path.join(base, "agent-%s.meta.json" % agent_id)
    path = os.path.join(base, "agent-%s.jsonl" % agent_id)
    try:
        st = os.stat(path)
    except OSError:
        # A task with no transcript and no meta file is a background command,
        # not an agent. isfile rather than a parsed file, so a meta file that
        # will not read still says an agent was there.
        if os.path.isfile(meta_path):
            bucket.scalars["agent_fences_lost"] += 1
        return
    meta = read_json(meta_path)
    agent_type = meta.get("agentType") if meta else None
    agent_type = agent_type if isinstance(agent_type, str) and agent_type else "unknown"
    depth = meta.get("spawnDepth") if meta else None
    depth = depth if isinstance(depth, int) and not isinstance(depth, bool) else None

    cur = get_cursor(db, path)
    start = 0
    # An agent counts once per segment that fenced it, however many times that
    # segment stops it.
    first_seen = cur is None or cur.segment_id != segment_id
    if rebuild and not first_seen:
        # A rebuild re-delivers fences this segment already counted, and its
        # agent_run row was kept precisely because it cannot be re-derived. If
        # the agent has run on since, those bytes belong to a stop that has not
        # been fenced yet — counting them here would read as a lane that went
        # round twice.
        return
    with open(path, "rb") as f:
        # One open for the three questions a fence asks of the file: whether it
        # is still the transcript the cursor read, what its head is now, and
        # what it has gained.
        if cur is not None and same_file(f, st, cur) and st.st_size >= cur.offset:
            start = cur.offset
        head = head_of(f, st.st_size)

        span = resumed_span(cur, start > 0)
        reader = Reader(f, start, lambda: span)
        for rec in reader.records():
            # A nested agent's fence reaches the root session transcript, not
            # this one, so a fence here would be a second delivery of a stop the
            # root already counted.
            feed(span, rec, False)
        consumed = reader.at
    put_cursor(
        db,
        path,
        Cursor(
            agent_id=agent_id,
            inode=st.st_ino,
            head_len=head[0],
            head_sha=head[1],
            offset=consumed,
            base_offset=None,
            ordinal=None,
            segment_id=segment_id,
            last_ts=span.last_ts,
            last_message=span.last_message,
            last_skill=span.skill_now,
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


def resumed_span(cur, resuming):
    """A span that knows what the span before it had already counted.

    Only on a resume: a rebuild re-reads bytes from the segment's start, so it
    must sum them again rather than skip the message it stopped inside.
    """
    span = Span()
    if cur is not None and resuming:
        if cur.last_message:
            span.messages.add(cur.last_message)
            span.last_message = cur.last_message
        span.skill_now = cur.last_skill
    return span


class Reader:
    """Complete records from an offset, and the offset itself.

    The position belongs here rather than to a span because a session
    transcript's span is replaced at every boundary, while the file is read
    straight through. `current` is what hands an unparsable line to whichever
    span is counting when it turns up.
    """

    def __init__(self, f, start, current):
        self.f = f
        self.at = start
        self.current = current

    def records(self):
        """Each record that parses. One that does not is counted and skipped —
        it never costs the rest of the file — and the position still moves past
        it, so it is read once and not again."""
        for line, at in read_lines(self.f, self.at):
            self.at = at
            rec = parse_record(line)
            if rec is None:
                if line.strip():
                    self.current().malformed += 1
                continue
            yield rec


def sweep_transcript(db, path, project, since_epoch):
    st = os.stat(path)
    if not stat.S_ISREG(st.st_mode):
        return
    if unchanged(st, get_cursor(db, path)):
        return
    session = os.path.splitext(os.path.basename(path))[0]
    with open(path, "rb") as f:
        db.execute("BEGIN IMMEDIATE")
        try:
            # The cursor is read again inside the transaction, and every decision
            # taken from it. Deciding outside it lets two sweeps read the same
            # offset and consume the same span twice, which is the one error
            # that puts a wrong number in the store rather than no number.
            cur = get_cursor(db, path)
            # The size every decision below rests on, read from the handle the
            # scan itself reads: a stat taken before the transaction can
            # describe a file another sweep has already moved past.
            st = os.fstat(f.fileno())
            mode, start, ordinal, base, head = plan(f, st, cur, since_epoch)
            closed = {
                row[0]
                for row in db.execute(
                    "SELECT id FROM segment WHERE session_id=? AND closed_seq IS NOT NULL",
                    (session,),
                )
            }
            cleared = []
            if rebuilding(mode, cur):
                # Whatever the open segment held came from a span about to be
                # read again, or from a file that no longer holds it. A resume
                # adds to what is there, so it never clears.
                cleared = open_segments(db, session)
                clear_open(db, cleared)
            if mode == "preexisting":
                # Nothing here may be read, so the open segment keeps only what
                # an agent gave it. Its id stays on the cursor: parking a null
                # one would send the next append into a closed segment.
                drop_segments(db, cleared)
                put_cursor(
                    db,
                    path,
                    Cursor(
                        agent_id=None,
                        inode=st.st_ino,
                        head_len=head[0],
                        head_sha=head[1],
                        offset=start,
                        base_offset=start,
                        ordinal=ordinal,
                        segment_id=cur.segment_id if cur is not None else None,
                        last_ts=None,
                        # Nothing of this file was read, so nothing it said
                        # before carries into what it says next.
                        last_message=None,
                        last_skill=None,
                    ),
                )
                db.execute("COMMIT")
                return
            consumed, last_ts, ordinal, base, segment_id, seen, span = scan_session(
                db,
                f,
                path,
                session,
                project,
                start,
                ordinal,
                base,
                closed,
                (cur, bool(cleared)),
            )
            drop_segments(db, [s for s in cleared if s not in seen])
            put_cursor(
                db,
                path,
                Cursor(
                    agent_id=None,
                    inode=st.st_ino,
                    head_len=head[0] if head else cur.head_len,
                    head_sha=head[1] if head else cur.head_sha,
                    offset=consumed,
                    base_offset=base,
                    ordinal=ordinal,
                    segment_id=segment_id,
                    last_ts=last_ts or (cur.last_ts if cur is not None else None),
                    last_message=span.last_message,
                    last_skill=span.skill_now,
                ),
            )
            db.execute("COMMIT")
        except Exception:
            try:
                db.execute("ROLLBACK")
            except Exception:
                # SQLite aborts the transaction itself on some errors, and
                # rolling back what is already gone would replace the real
                # failure with a meaningless one.
                pass
            raise


def scan_session(db, f, path, session, project, start, ordinal, base, closed, state):
    """Consume a span of a session transcript. Returns (offset, last timestamp,
    ordinal, the offset the open segment began at, its id, and the ids written)."""
    cur, rebuild = state
    last_ts = None
    seen = set()
    segment_id = "%s#%d" % (session, ordinal)
    active = segment_id not in closed
    span, bucket = resumed_span(cur, not rebuild), Bucket()
    reader = Reader(f, start, lambda: span)
    for rec in reader.records():
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
                seen.add(segment_id)
            ordinal += 1
            base = reader.at
            segment_id = "%s#%d" % (session, ordinal)
            active = segment_id not in closed
            # A boundary ends the message and the skill run with the segment, so
            # the next one starts remembering nothing.
            span, bucket = Span(), Bucket()
        elif active:
            try:
                fold_fence(db, path, segment_id, bucket, event[1], event[2], rebuild)
            except (OSError, ValueError):
                # One agent transcript that will not read costs its own fence,
                # not the session file it was named in. Nothing is written for
                # it, so the count is what says the figure is short.
                #
                # Only what a bad file throws is caught here. A database error
                # has already killed the transaction this scan is inside, and
                # swallowing it would let the rest of the file write in
                # autocommit — cursor at the end, counts nowhere.
                bucket.scalars["agent_fences_lost"] += 1
    if active:
        bucket.absorb_main(span)
        if write_bucket(db, segment_id, bucket, session, project, ordinal):
            seen.add(segment_id)
    # A segment closed by idle leaves its id behind: the records that follow it
    # belong to a new one, or a reviewed segment would gain rows after the fact.
    while segment_id in closed:
        ordinal += 1
        base = reader.at
        segment_id = "%s#%d" % (session, ordinal)
    return reader.at, last_ts, ordinal, base, segment_id, seen, span


def prune_agent_cursors(db):
    """Agent cursors whose transcript the 30-day cleanup has taken.

    They are never walked and never idle-closed, so nothing else would ever
    remove them — and there are ten agent transcripts for every session one, so
    the table would grow without bound. A row that goes and whose file comes
    back is read from 0 again, which is the same answer it gave the first time.
    """
    rows = db.execute("SELECT path FROM cursor WHERE agent_id IS NOT NULL").fetchall()
    gone = [(path,) for (path,) in rows if not os.path.exists(path)]
    if not gone:
        return
    try:
        db.execute("BEGIN IMMEDIATE")
    except Exception:
        return
    try:
        db.executemany("DELETE FROM cursor WHERE path=?", gone)
        db.execute("COMMIT")
    except Exception:
        try:
            db.execute("ROLLBACK")
        except Exception:
            pass


def close_stale(db, now):
    prune_agent_cursors(db)
    rows = db.execute(
        "SELECT path, segment_id, ordinal FROM cursor WHERE agent_id IS NULL"
    ).fetchall()
    for path, segment_id, ordinal in rows:
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = None
        if mtime is not None and (not segment_id or now - mtime < IDLE_SECONDS):
            continue
        try:
            db.execute("BEGIN IMMEDIATE")
        except Exception:
            # The store is busy or gone. Every close here is re-derivable on the
            # next sweep, so there is nothing to do but leave it.
            return
        try:
            if mtime is None:
                # The 30-day cleanup took the transcript. The digest is the only
                # record left, so it stays; the cursor pointing at nothing goes.
                if segment_id:
                    close_segment(db, segment_id, "gone")
                db.execute("DELETE FROM cursor WHERE path=?", (path,))
            else:
                row = db.execute(
                    "SELECT closed_seq FROM segment WHERE id=?", (segment_id,)
                ).fetchone()
                if row is not None and row[0] is None:
                    close_segment(db, segment_id, "idle")
                    # The records that follow belong to a new segment. Its start
                    # is unknown until one arrives, so the cursor's own offset
                    # stands in: nothing before it can belong to the new one.
                    # last_skill goes with it: a skill still running when the
                    # session fell idle belongs to the segment that ended, and
                    # carrying it into the next one means the skill is never
                    # counted there — which puts it on the digest's "never
                    # fired" list while it was firing.
                    db.execute(
                        "UPDATE cursor SET ordinal=?, segment_id=?, "
                        'base_offset="offset", last_skill=NULL WHERE path=?',
                        (
                            (ordinal or 0) + 1,
                            "%s#%d"
                            % (segment_id.rsplit("#", 1)[0], (ordinal or 0) + 1),
                            path,
                        ),
                    )
            db.execute("COMMIT")
        except Exception:
            try:
                db.execute("ROLLBACK")
            except Exception:
                pass


def sweep(db, since_epoch):
    failed = 0
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
                # One transcript never costs the sweep. It contributed no
                # segment, so it has nothing of its own to be counted on, and
                # without this a file that fails every sweep is invisible.
                failed += 1
    try:
        # Added, not assigned: the digest prints this as an all-time figure, and
        # one clean sweep would otherwise erase a week of failures from the line
        # that explains why a number is short.
        meta_set(db, "transcripts_failed", meta_get(db, "transcripts_failed") + failed)
    except Exception:
        pass
    close_stale(db, time.time())


# ── record ───────────────────────────────────────────────────────────────────


def lock_pid():
    """The pid in the lock file, or "" when there is none to read. Only a pid's
    worth is read, whatever is in there."""
    try:
        with open(LOCK_PATH) as f:
            return f.read(32).strip()
    except (OSError, UnicodeDecodeError):
        return ""


def alive(pid):
    """Whether a process is still running. Signal 0 checks for it without
    sending anything, and answers on every platform — /proc does not exist off
    Linux, and reading a lock as unheld there would let two sweeps run at once.
    A pid this process does not own answers EPERM, which is still alive."""
    try:
        # Not a pid: 0 signals this process's own group and would read as held
        # for as long as the lock is young, and a negative one is a group too.
        if int(pid) <= 0:
            return False
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OSError):
        return True
    except (ValueError, OverflowError):
        # Not a pid this system could ever have issued, so the lock holding it
        # is corrupt — and a corrupt lock nothing can steal wedges the recorder
        # for good.
        return False
    return True


def lock_held():
    """True when another sweep owns the lock. A lock older than ten minutes, or
    one whose process is gone, is stolen."""
    try:
        age = time.time() - os.path.getmtime(LOCK_PATH)
    except OSError:
        return False
    if age > LOCK_STALE_SECONDS:
        return False
    pid = lock_pid()
    return bool(pid) and pid.isdigit() and alive(pid)


def take_lock():
    """True when this process now holds the lock.

    The pid is written before the lock exists, not after: a lock file that is
    momentarily empty reads as unheld, and a second sweep would steal it out
    from under the first.
    """
    mine = "%s.%d" % (LOCK_PATH, os.getpid())
    try:
        fd = os.open(mine, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
        try:
            os.write(fd, str(os.getpid()).encode())
        finally:
            os.close(fd)
    except OSError:
        return False
    try:
        for _ in (0, 1):
            try:
                os.link(mine, LOCK_PATH)
                return True
            except FileExistsError:
                if lock_held():
                    return False
                try:
                    os.unlink(LOCK_PATH)
                except OSError:
                    return False
            except OSError:
                # No hardlinks on this filesystem. The window this closes is a
                # lock file that momentarily reads as empty; a store that cannot
                # link at all would otherwise never sweep again, which is worse.
                return take_lock_direct()
        return False
    finally:
        try:
            os.unlink(mine)
        except OSError:
            pass


def take_lock_direct():
    try:
        fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return False
    except OSError:
        return False
    try:
        os.write(fd, str(os.getpid()).encode())
    finally:
        os.close(fd)
    return True


def release_lock():
    """Only ever this process's own lock: a sweep that overran and had its lock
    stolen must not then delete the lock of whoever took it."""
    if lock_pid() == str(os.getpid()):
        try:
            os.unlink(LOCK_PATH)
        except OSError:
            pass


def read_since():
    """(epoch, fresh). A missing marker is written as now and that run records
    nothing — a missing marker must never become a backfill.

    A marker that is present but will not parse is left exactly as it is, and
    nothing is recorded until someone fixes it. Rewriting it would move the one
    value in the store that must never move, and destroy the evidence that it
    had. The doctor is what says so out loud.
    """
    try:
        with open(SINCE_PATH) as f:
            raw = f.read(64).strip()
    except OSError:
        raw = None
    if raw is not None:
        at = parse_iso(raw)
        return (at, False) if at is not None else (None, True)
    try:
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
    """Read the hook payload away so a writer sending more than a pipe buffer
    holds is not left blocked on us. Nothing in it is read: the transcripts are
    the source.

    Bounded by a deadline and a byte cap, because reading to EOF never ends on a
    stdin nobody closes — and this hook is wired async, so that would leave a
    process alive after the session that started it. Closing the descriptor
    instead would end it just as surely, but by handing the writer the EPIPE
    this exists to spare it. The deadline is short because a hook payload is
    written in one go by a parent that already holds it, and SessionEnd hooks
    share a 1.5 s budget.
    """
    try:
        if sys.stdin is None or sys.stdin.isatty():
            return
        fd = sys.stdin.fileno()
        deadline = time.monotonic() + DRAIN_SECONDS
        left = DRAIN_BYTES
        while left > 0:
            waiting = deadline - time.monotonic()
            if waiting <= 0 or not select.select([fd], [], [], waiting)[0]:
                return
            chunk = os.read(fd, min(CHUNK, left))
            if not chunk:
                return
            left -= len(chunk)
    except Exception:
        pass


def record(args):
    # Before anything that can return: the payload is on the pipe whether or not
    # this run sweeps, and the trigger that carries --interval is the one that
    # no-ops most. Draining after the gate would mean never draining at all.
    drain_stdin()
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
        if db is not None:
            try:
                # A marker written this run records nothing: everything on disk
                # predates it, and reading it would be the backfill.
                if not fresh:
                    sweep(db, since_epoch)
            finally:
                db.close()
        touch(SWEPT_PATH)
    finally:
        release_lock()
    return 0


# ── review ───────────────────────────────────────────────────────────────────


def table(out, title, headers, rows, dropped=0):
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
    if dropped:
        # The Window section is careful to say when a figure is short; a ranked
        # table that quietly stops at twelve rows reads as the whole list.
        out.append("    … and %d more, not shown" % dropped)


def grouped(db, sql):
    return db.execute(sql).fetchall()


def ranked(db, sql):
    """The top rows of a ranked query, and how many it left behind.

    The limit is applied here rather than in the SQL so the count of what was
    dropped comes from the same query as the rows: a second COUNT could answer
    for a different window.
    """
    rows = db.execute(sql).fetchall()
    return rows[:TOP_ROWS], max(0, len(rows) - TOP_ROWS)


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
        parts.append("%d agent stops had no readable transcript" % short_of[1])
    if parts:
        out.append("    incomplete: " + ", ".join(parts))
    # These belong to the store, not to the window: neither is scoped to a
    # segment, and saying so stops a drop from last spring reading as one from
    # the fortnight under review.
    ever = []
    for key, phrase in (
        ("transcripts_failed", "%d transcripts would not sweep"),
        ("segments_dropped", "%d segments could not be rebuilt"),
    ):
        count = meta_get(db, key)
        if count:
            ever.append(phrase % count)
    if ever:
        out.append("    store, all time: " + ", ".join(ever))

    out.append("")
    out.append("Delegation")
    rows = grouped(
        db,
        """
        SELECT w.project,
               CASE WHEN t.agent='' THEN 'session' ELSE 'agents' END AS scope,
               SUM(t.n), COUNT(DISTINCT t.segment_id),
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
        # No projects column: these rows are grouped by project, so it would
        # read 1 on every line and say nothing.
        ["project", "scope", "n", "segments", "Edit", "Write", "Bash"],
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
    rows, dropped = ranked(
        db,
        """
        SELECT d.kind, d.signature,
               CASE WHEN d.agent='' THEN 'session' ELSE 'agent' END,
               SUM(d.n), COUNT(DISTINCT d.segment_id), COUNT(DISTINCT w.project)
        FROM denial d JOIN win w ON w.id=d.segment_id
        GROUP BY d.kind, d.signature, 3 ORDER BY 6 DESC, 4 DESC""",
    )
    table(
        out,
        "Permission friction",
        ["kind", "signature", "who", "n", "segments", "projects"],
        rows,
        dropped,
    )

    out.append("")
    rows, dropped = ranked(
        db,
        """
        SELECT t.tool, CASE WHEN t.agent='' THEN 'session' ELSE 'agents' END,
               SUM(t.n), COUNT(DISTINCT t.segment_id), COUNT(DISTINCT w.project), SUM(t.errors)
        FROM tool_use t JOIN win w ON w.id=t.segment_id
        GROUP BY t.tool, 2 ORDER BY 3 DESC""",
    )
    table(
        out,
        "Tools",
        ["tool", "who", "n", "segments", "projects", "errors"],
        rows,
        dropped,
    )
    rows, dropped = ranked(
        db,
        """
        SELECT b.verb, CASE WHEN b.agent='' THEN 'session' ELSE 'agents' END,
               SUM(b.n), COUNT(DISTINCT b.segment_id), COUNT(DISTINCT w.project), SUM(b.errors)
        FROM bash_verb b JOIN win w ON w.id=b.segment_id
        GROUP BY b.verb, 2 ORDER BY 3 DESC""",
    )
    out.append("")
    table(
        out,
        "Bash verbs",
        ["verb", "who", "n", "segments", "projects", "errors"],
        rows,
        dropped,
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
        # Saying nothing here reads as "every installed skill fired", which is
        # the opposite of what is known.
        out.append(
            "    never fired: not known — the installed skills could not be read"
        )
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
    rows, dropped = ranked(
        db,
        """
        SELECT h.hook, SUM(h.n), COUNT(DISTINCT h.segment_id), COUNT(DISTINCT w.project),
               SUM(h.errors), MAX(h.ms_max)
        FROM hook_run h JOIN win w ON w.id=h.segment_id
        GROUP BY h.hook ORDER BY 2 DESC""",
    )
    table(
        out,
        "Hooks",
        ["hook", "n", "segments", "projects", "errors", "ms max"],
        rows,
        dropped,
    )

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


def store_problem():
    """Why the store cannot be read, in the words of whoever has to fix it."""
    try:
        import sqlite3
    except ImportError:
        return "python3 has no sqlite3 module, so nothing has ever been recorded"
    if not os.path.exists(DB_PATH):
        return "nothing recorded yet — no store at %s" % DB_PATH
    db = None
    try:
        db = sqlite3.connect(DB_PATH)
        version = db.execute("PRAGMA user_version").fetchone()[0]
    except Exception as failure:
        # The one function whose whole job is explaining an unreadable store
        # may not answer with a traceback, so it catches whatever comes —
        # permission, encoding, a path that is a directory.
        return "%s will not open: %s" % (DB_PATH, failure)
    finally:
        if db is not None:
            try:
                db.close()
            except Exception:
                pass
    if version != SCHEMA_VERSION:
        return "%s is schema version %d; this build reads version %d" % (
            DB_PATH,
            version,
            SCHEMA_VERSION,
        )
    return "%s will not open" % DB_PATH


def accept(db, args):
    """Move the marker, and say what that hid. A digest nobody can get back is
    not something to do on a typo."""
    from lib.out import print_line

    try:
        seq = int(args[args.index("--accept") + 1])
    except (IndexError, ValueError):
        sys.stderr.write("retro: --accept needs a closed_seq\n")
        return 2
    through = meta_get(db, "reviewed_through")
    highest = db.execute(
        "SELECT MAX(closed_seq) FROM segment WHERE closed_seq IS NOT NULL"
    ).fetchone()[0]
    if seq <= through:
        sys.stderr.write(
            "retro: reviewed_through is already %d; --accept only moves forward\n"
            % through
        )
        return 2
    if highest is None or seq > highest:
        sys.stderr.write(
            "retro: %d is past the last closed segment (%s). Accepting it would "
            "retire segments nobody has seen.\n"
            % (seq, "none" if highest is None else highest)
        )
        return 2
    covered = db.execute(
        "SELECT count(*) FROM segment WHERE closed_seq > ? AND closed_seq <= ?",
        (through, seq),
    ).fetchone()[0]
    meta_set(db, "reviewed_through", seq)
    print_line(
        "accepted %d segments · reviewed_through %d → %d" % (covered, through, seq)
    )
    return 0


def review(args):
    # Imported here rather than at module level so a broken checkout costs the
    # digest and not the recorder: everything record() does is guarded, and a
    # module-level import is not.
    from lib.out import print_line

    db = open_store(create=False)
    if db is None:
        sys.stderr.write("retro: %s\n" % store_problem())
        return 1
    try:
        if "--accept" in args:
            return accept(db, args)
        for line in digest(db, "--all" in args):
            # print_line, not a bare write: the digest is full of · and →, and a
            # stream that will not take them degrades the glyph rather than
            # losing the line. It swallows a closed pipe too, which is why the
            # exit below cannot leave that to interpreter shutdown.
            print_line(line)
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
    code = 2
    try:
        try:
            from lib.out import utf8_stdout

            utf8_stdout()
        except Exception:
            # A checkout missing its own package still records; the doctor is
            # what says so. Only the digest's glyphs depend on this.
            pass
        code = main(sys.argv[1:])
    finally:
        for stream in (sys.stdout, sys.stderr):
            try:
                stream.flush()
            except Exception:
                pass
        # `review | head` closes the pipe early, and interpreter shutdown
        # flushes stdout outside every guard above — where that raises, it
        # replaces the exit code with 120.
        os._exit(code)
