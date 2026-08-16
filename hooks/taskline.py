#!/usr/bin/env python3
"""UserPromptSubmit — one line of task state, injected as context every turn.

The rule to open a task before acting decays without it, for two mechanical
reasons. The task tools are deferred, so a session that never searches for their
schemas cannot call them and nothing shows that it failed; and a rule read once
at session start competes with everything that comes after it. Restating the
state on every turn is what keeps it true.

Advisory, never a gate: it exits 0 on every path including its own bugs, and
says nothing it cannot stand behind — a list it only half read gets a line that
admits it, and one it could not read at all gets no line. A reminder must not
cost a prompt, and a wrong reminder is worse than none.
"""

import json
import os
import sys
import traceback

NAMED = 4  # open tasks the line names before it starts eliding
SUBJECT_CHARS = 60  # of a subject, before it is cut
OWNER_CHARS = 24  # of an owner, which is an agent name
STATUS_CHARS = 16  # of a status, which is one word
HINT = (
    "Tasks: none open — open a lane before acting. Tools are deferred: "
    'ToolSearch "select:TaskCreate,TaskUpdate,TaskGet,TaskList"'
)


def one_line(text, limit=0):
    """Collapsed to a single line and cut visibly. Every field is passed through
    this: task text is free text, and one stray newline in it would split the
    line the hook exists to inject."""
    text = " ".join(str(text or "").split())
    if limit and len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def id_set(tasks):
    """Ids as text, so a numeric id and a numeric blocker still meet. A task
    with no id stays out of the set, or a null blocker would match it and read
    as blocked on nothing."""
    return {str(t["id"]) for t in tasks if t.get("id") is not None}


def state(task, open_ids, known_ids, complete):
    """Status, and the agent holding it.

    blocked is not a status the platform stores — it is pending with a blocker
    that has not finished — so it is derived here, the way the user's list shows
    it. Over a complete list a blocker that is not in it is a dangling reference
    and blocks nothing; over a partial one it is more likely a file that would
    not read, so the line errs toward blocked. Being left alone for a turn costs
    less than being picked up while something else owns it.
    """
    status = one_line(task.get("status"), STATUS_CHARS) or "pending"
    blockers = task.get("blockedBy")
    if status == "pending" and isinstance(blockers, (list, tuple)):
        ids = [str(b) for b in blockers]
        if any(b in open_ids for b in ids) or (
            not complete and any(b not in known_ids for b in ids)
        ):
            status = "blocked"
    owner = one_line(task.get("owner"), OWNER_CHARS)
    return f"({status}, {owner})" if owner else f"({status})"


def render(listing):
    """The line, or None when there is nothing that can be said honestly."""
    open_tasks = [t for t in listing.tasks if t.get("status") != "completed"]
    if not open_tasks:
        # An empty list and one that would not read look the same from here, so
        # only a clean read may claim there is nothing open.
        return HINT if listing.complete else None
    open_ids, known_ids = id_set(open_tasks), id_set(listing.tasks)
    # In-progress first: past the cap it is the running work that has to survive
    # the cut. sorted is stable, so id order holds within each group.
    ordered = sorted(open_tasks, key=lambda t: t.get("status") != "in_progress")
    parts = []
    for task in ordered[:NAMED]:
        subject = one_line(task.get("subject"), SUBJECT_CHARS) or "untitled"
        parts.append(f"{subject} {state(task, open_ids, known_ids, listing.complete)}")
    if len(ordered) > NAMED:
        parts.append(f"+{len(ordered) - NAMED} more")
    count = f"{len(open_tasks)} open" + ("" if listing.complete else " (partial list)")
    return f"Tasks: {count} · " + " · ".join(parts)


def main():
    """The line to print, or None when this turn gets none."""
    # Imported here rather than at module level so a broken checkout costs the
    # line and nothing else: everything below __main__ is guarded, the import
    # would not be.
    from lib.tasks import load_tasks

    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    session = payload.get("session_id")
    if not isinstance(session, str) or not session:
        # No session, no list to speak for. Claiming none are open would be a
        # guess, and a wrong claim is worse than saying nothing.
        return None
    return render(load_tasks(session))


if __name__ == "__main__":
    try:
        line = None
        try:
            from lib.out import print_line, utf8_stdout

            utf8_stdout()
            line = main()
        except Exception:
            # stderr on a zero exit reaches the debug log and never the model's
            # context, so a bug here stays diagnosable without being injected.
            traceback.print_exc(file=sys.stderr)
        if line:
            print_line(line)
    finally:
        try:
            sys.stderr.flush()
        except Exception:
            pass
        # Interpreter shutdown flushes stdout outside every guard above, and a
        # reader that closed the pipe makes that flush exit 120.
        os._exit(0)
