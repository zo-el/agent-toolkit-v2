"""This session's task list, as the platform stores it on disk.

The statusline segment and the taskline hook both speak for the same list, so
the layout is resolved here once. stdlib only, like everything a hook runs.
"""

import json
import os
from collections import namedtuple

HOME = os.path.expanduser("~")

# complete is False when part of the list would not read. Without it an empty
# list and a list that could not be read are the same answer, and a caller then
# asserts one while the other is true.
TaskList = namedtuple("TaskList", "tasks complete")


def _files(session_id):
    """(directory, entries, complete) for this session's task files.

    Two layouts, because the directory is named for whichever construct owns the
    list: the full session id normally, and session-<first8> when agent teams
    are on and the team name derives the path. A directory holding no task file
    is not the list — sessions leave empty ones behind, and the other layout may
    still hold the real one.

    Both candidates are probed even once one has answered: a directory that
    refuses to list may be the one holding the newer list, and the read is only
    complete when neither refused. A missing directory is not a refusal.
    """
    if not isinstance(session_id, str) or not session_id:
        # Never looked, so nothing is known — least of all that the list is
        # empty, which is what a complete read would be claiming.
        return None, (), False
    # The id goes into the path unsanitised. It is the harness's own value, on
    # its way to a directory the harness named, so a traversal check would only
    # be re-validating the platform against itself.
    root = os.path.join(HOME, ".claude", "tasks")
    complete, found = True, None
    for d in (
        os.path.join(root, session_id),
        os.path.join(root, f"session-{session_id[:8]}"),
    ):
        try:
            entries = os.listdir(d)
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError:
            complete = False
            continue
        if found is None and any(n.endswith(".json") for n in entries):
            found = (d, entries)
    return (*found, complete) if found else (None, (), complete)


def _order(task):
    """Ids are strings of integers, so a numeric sort reproduces the order the
    user sees. Anything else sorts after them, by id. isdecimal rather than
    isdigit: superscripts pass isdigit and then raise in int()."""
    tid = str(task.get("id") or "")
    return (0, int(tid), "") if tid.isdecimal() else (1, 0, tid)


def load_tasks(session_id):
    """Every task in this session's list, in id order, and whether the read was
    clean.

    A file that will not read or parse is skipped rather than failing the whole
    list — a partial answer is still worth having — but the caller is told, so it
    can decline to speak for a list it only half has. Task files are written
    while this runs, so a torn read is expected rather than exceptional.
    """
    d, entries, complete = _files(session_id)
    if not d:
        return TaskList([], complete)
    tasks = []
    for name in entries:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, name)) as f:
                task = json.load(f)
        except FileNotFoundError:
            # Deleted between the listing and the open, which is routine: the
            # platform clears the whole list once every task completes. A task
            # that no longer exists is not one that would not read.
            continue
        except (OSError, ValueError, RecursionError):
            # RecursionError because nesting deep enough to exhaust the stack is
            # a file that will not parse, and skipping it is the promise here.
            complete = False
            continue
        if isinstance(task, dict):
            tasks.append(task)
        else:
            complete = False
    tasks.sort(key=_order)
    return TaskList(tasks, complete)
