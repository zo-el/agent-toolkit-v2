"""settings.json with the toolkit's values merged in and everything else kept.

    python3 hooks/lib/settings.py apply|plan < request.json

install.sh declares the values and serialises applies across the machine. This
file owns the rest of the contract in documentation/specs/install.md, Settings:
what a merge changes, when a file is current, the ledger of values this
machine's installs wrote, and the re-read that keeps Claude Code's own writes.

The request carries: settings, ledger and backups paths; desired, a fragment
shaped like settings.json; absent, key paths the toolkit keeps unset; home,
root and prev_root, for recognising what an earlier install wrote. The result
is one JSON object on stdout.
"""

import copy
import difflib
import json
import os
import re
import sys
import tempfile
import time

MISSING = object()
ATTEMPTS = 5

# Recognised by their command rather than recorded in the ledger. install-skills
# is the previous generation's entry point, which never ran from the stable link.
OWNED_BY_COMMAND = ("hooks", "statusLine")
TOOLKIT_COMMAND = re.compile(r"agent-toolkit-run|\.claude/agent-toolkit/|install-skills")


class SettingsError(Exception):
    """kind is who can fix it: "user" for the file's content, "install" for a
    write that did not land."""

    def __init__(self, kind, reason):
        super().__init__(reason)
        self.kind = kind


def fingerprint(node):
    """Equal for two values that differ only in key order, whitespace, or where
    an entry sits in an array."""

    def canonical(value):
        if isinstance(value, dict):
            return {k: canonical(v) for k, v in value.items()}
        if isinstance(value, list):
            return sorted((canonical(v) for v in value), key=fingerprint)
        return value

    return json.dumps(canonical(node), sort_keys=True)


def get(node, path):
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return MISSING
        node = node[key]
    return node


def put(node, path, value):
    for depth, key in enumerate(path[:-1]):
        node = node.setdefault(key, {})
        if not isinstance(node, dict):
            raise SettingsError("user", "%s is not an object" % ".".join(path[: depth + 1]))
    node[path[-1]] = value


def drop(node, path):
    parent = get(node, path[:-1])
    if isinstance(parent, dict):
        parent.pop(path[-1], None)


def same(a, b):
    """JSON equality. Python's own == says 1 == True."""
    return a is not MISSING and b is not MISSING and fingerprint(a) == fingerprint(b)


def ours(handler):
    return isinstance(handler, dict) and bool(
        TOOLKIT_COMMAND.search(str(handler.get("command") or ""))
    )


def owned(desired):
    """(values, members) the desired fragment sets: a scalar at a key path, or
    an entry in a list at a key path. Members keep their declared order, which
    is the order a write appends them in."""
    values, members = {}, []

    def walk(node, path):
        for key, value in node.items():
            here = path + (key,)
            if not path and key in OWNED_BY_COMMAND:
                continue
            if isinstance(value, dict):
                walk(value, here)
            elif isinstance(value, list):
                members.extend((here, fingerprint(v)) for v in value)
            else:
                values[here] = value

    walk(desired, ())
    return values, list(dict.fromkeys(members))


def has_toolkit_wiring(settings):
    hooks = settings.get("hooks")
    groups = [g for gs in hooks.values() if isinstance(gs, list) for g in gs] if isinstance(hooks, dict) else []
    handlers = [h for g in groups if isinstance(g, dict) and isinstance(g.get("hooks"), list) for h in g["hooks"]]
    return ours(settings.get("statusLine")) or any(ours(h) for h in handlers)


def earlier_forms(item, request):
    """What an earlier install wrote for the same member: a ~/ path spelled
    out, and the directory the stable link pointed at before this install."""
    value = json.loads(item)
    if not isinstance(value, str):
        return {item}
    home, root, prev = request.get("home", ""), request.get("root", ""), request.get("prev_root", "")
    forms = {value}
    if home and "~/" in value:
        forms |= {value.replace("~/", home + "/"), value.replace("~/", "/" + home + "/")}
    if root and prev and prev != root:
        forms |= {f.replace(root, prev) for f in list(forms)}
    return {fingerprint(f) for f in forms}


def read_ledger(request, current, values, members):
    """The ledger on disk, or on a machine whose install predates it, every
    toolkit-owned value present now, in whichever form it was written."""
    try:
        with open(request["ledger"], encoding="utf-8") as f:
            data = json.load(f)
        return (
            {tuple(e["path"]): e["value"] for e in data["values"]},
            {(tuple(e["path"]), fingerprint(e["value"])) for e in data["members"]},
        )
    except (OSError, ValueError, KeyError, TypeError):
        pass
    if not (request.get("prev_root") or has_toolkit_wiring(current)):
        return {}, set()
    found_values = {p: get(current, p) for p in values if get(current, p) is not MISSING}
    found_members = set()
    for path, item in members:
        entries = get(current, path)
        if isinstance(entries, list):
            present = {fingerprint(e) for e in entries}
            found_members |= {(path, f) for f in earlier_forms(item, request) if f in present}
    return found_values, found_members


def merge(current, request):
    """(merged, ledger, restart reasons)."""
    if not isinstance(current, dict):
        raise SettingsError("user", "the top level is not an object")
    desired = request["desired"]
    values, members = owned(desired)
    had_values, had_members = read_ledger(request, current, values, members)
    merged = copy.deepcopy(current)
    kept_values, kept_members = {}, []

    for path, value in had_values.items():
        if path not in values and same(get(merged, path), value):
            drop(merged, path)
    wanted = set(members)
    for path, item in had_members:
        entries = get(merged, path)
        if (path, item) not in wanted and isinstance(entries, list):
            entries[:] = [e for e in entries if fingerprint(e) != item]
    for path in request.get("absent", []):
        drop(merged, tuple(path))

    for path, value in values.items():
        before = get(current, path)
        put(merged, path, value)
        if not same(before, value) or same(had_values.get(path, MISSING), value):
            kept_values[path] = value
    for path, item in members:
        entries = get(merged, path)
        if entries is MISSING:
            entries = []
            put(merged, path, entries)
        if not isinstance(entries, list):
            raise SettingsError("user", "%s is not a list" % ".".join(path))
        if not any(fingerprint(e) == item for e in entries):
            entries.append(json.loads(item))
            kept_members.append((path, item))
        elif (path, item) in had_members:
            kept_members.append((path, item))

    if "statusLine" in desired:
        merged["statusLine"] = desired["statusLine"]
    elif ours(merged.get("statusLine")):
        del merged["statusLine"]
    merge_hooks(merged, desired.get("hooks", {}))

    restart = [k for k in ("env", "enabledPlugins") if fingerprint(current.get(k)) != fingerprint(merged.get(k))]
    ledger = {
        "values": [{"path": list(p), "value": v} for p, v in kept_values.items()],
        "members": [{"path": list(p), "value": json.loads(i)} for p, i in kept_members],
    }
    return merged, ledger, restart


def merge_hooks(merged, wiring):
    """The toolkit's handlers are taken out of every event, including events it
    no longer wires, then its groups are appended. A foreign handler sharing a
    group with one of ours keeps its group. An event that is not a list is left
    alone rather than failing the whole merge."""
    hooks = merged.get("hooks", MISSING)
    if hooks is MISSING:
        if not wiring:
            return
        hooks = merged["hooks"] = {}
    elif not isinstance(hooks, dict):
        raise SettingsError("user", "hooks is not an object")
    emptied = set()
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            handlers = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(handlers, list) or not any(ours(h) for h in handlers):
                kept.append(group)
            elif any(not ours(h) for h in handlers):
                kept.append({**group, "hooks": [h for h in handlers if not ours(h)]})
        if groups and not kept:
            emptied.add(event)
        groups[:] = kept
    for event, groups in wiring.items():
        existing = hooks.setdefault(event, [])
        if not isinstance(existing, list):
            raise SettingsError("user", "hooks.%s is not a list" % event)
        existing.extend(copy.deepcopy(groups))
    for event in emptied - set(wiring):
        del hooks[event]


def render(settings):
    return json.dumps(settings, indent=2, ensure_ascii=False) + "\n"


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise SettingsError("user", "cannot read %s: %s" % (path, e.strerror))


def parse(raw):
    if raw is None or not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except ValueError as e:
        raise SettingsError("user", "settings.json does not parse: %s" % e)


def newest_backup(backups):
    try:
        names = [n for n in os.listdir(backups) if n.startswith("settings.json.")]
    except OSError:
        return ""
    paths = [os.path.join(backups, n) for n in names]
    return max(paths, key=os.path.getmtime, default="")


def write_new(path, data, mode):
    """A file that did not exist, created whole, so a backup never overwrites
    another and a reader never sees half of one."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def backup(backups, raw):
    os.makedirs(backups, exist_ok=True)
    base = os.path.join(backups, "settings.json." + time.strftime("%Y%m%d-%H%M%S"))
    for n in range(1000):
        path = base if n == 0 else "%s.%d" % (base, n)
        try:
            write_new(path, raw, 0o600)
            return path
        except FileExistsError:
            continue
    raise OSError("no free backup name at " + base)


def stage(path, data):
    """data in a temporary file beside path, carrying path's mode, ready to be
    renamed over it."""
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        try:
            mode = os.stat(path).st_mode & 0o7777
        except OSError:
            mode = 0o666 & ~current_umask()
        os.chmod(tmp, mode)
    except BaseException:
        os.unlink(tmp)
        raise
    return tmp


def current_umask():
    mask = os.umask(0)
    os.umask(mask)
    return mask


def replace(path, data):
    os.replace(stage(path, data), path)


def run(request, write, read=read_bytes):
    """One apply or plan. read is the only way this touches settings.json
    before the rename, so a test can change the file between the merge and the
    re-read, which is the one window a concurrent writer can land in."""
    path = request["settings"]
    result = {"settings": "current", "ledger": "current", "restart": []}
    for _ in range(ATTEMPTS):
        before = read(path)
        current = parse(before)
        merged, ledger, restart = merge(current, request)
        changed = before is None or fingerprint(merged) != fingerprint(current)
        if not write:
            if changed:
                old = render(current).splitlines(True) if before is not None else []
                result.update(settings="would-write", restart=restart)
                result["diff"] = "".join(difflib.unified_diff(old, render(merged).splitlines(True), path, path))
            return result
        if changed:
            try:
                staged = stage(path, render(merged).encode("utf-8"))
                saved = backup(request["backups"], before) if before is not None else ""
            except OSError as e:
                raise SettingsError("install", "cannot write %s: %s" % (path, e.strerror or e))
            if read(path) != before:
                os.unlink(staged)
                if saved:
                    os.unlink(saved)
                continue
            try:
                # A settings.json that is a symlink becomes a file: writing
                # through the link would write outside ~/.claude.
                os.replace(staged, path)
            except OSError as e:
                os.unlink(staged)
                raise SettingsError("install", "cannot write %s: %s" % (path, e.strerror))
            result.update(settings="written", backup=saved, restart=restart)
        write_ledger(request["ledger"], ledger, result)
        return result
    raise SettingsError("install", "settings.json changed on every re-read, so nothing was applied")


def write_ledger(path, ledger, result):
    data = (json.dumps(ledger, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    try:
        if read_bytes(path) == data:
            return
        replace(path, data)
        result["ledger"] = "written"
    except (OSError, SettingsError) as e:
        result.update(ledger="failed", ledger_reason=str(getattr(e, "strerror", None) or e))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    request = json.load(sys.stdin)
    try:
        result = run(request, write=(mode == "apply"))
    except SettingsError as e:
        result = {"settings": "failed", "kind": e.kind, "reason": str(e)}
        if e.kind == "user":
            result["backup"] = newest_backup(request["backups"])
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
