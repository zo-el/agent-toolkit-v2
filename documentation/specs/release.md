# Release

A merge to `main` becomes a release. Every machine finds that release on its own, downloads it in the background, and installs it at its next safe point. `hooks/update.sh` is the machine's half; a workflow in the repository is the publishing half.

Install is the other half of this and is not restated here: `documentation/specs/install.md` owns what a version directory is, how one goes live, how a version is identified, and what a finding and a hook report look like. Its terms carry over.

## Terms

| Term | Meaning |
| ---------------- | ------- |
| release | a published GitHub release named `v<count>`, whose tag points at one commit on `main` |
| track | `~/.claude/agent-toolkit-track`, one line saying which release this machine follows |
| wanted release | the release the track resolves to |
| live version | the version directory the stable link points at, and the version it holds |
| staged | a release unpacked at `~/.claude/agent-toolkit-releases/v<N>`, complete, with its `VERSION` written |
| record | `~/.claude/agent-toolkit-staging.json`, what the updater knows: the last check, what is staged, what failed, what it has announced |
| dev mode | the live version directory is a git work tree, so this machine's toolkit is a clone someone edits |

## Boundaries

- The updater reads GitHub through `gh`, using whatever account `gh` is logged into. It holds no token of its own and never runs git over the network, so a machine whose ssh key is out of reach still updates.
- It writes only `~/.claude/agent-toolkit-releases/` and the record. The track is the user's file and the updater never writes it.
- It writes inside a release folder only while that folder is still part-written under a temporary name. Once a folder is staged, nothing writes into it again.
- It never moves the stable link. Install does that, from the directory install runs in.
- It never touches a clone, and never removes the live version directory.
- It publishes nothing. Releases are made by the workflow, from a merge a person approved.
- Linux only, as install is.

## Making a release

Rulesets and branch protection are not available on this plan, so no check can be required before a merge. The gate is moved rather than lost: **the merge is the human gate, and the release is the machine gate.** A merge that fails the suite lands on `main` and produces no release, so no machine ever sees it.

A push to `main` runs the release workflow, which:

1. checks out the pushed commit with its whole history, because the release name counts it;
2. runs `tests/run.sh`, and stops unless it passes;
3. reads the changelog lines of the pull request that carried the commit, and stops when there are none;
4. publishes `v<count>` from that commit, with those lines as its notes.

- **`v<count>`** is the commit count of the released commit, the same number install reads for a checkout, so a release and a clone compare directly.
- **The tag is lightweight and points at the released commit**, so one API call gives a machine the exact commit a release names.
- **Runs are serialised**, so counts are published in the order they were merged.
- **A run publishes nothing twice.** A `v<count>` that already exists ends the run without a release.
- **Every run writes one line saying what it did**, released or not, where the run's own summary shows it.
- **The workflow publishes as the repository's own token**, so the release and its tag start no further workflow run. Nothing depends on one.
- **A run that makes no release fails** when the merge carried no pull request, or its body carried no changelog section at all. Both mean `main` moved without the gate, and both are loud. An explicit `none` is not a failure.

### Release notes

A release's notes are the changelog lines of the pull request that was merged, and nothing else. Generated notes list every merged pull request, chores included, which is not what a changelog entry is.

The pull request body carries a `## Changelog` section holding either one or more entries, one short line each naming what was worked on, or the single word `none` when the change is not one a user sees.

- **`none` means no release.** Chores, refactors, tests, tooling and doc tidying leave the fleet where it is, and `main` runs ahead of the latest release until the next change a user sees. A release is a whole snapshot, not a patch, so that change carries the chores with it.
- **A missing section fails the run**, so forgetting is not the same as deciding.

### Rolling back

`gh release edit v<prev> --latest` makes an earlier release the one GitHub reports as latest. Every machine tracking `latest` converges on it at its next check, downgrading, and each says so in its report. Immutability leaves the latest flag editable for exactly this.

### Immutable releases

Release immutability is on for the repository, so a published release's tag is locked to its commit and its assets cannot be changed or deleted. Title, notes and the latest flag stay editable.

The machine verifies the commit for itself either way, so immutability is a second lock rather than the only one.

## What a machine follows

`~/.claude/agent-toolkit-track` holds one line:

| Line | Meaning |
| ------------------ | ------- |
| absent, or `latest` | follow the release GitHub reports as latest |
| `v<N>` | follow that release and no other |
| `off` | check nothing, download nothing, apply nothing |

- The file is the user's alone. Nothing in the toolkit writes it, and install neither reads it nor removes it.
- **Any other content stops the updater**, with a required finding naming the file and these three forms. The file exists only because someone wrote it, and guessing what they meant is worse than stopping.
- **`off` costs the machine every report about releases**, including that it is behind one. Nothing else on the machine tells it.

## Modes

| Invocation | Network | Writes | Output | Exit |
| ----------------------- | ----------- | ------ | ------ | ---- |
| `hooks/update.sh stage` | GitHub reads | release folders, the record | nothing | always `0` |
| `hooks/update.sh apply` | none | through install, when a staged release goes live | hook report | always `0` |
| `hooks/update.sh now` | GitHub reads | as `stage`, then as `apply` | what it fetched, then install's terminal report | `0`, `1` |
| `hooks/update.sh --help` | none | nothing | usage | `0` |
| any other argument | none | nothing | usage on stderr | `2` |

- `stage` is wired async at every `SessionStart`. Nothing waits on it, so it is where the network lives.
- `apply` is wired synchronously at `SessionStart` for `startup`, `resume`, `clear` and `compact`. It is local, and it is silent and immediate when there is nothing to do.
- `now` is the whole cycle at once, in the foreground, ignoring the throttle and any bad mark. It is how a person updates on demand, how a machine leaves dev mode, and what a report offers as its fix. It ends by running the wanted version's `install.sh`, so a machine already at the wanted release re-installs it.
- `now` on a machine tracking `off` changes nothing, says so, and exits `1`.

## The cycle

| Step | Where | What |
| -------- | ----- | ---- |
| check | `stage`, `now` | resolve the wanted release and the commit its tag points at |
| judge | `stage`, `now` | stop when that release is live, already staged, or marked bad |
| download | `stage`, `now` | fetch the source archive of that commit |
| verify | `stage`, `now` | the archive is whole, and it is that commit, and that commit is on `main` |
| unpack | `stage`, `now` | into a part-written folder, `VERSION` written, renamed to `~/.claude/agent-toolkit-releases/v<N>` |
| activate | `apply`, `now` | run the staged folder's `install.sh` |

The rename is what makes a release staged: a folder under a `v<N>` name is always complete, and a part-written one never has that name. The rename and the stable link's move are both atomic, so no reader ever sees half of either.

### Checking

- **Throttled to six hours.** A check that starts less than six hours after the last one began does nothing. `now` ignores this.
- Two reads answer it: the release the track names, and the tag it carries. An annotated tag is followed to its commit.
- **A 404 is not an answer on its own.** The repository is private, so a token that cannot see it 404s exactly as a repository with no release does. A 404 is resolved by reading the repository itself: 404 again means the token cannot see it, which is an access failure, and a read means no release has been published yet, which is silence.
- **Every call is bounded**, and the whole of `stage` is bounded, so a hung network cannot leave a process behind.
- **One stage at a time.** A second takes no lock and exits. The lock is the updater's own, so staging never delays an install.

### Verifying

Three things, all of them before anything is staged:

- the download decompresses whole;
- the commit id the archive carries is the commit the release names;
- that commit is the head of `main`, or an ancestor of it.

The third is the one that matters most: it is what makes *a person merged this* the condition for running on every machine, rather than *a person published a release*. A release built from a branch that was never merged is refused by every machine, whatever the release says.

Any failure stages nothing, records the reason, and is reported at the next `apply`.

### Activating

- Nothing staged for the wanted release, or a staged version equal to the live one, means nothing runs and nothing prints. This is the ordinary case, and it costs no more than reading the record and the live version.
- Otherwise install runs from the staged folder and does everything install does. Its root checks come first, the stable link moves only when they pass, and its report names what applied.
- **Went live**, meaning the stable link resolves to the staged folder afterwards: the release is this machine's. The report carries install's own output, its restart line included.
- **Did not go live**: nothing on the machine changed, the version is marked bad, and it is not tried again until the wanted release changes. The report carries install's reason. `hooks/update.sh now` tries it regardless, which is what a machine does after fixing the cause.
- Install serialises applies across the machine already, so an activation and a session's `--sync` never write at once. A `--sync` that takes the lock second finds the stable link moved off its own root and stops. An activation that takes the lock second applies over what the `--sync` wrote, which is what going live means.

**What a new version reaches, and when.** Hooks, permissions, settings, agents and skills are live as soon as install applies them, because Claude Code reloads them when `settings.json` changes. `CLAUDE.md` reaches a session only at its next start, and an agent already running keeps the definition it started with. Applying at a compaction therefore changes the machine mid-lane and the rules at the next start, which is the accepted cost of not waiting for a session to end.

## Dev mode

A machine is in dev mode when its live version directory is a git work tree. Nothing declares it; installing from a clone is what causes it, and it is read from the directory itself.

- The updater checks, and does nothing else. It downloads nothing and activates nothing, so an edit in progress is never overwritten.
- A machine leaves dev mode with `hooks/update.sh now`, which installs the wanted release over it. The clone is left on disk, untouched.
- When the wanted release's count is above the clone's, the updater says so once, naming both versions and both ways forward: pull the clone, or install the release.

## Announcing once

A release the machine will not install is announced at most once, and the record holds which. A machine that is in dev mode, pinned, or behind by choice is told, and then left alone.

## Reports

`apply` prints the hook report `documentation/specs/install.md` defines, with the same finding fields, or prints nothing. `additionalContext` opens with `agent-toolkit updates:` so it reads apart from the doctor's.

```json
{
  "systemMessage": "agent-toolkit: updated to v42. Restart Claude Code to load the new rules",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "agent-toolkit updates:\nv42 is live, from v41·a1b2c3d\n! the last update check failed: gh holds no token for github.com. Fix (user): gh auth login --hostname github.com --web"
  }
}
```

| What | Severity | Who | Fix |
| ---- | -------- | --- | --- |
| a release went live | not a finding: the change line, and install's restart line when one is due | | |
| a release did not go live | required | user | `hooks/update.sh now`, once install's own reason is dealt with |
| the last check failed | advisory | user | that failure's own fix |
| no check has succeeded in seven days | advisory | user | `hooks/update.sh now` |
| the archive was not the commit the release names, or the commit is not on `main` | required | user | nothing automatic: the release is wrong and the repository owner acts |
| the track holds something else | required | user | edit or remove `~/.claude/agent-toolkit-track` |
| `gh` is missing, holds no token, or cannot see the repository | advisory | user | install's own requirement list owns this fix |
| the wanted release is not being installed here | advisory, announced once | user | the way forward for dev mode, a pin, or `off` |

- `systemMessage` reaches the user: one line, present when a release went live, when one failed to, or when a required finding stands.
- **Silence is the normal state.** A machine at the wanted release whose last check succeeded prints nothing at all.
- **`stage` reports nothing.** An async hook's output reaches nothing reliably and is killed at teardown in `-p` mode, so it records and `apply` reports. A failure is therefore reported at the session start after the one that hit it.
- **Two checks catch two different silences.** A recorded failure names its own cause the moment it happens, which a clock cannot do; and a successful check older than seven days catches a `stage` that is not running at all, which a recorded failure cannot.

## Which release a machine runs

No new mechanism. A staged release carries `VERSION` holding `v<count>·<sha>`, install stamps it once the install is clean, and the status line shows it. A release and a clone are named the same way on purpose, so the same stamp answers for both.

The updater's report is what distinguishes them when it matters: it names the live version and the wanted release whenever they differ.

## Pruning

- **Only `stage` prunes**, never `apply`, so no session start waits on a removal.
- It keeps the live version directory, the wanted release, and the one that was live before the current one. Everything else under `~/.claude/agent-toolkit-releases` goes, along with any part-written folder more than a day old.
- The stable link is read again immediately before each removal, and the directory it points at is never removed.
- Install never removes a version directory, and that boundary is unchanged. Release folders are the updater's to remove, and a clone is nobody's.

## Bootstrap

A machine with no toolkit gets its first release through `gh`, not through git: `gh auth login`, read the latest release's tag and commit, unpack that commit's archive into `~/.claude/agent-toolkit-releases/<tag>`, and run `install.sh` from it. The updater takes over from there.

- **It needs no ssh key and no clone**, which is what makes it the way back when the stable link has nothing behind it.
- **A machine that will edit the toolkit clones instead**, and installing from the clone is what puts it in dev mode.

## The guide

`INSTALL.md` gains, each stated once:

- the two ways in, and which one to pick: fetch the latest release to use the toolkit, clone it to work on it;
- the track file, its three forms, and that `off` means the machine stops being told anything;
- `hooks/update.sh now` as update on demand, and as the way out of dev mode;
- what updating does on its own: a release is found in the background and installed at the next session start or compaction, and the report says when to restart.

Its existing updating section is replaced by this, because a version arriving on its own is now the ordinary case.

## Guard

A release flow puts these within an agent's reach, so `hooks/guard.sh` asks before each:

- `gh workflow run`, `gh workflow enable`, `gh workflow disable`;
- `gh run rerun`, `gh run cancel`, `gh run delete`;
- `gh api` with a mutating method against a `releases`, `git/refs` or `git/tags` path.

`gh release create`, `edit`, `delete`, `delete-asset` and `upload` already ask, as does `git push`.

Reading stays free: `gh release download`, `gh release view`, and `gh api` without a mutating method. The updater itself does nothing but read, and a machine that needed approval at every session start would update on no machine at all.

## Failure

| What goes wrong | What happens |
| --------------- | ------------ |
| `gh` is missing, or holds no token | nothing is checked. The record carries it, and the next `apply` reports it |
| GitHub 404s the release and the repository | the token cannot see the repository. Reported as an access failure, never as "no release" |
| GitHub 404s the release but the repository reads | no release has been published. Nothing is reported |
| the download is truncated, or will not decompress | nothing is staged, the reason is recorded, the next `apply` reports it |
| the archive is not the commit the release names | nothing is staged. Required finding |
| the release's commit is not on `main` | nothing is staged. Required finding naming the release |
| `stage` is killed partway | a part-written folder is left and pruned later. Nothing is staged, and the next `stage` starts again |
| two stages overlap | the second takes no lock and exits |
| install from the staged folder does not go live | nothing on the machine changed. The version is marked bad and the report carries install's reason |
| install goes live and a later write fails | install's own contract: the new version is live and the report names what did not apply |
| the track holds something the updater does not accept | the updater stops and reports. Nothing is checked, downloaded or applied |
| the stable link dangles | the updater is behind it and cannot run. The launcher reports it, and the bootstrap is the way back |
| a staged folder is deleted by hand | it is staged again at the next check |
| the suite fails in the workflow | no release. The run fails, and GitHub tells the author. Machines see nothing new, which is correct |
| the merged pull request says `none` | no release. The run succeeds and its summary says so |
| there is no pull request, or no changelog section | no release, and the run fails |
| `v<count>` already exists | no release. The run says so in its summary |

## Rejected

- **A clone on every machine, pulled.** No pin and no gate: `main` would reach machines before the suite had judged it. It needs git over the network, which fails from Claude Code's shell whenever the key is behind a passphrase and no agent is reachable.
- **A `gh` extension.** `gh` would own fetching, pinning and upgrading, and it authenticates exactly as we want. An extension is a command on `PATH` under `gh`'s own directory, not a version directory a stable link can point at, and it moves only when told.
- **chezmoi, or another dotfile manager.** It would replace `install.sh`, which is where the cost actually is: root checks, the launcher, the settings merge, the ledger.
- **Generated release notes.** They list every merged pull request, chores included.
- **A required check before merge.** Rulesets and branch protection answer 403 on this plan.
- **Downloading in the hook that applies.** Every session start would wait on the network.
- **Reporting from the async stage.** Its output reaches nothing reliably and is killed at teardown in `-p` mode.
- **A clock alone as the silent-failure guard.** An expired token and a fortnight away from the machine look the same to a clock. The recorded failure names the cause.
- **Install owning the update state.** How a version arrives is outside install, and that boundary is what lets install treat a clone and a release identically.
- **Verifying by recomputing the tree.** It answers the same question as the commit id in the archive, and it stops being true the day the repository gains an `export-ignore`.
- **A release asset instead of the source archive.** The archive of a commit is already fixed content, and an asset adds an upload step and a second thing to verify.
- **A status line segment for a pending update.** It shows something that stops being true at the next session start.
- **Applying at the `fork` session source.** A compaction is the point at which a session's context is rebuilt; a fork inherits one that is already running.
- **A copy of the updater outside every version directory.** It is a second thing to keep in step, and the launcher already names the fix when the stable link dangles.

## Decisions left to the build

| Decision | Options | Where it lands |
| -------- | ------- | -------------- |
| where the `gh auth login` fix text lives | one copy in `install.sh` with the updater naming the requirement instead of repeating the command, or a small file both read | `install.sh`, `hooks/update.sh` |
| how the record is written | one JSON file through jq, or a directory of one-line files | `hooks/update.sh` |
| how `stage` bounds itself | `timeout` around the whole run, or a deadline checked between steps | `hooks/update.sh` |
| how `stage` takes its lock | `flock` through python as install does, or a directory rename | `hooks/update.sh` |
| the runner image | the pinned image the suite passes on | the release workflow |
| whether the suite also runs on pull requests | a second workflow, against a budget of 2,000 runner minutes a month and a suite of about four | the workflows |
