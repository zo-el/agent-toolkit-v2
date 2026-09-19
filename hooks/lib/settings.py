"""settings.json with the toolkit's values merged in and everything else kept.

    python3 hooks/lib/settings.py apply|plan < request.json

install.sh declares the values and holds the lock. This file does the rest of
the Settings contract in documentation/specs/install.md.

The request carries: settings, ledger and backups paths; desired, a fragment
shaped like settings.json; absent, key paths the toolkit keeps unset; forbidden,
array members it keeps unset, matched by what they are; home, root and
prev_root, for recognising what an earlier install wrote. The result is one JSON
object on stdout.
"""

import copy
import difflib
import errno
import json
import os
import re
import shlex
import sys
import tempfile
import time

MISSING = object()
ATTEMPTS = 5

# Recognised by their command rather than recorded in the ledger. install-skills
# is the previous generation's entry point, which never ran from the stable link.
OWNED_BY_COMMAND = ("hooks", "statusLine")
TOOLKIT_COMMAND = re.compile(r"agent-toolkit-run|\.claude/agent-toolkit/|install-skills")

# The only places a ledger entry may retire a value from. A ledger naming any
# other path, such as a permissions.allow rule or a hook, is ignored.
RETIRABLE_MEMBERS = {("permissions", "deny"), ("permissions", "additionalDirectories")}
NOT_TOP_LEVEL_VALUES = {"hooks", "statusLine", "permissions", "sandbox", "env", "enabledPlugins"}


class SettingsError(Exception):
    """kind is who can fix it: "user" or "install". fix is their command."""

    def __init__(self, kind, reason, fix=""):
        super().__init__(reason)
        self.kind = kind
        self.fix = fix


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
    """Equal by fingerprint. Python's own == says 1 == True."""
    return a is not MISSING and b is not MISSING and fingerprint(a) == fingerprint(b)


def ours(handler):
    return isinstance(handler, dict) and bool(
        TOOLKIT_COMMAND.search(str(handler.get("command") or ""))
    )


def retirable(path):
    if len(path) == 1:
        return path[0] not in NOT_TOP_LEVEL_VALUES
    return (len(path) == 2 and path[0] in ("env", "enabledPlugins", "attribution")) or path == (
        "permissions",
        "defaultMode",
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


def shell_path(path, home):
    if home and path.startswith(home + "/"):
        return "~/" + shlex.quote(path[len(home) + 1 :])
    return shlex.quote(path)


def for_the_user(error, request):
    """A failure in the file's own content. No command can know the right value,
    so the fix opens the file; install.sh names the newest backup beside it."""
    if error.fix:
        return error
    return SettingsError(
        error.kind, str(error), '"${EDITOR:-vi}" %s' % shell_path(request["settings"], request.get("home", ""))
    )


def ledger_on_disk(request, write, result):
    """The (values, members) the ledger holds, or None when there is none and
    the file itself has to say what an earlier install wrote.

    One that will not read is moved aside and reported, and then answers None
    like a missing one: rebuilding from the file is what a deleted ledger
    already does, and it claims nothing the toolkit's own wiring does not
    vouch for. Anything narrower leaves retirement off for good, since the
    ledger this run writes would hold only what this run changed.
    """
    path = request["ledger"]
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return (
            {tuple(e["path"]): e["value"] for e in data["values"] if retirable(tuple(e["path"]))},
            {(tuple(e["path"]), fingerprint(e["value"])) for e in data["members"] if tuple(e["path"]) in RETIRABLE_MEMBERS},
        )
    except FileNotFoundError:
        return None
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        reason = str(e)
        if write:
            try:
                os.makedirs(request["backups"], exist_ok=True)
                aside = free_name(request["backups"], "agent-toolkit-applied.json.unreadable")
                os.replace(path, aside)
                result["ledger_aside"] = aside
            except OSError as move_failed:
                reason += ", and it cannot be moved aside: %s" % (move_failed.strerror or move_failed)
        result["ledger_unreadable"] = reason
        return None


def free_name(directory, name):
    """A path under directory that nothing holds yet, named for the time."""
    base = os.path.join(directory, "%s-%s" % (name, time.strftime("%Y%m%d-%H%M%S")))
    path, n = base, 0
    while os.path.lexists(path):
        n += 1
        path = "%s.%d" % (base, n)
    return path


def predating(request, current, values, members):
    """On a machine whose install predates the ledger, every toolkit-owned value
    present now, in whichever form it was written.

    Toolkit wiring in the file is what says an install ran here. Without it this
    is a first apply, and the values in the file are the user's own."""
    if not has_toolkit_wiring(current):
        return {}, set()
    found_values = {p: get(current, p) for p in values if get(current, p) is not MISSING}
    found_members = set()
    for path, item in members:
        entries = get(current, path)
        if isinstance(entries, list):
            present = {fingerprint(e) for e in entries}
            found_members |= {(path, f) for f in earlier_forms(item, request) if f in present}
    return found_values, found_members


def refused(entry, rule, home):
    """A member the toolkit keeps unset, matched by what it is rather than by a
    ledger that vouches for who wrote it: one path exactly, or anything at or
    below one. A path above either is the user's own and is left alone.

    Normalised first, because the rule names a directory and there are a dozen
    spellings of one: a trailing slash, a doubled separator, a "." or a ".."
    that any path resolver collapses. A symlink pointing into one is not caught,
    which would need the filesystem: an entry like that is one the user made and
    approved deliberately, and it is theirs."""
    path = named(entry, home)
    if path is None:
        return False
    if "is" in rule:
        return path == rule["is"]
    return path == rule["under"] or path.startswith(rule["under"] + "/")


def named(entry, home):
    """The directory an entry names, or None for an entry that is not a path."""
    if not isinstance(entry, str):
        return None
    if entry.startswith("~/"):
        entry = home + entry[1:]
    return os.path.normpath(entry)


def merge(current, request, on_disk):
    """(merged, ledger, restart reasons, approvals taken away). on_disk is what
    the ledger holds, or None when there is none and the file itself has to say
    what an earlier install wrote."""
    if not isinstance(current, dict):
        raise SettingsError("user", "the top level is not an object")
    desired = request["desired"]
    values, members = owned(desired)
    had_values, had_members = on_disk if on_disk is not None else predating(request, current, values, members)
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
    for rule in request.get("forbidden", []):
        entries = get(merged, tuple(rule["path"]))
        if isinstance(entries, list):
            entries[:] = [e for e in entries if not refused(e, rule, request["home"])]

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
    return merged, ledger, restart, taken_away(current, merged, request)


def taken_away(current, merged, request):
    """The paths a kept-unset rule names that current approves and merged does
    not. Read off the two files rather than the rule's own filter, because the
    ledger retires the entry an earlier version wrote before that filter runs."""
    home = request["home"]
    gone = set()
    for rule in request.get("forbidden", []):
        before = get(current, tuple(rule["path"]))
        after = get(merged, tuple(rule["path"]))
        if isinstance(before, list):
            left = {named(e, home) for e in after} if isinstance(after, list) else set()
            gone |= {named(e, home) for e in before if refused(e, rule, home)} - left
    return sorted(gone)


def merge_hooks(merged, wiring):
    """The toolkit's handlers are taken out of every event, including events it
    no longer wires, then its groups are appended. A foreign handler sharing a
    group with one of ours keeps its group. An event the toolkit does not wire is
    left alone when it is not a list; one it wires fails the merge."""
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
    """allow_nan=False: Claude Code's parser rejects NaN, so a file holding it
    would load no settings at all."""
    return json.dumps(settings, indent=2, ensure_ascii=False, allow_nan=False) + "\n"


def redacted(settings, desired):
    """For a diff that is printed: env values carry tokens. The toolkit's own
    stay readable."""
    env = settings.get("env")
    if not isinstance(env, dict):
        return settings
    own = desired.get("env", {})
    return {**settings, "env": {k: (v if k in own else "<redacted>") for k, v in env.items()}}


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise SettingsError("user", "cannot read %s: %s" % (path, e.strerror or e), "ls -l %s" % shlex.quote(path))


def reject_constant(name):
    raise ValueError("%s is not JSON" % name)


def parse(raw):
    """An absent file is a first install. A file that is there and holds nothing
    is a loss the user owns: overwriting it would bury whatever it held."""
    if raw is None:
        return {}
    if not raw.strip():
        raise SettingsError("user", "settings.json is empty")
    try:
        return json.loads(raw, parse_constant=reject_constant)
    except ValueError as e:
        raise SettingsError("user", "settings.json does not parse: %s" % e)


def newest_backup(backups):
    """(path, when) of the newest settings backup that parses, or ("", "").
    One that will not read or will not parse is no backup to offer."""
    found = []
    try:
        names = os.listdir(backups)
    except OSError:
        return "", ""
    for name in names:
        if not name.startswith("settings.json."):
            continue
        path = os.path.join(backups, name)
        try:
            found.append((os.stat(path).st_mtime, path))
        except OSError:
            continue
    for mtime, path in sorted(found, reverse=True):
        try:
            with open(path, encoding="utf-8") as f:
                json.load(f)
        except (OSError, ValueError):
            continue
        return path, time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
    return "", ""


def write_new(path, data, mode):
    """Created with O_EXCL, so a backup never overwrites another."""
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
    raise OSError(errno.EEXIST, "no free backup name", base)


def stage(path, data, new_mode=None):
    """data in a temporary file beside path, carrying path's mode, ready to be
    renamed over it. The temporary name keeps path's extension, so a deny rule
    written for settings*.json covers it too."""
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    stem, ext = os.path.splitext(os.path.basename(path))
    try:
        fd, tmp = tempfile.mkstemp(prefix=stem + ".", suffix=ext, dir=directory)
    except OSError as e:
        # The temporary name is this file's own, so the directory is what the
        # report can name.
        raise OSError(e.errno, e.strerror, directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        try:
            mode = os.stat(path).st_mode & 0o7777
        except OSError:
            mode = new_mode if new_mode is not None else 0o666 & ~current_umask()
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


def write_failed(error, fallback):
    where = error.filename or fallback
    return SettingsError("user", "cannot write %s: %s" % (where, error.strerror or error), "ls -ld %s" % shlex.quote(where))


def run(request, write, read=None):
    """One apply or plan. read is the only way this reads settings.json, so a
    test can change the file between the merge and the re-read."""
    path = request["settings"]
    read = read or read_bytes
    result = {"settings": "current", "ledger": "current", "restart": []}
    on_disk = ledger_on_disk(request, write, result)
    for _ in range(ATTEMPTS):
        before = read(path)
        try:
            current = parse(before)
            merged, ledger, restart, taken = merge(current, request, on_disk)
        except SettingsError as e:
            raise for_the_user(e, request)
        try:
            text = render(merged).encode("utf-8")
        except ValueError as e:
            raise for_the_user(SettingsError("user", "settings.json holds a value JSON cannot carry: %s" % e), request)
        changed = before is None or fingerprint(merged) != fingerprint(current)
        if not write:
            if changed:
                old = render(redacted(current, request["desired"])).splitlines(True) if before is not None else []
                new = render(redacted(merged, request["desired"])).splitlines(True)
                result.update(settings="would-write", restart=restart, diff="".join(difflib.unified_diff(old, new, path, path)))
            if "ledger_unreadable" in result or ledger_bytes(ledger) != read_bytes(request["ledger"]):
                result["ledger"] = "would-write"
            return result
        if changed:
            saved = staged = ""
            try:
                saved = backup(request["backups"], before) if before is not None else ""
                staged = stage(path, text, new_mode=0o600)
            except OSError as e:
                if saved:
                    os.unlink(saved)
                raise write_failed(e, path)
            if read(path) != before:
                os.unlink(staged)
                if saved:
                    os.unlink(saved)
                continue
            link = os.readlink(path) if os.path.islink(path) else ""
            # The old ledger with this one folded in, written while the values
            # are still unapplied: a ledger write that fails after the rename
            # then leaves no value recorded as the user's own.
            write_ledger(request["ledger"], combined(on_disk, ledger), result)
            try:
                # A settings.json that is a symlink becomes a file: writing
                # through the link would write outside ~/.claude.
                os.replace(staged, path)
            except OSError as e:
                os.unlink(staged)
                raise write_failed(e, path)
            result.update(settings="written", backup=saved, restart=restart, taken_away=taken)
            if link:
                result["replaced_link"] = link
        write_ledger(request["ledger"], ledger, result)
        return result
    raise SettingsError("install", "settings.json changed on every re-read, so nothing was applied")


def combined(on_disk, ledger):
    """This run's ledger folded into what was there before it."""
    if on_disk is None:
        return ledger
    had_values, had_members = on_disk
    values = dict(had_values)
    values.update((tuple(e["path"]), e["value"]) for e in ledger["values"])
    members = list(had_members) + [(tuple(e["path"]), fingerprint(e["value"])) for e in ledger["members"]]
    return {
        "values": [{"path": list(p), "value": v} for p, v in values.items()],
        "members": [{"path": list(p), "value": json.loads(i)} for p, i in dict.fromkeys(members)],
    }


def ledger_bytes(ledger):
    return (json.dumps(ledger, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def write_ledger(path, ledger, result):
    data = ledger_bytes(ledger)
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
        newest, when = newest_backup(request["backups"])
        result = {"settings": "failed", "kind": e.kind, "reason": str(e), "fix": e.fix,
                  "newest_backup": newest, "backup_when": when}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
