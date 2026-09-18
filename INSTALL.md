# Install

Linux only.

## 1. Get the toolkit

In your own terminal. Both routes need `gh`, so GitHub access comes first.

```bash
gh auth login --hostname github.com --git-protocol ssh --web
```

`gh auth login` can generate an SSH key and upload it for you.

**To use the toolkit, fetch the latest release.** No clone, and no SSH key: this is also the way back when `~/.claude/agent-toolkit` points at nothing.

```bash
repo=zo-el/agent-toolkit-v2
tag="$(gh api "repos/$repo/releases/latest" --jq .tag_name)"
sha="$(gh api "repos/$repo/git/ref/tags/$tag" --jq .object.sha)"
dir="$HOME/.claude/agent-toolkit-releases/$tag"
mkdir -p "$dir"
gh api "repos/$repo/tarball/$sha" | tar -xz -C "$dir" --strip-components=1
printf '%s\n' "${sha:0:7}" >"$dir/REVISION"
cd "$dir"
```

`REVISION` is half of what names a version, and the archive carries the other half. Without it the directory has no version, and the status line shows none. The updater takes over once install has run.

**To work on the toolkit, clone it.** Installing from a clone is what puts a machine in dev mode, where updates leave it alone. This needs `git`.

```bash
git clone git@github.com:zo-el/agent-toolkit-v2.git ~/Documents/git-repo/agent-toolkit-v2
```

The clone can live anywhere except `~/.claude/agent-toolkit`.

An agent that already holds the repo starts at step 2.

## 2. Run the installer

From the directory step 1 left you in:

```bash
./install.sh
```

## 3. Do what it lists under Needs you

A person runs them. An agent hands them to the user exactly as printed and runs none of them.

## 4. Run it again

Repeat `./install.sh` until its last line counts 0 required findings.

## 5. Start Claude Code

Or restart it, when the report says so. Sign in if asked.

Notifications are the `claude-notifications-go` plugin's own, and install holds no view on them. `/claude-notifications-go:settings` is where you choose which events reach you.

## Penpot, for the ui-developer

Optional, and separate from install: the `ui-developer` designs without it, from code and screenshots.

- Node 22.
- Install puts the bridge's four files in `~/.claude/tools/penpot-mcp` and does nothing else for it. The bridge runs from there, started with `start-bridge.sh`, and fetches its own dependencies at its first run. `npx @penpot/mcp` does not work on a machine whose corepack looks for a `pnpm.cjs` that pnpm 12 no longer ships.
- It serves the MCP endpoint at `http://localhost:4401/mcp` and the plugin manifest at `http://localhost:4400/manifest.json`.
- Connecting the plugin, and keeping it open, is per session. The `ui-developer` prints those steps when its Penpot tools stop answering, so they live there rather than here.

## What install touches

Only `~/.claude`, and Claude Code's plugins, which it fetches:

- `~/.claude/agent-toolkit`, a link to the repo, and `~/.claude/agent-toolkit-run`, which every toolkit command in settings runs through
- a link per skill in `~/.claude/skills`, and a copy per agent in `~/.claude/agents`
- the toolkit's values in `~/.claude/settings.json`, with everything else kept and a backup in `~/.claude/backups` before each write
- `~/.claude/CLAUDE.md`, replaced after a backup by one that imports the repo's `CLAUDE.md`

Spawning the `ui-developer` fetches `@playwright/mcp` into the npm cache, which install itself does not. It never runs `sudo`, installs a system package, or sets your git identity. `./install.sh --dry-run` prints every change it would make and writes nothing.

## Exit codes

| Exit | `./install.sh` | `./install.sh --dry-run` |
| ---- | -------------- | ------------------------ |
| `0` | no required finding remains | a full install can end with no required finding on its own |
| `1` | a required finding remains | a check of the repo fails, or a step needs you |
| `2` | arguments it does not accept | arguments it does not accept |

## Updating

A release is found in the background at every session start and installed at the next session start or compaction. The report says when to restart, and that is the whole of it: nothing to run, and nothing to watch.

On demand, whatever the six hour throttle says:

```bash
~/.claude/agent-toolkit/hooks/update.sh now
```

That is also how a machine installed from a clone takes a release instead. The clone is left on disk, untouched.

`~/.claude/agent-toolkit-track` holds one line and is yours alone. Nothing in the toolkit writes it.

| Line | What the machine follows |
| ------------------- | ------------------------ |
| absent, or `latest` | the release GitHub reports as latest |
| `v1.5.0` | that release and no other |
| `off` | nothing at all. It stops being told about releases, including that it is behind one |

A machine running a clone is told once that a newer release exists, and then left alone: `git pull` is how it moves.

## Moving the repo

Run `./install.sh` from the new location.
