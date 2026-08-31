#!/usr/bin/env python3
"""PreToolUse[Bash]. The mechanical half of the Writing standards, at the commit.

When the command about to run is a git commit, this reads its message and the
diff it is about to commit, and denies on what is objectively checkable: a dash
used as punctuation, a changelog entry grown into a diff, and comments arriving
faster than they leave. Every finding is named at once, with its path, its line
and the offending text, so one pass fixes all of them.

A finding that is wrong, or text that is deliberate and accepted, is cleared by
a Style-ack trailer on the commit message. The trailer lands in git history,
where it stays auditable.

Silence is the answer everywhere else, and the hook exits 0 on every path: a
command that is not a commit, a message it cannot read, a repository it cannot
resolve, a diff too large to be this change's business, and its own unexpected
errors.
"""

import json
import os
import re
import sys

# shlex, subprocess and traceback are imported where they are used, because this
# runs on every Bash call and returns on the first character of most of them.

# Thresholds, grounded in documentation/specs/style-checks.md and meant to move.
CHANGELOG_ENTRY_CHARS = 160
CHANGELOG_ENTRY_COUNT = 5
COMMENT_NET = 20
DIFF_LINE_CAP = 5000
FINDINGS_SHOWN = 40
MESSAGE_FILE_BYTES = 65536
GIT_TIMEOUT = 10

EM_DASH = "—"
EN_DASH = "–"

DOC_EXTENSIONS = {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}

# A marker only earns a place here where it is unambiguous for that extension.
# "* " and "*/" are block comment continuations; a bare "*" would take a pointer
# dereference with it.
_MARKERS = {
    (
        "#",
    ): ".py .pyi .sh .bash .zsh .rb .pl .yml .yaml .toml .ini .cfg .tf .nix .r .jl",
    ("//", "/*", "* ", "*/"): (
        ".c .h .cpp .hpp .cc .hh .java .js .jsx .mjs .cjs .ts .tsx .go .rs .swift"
        " .kt .kts .scala .php .cs .m .mm .dart .proto .zig"
    ),
    ("--",): ".sql .lua .hs .elm",
    (";",): ".el .lisp .clj .cljs .scm",
    ("<!--",): ".html .htm .xhtml .xml .vue",
}
COMMENT_MARKERS = {
    ext: markers for markers, exts in _MARKERS.items() for ext in exts.split()
}
# "Fewer comments than you found" is about code. In a configuration format a
# comment documents an option, and it is counted for dashes but not for drift.
CONFIG_EXTENSIONS = {".yml", ".yaml", ".toml", ".ini", ".cfg", ".tf", ".nix"}

EXCLUDED_DIRS = {"node_modules", "vendor", "target", "dist", "build"}
EXCLUDED_SUFFIXES = (".lock", ".snap", ".svg", "-lock.json")

CONTROL_CHARS = ";&|()"
REDIRECT_CHARS = "<>&"
# A leading NAME=VALUE, and the wrappers that keep the real command word behind
# them, are stepped over so the command word can be found.
COMMAND_PREFIXES = {"env", "command", "nohup", "time"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# git's own options, before the subcommand. The location ones are replayed on
# the diff so it reads the repository the commit will write.
GIT_LOCATION_OPTIONS = {"-C", "--git-dir", "--work-tree", "--namespace"}
GIT_VALUE_OPTIONS = GIT_LOCATION_OPTIONS | {
    "-c",
    "--exec-path",
    "--config-env",
    "--super-prefix",
}

# git commit's own options. Short ones cluster, so -am is -a -m.
SHORT_VALUE = set("mFCct")
# Attached values only, which is what keeps -S<keyid> from reading as -a.
SHORT_OPTIONAL_VALUE = set("Su")
# A message these produce cannot be read here, so the message check stays quiet
# while the diff checks still run.
MESSAGE_FROM_ELSEWHERE = {
    "--reuse-message",
    "--reedit-message",
    "--fixup",
    "--squash",
    "--template",
}
LONG_VALUE = MESSAGE_FROM_ELSEWHERE | {
    "--message",
    "--file",
    "--author",
    "--date",
    "--cleanup",
    "--pathspec-from-file",
    "--trailer",
}

HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)")
BULLET = re.compile(r"^ {0,3}[-*+]\s+(\S.*)$")
TRAILER = re.compile(r"^\s*style-ack\s*:(.*)$", re.IGNORECASE)


class Commit:
    """What the command says it is about to commit."""

    def __init__(self):
        self.location = []
        self.messages = []
        self.message_file = None
        self.message_elsewhere = False
        self.stage_all = False
        self.dry_run = False
        self.include = False
        self.pathspecs = []
        self.paths_unknown = False


class GitUnavailable(Exception):
    """git could not be run at all, so no later call would work either.

    Raised rather than returned so one timeout is paid once, instead of once per
    probe and once per diff range.
    """


def warn(text):
    """One line to stderr, which reaches the debug log and never the model.

    Silence is this hook's answer to most things, so the few failures that are
    breakage rather than a verdict have to leave a trace somewhere.
    """
    try:
        sys.stderr.write("style: %s\n" % text)
        sys.stderr.flush()
    except Exception:
        pass


def strip_heredocs(command):
    """The command with every heredoc body removed.

    A body is text rather than shell words, and an apostrophe in it opens a
    quote that never closes. A run with no closing delimiter is not a heredoc,
    and nothing is dropped for it.
    """
    if "<<" not in command:
        return command
    lines = command.split("\n")
    kept = []
    index = 0
    while index < len(lines):
        kept.append(lines[index])
        index += 1
        for match in HEREDOC.finditer(kept[-1]):
            end = index
            while end < len(lines) and lines[end].strip() != match.group(2):
                end += 1
            if end < len(lines):
                index = end + 1
    return "\n".join(kept)


def tokenize(command):
    """Shell words, with the separators kept as words of their own."""
    import shlex

    lexer = shlex.shlex(strip_heredocs(command), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def is_redirect(token):
    return "<" in token or ">" in token


def segments(tokens):
    """(subshell depth, words) for each command in a compound command.

    A redirect keeps its command rather than splitting it, and takes with it the
    file descriptor in front and the target behind. Left in place, a bare 2 from
    2>/dev/null reads as a pathspec, and the check then narrows to a file that
    does not exist and finds nothing.
    """
    current = []
    depth = 0
    skip = False
    for token in tokens:
        if skip:
            skip = False
            continue
        if not token.strip():
            continue
        if is_redirect(token) and all(char in REDIRECT_CHARS for char in token):
            if current and current[-1].isdigit():
                current.pop()
            skip = True
            continue
        if all(char in CONTROL_CHARS for char in token):
            if current:
                yield depth, current
            current = []
            depth += token.count("(") - token.count(")")
            depth = max(depth, 0)
        else:
            current.append(token)
    if current:
        yield depth, current


def command_words(segment):
    """The segment with its environment prefix stripped."""
    index = 0
    while index < len(segment) and (
        ASSIGNMENT.match(segment[index]) or segment[index] in COMMAND_PREFIXES
    ):
        index += 1
    return segment[index:]


def parse_git_commit(segment):
    """A Commit when this segment is a git commit, otherwise None."""
    words = command_words(segment)
    if not words or os.path.basename(words[0]) != "git":
        return None
    commit = Commit()
    index = 1
    while index < len(words) and words[index].startswith("-"):
        name, attached, _ = words[index].partition("=")
        if name in GIT_LOCATION_OPTIONS:
            if attached:
                commit.location.append(words[index])
                index += 1
            elif index + 1 < len(words):
                commit.location.extend(words[index : index + 2])
                index += 2
            else:
                return None
        elif name in GIT_VALUE_OPTIONS and not attached:
            index += 2
        else:
            index += 1
    if index >= len(words) or words[index] != "commit":
        return None
    return parse_commit_options(commit, words[index + 1 :])


def parse_commit_options(commit, args):
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            commit.pathspecs.extend(args[index + 1 :])
            break
        if arg.startswith("--"):
            name, attached, value = arg.partition("=")
            if name in MESSAGE_FROM_ELSEWHERE:
                commit.message_elsewhere = True
            if name == "--pathspec-from-file":
                commit.paths_unknown = True
            if not attached and name in LONG_VALUE:
                value = args[index + 1] if index + 1 < len(args) else ""
                index += 1
            if name in ("--message", "--trailer"):
                commit.messages.append(value)
            elif name == "--file":
                commit.message_file = value
            elif name == "--all":
                commit.stage_all = True
            elif name in ("--dry-run", "--short", "--porcelain"):
                commit.dry_run = True
            elif name in ("--include", "--interactive", "--patch"):
                commit.include = True
        elif arg.startswith("-") and len(arg) > 1:
            index = parse_short_cluster(commit, args, index)
        else:
            commit.pathspecs.append(arg)
        index += 1
    return commit


def parse_short_cluster(commit, args, index):
    """One -abc cluster, returning the index of its last consumed word."""
    cluster = args[index][1:]
    for position, flag in enumerate(cluster):
        rest = cluster[position + 1 :]
        if flag in SHORT_OPTIONAL_VALUE:
            return index
        if flag in SHORT_VALUE:
            if rest:
                value = rest
            elif index + 1 < len(args):
                value, index = args[index + 1], index + 1
            else:
                value = ""
            if flag == "m":
                commit.messages.append(value)
            elif flag == "F":
                commit.message_file = value
            else:
                commit.message_elsewhere = True
            return index
        if flag == "a":
            commit.stage_all = True
        elif flag in "ip":
            commit.include = True
    return index


def find_commits(tokens, start_cwd):
    """(Commit, directory it runs in) for every git commit in the command.

    A cd counts for a commit in the same subshell or in one enclosing it, and
    not for a subshell that has already closed, so the directory is tracked per
    depth. It is None where a cd cannot be followed, which leaves the diff
    checks out and the message check running.
    """
    found = []
    cwds = [start_cwd]
    for depth, segment in segments(tokens):
        while len(cwds) <= depth:
            cwds.append(cwds[-1])
        del cwds[depth + 1 :]
        commit = parse_git_commit(segment)
        if commit is not None:
            found.append((commit, cwds[depth]))
            continue
        words = command_words(segment)
        if not words or words[0] != "cd":
            continue
        targets = [word for word in words[1:] if not word.startswith("-")]
        target = targets[0] if len(targets) == 1 else ""
        if not target or not cwds[depth] or any(c in target for c in "$`~*?"):
            cwds[depth] = None
            continue
        cwds[depth] = os.path.normpath(os.path.join(cwds[depth], target))
    return found


def read_message_file(path, cwd):
    """The message a -F names, when that file is readable right now.

    The path is arbitrary and is read anyway, because refusing would make -F the
    way past the check. Nothing of its text is ever quoted back: see
    message_findings.
    """
    if not path or path == "-":
        return None
    if not os.path.isabs(path):
        if not cwd:
            return None
        path = os.path.join(cwd, path)
    try:
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as handle:
            return handle.read(MESSAGE_FILE_BYTES).decode("utf-8", "replace")
    except OSError:
        return None


GIT_SAFE_CONFIG = [
    "-c",
    "core.quotepath=false",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "protocol.ext.allow=never",
]


def git(location, args, cwd, quiet=False):
    """git's stdout, or None when it did not run clean.

    A clean filter still runs when a worktree file has to be read, which is what
    the commit itself is about to do anyway. Everything reachable from a config
    key is turned off here instead.
    """
    import subprocess

    environment = dict(os.environ)
    # A hook must not touch the index it is reading, and must not stall on a
    # credential or a pager.
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_PAGER"] = "cat"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            ["git"] + GIT_SAFE_CONFIG + location + args,
            cwd=cwd or None,
            capture_output=True,
            timeout=GIT_TIMEOUT,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError) as error:
        # A timeout or a missing binary is never the silence the spec sanctions,
        # so it speaks whatever the caller asked for.
        warn("git %s in %s: %s" % (" ".join(args[:2]), cwd, error))
        raise GitUnavailable(error)
    if result.returncode != 0:
        if not quiet:
            first = result.stderr.decode("utf-8", "replace").strip().split("\n")[0]
            warn("git %s in %s: %s" % (" ".join(args[:2]), cwd, first))
        return None
    return result.stdout.decode("utf-8", "replace")


def diff_base():
    return [
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ]


def diff_arguments(commit):
    """The diff ranges that hold what this command is about to commit.

    An amend is treated like any other commit: what it newly introduces is the
    staged change, and the content already in HEAD was checked when HEAD was
    made.
    """
    base = diff_base()
    if commit.stage_all or commit.paths_unknown:
        return [base + ["HEAD"]]
    if commit.pathspecs:
        paths = base + ["HEAD", "--"] + commit.pathspecs
        return [base + ["--cached"], paths] if commit.include else [paths]
    return [base + ["--cached"]]


def read_diff(commit, cwd):
    """The diffs holding what is about to be committed, or None.

    The size is settled from --numstat before the content is asked for, so a
    vendor drop past DIFF_LINE_CAP is never read into memory at all.
    """
    texts = []
    changed = 0
    state = None
    for arguments in diff_arguments(commit):
        counts = git(commit.location, arguments + ["--numstat"], cwd, quiet=True)
        if counts is None:
            if state is None:
                state = repository_state(commit.location, cwd)
            is_repository, has_head = state
            if not is_repository:
                return None
            if has_head:
                warn("git diff failed in a repository at %s" % cwd)
                return None
            # A first commit has an index and no parent. The pathspec is kept,
            # or this judges files the commit will not carry.
            arguments = ["--cached" if a == "HEAD" else a for a in arguments]
            counts = git(commit.location, arguments + ["--numstat"], cwd)
        if counts is None:
            return None
        changed += numstat_total(counts)
        if changed > DIFF_LINE_CAP:
            return None
        text = git(commit.location, arguments, cwd)
        if text is None:
            return None
        texts.append(text)
    return texts


def repository_state(location, cwd):
    """(it is a repository, it has a HEAD) for the target of this commit.

    A directory that is not a repository is the silence the spec sanctions. One
    that is, and whose diff still failed, is breakage that has to leave a line.
    """
    if git(location, ["rev-parse", "--git-dir"], cwd, quiet=True) is None:
        return False, False
    head = git(location, ["rev-parse", "--verify", "HEAD"], cwd, quiet=True)
    return True, head is not None


def numstat_total(counts):
    """Lines added and removed across a --numstat listing.

    A binary file reports a dash for each count and contributes nothing, which
    is also all its content diff would contribute.
    """
    total = 0
    for line in counts.split("\n"):
        fields = line.split("\t")
        # A path this never reads must not spend the cap, or one vendor drop
        # switches the checks off for everything committed beside it.
        if len(fields) < 3 or excluded(fields[2]):
            continue
        total += sum(int(n) for n in fields[:2] if n.isdigit())
    return total


def excluded(path):
    parts = path.split("/")
    if any(part in EXCLUDED_DIRS for part in parts):
        return True
    if any(
        parts[i] == ".claude" and parts[i + 1] == "worktrees"
        for i in range(len(parts) - 1)
    ):
        return True
    name = parts[-1]
    return name.endswith(EXCLUDED_SUFFIXES) or ".min." in name


def parse_diff(text):
    """One record per file: its path, whether it is new, and its hunk lines.

    A line is (kind, line number in the new file, text), and a hunk boundary is
    marked with a None kind so markdown fence state can restart there.
    """
    files = []
    current = None
    line_number = 0
    is_new = False
    in_header = False
    for raw in text.split("\n"):
        if raw.startswith("diff --git "):
            current, is_new, in_header = None, False, True
            continue
        match = HUNK.match(raw)
        if match:
            in_header = False
            if current is not None:
                line_number = int(match.group(1))
                current["lines"].append((None, line_number, ""))
            continue
        # Only the header carries the path. A committed patch file has +++ lines
        # of its own, and reading one as a path invents a file the commit for
        # which has none.
        if in_header:
            if raw.startswith("new file mode "):
                is_new = True
            elif raw.startswith("+++ ") and raw[4:].strip() != "/dev/null":
                path = raw[4:].strip()
                current = {
                    "path": path[2:] if path.startswith("b/") else path,
                    "new": is_new,
                    "lines": [],
                }
                files.append(current)
            continue
        if current is None:
            continue
        if raw.startswith("+"):
            current["lines"].append(("+", line_number, raw[1:]))
            line_number += 1
        elif raw.startswith("-"):
            current["lines"].append(("-", line_number, raw[1:]))
        elif raw.startswith(" "):
            current["lines"].append((" ", line_number, raw[1:]))
            line_number += 1
    return files


def diff_records(texts):
    """One record per path, over every diff that was read.

    The include form asks for the index and for a pathspec separately, and a
    file in both would otherwise be checked twice. The later answer is the
    narrower one, so it wins.
    """
    records = {}
    for text in texts:
        for record in parse_diff(text):
            records[record["path"]] = record
    return list(records.values())


def doc_prose(record):
    """(line number, text) for added lines of a document that are prose.

    Fence state restarts at every hunk, because the lines between hunks were
    never shown. Front matter is only recognised where the hunk reaches line 1.
    """
    fenced = False
    front_matter = False
    at_file_start = False
    for kind, number, text in record["lines"]:
        if kind is None:
            fenced, front_matter = False, False
            at_file_start = number == 1
            continue
        stripped = text.strip()
        if at_file_start:
            at_file_start = False
            if stripped == "---":
                front_matter = True
                continue
        if front_matter:
            if stripped in ("---", "..."):
                front_matter = False
            continue
        if kind == "-":
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced or kind != "+":
            continue
        if text.startswith("    ") or text.startswith("\t"):
            continue
        if stripped.startswith(">"):
            continue
        yield number, text


def source_prose(record, markers):
    """(line number, text) for the comment text of added source lines."""
    for kind, number, text in record["lines"]:
        if kind != "+":
            continue
        stripped = text.lstrip()
        leading = next((m for m in markers if stripped.startswith(m)), None)
        if leading:
            if leading == "#" and stripped.startswith("#!"):
                continue
            yield number, stripped[len(leading) :]
            continue
        if any(quote in text for quote in "\"'`"):
            continue
        positions = [(text.find(m), m) for m in markers if text.find(m) >= 0]
        if positions:
            at, marker = min(positions)
            yield number, text[at + len(marker) :]


def added_prose(record):
    extension = os.path.splitext(record["path"])[1].lower()
    if extension in DOC_EXTENSIONS:
        return doc_prose(record)
    markers = COMMENT_MARKERS.get(extension)
    return source_prose(record, markers) if markers else iter(())


def dashes(text):
    """(character name, index) for every dash used as punctuation."""
    for index, char in enumerate(text):
        if char == EM_DASH:
            yield "em dash", index
        elif char == EN_DASH:
            # A digit on each side is a range, which the rule allows.
            before = text[index - 1] if index else ""
            after = text[index + 1] if index + 1 < len(text) else ""
            if not (before.isdigit() and after.isdigit()):
                yield "en dash", index


def fragment(text, index, width=40):
    """The offending text around one dash, on a single line.

    A commit message is many lines, and one finding per line is what makes the
    deny reason readable.
    """
    start, end = max(0, index - width), min(len(text), index + width)
    return (
        ("…" if start else "")
        + " ".join(text[start:end].split())
        + ("…" if end < len(text) else "")
    )


def comment_drift(files):
    """(added, removed, paths) for comment lines over files that existed."""
    added = removed = 0
    paths = []
    for record in files:
        if record["new"]:
            continue
        extension = os.path.splitext(record["path"])[1].lower()
        markers = COMMENT_MARKERS.get(extension)
        if not markers or extension in CONFIG_EXTENSIONS:
            continue
        for kind, _, text in record["lines"]:
            if kind not in ("+", "-"):
                continue
            stripped = text.lstrip()
            if stripped.startswith("#!") or not any(
                stripped.startswith(marker) for marker in markers
            ):
                continue
            if kind == "+":
                added += 1
            else:
                removed += 1
            if record["path"] not in paths:
                paths.append(record["path"])
    return added, removed, paths


def message_findings(message, quotable):
    """Findings over the commit message.

    Text the command itself carried is quoted back. Text that came from a file
    is not: the path is arbitrary, so quoting it would read that file out to the
    model a fragment at a time.
    """
    findings = []
    for name, index in dashes(message):
        if quotable:
            findings.append('message: %s in "%s"' % (name, fragment(message, index)))
        else:
            line = message.count("\n", 0, index) + 1
            findings.append("message: %s on line %d of the message file" % (name, line))
    return findings


def diff_findings(files):
    """(the finding a commit has one of, the findings it has many of).

    Two lists because the report shows only its first FINDINGS_SHOWN: drift
    reported behind a file's worth of dashes is never read at all, so the caller
    puts it at the head of everything.
    """
    files = [record for record in files if not excluded(record["path"])]
    detail = []
    for record in files:
        for number, text in added_prose(record):
            for name, index in dashes(text):
                detail.append(
                    '%s:%d: %s in "%s"'
                    % (record["path"], number, name, fragment(text, index))
                )
        detail.extend(changelog_findings(record))
    drift = []
    added, removed, paths = comment_drift(files)
    if added - removed >= COMMENT_NET:
        drift.append(
            "comments: +%d/-%d in %s (limit +%d net)"
            % (added, removed, ", ".join(paths), COMMENT_NET)
        )
    return drift, detail


def changelog_findings(record):
    if not os.path.basename(record["path"]).upper().startswith("CHANGELOG"):
        return []
    findings = []
    entries = 0
    for kind, number, text in record["lines"]:
        match = BULLET.match(text) if kind == "+" else None
        if not match:
            continue
        entries += 1
        entry = match.group(1).strip()
        if len(entry) > CHANGELOG_ENTRY_CHARS:
            findings.append(
                '%s:%d: changelog entry is %d characters, over %d: "%s…"'
                % (
                    record["path"],
                    number,
                    len(entry),
                    CHANGELOG_ENTRY_CHARS,
                    entry[:60],
                )
            )
    if entries > CHANGELOG_ENTRY_COUNT:
        findings.append(
            "%s: %d entries added in one commit, over %d. A whole change is a "
            "handful of lines, not one bullet per fix."
            % (record["path"], entries, CHANGELOG_ENTRY_COUNT)
        )
    return findings


def acknowledged(message):
    """True when the message's trailers carry a Style-ack that gives a reason.

    Trailers are the last paragraph, so a body that quotes one, such as this
    feature's own documentation, does not clear anything.
    """
    last = message.strip().split("\n\n")[-1]
    return any(
        match.group(1).strip()
        for match in (TRAILER.match(line) for line in last.split("\n"))
        if match
    )


def reason(findings):
    shown = findings[:FINDINGS_SHOWN]
    hidden = len(findings) - len(shown)
    lines = [
        "Style check: %d finding%s in this commit."
        % (len(findings), "" if len(findings) == 1 else "s"),
        "",
    ]
    lines.extend("  " + finding for finding in shown)
    if hidden:
        lines.append("  and %d more not shown" % hidden)
    lines.extend(
        [
            "",
            "A dash as punctuation becomes two sentences, a colon, or a comma. A "
            "changelog entry is the gist of a change, not its diff. A comment goes "
            "where the code cannot say it, so cut the ones that restate the code.",
            "",
            "If a finding is wrong, or the text is deliberate and you accept it, add "
            "a trailer to the commit message: Style-ack: <what you are accepting and "
            "why>. It clears every finding on this commit and lands in git history, "
            "so the decision stays auditable. It is not a way past a finding that is "
            "real.",
        ]
    )
    return "\n".join(lines)


def findings_for(payload):
    """Every finding against the command in this payload, in one list."""
    if payload.get("tool_name") != "Bash":
        return []
    command = payload.get("tool_input", {}).get("command")
    if not isinstance(command, str) or "commit" not in command:
        return []
    try:
        tokens = tokenize(command)
    except ValueError as error:
        warn("could not split the command: %s" % error)
        return []
    findings = []
    for commit, cwd in find_commits(tokens, payload.get("cwd") or os.getcwd()):
        # A dry run writes nothing, and it does not answer for the commit that
        # may follow it in the same command.
        if not commit.dry_run:
            findings.extend(commit_findings(commit, cwd))
    return findings


def commit_findings(commit, cwd):
    """Every finding against one commit, or none when it is acknowledged."""
    message = "\n\n".join(commit.messages)
    quotable = True
    if commit.message_file:
        from_file = read_message_file(commit.message_file, cwd)
        if from_file:
            message = "\n\n".join(filter(None, [message, from_file]))
            quotable = False
    if message and acknowledged(message):
        return []

    # The flag means the message cannot be read, not that a flag was present:
    # git commit --squash=HEAD -m "..." commits the -m text.
    unreadable = commit.message_elsewhere and not commit.messages
    findings = [] if unreadable else message_findings(message, quotable)
    absolute = any("=/" in part or part.startswith("/") for part in commit.location)
    if cwd or absolute:
        try:
            text = read_diff(commit, cwd)
        except GitUnavailable:
            text = None
        if text is not None:
            drift, detail = diff_findings(diff_records(text))
            findings = drift + findings + detail
    return findings


def main():
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    try:
        findings = findings_for(payload)
    except Exception:
        # A traceback carries file and line only, which no one can reproduce.
        warn(
            "failed on %.200r in %r"
            % (payload.get("tool_input", {}).get("command"), payload.get("cwd"))
        )
        raise
    if not findings:
        return None
    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason(findings),
            }
        }
    )


if __name__ == "__main__":
    try:
        try:
            verdict = main()
            if verdict:
                # json.dumps escapes to ASCII, so no locale can refuse this.
                sys.stdout.write(verdict + "\n")
                sys.stdout.flush()
        except Exception:
            import traceback

            # stderr on a zero exit reaches the debug log and never the model's
            # context, so a bug here stays diagnosable without blocking a commit.
            traceback.print_exc(file=sys.stderr)
    finally:
        try:
            sys.stderr.flush()
        except Exception:
            pass
        os._exit(0)
