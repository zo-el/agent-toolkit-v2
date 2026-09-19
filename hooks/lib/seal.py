"""A content digest over a version directory.

Verifying asks whether the supplier gave what it said it would. This answers a
different question: whether the tree about to be run is the tree that was
verified. Contract: documentation/specs/release.md, Sealing.

    seal.py <directory>    prints the digest, or nothing with the reason on stderr

Every field is NUL terminated and a path cannot hold a NUL, so no path can be
read as the start of another entry.

Exit 1: the tree could not be read.
"""

import hashlib
import os
import sys

# The one mode bit the root checks and the launcher turn on. Ownership and
# timestamps change nothing about what running the tree does.
EXECUTABLE = 0o111
BLOCK = 1 << 20
ALGORITHM = "sha256"


def _bytes_of(path):
    digest = hashlib.new(ALGORITHM)
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(BLOCK), b""):
            digest.update(block)
    return digest.hexdigest().encode("ascii")


def _record(kind, path, fields):
    return b"".join(field + b"\0" for field in [kind, path, *fields])


def _entries(root):
    """One record per name in the tree, unordered. A symlink is never followed,
    so a link to a directory is an entry rather than a way in."""
    stack = [root]
    while stack:
        with os.scandir(stack.pop()) as listing:
            for entry in listing:
                path = os.fsencode(os.path.relpath(entry.path, root))
                if entry.is_symlink():
                    yield path, _record(b"l", path, [os.fsencode(os.readlink(entry.path))])
                elif entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
                elif entry.is_file(follow_symlinks=False):
                    runs = b"1" if entry.stat(follow_symlinks=False).st_mode & EXECUTABLE else b"0"
                    yield path, _record(b"f", path, [runs, _bytes_of(entry.path)])
                else:
                    # Nothing a git archive carries, and nothing install runs, but
                    # a name in the tree is still a name the seal answers for.
                    yield path, _record(b"o", path, [])


def of_tree(root):
    """The digest, or None when the tree could not be read."""
    try:
        records = sorted(_entries(os.path.realpath(root)))
    except OSError as reason:
        print(reason, file=sys.stderr)
        return None
    whole = hashlib.new(ALGORITHM)
    for _, record in records:
        whole.update(record)
    return "%s:%s" % (ALGORITHM, whole.hexdigest())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    found = of_tree(sys.argv[1])
    if found is None:
        sys.exit(1)
    print(found)
