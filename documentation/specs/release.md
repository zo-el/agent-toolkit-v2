# Release

A merge to `main` becomes a release. Every machine finds that release on its own, downloads it in the background, and installs it at its next safe point. `hooks/update.sh` is the machine's half; a workflow in the repository is the publishing half.

Install is the other half of this and is not restated here: `documentation/specs/install.md` owns what a version directory is, how one goes live, how a version is identified, what the launcher is, and what a finding and a hook report look like. Its terms carry over.

## Terms

| Term | Meaning |
| ---------------- | ------- |
| release | a published GitHub release named `v<version>`, whose tag points at one commit on `main` |
| track | `~/.claude/agent-toolkit-track`, one line saying which release this machine follows |
| wanted release | the release the track resolves to |
| live version | the version directory the stable link points at, and the version it holds |
| staged | a release unpacked at `~/.claude/agent-toolkit-releases/v<version>`, complete, with the `REVISION` install reads written beside the `VERSION` the archive already carries |
| record | `~/.claude/agent-toolkit-staging.json`, everything the updater remembers: the wanted release and its commit, when the last check began and whether it succeeded, the last failure and its cause, the versions marked bad, the version last reported live, the directory that was live before the current one, and the releases it has already announced |
| notes source | the `## Changelog` section of the merged pull request that carried a commit, read in one place and defined below |
| dev mode | the live version directory is a git work tree, so this machine's toolkit is a clone someone edits |

## Boundaries

- The updater reads GitHub through `gh`, using whatever account `gh` is logged into. It holds no token of its own and never runs git over the network, so a machine whose ssh key is out of reach still updates.
- It writes only `~/.claude/agent-toolkit-releases/` and the record. The track is the user's file and the updater never writes it.
- It writes inside a release folder only while that folder is still part-written under a temporary name. Once a folder is staged, nothing writes into it again.
- It never moves the stable link. Install does that, from the directory install runs in.
- It never touches a clone, and never removes the live version directory.
- It publishes nothing. Releases are made by the workflow, from a merge a person approved.
- Linux only, as install is.

## What a release carries

A release is the whole version directory at one commit: `CLAUDE.md`, every agent, every skill, every hook, `install.sh`, `INSTALL.md` and the specs. Nothing is selected out and nothing is added.

- **An agent or a skill arrives exactly as a rule does.** A release that adds one is an ordinary release, and install's own agent copies and skill links are what put it on the machine.
- **The Penpot bridge travels with it.** `tools/penpot-mcp/` holds the bridge's `package.json`, its lock file and its two scripts, and install copies them out to `~/.claude/tools/penpot-mcp/`, which `documentation/specs/install.md` owns. A release therefore carries the bridge's four files and none of its installed state.

## Making a release

Rulesets and branch protection are not available on this plan, so no check can be required before a merge. The gate is moved rather than lost: **the merge is the human gate, and the release is the machine gate.** A merge that fails the suite lands on `main` and is released by nothing, so no machine ever runs a tree the suite has not passed. The commit itself reaches machines later, inside the next release that does pass.

A push to `main` runs the release workflow, which:

1. checks out the pushed commit as a work tree, at no depth behind it, because nothing counts commits;
2. runs `tests/run.sh`, and goes no further unless its summary counts no failures and no skips;
3. asks the notes source for that commit's changelog lines, and publishes nothing without them;
4. reads `VERSION` from that commit and publishes `v<version>` from it, with those lines as its notes.

- **`tests/run.sh` is the whole gate.** It sources `tests/install.sh`, so the installer's cases run inside it. There is no second command.
- **A skipped check is not a passed one.** The suite exits `0` with any number of skips and counts them in its last line. The gate is the suite's own counts of failures and skips, both at zero.
- **A skip is the runner's to remove.** A check skips where `jscpd` and `npx` are both out of reach, where the tree is not a git work tree, and where the run is root, so the runner is none of those.
- **A check that skips for a reason the runner cannot answer is changed, not tolerated.** The gate learns no list of accepted skips: a check with nothing to read reports a verdict on nothing to read, because a list of exceptions is a gate that stops meaning anything.
- **The style gate is not a workflow check.** `hooks/style.py` denies a commit before it runs, which only the machine making that commit can do; once a merge has landed there is nothing left to deny. The suite covers the hook's own behaviour, and a `Style-ack:` trailer that cleared a finding is in the history for anyone to read.
- **The version is declared, not computed.** `VERSION` at the repository root holds one line of three dot separated numbers, and the release takes its name from the line the released commit carries. A version directory's version is `v<version>·<revision>`, so a release name is that version's semantic half and a release and a clone compare directly.
- **The pull request that carries changelog lines bumps it**: the major when the new release needs the user to do something by hand, the minor when a user sees something new, the patch when it is a fix. One that says `none` leaves `VERSION` alone, so the bump and the changelog section are one decision rather than two.
- **`VERSION` starts at `1.0.0`.** The toolkit is installed, in daily use, and has a published install contract, so a `0.x` line claiming no compatibility promise would be false, and the major would stop meaning what the bump rule says it means.
- **The tag is lightweight and points at the released commit**, so one API call gives a machine the exact commit a release names.
- **Runs are serialised**, so releases are published in the order they were merged.
- **A version publishes once**, and how the run ends depends on the commit the existing release names. The same commit means the work is already published, so the run succeeds saying so, which is what a re-run is. A different commit means the product changed and the bump was forgotten, so the run fails: a release that silently never happens is the failure this gate exists to prevent.
- **The same suite runs on a pull request**, as a second workflow. It gates nothing, since no check can be required before a merge, and it is there so an author sees a failing suite before the merge rather than after it.
- **A job is given the permission it needs and no more.** The repository is public, so a pull request from a fork can start the suite job, and what runs in it is that branch's own code: that job may read the repository and nothing else. The release job may write, because publishing is what it is for, and only a push to `main` starts it, which no fork can cause. Neither checkout leaves its credentials in the tree for the code it is about to run.
- **Every run writes one line saying what it did**, released or not, where the run's own summary shows it.
- **The workflow publishes as the repository's own token**, so the release and its tag start no further workflow run. Nothing depends on one.

### Release notes

A release's notes are its changelog lines and nothing else. Generated notes list every merged pull request, chores included, which is not what a changelog entry is.

**The lines come from one place.** The workflow asks the notes source for them, naming the released commit, and everything else here is written against its answer rather than against where a person wrote the lines. The answer has exactly three forms:

| Answer | What the run does |
| ------------- | ----------------- |
| one or more entries | publishes, with those lines as the notes |
| `none` | publishes nothing. The run succeeds and its summary says so |
| no answer at all | publishes nothing. The run fails |

**The source is the merged pull request.** Its body carries a `## Changelog` section holding either one or more entries, one short line each naming what was worked on, or the single word `none`. A commit that reached `main` without a pull request, and a pull request whose body carries no such section, are both the third answer.

- **`none` means no release.** Chores, refactors, tests, tooling and doc tidying leave the fleet where it is, and `main` runs ahead of the latest release until the next change a user sees. A release is a whole snapshot, not a patch, so that change carries the chores with it.
- **No answer at all fails the run**, so forgetting is not the same as deciding. It means `main` moved without the gate, and it is loud.
- **The PR body carries this one block and nothing else beyond the goal.** `CLAUDE.md`'s rule that a body carries nothing but the goal admits the changelog section, and admits no other addition.
- An entry is one short line, as `CLAUDE.md` defines it. The workflow neither shortens nor reformats what it is given.

### Rolling back

A release that should be running nowhere is marked a prerelease. The latest release is by definition the newest that is neither a draft nor a prerelease, so the one before it becomes latest again. Every machine tracking `latest` converges on it at its next check, downgrading, and each says so in its report. Immutability leaves the prerelease and latest flags editable for exactly this.

A machine that must not move at all is pinned in its track instead, which needs nobody else's agreement.

### Immutable releases

Release immutability is on for the repository, so a published release's tag is locked to its commit and its assets cannot be changed or deleted. Title, notes and the latest flag stay editable.

The machine verifies the commit for itself either way, so immutability is a second lock rather than the only one.

## What a machine follows

`~/.claude/agent-toolkit-track` holds one line:

| Line | Meaning |
| ------------------ | ------- |
| absent, or `latest` | follow the release GitHub reports as latest |
| `v<version>` | follow that release and no other |
| `off` | check nothing, download nothing, apply nothing |

- The file is the user's alone. Nothing in the toolkit writes it, and install neither reads it nor removes it.
- **Any other content stops the updater**, with a required finding naming the file and these three forms. The file exists only because someone wrote it, and guessing what they meant is worse than stopping.
- **`off` costs the machine every report about releases**, including that it is behind one. Nothing else on the machine tells it.

## Modes

| Invocation | Network | Writes | Output | Exit |
| ----------------------- | ----------- | ------ | ------ | ---- |
| `hooks/update.sh stage` | GitHub reads | release folders, the record | nothing | always `0` |
| `hooks/update.sh apply` | none of its own | through install, when a staged release goes live | hook report | always `0` |
| `hooks/update.sh now` | GitHub reads | as `stage`, then as `apply` | what it fetched, then install's terminal report | `0`, `1` |
| `hooks/update.sh --help` | none | nothing | usage | `0` |
| any other argument | none | nothing | usage on stderr | `2` |

- **Both wired modes run through the launcher**, as every toolkit command in settings does: `stage` with the `async` caller, `apply` with `SessionStart`. The wiring names `hooks/update.sh`, which puts it among the entry points the root checks require, so a release whose updater is missing or not executable fails those checks and never goes live.
- `stage` is wired async at every `SessionStart`. Nothing waits on it, so it is where the network lives. The launcher says nothing for an async caller, which is what a mode that reports nothing needs.
- `apply` is wired synchronously at `SessionStart` for `startup`, `resume`, `clear` and `compact`. It reads the track, the record and the live version, and nothing else. It is silent and immediate when there is nothing to do, which is every start but the one that takes a new release.
- `now` is the whole cycle at once, in the foreground, ignoring the throttle and any bad mark. It is how a person updates on demand, how a machine leaves dev mode, and what a report offers as its fix. It ends by running the wanted version's `install.sh`, so a machine already at the wanted release re-installs it.
- **`now` that could stage nothing** prints the reason with its fix and stops, installing nothing and changing nothing. The live version stays live and untouched, and the exit is `1`. This is its commonest ending, because it is the one a person runs the moment updates stop working.
- `now` on a machine tracking `off` changes nothing, says so, and exits `1`.

## The cycle

| Step | Where | What |
| -------- | ----- | ---- |
| check | `stage`, `now` | resolve the wanted release and the commit its tag points at |
| judge | `stage`, `now` | stop when that release is live, already staged, or marked bad |
| download | `stage`, `now` | fetch the source archive of that commit |
| verify | `stage`, `now` | the archive is whole, and it is that commit, and that commit is on `main` |
| unpack | `stage`, `now` | into a part-written folder, `REVISION` written beside the archive's `VERSION`, renamed to `~/.claude/agent-toolkit-releases/v<version>` |
| activate | `apply`, `now` | run the staged folder's `install.sh` |

The rename is what makes a release staged: a folder under a `v<version>` name is always complete, and a part-written one never has that name. The rename and the stable link's move are both atomic, so no reader ever sees half of either.

### Checking

- **Throttled to six hours.** A check that starts less than six hours after the last one began does nothing. A last check recorded in the future counts as never having happened, so a clock that was wrong once does not stop a machine checking for good. `now` ignores the throttle.
- Two reads answer it: the release the track names, and the tag it carries. An annotated tag is followed to its commit.
- **A 404 is not an answer on its own.** GitHub answers 404 rather than 403 for a repository a token cannot see, so a repository out of reach and a repository with no release give the same answer. Whether this one is reachable is a setting somebody can change, and a machine that read that setting once would be wrong the day it changed. A 404 is resolved by reading the repository itself, and what the second read means depends on what was asked for:
  - the repository 404s too: the token cannot see it, which is an access failure;
  - the repository reads and the track says `latest`: no release has been published yet, which is silence;
  - the repository reads and the track named a release: that release does not exist, which is a required finding naming the track's line. A machine pinned to a release nobody published would otherwise check every six hours forever and say nothing.
- **Every call is bounded**, and the whole of `stage` is bounded, so a hung network cannot leave a process behind.
- **One stage at a time.** A second takes no lock and exits. The lock is the updater's own, so staging never delays an install.

### Verifying

Four things, all of them before anything is staged:

- the download decompresses whole;
- the commit id the archive carries is the commit the release names;
- that commit is the head of `main`, or an ancestor of it;
- the `VERSION` the archive carries is the version the release is named for.

The third is the one that matters most: it is what makes *a person merged this* the condition for running on every machine, rather than *a person published a release*.

**The four are not four independent attestations.** Every one of them is GitHub answering over one channel: the commit id an archive carries is a pax header the server writes rather than a hash binding the members beside it, and the on-`main` answer comes from the same place. What the design trusts is that channel and the account `gh` is logged into. The third check is what turns that trust into a rule about merges rather than about publishing.

**The fourth exists because the version is declared.** A release named for one version whose tree declares another would install, go live, and leave the machine at a version that is still not the wanted one, so every session start would stage and install it again for good. Nothing inside the archive can prove a declared version is the right one, and this is the one thing about it a machine can check: that the name and the tree agree.

**A check that was not answered is not a check that failed.** GitHub saying the commit is not on `main` is a required finding, because the release is wrong. GitHub saying nothing, through a rate limit, a refusal or a read that did not complete, is an ordinary recorded failure: nothing is staged, and the next `apply` reports the cause. One unlucky call must never tell the user their repository has been tampered with.

Any failure stages nothing, records the reason, and is reported at the next `apply`.

### Activating

- Nothing staged for the wanted release, or a staged version equal to the live one, means no install runs. This is the ordinary case, and it costs no more than reading the track, the record and the live version. Whether anything prints is the report's own rule below.
- Otherwise install runs from the staged folder and does everything install does. Its root checks come first, the stable link moves only when they pass, and its report names what applied.
- **An activation is as slow as a full install, plugin fetches included**, and the session start or compaction that runs it waits. It happens once per release, and the alternative is a machine that never quite has the version it reports.
- **Went live**, meaning the stable link resolves to the staged folder afterwards: the release is this machine's. The report carries install's own output.
- **Going live always calls for a restart**, whatever install says. Install asks for one when it changed something Claude Code reads only at start, and a version swap changes none of those files while changing what one of them points at: `~/.claude/CLAUDE.md` imports the version directory's `CLAUDE.md` through the stable link, so the rules change and the file install writes does not.
- **Did not go live**: nothing on the machine changed, the version is marked bad, and it is not tried again until the wanted release changes. The report carries install's reason. `hooks/update.sh now` tries it regardless, which is what a machine does after fixing the cause.
- **One activation at a time.** `apply` takes the updater's activation lock without waiting more than a moment for it, and a session that cannot take it installs nothing. No session start ever waits out another session's install.
- **The report comes off the record, not off this run.** `apply` reports whenever the live version differs from the version the record says was last reported, whether this run caused the change or another session did, and then records what it reported. Two sessions starting together are each told once, which is right: they are two sessions.
- Install's own lock still stands behind all of this, so a `--sync` that takes it after an activation finds the stable link moved off its own root and stops, and an activation that takes it after a `--sync` applies over what that wrote.

**What a new version reaches, and when.**

- Hooks, permissions and settings are live as soon as install writes `settings.json`, which Claude Code reloads.
- A skill is live once install re-points its link and the report sets `reloadSkills`.
- An agent is a copy install rewrites, so the next agent spawned carries the new definition and one already running keeps the definition it started with.
- `CLAUDE.md` reaches a session only at its next start.

Applying at a compaction therefore changes the machine mid-lane and the rules at the next start, which is the accepted cost of not waiting for a session to end.

## Dev mode

A machine is in dev mode when its live version directory is a git work tree. Nothing declares it; installing from a clone is what causes it, and it is read from the directory itself.

- The updater checks, and does nothing else. It downloads nothing and activates nothing, so an edit in progress is never overwritten.
- A machine leaves dev mode with `hooks/update.sh now`, which installs the wanted release over it. The clone is left on disk, untouched.
- When the wanted release's version is newer than the clone's, the updater says so once, naming both versions and both ways forward: pull the clone, or install the release.
- **The comparison is the semantic version alone.** A clone whose `VERSION` is behind a published release is told, however much unmerged work sits on top of it, and one holding a bump nobody has released yet reads as newer and is told nothing. A clone at the same version is told nothing either: it is somebody's work in progress, and only a release it has not reached is news.

## Announcing once

A machine in dev mode is told once that a release exists which it is not going to install, and the record holds which release, so no later check says it again.

**Dev mode is the only case.** A pinned machine installs the release it is pinned to, so there is nothing it is declining. A machine tracking `off` is told nothing whatever, which is the whole of what `off` means.

## Reports

`apply` prints the hook report `documentation/specs/install.md` defines, with the same finding fields, or prints nothing. `additionalContext` opens with `agent-toolkit updates:` so it reads apart from the doctor's.

```json
{
  "systemMessage": "agent-toolkit: updated to v1.5.0. Restart Claude Code to load the new version",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "agent-toolkit updates:\nv1.5.0 is live, from v1.4.0·a1b2c3d\n! the last update check failed: gh holds no token for github.com. Fix (user): gh auth login --hostname github.com --web"
  }
}
```

| What | Severity | Who | Fix |
| ---- | -------- | --- | --- |
| the live version changed since the last report | not a finding: the change line, install's own report when this run produced one, and the restart line, which a changed version always warrants | | |
| a release did not go live | required | user | `~/.claude/agent-toolkit/hooks/update.sh now`, once install's own reason is dealt with |
| the last check failed | advisory | user | that failure's own fix |
| no check has succeeded in seven days | advisory | user | `~/.claude/agent-toolkit/hooks/update.sh now` |
| the archive was not the commit the release names, declares another version, or the commit is not on `main` | required | user | nothing automatic: the release is wrong and the repository owner acts |
| the track holds something else | required | user | edit or remove `~/.claude/agent-toolkit-track` |
| the track names a release nobody published | required | user | edit `~/.claude/agent-toolkit-track` to a release that exists, or to `latest` |
| `gh` is missing, holds no token, or cannot see the repository | advisory | user | the same command install's requirement list names, which is where that text lives |
| a release exists that this clone will not install | advisory, announced once | user | pull the clone, or `~/.claude/agent-toolkit/hooks/update.sh now` to take the release instead |

- `systemMessage` reaches the user: one line, present when the live version changed, when a release failed to go live, or when a required finding stands.
- **A fix is printed as a command that runs from anywhere**, which for the updater means its path through the stable link. The report is read in a session whose working directory is a project, not the toolkit.
- **`reloadSkills` is set whenever the report says the live version changed.** A new version directory re-points every skill link, and the terminal report install prints on a full install has no field that says so.
- **Silence is the normal state.** A machine at the wanted release whose last check succeeded prints nothing at all.
- **The updater reports its own access failures**, rather than leaving them to the doctor. `--sync` skips the requirements a user can only satisfy outside Claude Code, `gh` among them, so a session start would otherwise skip the one thing that stops updates.
- **`stage` reports nothing.** An async hook's output reaches nothing reliably and is killed at teardown in `-p` mode, so it records and `apply` reports. A failure is therefore reported at the session start after the one that hit it.
- **A report that is already speaking names the live version and the wanted release whenever they differ**, which is the only place the two are distinguished. It is a rider on a report, never a reason to make one, or a machine that is behind on purpose would break the silence at every start. Which release a machine runs needs no mechanism of its own: a staged release carries the `VERSION` of the commit it was cut from and the `REVISION` the updater wrote beside it, install stamps both as one version, and the status line shows it, exactly as for a clone.

## Pruning

- **Only `stage` prunes**, never `apply`, so no session start waits on a removal.
- It keeps the live version directory, the wanted release, and the one the record names as live before the current one. Install computes that directory and keeps no note of it, so the activation that moves off a directory is what records it. Everything else under `~/.claude/agent-toolkit-releases` goes, along with any part-written folder more than a day old.
- The stable link is read again immediately before each removal, and the directory it points at is never removed.
- Install never removes a version directory, and that boundary is unchanged. Release folders are the updater's to remove, and a clone is nobody's.

## Bootstrap

A machine with no toolkit gets its first release through `gh`, not through git: `gh auth login`, read the latest release's tag and commit, unpack that commit's archive into `~/.claude/agent-toolkit-releases/<tag>`, write its `REVISION`, and run `install.sh` from it. The updater takes over from there.

- **It needs no ssh key and no clone**, which is what makes it the way back when the stable link has nothing behind it.
- **The `REVISION` line is part of it.** The archive carries `VERSION` already; without `REVISION` beside it the folder has no version, so the first install stamps nothing and the status line shows no release.
- **A machine that will edit the toolkit clones instead**, and installing from the clone is what puts it in dev mode.

## The guide

`INSTALL.md` states each of these once:

- **the two ways in, and which to pick**: fetch the latest release to use the toolkit, clone it to work on it;
- the track file, its three forms, and that `off` means the machine stops being told anything;
- `hooks/update.sh now` as update on demand, and as the way a machine running a clone takes a release instead;
- what updating does on its own: a release is found in the background and installed at the next session start or compaction, and the report says when to restart.

Its `Updating` section is the last three, because a version arriving on its own is the ordinary case rather than a consequence of pulling the repo. `Moving the repo` is about a clone, and everything the guide says about install itself is `documentation/specs/install.md`'s.

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
| GitHub 404s `latest` but the repository reads | no release has been published. Nothing is reported |
| the download is truncated, or will not decompress | nothing is staged, the reason is recorded, the next `apply` reports it |
| the archive is not the commit the release names | nothing is staged. Required finding |
| the archive declares a version the release is not named for | nothing is staged. Required finding naming both, since installing it would re-install on every session start for good |
| the release's commit is not on `main` | nothing is staged. Required finding naming the release |
| `stage` is killed partway | a part-written folder is left and pruned later. Nothing is staged, and the next `stage` starts again |
| two stages overlap | the second takes no lock and exits |
| `~/.claude/agent-toolkit-releases` cannot be created, written, or holds no room | nothing is staged, the reason is recorded, and the next `apply` reports it with its own fix |
| install from the staged folder does not go live | nothing on the machine changed. The version is marked bad and the report carries install's reason |
| install goes live and a later write fails | install's own contract: the new version is live and the report names what did not apply |
| an activation is killed partway | the stable link may already have moved, so the release is live and the rest of the install is not done. A `--sync` from the new root, in that session or the next, applies the remainder and stamps it. The report was lost with the process, so the next `apply` finds a live version the record never reported and says so then |
| two sessions start at once | one activates and both are told. The one that cannot take the activation lock installs nothing and waits on nothing |
| the track holds something the updater does not accept | the updater stops and reports. Nothing is checked, downloaded or applied |
| the track names a release nobody published | nothing is staged. Required finding naming the track's line, rather than the silence a missing `latest` earns |
| GitHub will not say whether the commit is on `main` | nothing is staged. An ordinary recorded failure, never the finding that the release is wrong |
| the record will not parse | it is replaced and the run says so. A check and an activation both still happen: the record is what the updater remembers, not what it is allowed to do |
| the stable link dangles | the updater is behind it and cannot run. The launcher reports it, and the bootstrap is the way back |
| a staged folder is deleted by hand | it is staged again at the next check |
| the suite fails in the workflow | no release. The run fails, and GitHub tells the author. Machines see nothing new, which is correct |
| the suite skips a check in the workflow | no release, and the run fails. The runner is meant to satisfy every check, so a skip is a broken runner rather than a tolerated gap |
| the account's runner minutes are spent | no run, so no release. GitHub tells the account owner. Machines stay where they are and report nothing, because nothing on a machine is wrong. A merge that reaches no machine is visible on GitHub and nowhere else |
| the merged pull request says `none` | no release. The run succeeds and its summary says so |
| the commit reached `main` without a pull request, or the body carries no changelog section | no release, and the run fails |
| `v<version>` is already published, at the commit being run for | no release. The run succeeds and its summary says so |
| `v<version>` is already published, at a different commit | no release, and the run fails. The product changed and `VERSION` was not bumped |
| `VERSION` is missing, or is not three dot separated numbers | no release, and the run fails |

## Rejected

- **A clone on every machine, pulled.** No pin and no gate: `main` would reach machines before the suite had judged it. It needs git over the network, which fails from Claude Code's shell whenever the key is behind a passphrase and no agent is reachable.
- **A `gh` extension.** `gh` would own fetching, pinning and upgrading, and it authenticates exactly as we want. An extension is a command on `PATH` under `gh`'s own directory, not a version directory a stable link can point at, and it moves only when told.
- **chezmoi, or another dotfile manager.** It would replace `install.sh`, which is where the cost actually is: root checks, the launcher, the settings merge, the ledger.
- **Generated release notes.** They list every merged pull request, chores included.
- **Running the style gate in the workflow.** It is a `PreToolUse` deny on a commit that has not run yet, and after a merge there is nothing left to deny. Running it over a merged range would report findings on work already accepted, with no way to answer them but a second commit.
- **The commit count as the version.** It cannot be forgotten, which a declared file can, but it numbers commits rather than releases, so two versions could be ordered without either having been published, and nothing in the number says whether the update asks anything of the user. It also needs the whole history wherever it is read.
- **Reading the notes in more than one place.** One step answers for a release, so no other step in the workflow learns what a pull request is, and the source can change without them changing.
- **Marking the previous release latest, to roll back in one step.** It rests on GitHub honouring that flag over its own date order, which its reference does not state. The prerelease flag rests on the definition of latest itself.
- **A required check before merge.** Rulesets and branch protection answer 403 on this plan.
- **Downloading in the hook that applies.** Every session start would wait on the network.
- **Reporting from the async stage.** Its output reaches nothing reliably and is killed at teardown in `-p` mode.
- **A clock alone as the silent-failure guard.** An expired token and a fortnight away from the machine look the same to a clock. The recorded failure names the cause.
- **Install owning the update state.** How a version arrives is outside install, and that boundary is what lets install treat a clone and a release identically.
- **Verifying by recomputing the tree.** It restates the trust Verifying already rests on rather than adding to it, and it stops being true the day the repository gains an `export-ignore`.
- **A release asset instead of the source archive.** The archive of a commit is already fixed content, and an asset adds an upload step and a second thing to verify.
- **A status line segment for a pending update.** It shows something that stops being true at the next session start.
- **Applying at the `fork` session source.** A compaction is the point at which a session's context is rebuilt; a fork inherits one that is already running.
- **A copy of the updater outside every version directory.** It is a second thing to keep in step, and the launcher already names the fix when the stable link dangles.
