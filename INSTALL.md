# Install

Linux only.

## 1. Get the repo

In your own terminal. The repo is private, so GitHub access comes first. These two commands need `git` and `gh`.

```bash
gh auth login --hostname github.com --git-protocol ssh --web
git clone git@github.com:zo-el/agent-toolkit-v2.git ~/Documents/git-repo/agent-toolkit-v2
```

`gh auth login` can generate an SSH key and upload it for you. The clone can live anywhere except `~/.claude/agent-toolkit`.

An agent that already holds the repo starts at step 2.

## 2. Run the installer

From the repo:

```bash
./install.sh
```

## 3. Do what it lists under Needs you

A person runs them. An agent hands them to the user exactly as printed and runs none of them.

## 4. Run it again

Repeat `./install.sh` until its last line counts 0 required findings.

## 5. Start Claude Code

Or restart it, when the report says so. Sign in if asked.

## What install touches

Only `~/.claude`, and Claude Code's plugins, which it fetches:

- `~/.claude/agent-toolkit`, a link to the repo, and `~/.claude/agent-toolkit-run`, which every toolkit command in settings runs through
- a link per skill in `~/.claude/skills`, and a copy per agent in `~/.claude/agents`
- the toolkit's values in `~/.claude/settings.json`, with everything else kept and a backup in `~/.claude/backups` before each write
- `~/.claude/CLAUDE.md`, replaced after a backup by one that imports the repo's `CLAUDE.md`

It never runs `sudo`, installs a system package, or sets your git identity. `./install.sh --dry-run` prints every change it would make and writes nothing.

## Exit codes

| Exit | `./install.sh` | `./install.sh --dry-run` |
| ---- | -------------- | ------------------------ |
| `0` | no required finding remains | a full install can end with no required finding on its own |
| `1` | a required finding remains | a check of the repo fails, or a step needs you |
| `2` | arguments it does not accept | arguments it does not accept |

## Updating

Once a new version is in the repo, the next session start on the machine applies it and says when to restart. `./install.sh` applies it immediately.

## Moving the repo

Run `./install.sh` from the new location.
