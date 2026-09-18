"""A version directory's version, v<version>·<revision>.

The installer stamps it, the status line compares against it, and the updater
judges releases by it, so all three read it here. Contract:
documentation/specs/install.md, Version identity.

    version.py root <dir>       the directory's version, or nothing
    version.py release <text>   the release name a version or a name stands for
    version.py same <a> <b>     exit 0 when the two are the same version
    version.py newer <a> <b>    exit 0 when a is a later release than b

root exits 3 when git did not answer in time, 4 when git failed, with its
message, and 5 when VERSION or REVISION is there and will not read, named with
the reason. release exits 1 when it is neither. Anything else exits 2.
"""

import os
import re
import subprocess
import sys

SEMANTIC = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
REVISION = re.compile(r"[0-9a-f]{4,40}")
NAME = re.compile(r"v(%s)" % SEMANTIC.pattern)
LABEL = re.compile(r"v(%s)·(%s)" % (SEMANTIC.pattern, REVISION.pattern))

# A variable naming another repository would answer for that one instead.
GIT_ENV_OVERRIDES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY")


class Unknown(Exception):
    """git could not say, which is not the same answer as no version: a caller
    that treated it as one would remove a stamp that is right."""


class Unreadable(Exception):
    """A file holding half the version is there and will not read, which is not
    no version either. It carries which file, because a reader that always said
    VERSION would send the user to look at the wrong one."""

    def __init__(self, name, reason):
        super().__init__("%s cannot be read: %s" % (name, reason))
        self.name = name


def _triple(digits):
    return tuple(int(n) for n in digits.split("."))


def parse(label):
    """((major, minor, patch), revision) for a well-formed label, or None."""
    match = LABEL.fullmatch(label) if isinstance(label, str) else None
    return (_triple(match.group(1)), match.group(2)) if match else None


def semantic(text):
    """The (major, minor, patch) of a release name, v1.5.0, or of a whole
    version label, v1.5.0·a1b2c3d, or None. A release is named for the semantic
    half alone, so one reading answers for a release and a version directory."""
    match = NAME.fullmatch(text) if isinstance(text, str) else None
    if match:
        return _triple(match.group(1))
    found = parse(text)
    return found[0] if found else None


def same(a, b):
    """Semantic versions equal and one revision a prefix of the other, so a
    release abbreviated to one length compares with a checkout abbreviated to
    another."""
    pa, pb = parse(a), parse(b)
    if not (pa and pb) or pa[0] != pb[0]:
        return False
    return pa[1].startswith(pb[1]) or pb[1].startswith(pa[1])


def newer(a, b):
    """a is a later release than b, by the ordering semantic versioning defines.
    The revision takes no part: it says which tree, not which release, so either
    side may be a bare release name."""
    sa, sb = semantic(a), semantic(b)
    return sa is not None and sb is not None and sa > sb


def _line(root, name):
    """The one line of a file at the root, None when it is not there."""
    try:
        with open(os.path.join(root, name), encoding="utf-8") as f:
            content = f.read(256)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        raise Unreadable(name, getattr(e, "strerror", None) or e)
    return content[:-1] if content.endswith("\n") else content


def _revision_from_git(root, timeout):
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
    return git("rev-parse", "--short", "HEAD")


def of_root(root, timeout=5.0):
    """The root's version, or None when either half is missing or malformed.

    Raises subprocess.TimeoutExpired when git does not answer in time, Unknown
    when git fails on a directory that holds a repository, and Unreadable when
    VERSION or REVISION is there and will not read."""
    root = os.path.realpath(root)
    version = _line(root, "VERSION")
    if version is None or not SEMANTIC.fullmatch(version):
        return None
    revision = _revision_from_git(root, timeout) or _line(root, "REVISION")
    if revision is None or not REVISION.fullmatch(revision):
        return None
    return "v%s·%s" % (version, revision)


def _root_command(directory):
    try:
        found = of_root(directory)
    except subprocess.TimeoutExpired:
        sys.exit(3)
    except Unknown as e:
        print(e)
        sys.exit(4)
    except Unreadable as e:
        print(e)
        sys.exit(5)
    if found:
        print(found)


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "root":
        _root_command(args[1])
    elif len(args) == 2 and args[0] == "release":
        found = semantic(args[1])
        if found is None:
            sys.exit(1)
        print("v%d.%d.%d" % found)
    elif len(args) == 3 and args[0] == "same":
        sys.exit(0 if same(args[1], args[2]) else 1)
    elif len(args) == 3 and args[0] == "newer":
        sys.exit(0 if newer(args[1], args[2]) else 1)
    else:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
