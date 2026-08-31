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

# shlex, subprocess and traceback are imported where they are used. This hook
# runs on every Bash call and returns on the first character of most of them,
# and at that scale their import time is the whole cost of the check.

# Thresholds. Grounded guesses, meant to move once the check has been seen
# firing: 943 changelog bullets measured across this machine's projects have a
# median of 94 characters against a rule whose own example is 44.
CHANGELOG_ENTRY_CHARS = 160
CHANGELOG_ENTRY_COUNT = 5
# One genuinely earned comment must not trip it.
COMMENT_NET = 3
# Past this a commit is an import or a vendor drop, and its prose is not ours.
DIFF_LINE_CAP = 5000
# The deny reason has to be actionable in one pass, not exhaustive past reading.
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

EXCLUDED_DIRS = {"node_modules", "vendor", "target", "dist", "build"}
EXCLUDED_SUFFIXES = (".lock", ".snap", ".svg", "-lock.json")

SEPARATOR_CHARS = ";&|()<>"
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
LONG_VALUE = {
    "--message",
    "--file",
    "--reuse-message",
    "--reedit-message",
    "--fixup",
    "--squash",
    "--template",
    "--author",
    "--date",
    "--cleanup",
    "--pathspec-from-file",
    "--trailer",
}
# A message these produce cannot be read here, so the message check stays quiet
# while the diff checks still run.
MESSAGE_FROM_ELSEWHERE = {
    "--reuse-message",
    "--reedit-message",
    "--fixup",
    "--squash",
    "--template",
}

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
        self.amend = False
        self.dry_run = False
        self.include = False
        self.pathspecs = []


def tokenize(command):
    """Shell words, with the separators kept as words of their own."""
    import shlex

    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def segments(tokens):
    """One list of words per command in a compound command."""
    current = []
    for token in tokens:
        if token and all(char in SEPARATOR_CHARS for char in token):
            if current:
                yield current
            current = []
        else:
            current.append(token)
    if current:
        yield current


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
            if not attached and name in LONG_VALUE:
                value = args[index + 1] if index + 1 < len(args) else ""
                index += 1
            if name in ("--message", "--trailer"):
                commit.messages.append(value)
            elif name == "--file":
                commit.message_file = value
            elif name == "--all":
                commit.stage_all = True
            elif name == "--amend":
                commit.amend = True
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


def resolve_cwd(tokens, start_cwd):
    """The directory the commit runs in, or None when a cd cannot be followed."""
    cwd = start_cwd
    for segment in segments(tokens):
        words = command_words(segment)
        if not words or words[0] != "cd":
            continue
        targets = [word for word in words[1:] if not word.startswith("-")]
        if len(targets) != 1 or not cwd:
            return None
        target = targets[0]
        if any(char in target for char in "$`~*?"):
            return None
        cwd = os.path.normpath(os.path.join(cwd, target))
    return cwd


def read_message_file(path, cwd):
    """The message a -F names, when that file is readable right now."""
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


def git(location, args, cwd):
    """git's stdout, or None when it did not run clean."""
    import subprocess

    environment = dict(os.environ)
    # A hook must not touch the index it is reading, and must not stall on a
    # credential or a pager.
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_PAGER"] = "cat"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    try:
        result = subprocess.run(
            ["git", "-c", "core.quotepath=false"] + location + args,
            cwd=cwd or None,
            capture_output=True,
            timeout=GIT_TIMEOUT,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "replace")


def diff_arguments(commit):
    """The diff ranges that hold what this command is about to commit.

    An amend is treated like any other commit: what it newly introduces is the
    staged change, and the content already in HEAD was checked when HEAD was
    made.
    """
    base = ["diff", "--no-color", "--no-ext-diff", "--no-textconv"]
    if commit.stage_all:
        return [base + ["HEAD"]]
    if commit.pathspecs:
        paths = base + ["HEAD", "--"] + commit.pathspecs
        return [base + ["--cached"], paths] if commit.include else [paths]
    return [base + ["--cached"]]


def read_diff(commit, cwd):
    """The unified diff of what is about to be committed, or None."""
    texts = []
    for arguments in diff_arguments(commit):
        text = git(commit.location, arguments, cwd)
        if text is None:
            # No HEAD yet: the first commit of a repository has only an index.
            text = git(commit.location, ["diff", "--no-color", "--cached"], cwd)
        if text is None:
            return None
        texts.append(text)
    return "".join(texts)


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
    for raw in text.split("\n"):
        if raw.startswith("diff --git "):
            current, is_new = None, False
            continue
        # The mode line precedes the path line, so it is held until there is a
        # record to put it on.
        if raw.startswith("new file mode "):
            is_new = True
            continue
        if raw.startswith("+++ "):
            path = raw[4:].strip()
            if path == "/dev/null":
                current = None
                continue
            current = {
                "path": path[2:] if path.startswith("b/") else path,
                "new": is_new,
                "lines": [],
            }
            files.append(current)
            continue
        if current is None:
            continue
        match = HUNK.match(raw)
        if match:
            line_number = int(match.group(1))
            current["lines"].append((None, line_number, ""))
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


def changed_line_count(files):
    return sum(
        1 for record in files for kind, _, _ in record["lines"] if kind in ("+", "-")
    )


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
    """(added, removed) comment lines, over files that existed before this."""
    added = removed = 0
    for record in files:
        if record["new"]:
            continue
        markers = COMMENT_MARKERS.get(os.path.splitext(record["path"])[1].lower())
        if not markers:
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
    return added, removed


def message_findings(message):
    return [
        'message: %s in "%s"' % (name, fragment(message, index))
        for name, index in dashes(message)
    ]


def diff_findings(files):
    files = [record for record in files if not excluded(record["path"])]
    findings = []
    for record in files:
        for number, text in added_prose(record):
            for name, index in dashes(text):
                findings.append(
                    '%s:%d: %s in "%s"'
                    % (record["path"], number, name, fragment(text, index))
                )
        findings.extend(changelog_findings(record))
    added, removed = comment_drift(files)
    if added - removed >= COMMENT_NET:
        findings.append(
            "comments: +%d/-%d in files that already existed (limit +%d net)"
            % (added, removed, COMMENT_NET)
        )
    return findings


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
    """True when the message carries a Style-ack trailer that gives a reason."""
    return any(
        match.group(1).strip()
        for match in (TRAILER.match(line) for line in message.split("\n"))
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
        lines.append("  and %d more of the same kind" % hidden)
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
    except ValueError:
        return []
    commit = next(
        (c for c in (parse_git_commit(s) for s in segments(tokens)) if c), None
    )
    if commit is None or commit.dry_run:
        return []

    cwd = resolve_cwd(tokens, payload.get("cwd") or os.getcwd())
    message = "\n\n".join(commit.messages)
    if commit.message_file:
        from_file = read_message_file(commit.message_file, cwd)
        message = "\n\n".join(filter(None, [message, from_file]))
    if message and acknowledged(message):
        return []

    findings = message_findings(message) if not commit.message_elsewhere else []
    absolute = any(part.startswith("/") for part in commit.location)
    if cwd or absolute:
        text = read_diff(commit, cwd)
        if text is not None:
            files = parse_diff(text)
            if changed_line_count(files) <= DIFF_LINE_CAP:
                findings.extend(diff_findings(files))
    return findings


def main():
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    findings = findings_for(payload)
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
                from lib.out import print_line, utf8_stdout

                utf8_stdout()
                print_line(verdict)
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
