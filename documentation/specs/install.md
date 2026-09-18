# Install

`install.sh` puts the toolkit on a Linux machine and keeps the machine in step with the version directory it is installed from. `INSTALL.md` is the guide a person or an agent follows to get there.

## Terms

| Term | Meaning |
| ------------------- | ------- |
| version directory | the directory holding one version of the toolkit: a git checkout, or a release unpacked into a folder such as `~/.claude/agent-toolkit-releases/v<N>`. Install behaves the same for either |
| stable link | `~/.claude/agent-toolkit`, a symlink to the installed version directory. Nothing else on the device names the version directory |
| root checks | the checks that judge a version directory on its own, listed under Root checks |
| launcher | `~/.claude/agent-toolkit-run`, a plain file outside every version directory. Every command the toolkit writes into settings runs through it |
| toolkit-owned value | a value in `settings.json` the toolkit sets |
| finding | one entry in a report: what is wrong or what changed, its severity, who acts, and the fix |

## Boundaries

- Linux only.
- Install writes only inside `~/.claude`. Its only network use is fetching plugins, in a full install.
- It never runs `sudo`, never installs a system package, never sets git identity, and never runs git over the network.
- It writes nothing inside the version directory, so a read-only directory, or one with no `.git`, installs the same way.
- It never deletes a version directory, the one it replaces included.
- How a new version arrives in a version directory is outside install. Install only ever acts on the directory it is run from.

## Modes

| Invocation | Writes | Network | Output | Exit |
| ---------------------- | ------ | ------- | ------ | ---- |
| `install.sh` | all installed state | plugin fetches | terminal report | `0` no required finding remains, `1` one does |
| `install.sh --dry-run` | nothing | none | every change a full install would make, then the terminal report | `0` a full install can go green on its own, `1` it cannot, because a root check fails or a user step is needed |
| `install.sh --sync` | local installed state | none | hook report | always `0` |
| `install.sh --help` | nothing | none | usage | `0` |
| any other argument | nothing | none | usage on stderr | `2` |

- A full install points the stable link at the directory it runs from. That is how a moved checkout, or a different version directory, gets installed. See Going live.
- `--sync` runs through the launcher at `SessionStart` (`startup`, `resume`, `clear`, `compact`, `fork`) and after an edit to a skill or agent inside the installed version directory. It never re-points the stable link. Started from a directory the stable link does not point at, it changes nothing and prints nothing.

## What install owns

| State | Path | Rule |
| ------------- | ---- | ---- |
| stable link | `~/.claude/agent-toolkit` | a symlink to the version directory, moved only as Going live describes. A real directory at this path is never replaced or written into |
| launcher | `~/.claude/agent-toolkit-run` | a copy of the version directory's launcher, replaced whenever the two differ |
| skills | `~/.claude/skills/<name>` | one symlink per skill into the version directory. A link into the previously installed version directory is removed, as is a dangling link whose target lies inside a version directory. Links the user made elsewhere are left alone, dangling or not |
| agents | `~/.claude/agents/<name>.md`, `~/.claude/agents/.toolkit-agents` | copies. The manifest names what the toolkit owns, so a retired agent is removed. A file at a toolkit agent's name that the manifest does not list is backed up, then replaced |
| settings | `~/.claude/settings.json` | toolkit-owned values merged in, everything else kept. See Settings |
| ledger | `~/.claude/agent-toolkit-applied.json` | the toolkit-owned values this machine's installs introduced or changed |
| pointer | `~/.claude/CLAUDE.md` | imports `@~/.claude/agent-toolkit/CLAUDE.md` |
| retro marker | `~/.claude/retro/since` | stamped at the first install, never rewritten |
| plugins | Claude Code's plugin store | the required marketplaces registered, the required plugins installed at user scope |
| bridge | `~/.claude/tools/penpot-mcp/` | a copy of each file in the version directory's `tools/penpot-mcp/`, replaced whenever the two differ. Nothing else in that directory is read, written or removed, so the dependencies and build the bridge puts there at its first run outlive every version |
| version stamp | `~/.claude/agent-toolkit-version` | the installed root's version, see Version identity. Written when no required finding stands. Removed when the installed root has no version |
| backups | `~/.claude/backups/` | a copy taken before every write to settings, the pointer, or a replaced agent file. A backup never overwrites another. Never pruned |

Install replaces every file it writes (launcher, bridge, settings, pointer, agents, ledger, stamp) by a rename, never by rewriting it in place.

## Going live

Nothing from a version directory reaches the device before that directory passes its root checks.

1. Install runs the root checks against the directory it runs from, before writing anything derived from it.
2. **Pass:** install moves the stable link to it and applies its state. The move is atomic: at every moment the stable link resolves to one complete version directory, the old one or the new one, and never to nothing. A write that fails after the move leaves the new directory live, and the report names what did not apply.
3. **Fail:** install writes nothing. The stable link stays where it was, so the previously installed directory, if there is one, stays live and untouched. The failures are `toolkit` findings and install exits `1`.

The same rule holds when the directory is already live, as with a checkout updated in place: a full install or `--sync` against a root that fails its checks writes nothing and reports. There is nothing to roll back to, so the link stays.

### Root checks

- every entry point the wiring names exists in the root and is executable, as do `install.sh` and the files install itself reads;
- the launcher exists in the root, and its own first line runs;
- the launcher run against a missing entry point asks, and the guard's first line runs;
- `skills/` and `agents/` hold something, so a partly unpacked directory never installs as an empty toolkit;
- every file install copies out of `tools/penpot-mcp/` is in the root, and each of its scripts starts, which is the same evidence of a whole directory that `skills/` and `agents/` are;
- every python hook compiles and `hooks/lib` imports, checked without writing into the root.

## Version identity

A root's version is `v<count>·<sha>`: the commit count of its HEAD and its abbreviated commit id. Releases are named `v<count>`, so a checkout and a release compare directly.

1. When the root is the top level of its own git work tree, the version comes from that history. A repository in a parent directory never counts.
2. Otherwise it comes from a `VERSION` file at the root holding that one line. A release's `VERSION` is written into its folder when the release arrives.
3. Otherwise the root has no version. It installs normally, and the stamp is removed.

A `VERSION` line in any other form counts as no version. Two versions are equal when their counts match and one sha is a prefix of the other. The stamp and the status line's freshness light both read a root's version through this rule, implemented once.

## Settings

- **Current** means the merge would change no value. Key order, whitespace, and the position of a foreign entry in an array are not differences. A current file is never rewritten.
- A write keeps every foreign key, value and hook entry, in the order they had.
- **Toolkit-owned values are enforced.** One edited by hand is restored at the next apply. Changing one means changing the toolkit.
- **A value the toolkit stops setting is removed** at the next apply: a top-level key, an `env` or `enabledPlugins` or `attribution` entry, `permissions.defaultMode`, a `permissions.deny` rule, an `additionalDirectories` entry. It stays when the ledger does not hold it with its current value, which covers two cases:
  - the user changed it after the toolkit wrote it;
  - it already held that value before the toolkit first wrote it.
- On a machine whose install predates the ledger, every toolkit-owned value present at the first apply that writes a ledger counts as toolkit-written. So does a value an earlier version wrote in a form it no longer uses, such as an absolute-path permission rule now written with `~/`.
- **A value the toolkit keeps unset is removed at every apply**, whoever set it. `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is the one, since agent teams spawn parallel sessions rather than subagents. It is not owned, so it is never recorded, and setting it again means changing the toolkit.
- A hook entry and the status line are the toolkit's when their command runs the launcher or a path under the stable link, including entries written by the toolkit's previous generation. They need no ledger.
- Removing a plugin's `enabledPlugins` entry does not uninstall the plugin.
- A settings file that does not parse, or that the merge cannot apply to, is never written. The finding carries the command that opens it, since no command can know the right value.
- **A ledger that will not read recovers the way a missing one does**, from the file itself. It is moved aside, kept in backups, and reported as an advisory: rebuilding from the file can vouch only for what the file still holds. Retiring nothing instead would leave retirement off for good, because the ledger that run writes would hold only what that run changed.
- Claude Code writes this file too, and honours no lock of install's. Immediately before the rename, install re-reads the file. If it changed since the merge began, install redoes the merge against the new content.
- Applies are serialised across the machine. A `--sync` that cannot take the lock within 5 seconds applies nothing and still reports, and a full install waits up to 60 seconds for it.
- **A ledger that does not parse never holds an apply back.** It is moved aside to a backup name and the run carries on as though there were none: every toolkit-owned value is set, and nothing is retired. The run reports it.
- Replacing a `settings.json` or a pointer that was a symlink writes the file in its place and says so.

## Wiring

- Every command the toolkit writes into settings, the status line included, runs the launcher with the entry point it stands for. Each one runs correctly when the home path contains a space.
- The pointer's import and the permission rules use `~/` paths, which Claude Code resolves.
- The launcher resolves the entry point through the stable link at call time and passes stdin and arguments through untouched. It passes the exit status through as well, except for a `PreToolUse` entry point that exits anything other than `0` or `2`: Claude Code treats those as non-blocking, so the launcher asks instead. When the stable link dangles, or the entry point is missing or not executable, it degrades by caller:

| Caller | What it does |
| ------------------ | ------------ |
| `PreToolUse` | returns `permissionDecision: "ask"` with a reason naming the fix. Never lets the call through unasked |
| `SessionStart` | the hook report, with a required finding naming where the stable link points and the command to run from the version directory's current location |
| status line | one short line saying the toolkit is unreachable |
| any other event | exit `0`, no output |

- **The gate reads its payload with `jq`, or with `python3` when `jq` is missing**, so the same verdicts hold on a machine that lacks one of them. A read-only call passes either way. With neither, the call is let through and the missing tools are a required finding.
- The launcher's own deletion is not defended against, any more than the deletion of `settings.json` is.
- Claude Code reloads hooks and permissions when `settings.json` changes. A wiring change that one session's `--sync` applies reaches every running session on the machine.

## Reports

Every run builds one list of findings.

| Field | Values |
| --------- | ------ |
| severity | `required`: the toolkit is not working as installed. `advisory`: one named feature is degraded |
| who acts | `install`: a full install fixes it. `user`: the user runs a command in their own terminal. `toolkit`: the version directory itself is broken, and the finding names the file |
| fix | the exact command, runnable as printed. A placeholder appears only for a value that is the user's own, such as their email address |

**Restart.** A run calls for restarting Claude Code when it changed something Claude Code reads only at start: `env`, a plugin or an `enabledPlugins` entry, or the pointer, or when it created `~/.claude/agents` or `~/.claude/skills`. Claude Code picks up everything else while running.

### Terminal report

Full install and `--dry-run` print, in this order:

1. What changed, or would change.
2. Findings under three headings: **Needs you** (`user`), **Run install again** (`install`), **Toolkit** (`toolkit`). Advisories follow the required findings under each heading.
3. The restart line, when one is due.
4. One result line with the count of required and advisory findings.

Each `user` fix stands alone on its own line, so it can be copied whole.

### Hook report

`--sync` prints nothing when there is nothing to report. Otherwise it prints exactly one JSON object and exits `0`, shaped for the event that ran it, `SessionStart` or `PostToolUse`:

```json
{
  "systemMessage": "agent-toolkit: 1 problem. Ask Claude to fix it, or run ~/.claude/agent-toolkit/install.sh",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "agent-toolkit doctor:\n✗ plugin pr-review-toolkit@claude-plugins-official is not installed. Fix (install): ~/.claude/agent-toolkit/install.sh\n! git user.email is not set. Fix (user): git config --global user.email \"<your email>\""
  }
}
```

- `systemMessage` reaches the user. One line, present only when a required finding stands, or when the run wrote settings or the pointer, or when a restart is due.
- `additionalContext` reaches the model. It opens with `agent-toolkit doctor:` and holds every finding, advisories included, each with who acts and its fix, plus what was written and its backup path.
- At `SessionStart`, `reloadSkills: true` is set when the run changed a skill link. A run whose only change is a relinked skill prints the object holding that field alone, because a new skill Claude Code has not rescanned is not yet usable.
- An agent copy or a skill link applied without a problem is not reported in a hook. A removal is: taking something away is not the same as keeping it current.
- The exit is always `0` because Claude Code drops the plain stdout of a hook that exits non-zero and shows the user only the first line of its stderr.

## Requirements

The list lives once, in `install.sh`. The doctor checks it, both reports render it, and the guide never repeats it. No check uses the network.

**`--sync` checks only what it can act on.** The requirements a user can satisfy only outside Claude Code, being `gh`, the ssh-agent and the git identity, are checked by a full install and skipped at session start. They cannot be fixed from the session that would report them, they cost a session start the time to ask other programs, and the same three lines in every session's context say nothing new.

| Requirement | Severity | Fix |
| ----------- | -------- | --- |
| `jq` and `python3` on PATH | required. Without them nothing can be merged or verified, so install stops before writing anything | the package line |
| `git` and `flock` on PATH | required | the package line |
| `claude` on PATH, at or above the minimum version | required. The plugin step is skipped | `curl -fsSL https://claude.ai/install.sh \| bash`, or `claude update` |
| the root checks pass | required, `toolkit` | the file, and for a python failure the interpreter's last line |
| each required plugin installed and enabled | required, `install` | a full install |
| `python3` imports `sqlite3` | advisory: the retro recorder stores nothing | the package line |
| the retro marker and store are readable | advisory | the recorder's own description of the problem |
| `gh` on PATH, holding a token for github.com | advisory: PR and release flows | the package line, then `gh auth login --hostname github.com --git-protocol ssh --web` |
| an ssh-agent holding a key is reachable from the shell Claude Code runs in | advisory: git over SSH from Claude Code fails, an approved push included | start Claude Code from a shell whose agent holds the key: `eval "$(ssh-agent -s)" && ssh-add && claude` |
| git `user.name` and `user.email` set | advisory: commits fail | `git config --global user.name "<your name>"` and `git config --global user.email "<your email>"` |

- **The package line** installs every missing package in one command, for the package manager present: `apt-get`, `dnf` or `pacman`. With none of those, it names the packages.
- A python too old for the hooks fails the compile check, which names the reason, so the version is not checked separately.

### Plugins

| Plugin | Marketplace | Source |
| ------------------------------------------------ | ------------------------- | ------------------------------------ |
| `pr-review-toolkit@claude-plugins-official` | `claude-plugins-official` | `anthropics/claude-plugins-official` |
| `claude-notifications-go@claude-notifications-go` | `claude-notifications-go` | `777genius/agent-notifications` |

- A full install registers each marketplace not already registered under its name, whatever source an existing registration used, then installs each plugin `claude plugin list --json` does not show, at user scope.
- Fetches run with `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`. Both sources are public, so HTTPS needs no credentials, while Claude Code's default SSH clone needs a key loaded in an ssh-agent the calling shell may not have. The user's own git remotes are untouched.
- `--dry-run` and `--sync` never fetch.
- A failed fetch or install is a required finding carrying Claude Code's own message. Everything local still applies.

## The guide

`INSTALL.md` sits at the repo root and is the first thing a person or an agent reads. README's Install section links to it. It carries only what `install.sh` cannot check, and the loop around it:

1. **Get the repo.** A person, in their own terminal. The repo is private, so GitHub access comes first:
   - `gh auth login --hostname github.com --git-protocol ssh --web`, which can generate an SSH key and upload it.
   - `git clone git@github.com:zo-el/agent-toolkit-v2.git ~/Documents/git-repo/agent-toolkit-v2`

   One sentence says these need git and gh. No other line of the guide names a package. Any location works except `~/.claude/agent-toolkit`. An agent already holding the repo starts at step 2.
2. **Run `./install.sh`** from the repo.
3. **Do what it lists under Needs you.** A person runs those commands. An agent hands them to the user exactly as printed and runs none of them.
4. **Run `./install.sh` again** until it ends with no required finding.
5. **Start Claude Code, or restart it when the report says so,** and sign in if asked.

It also states, once each:

- what install touches;
- the bridge: install puts its files at `~/.claude/tools/penpot-mcp/` and does nothing else for it. The Penpot account, Node, the dependencies it fetches at its first run, and connecting the plugin in a browser are the user's, and no install check looks at any of them;
- the exit codes;
- updating: once a new version is in the version directory, the next session start on the machine applies it and says when to restart, and `./install.sh` applies it immediately;
- moving the checkout: run `install.sh` from the new location.

## Failure

| What goes wrong | What happens |
| --------------- | ------------ |
| `jq` or `python3` missing | nothing written. Required finding with the package line |
| the root being installed fails a root check | nothing written, the stable link stays where it was. `toolkit` findings, exit `1`. The failing root stays on disk |
| `~/.claude/agent-toolkit` is a real directory | nothing written, exit `1`. The finding gives the command that moves it to `~/Documents/git-repo/agent-toolkit-v2` and runs install from there |
| the stable link dangles | a `PreToolUse` call is asked, session start reports it to the user and the model, the status line says so. A full install from the new location re-points the link, drops the old location from the approved directories, and unlinks the old location's skills |
| a skill name is held by something that is not the toolkit's | required finding naming the path. The path is left untouched |
| `settings.json` does not parse, or the merge fails | the file is left untouched. Required finding with the reason and the newest backup |
| another writer changes `settings.json` between the start of the merge and the re-read before the rename | the merge is redone against the new content. A write landing after that re-read is not detected |
| `--sync` cannot take the lock | nothing applied. Findings still reported |
| the ledger does not parse | it is moved aside to a backup name. Every toolkit-owned value is set, nothing is retired, and the run reports it |
| `settings.json` exists and is empty | the file is left untouched. Required user finding, because an empty file is a file something is wrong with, not an empty object |
| `settings.json` or the pointer is a symlink | the file is written in the link's place, and the report says the link is gone |
| a backup does not parse | it is never offered as the file to restore. The newest backup that does parse is |
| a write inside `~/.claude` fails | earlier steps stay applied. The report names what did not apply. No version stamp |
| a plugin fetch fails, or `claude` is missing or too old | required finding. Everything local still applies |
| the version directory has no git history and no valid `VERSION` | installs. The stamp is removed |
| an unknown argument | usage on stderr, exit `2`, nothing written |

## Rejected

- **Distributing the toolkit as a plugin.** A plugin cannot ship CLAUDE.md, env, permissions or the status line, and its agents are namespaced (`plugin:developer`), which breaks every bare-name reference.
- **The guide as the requirement list.** A second copy of what the script checks, held in step only by a test. The report already renders the list for this machine, with each fix.
- **An inline fallback for the guard in `settings.json`.** It protects the guard alone, and session start still could not say the toolkit is gone.
- **A hand-kept list of retired values.** It works only when whoever retires a value remembers to add it.
- **Moving the stable link first and checking after.** A broken version would be live with nothing to roll back to.
- **Warning at session start instead of applying.** A stale file keeps running dead hook paths until someone acts, and a hook that cannot start does not block the tool it guards.
- **Allowing the checkout at the stable path.** One layout keeps the stable link free to point at any version directory.
