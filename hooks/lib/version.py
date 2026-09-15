"""A version directory's version, v<count>·<sha>.

The installer stamps it and the status line compares against it, so both read it
here. Contract: documentation/specs/install.md, Version identity.

    python3 hooks/lib/version.py <root>    prints the version, or nothing

Exit 3: git did not answer in time. Exit 4: git failed, with its message.
"""

import os
import re
import subprocess
import sys

LABEL = re.compile(r"v([0-9]+)·([0-9a-f]{4,40})")

# A variable naming another repository would answer for that one instead.
GIT_ENV_OVERRIDES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY")


class Unknown(Exception):
    """git could not say, which is not the same answer as no version: a caller
    that treated it as one would remove a stamp that is right."""


def parse(label):
    """(count, sha) for a well-formed label, or None."""
    match = LABEL.fullmatch(label) if isinstance(label, str) else None
    return (int(match.group(1)), match.group(2)) if match else None


def same(a, b):
    """Counts match and one sha is a prefix of the other, so an abbreviation of
    any length still compares equal."""
    pa, pb = parse(a), parse(b)
    if not (pa and pb) or pa[0] != pb[0]:
        return False
    return pa[1].startswith(pb[1]) or pb[1].startswith(pa[1])


def _from_git(root, timeout):
    """The top level of a work tree is the directory holding .git, so a root
    without one is never read from a repository in a parent directory."""
    if not os.path.lexists(os.path.join(root, ".git")):
        return None
    env = {k: v for k, v in os.environ.items() if k not in GIT_ENV_OVERRIDES}

    def git(*args):
        try:
            done = subprocess.run(
                ["git", "-C", root, *args],
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env,
                stdin=subprocess.DEVNULL,
            )
        except OSError as e:
            raise Unknown("git cannot run: %s" % e.strerror)
        if done.returncode != 0:
            raise Unknown((done.stderr.strip().splitlines() or ["git %s failed" % args[0]])[-1])
        return done.stdout.strip()

    if os.path.realpath(git("rev-parse", "--show-toplevel")) != root:
        return None
    label = "v%s·%s" % (git("rev-list", "--count", "HEAD"), git("rev-parse", "--short", "HEAD"))
    return label if parse(label) else None


def _from_file(root):
    try:
        with open(os.path.join(root, "VERSION"), encoding="utf-8") as f:
            content = f.read(256)
    except (OSError, ValueError):
        return None
    line = content[:-1] if content.endswith("\n") else content
    return line if parse(line) else None


def of_root(root, timeout=5.0):
    """The root's version, or None when it has none.

    Raises subprocess.TimeoutExpired when git does not answer in time, and
    Unknown when git fails on a directory that holds a repository."""
    root = os.path.realpath(root)
    return _from_git(root, timeout) or _from_file(root)


if __name__ == "__main__":
    try:
        found = of_root(sys.argv[1])
    except subprocess.TimeoutExpired:
        sys.exit(3)
    except Unknown as e:
        print(e)
        sys.exit(4)
    if found:
        print(found)
