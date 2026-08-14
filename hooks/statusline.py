#!/usr/bin/env python3
"""statusLine command, one line:

    model │ effort │ context │ lines │ limits │ tasks │ bg │ branch+PR │ dir │ toolkit

Reads the status JSON Claude Code pipes to stdin. Every segment is wrapped and
degrades to nothing — a statusline must never crash or print a traceback, and a
segment with nothing to say takes no width. stdlib only, so it has no npm or jq
dependency at render time.

lines and limits are the exception to the no-width rule: neither has its data on
the first renders, so they hold their slot with a dim placeholder rather than let
the bar change shape mid-session. A session that never reports rate limits — an
API key rather than a subscription — keeps the limits placeholder for good, since
the payload gives no way to tell that from not knowing yet.
"""

import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DIM, BOLD, RESET = "\033[2m", "\033[1m", "\033[0m"
COLORS = {
    "red": "\033[31m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "magenta": "\033[35m",
    "cyan": "\033[36m",
}
SEP = f" {DIM}│{RESET} "

TAIL_BYTES = 2 * 1024 * 1024
HEAD_BYTES = 1 * 1024 * 1024

EFFORT_STYLE = {
    "max": COLORS["magenta"] + BOLD,
    "xhigh": COLORS["red"],
    "high": COLORS["yellow"],
    "medium": COLORS["cyan"],
    "low": DIM,
}


def read_chunks(path):
    """(tail, head) of the transcript. Only the ends are scanned so a multi-MB
    transcript stays cheap; head is empty when the file fits in the tail."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size <= TAIL_BYTES:
            return f.read().decode("utf-8", "replace"), ""
        f.seek(size - TAIL_BYTES)
        tail = f.read().decode("utf-8", "replace")
        f.seek(0)
        head = f.read(HEAD_BYTES).decode("utf-8", "replace")
    return tail, head


def segment_model(data):
    model = data.get("model") or {}
    name = model.get("display_name") or model.get("id") or ""
    if not name:
        return None
    big = f" {DIM}1M{RESET}" if "[1m]" in (model.get("id") or "") else ""
    return f"{BOLD}{name}{RESET}{big}"


def find_effort(data, tail, head):
    val = data.get("effort")
    if isinstance(val, dict):
        val = val.get("level")
    if isinstance(val, str) and val:
        return val
    # A payload carrying context_window is new enough to carry effort too, so a
    # missing field there means the model has no effort parameter at all — the
    # fallbacks below would report a stale value.
    if "context_window" in data:
        return None
    # Only user-type entries: /effort output lands there, while an assistant
    # entry can quote the same phrase in prose and match itself.
    for chunk in (tail, head):
        for line in reversed(chunk.splitlines()):
            if "Set effort level to " not in line:
                continue
            try:
                if json.loads(line).get("type") != "user":
                    continue
            except ValueError:
                continue
            hit = re.search(r"Set effort level to (low|medium|high|xhigh|max)\b", line)
            if hit:
                return hit.group(1)
    try:
        with open(os.path.join(HOME, ".claude", "settings.json")) as f:
            val = json.load(f).get("effortLevel")
        return val if isinstance(val, str) and val else None
    except Exception:
        return None


def segment_effort(data, tail, head):
    effort = find_effort(data, tail, head)
    if not effort:
        return None
    return f"{EFFORT_STYLE.get(effort, '')}⚡{effort}{RESET}"


def human_tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}".rstrip("0").rstrip(".") + "M"
    return f"{round(n / 1000)}k"


def segment_context(data, tail):
    native = data.get("context_window")
    native = native if isinstance(native, dict) else {}
    used = native.get("total_input_tokens")
    if used is None:
        cur = native.get("current_usage") or {}
        if isinstance(cur, dict) and cur.get("input_tokens") is not None:
            used = (
                (cur.get("input_tokens") or 0)
                + (cur.get("cache_creation_input_tokens") or 0)
                + (cur.get("cache_read_input_tokens") or 0)
            )
    pct = native.get("used_percentage")
    if pct is None and isinstance(native.get("remaining_percentage"), (int, float)):
        pct = 100 - native["remaining_percentage"]
    if used is None:
        # Native fields are null right after /compact and before the first
        # response; fall back to the last main-chain assistant usage block.
        for line in reversed(tail.splitlines()):
            if '"usage"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            usage = (entry.get("message") or {}).get("usage") or {}
            if "input_tokens" not in usage:
                continue
            used = (
                (usage.get("input_tokens") or 0)
                + (usage.get("cache_creation_input_tokens") or 0)
                + (usage.get("cache_read_input_tokens") or 0)
            )
            break
    if used is None and pct is None:
        return None
    model_id = (data.get("model") or {}).get("id") or ""
    window = native.get("context_window_size") or (
        1_000_000 if "[1m]" in model_id else 200_000
    )
    if pct is None:
        pct = used * 100 / window
    pct = max(0, min(100, round(pct)))
    color = (
        COLORS["green"] if pct < 60 else COLORS["yellow"] if pct < 80 else COLORS["red"]
    )
    bar = "▰" * min(8, round(pct * 8 / 100)) + "▱" * (8 - min(8, round(pct * 8 / 100)))
    tokens = (
        f" {DIM}{human_tokens(used)}/{human_tokens(window)}{RESET}"
        if used is not None
        else ""
    )
    return f"{color}{bar} {pct}%{RESET}{tokens}"


def segment_lines(data):
    cost = data.get("cost")
    cost = cost if isinstance(cost, dict) else {}
    added, removed = cost.get("total_lines_added"), cost.get("total_lines_removed")
    if not (added or removed):
        return f"{DIM}+0/-0{RESET}"
    return f"{COLORS['green']}+{added or 0}{RESET}{DIM}/{RESET}{COLORS['red']}-{removed or 0}{RESET}"


def compact_duration(seconds):
    """Coarsest useful form: 47m · 2h14m · 4d3h. Never more than two units —
    the point is how long you have, not the exact remainder."""
    if seconds < 60:
        return "<1m"
    m = int(seconds // 60)
    if m < 60:
        return f"{m}m"
    h, m = divmod(m, 60)
    if h < 24:
        return f"{h}h{m:02d}m"
    d, h = divmod(h, 24)
    return f"{d}d{h}h"


def segment_limits(data, now):
    """Usage against each rate-limit window, with how long until it resets.
    The window's own length is not shown — a fixed "5h" label says nothing you
    can act on, while the time left does. Falls back to the labels when the
    payload carries no reset time, since a bare pair of percentages would not
    say which window is which."""
    limits = data.get("rate_limits")
    limits = limits if isinstance(limits, dict) else {}
    parts, pcts = [], []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        pct = window.get("used_percentage")
        if not isinstance(pct, (int, float)):
            continue
        pcts.append(pct)
        resets = window.get("resets_at")
        left = None
        if isinstance(resets, (int, float)) and resets > now:
            left = compact_duration(resets - now)
        parts.append(f"{round(pct)}% {left}" if left else f"{label} {round(pct)}%")
    if not parts:
        return f"{DIM}⏱ —{RESET}"
    worst = max(pcts)
    color = DIM if worst < 50 else COLORS["yellow"] if worst < 80 else COLORS["red"]
    return f"{color}⏱ " + f"{RESET}{DIM} · {RESET}{color}".join(parts) + RESET


def segment_tasks(data):
    """Done out of total for this session's task list — the same list the user
    sees. Hidden when there are none, and the platform clears the whole list
    once every task completes, so this only ever shows live work."""
    sid = data.get("session_id")
    if not isinstance(sid, str) or not sid:
        return None
    # Two layouts, because the directory is named for whichever construct owns
    # the list: the full session id normally, and session-<first8> when agent
    # teams are on and the team name derives the path.
    root = os.path.join(HOME, ".claude", "tasks")
    names = None
    for d in (os.path.join(root, sid), os.path.join(root, f"session-{sid[:8]}")):
        try:
            found = os.listdir(d)
        except OSError:
            continue
        if any(n.endswith(".json") for n in found):
            names, base = found, d
            break
    if names is None:
        return None
    d = base
    total = done = 0
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, name)) as f:
                status = json.load(f).get("status")
        except (OSError, ValueError):
            continue
        total += 1
        done += status == "completed"
    if not total:
        return None
    color = COLORS["green"] if done == total else DIM
    return f"{color}☰ {done}/{total}{RESET}"


def proc_start(pid):
    """Kernel start time, which makes a pid unambiguous across reuse. Raises if
    the process is gone, so it doubles as the liveness test. comm can contain
    spaces and parentheses, so cut past the last ')' first."""
    with open(f"/proc/{pid}/stat", errors="replace") as f:
        return f.read().rsplit(")", 1)[1].split()[19]


def proc_ppid(pid):
    with open(f"/proc/{pid}/status", errors="replace") as f:
        for line in f:
            if line.startswith("PPid:"):
                return line.split()[1]
    return None


def owning_cli():
    """(pid, start) of the CLI this statusline renders for — the same ancestry
    walk bg.sh records ownership by, so the two agree on identity."""
    pid = str(os.getpid())
    while pid and pid not in ("0", "1"):
        if os.path.exists(os.path.join(HOME, ".claude", "sessions", f"{pid}.json")):
            return pid, proc_start(pid)
        pid = proc_ppid(pid)
    return None, None


def segment_bg():
    """Background processes this CLI still has running, from bg.sh's registry.
    Several sessions run at once, so a global count would report someone else's.

    A wrong count is worse than no count, so the two uncertainties fail at
    different levels: an unverifiable entry drops out of the count, while only
    an unidentifiable CLI or a missing registry hides the segment entirely.
    """
    reg = os.path.join(HOME, ".claude", "bg-procs")
    if not os.path.isdir(reg):
        return None
    owner, owner_start = owning_cli()
    if not owner:
        return None
    count = 0
    for name in os.listdir(reg):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(reg, name)) as f:
                entry = json.load(f)
        except (OSError, ValueError):
            continue
        if (
            str(entry.get("owner") or "") != owner
            or str(entry.get("owner_start") or "") != owner_start
        ):
            continue
        pid = str(entry.get("pid") or "")
        if not pid.isdigit():
            continue
        try:
            if proc_start(pid) != str(entry.get("start") or ""):
                continue
        except (OSError, ValueError, IndexError):
            continue
        count += 1
    return f"{COLORS['blue']}⚙ {count} bg{RESET}" if count else None


PR_STYLE = {
    "approved": COLORS["green"],
    "changes_requested": COLORS["red"],
    "pending": COLORS["yellow"],
    "draft": DIM,
}


def segment_git(data, cwd):
    """Branch, dirty marker, and the open PR for it. The PR rides here rather
    than in its own segment because it is the same question — what state is
    this branch in — and it costs no extra width when there is no PR."""

    def git(*args):
        return subprocess.run(
            ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=0.2
        ).stdout.strip()

    branch = git("symbolic-ref", "--short", "-q", "HEAD") or git(
        "rev-parse", "--short", "HEAD"
    )
    if not branch:
        return None
    try:
        dirty = "*" if git("status", "--porcelain", "-uno", "--no-renames") else ""
    except subprocess.TimeoutExpired:
        dirty = "?"
    pr = data.get("pr")
    pr_part = ""
    if isinstance(pr, dict) and pr.get("number"):
        style = PR_STYLE.get(pr.get("review_state"), DIM)
        pr_part = f" {style}#{pr['number']}{RESET}"
    return f"{COLORS['cyan']}⎇ {branch}{dirty}{RESET}{pr_part}"


def segment_toolkit():
    """The "are my changes applied?" light. install.sh stamps v<count>·<sha>;
    a ⚠ means the repo has moved past that stamp and needs a re-install.

    Freshness fails safe: only a positively verified match shows a clean stamp.
    A timeout or error shows a dim ? rather than asserting changes are live.
    """
    try:
        with open(os.path.join(HOME, ".claude", "agent-toolkit-version")) as f:
            label = f.read().strip()
    except OSError:
        return None
    if not label:
        return None
    marker = f"{DIM}?{RESET}"
    m = re.search(r"·([0-9a-f]+)", label)
    if m:
        try:
            cur = subprocess.run(
                [
                    "git",
                    "-C",
                    os.path.join(HOME, ".claude", "agent-toolkit"),
                    "rev-parse",
                    "--short",
                    "HEAD",
                ],
                capture_output=True,
                text=True,
                timeout=0.2,
            ).stdout.strip()
            if cur == m.group(1):
                marker = ""
            elif cur:
                marker = f"{COLORS['yellow']}⚠{RESET}"
        except Exception:
            pass
    return f"{DIM}⬡ {label}{RESET}{marker}"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}

    tail = head = ""
    transcript = data.get("transcript_path")
    if transcript:
        try:
            tail, head = read_chunks(transcript)
        except OSError:
            pass

    cwd = (
        (data.get("workspace") or {}).get("current_dir")
        or data.get("cwd")
        or os.getcwd()
    )
    now = time.time()
    segments = []
    for build in (
        lambda: segment_model(data),
        lambda: segment_effort(data, tail, head),
        lambda: segment_context(data, tail),
        lambda: segment_lines(data),
        lambda: segment_limits(data, now),
        lambda: segment_tasks(data),
        lambda: segment_bg(),
        lambda: segment_git(data, cwd),
        lambda: f"{DIM}{os.path.basename(cwd)}{RESET}",
        lambda: segment_toolkit(),
    ):
        try:
            seg = build()
        except Exception:
            seg = None
        if seg:
            segments.append(seg)
    print(SEP.join(segments))


if __name__ == "__main__":
    main()
