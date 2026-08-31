# Style checks

The Writing standards in `CLAUDE.md` are prose an agent can agree with and still not apply. `hooks/style.py` is their mechanical half. At the moment a commit is about to run it reads the message and the diff, and denies the call when anything objectively checkable is wrong, naming every finding at once so one pass fixes all of them.

All three checks block. Each of them can be wrong, and blocking on a wrong finding is only expensive where there is no way past it, so there is one: a `Style-ack:` trailer on the commit message clears every finding on that commit. The trailer is the mechanism deliberately, rather than an environment variable or a flag, because an override then lands in git history and stays auditable.

## What can be checked, and what cannot

| Expectation | Mechanical | Judgement |
| --- | --- | --- |
| Never a dash as punctuation | the character is there or it is not | nothing |
| Return fewer comments than you found | added and removed comment lines | whether a surviving comment earns its place |
| A changelog entry is the gist of a change | its length, and how many landed | whether it names the thing on screen or an abstraction |

The judgement column is not detectable by pattern. Anything trying to spot narration in a comment or abstraction in a changelog line fires on correct work. Judgement is handled the way `Reuse:` handled the search rule: the agent states a number in its report and accounts for it.

## Why not an existing tool

Nothing off the shelf fits, for one structural reason each. Git hook frameworks (`pre-commit`, `husky`, `commitlint`, `gitlint`) install configuration into the project repository and change it for everyone who clones it, which this toolkit may never do. Prose linters (`Vale`, `textlint`, `write-good`) read whole files rather than added lines and cannot see a commit message at all; against a tree where every file predates the rule they report thousands of true findings that are not this change's business. What is needed is a diff scoped check that runs from outside the repository, which is what a Claude Code hook already is.

## Ground truth

- `PreToolUse` returns a `permissionDecision` of `allow`, `deny` or `ask`. **`deny` cancels the call and returns `permissionDecisionReason` to the model with no user interaction**; `ask` prompts the user. `hooks/guard.sh` emits both.
- A hook that blocks must be synchronous. An async entry's decision arrives after the tool has run.
- Both events fire inside subagents. A Bash call arrives as `tool_name: "Bash"` with the raw string in `tool_input.command` and the session's directory in `cwd`.
- A hook entry's `if` field takes permission rule syntax (`Bash(git *)`) and tests each subcommand of a compound command. **`Bash(git commit *)` does not match `git -C <repo> commit`**, which is the form `CLAUDE.md` requires, so no narrowing may assume `commit` is the second word. The hook is wired on the whole `Bash` matcher and narrows itself.
- At `PreToolUse` the commit has not run, so the content to check is the index, not a commit. `git commit -a` and `-am` stage tracked changes at commit time, so for those the content is the working tree instead.
- `git diff --cached` works in a repository with no commits. `git diff HEAD` does not, and is the fallback's trigger.
- Only added lines can ever be examined. 400 em dashes are tracked in this repo at HEAD, 37 of them in `CLAUDE.md`; a whole file scan is all noise.
- The double hyphen is a false positive machine here. Every ` -- ` tracked in this repo (`CLAUDE.md`, `agents/developer.md`, `hooks/bg.sh`, `hooks/reap.sh`, `hooks/sync.sh`) is a shell end of options marker, and none is punctuation.
- The failure being caught is measured. 943 changelog bullets across 50 files under `git_repo/unyt*` have a median length of 94 characters and a p90 of 217, against a rule whose own example is 44. `RETRO.md` records a +326 comment drift surviving a whole feature because nothing counted it.
- The hook costs about 2ms of its own work per Bash call, on top of a 12ms Python interpreter start. `shlex`, `subprocess` and `traceback` are imported where they are used, because at that scale their import time is most of the cost.
- Repository config is executable. `--no-ext-diff` and `--no-textconv` cover the external diff driver and textconv; `core.fsmonitor` and the rest are turned off on the command line, where a repository cannot re-enable them. A clean filter still runs when a worktree file has to be read, which is what the commit itself is about to do.
- The wiring builder in `install.sh` constructs each hook entry from `type`, `command` and `async` alone, so an `if` field cannot be introduced through the wiring declaration.

## Where it lives

`hooks/style.py`, wired synchronously at `PreToolUse[Bash]` alongside `hooks/guard.sh`, with its cases in `tests/run.sh`. Python because the work is unicode scanning and per language comment counting, stdlib only like every hook here. It never contends with the guard for a decision: the guard is silent on `git commit`, and this hook is silent on everything else.

No new rule in `CLAUDE.md`: all three are already there. `agents/developer.md` carries the `Comments:` return line, which is the judgement half.

## When it fires

The command is split into shell words and into the segments of a compound command. A segment is a commit when its command word is `git`, past `git`'s own options, and its subcommand is `commit`. So `git -C <path> commit` counts, and `cd <path> && git commit` counts. A quoted mention inside another command does not, because its command word is that other command.

A redirect keeps its command rather than splitting it, and takes with it the file descriptor in front and the target behind, so `2>/dev/null` leaves no stray word behind. A heredoc body is text rather than words and is skipped to its delimiter. A line continuation leaves a whitespace word, which is dropped. Anything left behind by these would read as a pathspec, and the check would then narrow to a file that does not exist and find nothing.

A `cd` moves the check only when it runs before the commit and outside a subshell. Only the first commit in a compound command is examined.

Silence, before any check runs, on:

- a command with no `commit` substring at all, which is nearly every Bash call and must cost nothing.
- a command whose words cannot be split, and a segment whose git options run off the end of the command.
- `--dry-run`, `--short` and `--porcelain`, which write no commit.

## What is checked, per commit form

The content examined is what this command is about to add, and nothing that is already committed.

| Form | Content examined |
| --- | --- |
| `git commit` | the index, `git diff --cached` |
| `git commit -a`, `-am` | the tracked working tree, `git diff HEAD`, because `-a` stages at commit time and the index does not yet hold it |
| `git commit <paths>` | `git diff HEAD` over those paths, which is what an implied `--only` commits |
| `git commit -i <paths>` | the index and those paths together, each file read once |
| `--pathspec-from-file` | the whole tracked tree, since the paths it names cannot be read here |
| `git commit --amend` | the same as the form it takes without `--amend` |
| a repository with no `HEAD` | the index, since there is no parent to diff against |

**An amend is not special.** What it newly introduces is the staged change; the content already in `HEAD` was checked when `HEAD` was made. Re-reading it would report findings that were already answered, and would block a plain reword of a message that the check itself just rejected.

**An empty commit is not special either.** Its diff is empty, so the diff checks find nothing and the message check still applies.

## Reading the message

The message is what the command makes readable: every `-m` and `--message` value, every `--trailer` value, and the contents of the file a `-F` or `--file` names when that path resolves to a readable regular file at check time.

Text a `-F` file supplied is never quoted back. The path is arbitrary, so quoting it would read that file out to the model a window at a time; a finding in it gives the dash and its line in the message instead. Text the command carried itself is quoted, because the command wrote it.

When the message cannot be read, the message check stays silent and **the diff checks still run**. That covers an editor commit, a `-F` naming a file the command has not written yet, and `-C`, `--reuse-message`, `--reedit-message`, `--fixup`, `--squash` and `--template`, which take a message from somewhere else. An unread message is not an escape hatch: the override is, and it is one an unread message cannot reach, so an agent that needs it writes the message with `-m` instead.

## The override

A `Style-ack:` trailer on the commit message clears every finding on that commit.

- It must carry a reason. A bare `Style-ack:` with nothing after it clears nothing.
- It is for a finding that is wrong, or text that is deliberate and accepted. It is not a way past a finding that is real, and the deny reason says so.
- It lands in git history, so any override can be found later and judged.
- It is only reachable where the message is readable, which is `-m`, `--message`, `--trailer` and a `-F` file that already exists.

## Check 1: a dash as punctuation

Denies on U+2014 EM DASH and U+2013 EN DASH, in the message and in the added prose of the diff. An en dash with a digit on each side is a range and is allowed. The finding names `path:line` and quotes the offending text on one line, around the dash.

## Check 2: comment drift

Comment lines added and removed, counted only in files that existed before this commit, and only in formats where a comment sits over code. A configuration format (`.yml`, `.yaml`, `.toml`, `.ini`, `.cfg`, `.tf`, `.nix`) is counted for dashes and not for drift: there a comment documents an option, and several of them is an ordinary change. Denies when added minus removed reaches `COMMENT_NET`. The finding states the pair, and the fix is to account for each surviving addition or cut it.

## Check 3: changelog volume

Over added lines in a file whose basename starts with `CHANGELOG`: an entry longer than `CHANGELOG_ENTRY_CHARS`, quoted to its first 60 characters, and the count when one commit adds more than `CHANGELOG_ENTRY_COUNT` entries.

## The deny reason

One block, listing every finding at once, each on its own line with its `path:line` and the offending text. An agent fixes all of them in one pass rather than discovering them one at a time. Past `FINDINGS_SHOWN` the rest are counted rather than listed. The block closes with what each rule asks for, and with the override and what it is for.

## What is never examined

**On every check**

- Any line the commit did not add. Removed lines and untouched context are invisible.
- Vendored, generated and lock paths: `node_modules/`, `vendor/`, `target/`, `dist/`, `build/`, any path with a `.claude/worktrees/` component, `*-lock.json`, `*.lock`, `*.min.*`, `*.snap`, `*.svg`, and any file the diff reports as binary.
- A diff over `DIFF_LINE_CAP` changed lines, which is an import or a vendor drop rather than this change's prose.
- Any repository that cannot be resolved: a `cd` to a path that cannot be worked out, a directory that is not a repository, a git call that fails or times out. The message check does not need a repository and still runs.
- A file the commit deletes, which contributes neither its lines nor its comments.
- A combined diff, which a merge conflict produces. Its header is not `diff --git`, so no record is opened and nothing is reported at positions that do not mean what they say.

**The dash check**

- Two characters only. The double hyphen the rule also names is deliberately undetected: ` -- ` is end of options in every shell, a comment marker in SQL and Lua, `--` is a decrement operator and the prefix of every long flag, and `---` is front matter, a horizontal rule and a table separator. The rule stands; the check declines to guess.
- An en dash between two digits is a range.
- In a documentation file (`.md`, `.markdown`, `.mdx`, `.txt`, `.rst`, `.adoc`) every added line is prose, except inside a fenced or indented code block, inside YAML front matter, and on a blockquote line, which is someone else's words.
- Fence state is tracked from the diff's own kept lines and restarts at each hunk, because the lines between hunks were never shown. Two consequences are deliberate: a line added inside a code block whose opening fence is out of view reads as prose, and front matter is only recognised where a hunk reaches line 1, so an edit deep inside a long front matter block reads as prose too. Both err toward a finding, which the override clears.
- In a source file only comment text is prose: a line whose first non blank characters are a comment marker for that extension, or a trailing comment on a line carrying no quote character.
- Nothing else in a source file is read, so a string literal, a UI label, a test fixture and a data file are all invisible to it.

**The comment count**

- Only files present in the commit's parent. A new file's comments are not counted, which is the rule itself: fewer comments than you found, in a file you are working on.
- Only line comments and block comment bodies that lead with a marker: `//`, `#` (never a shebang), `/*`, `* `, `*/`, `--`, `;`, `<!--`, and only for extensions where that marker is unambiguous.
- Python docstrings, template literals and any block comment whose lines do not lead with a marker are not counted. In a docstring driven file the number is near zero, which is a small true number rather than a large guessed one.

**The changelog check**

- Only a file whose basename starts with `CHANGELOG`. `.changeset/` entries and `changelog.d/` fragments are not recognised.
- Only added top level bullets. Indented continuation is ignored, so a multi line entry is measured by its first line.

**Deliberately uncaught, in full**

- Comment bloat in a brand new file.
- Narration in a comment, and abstraction in a changelog entry. Both are judgement, and both go to the developer's `Comments:` line.
- A missing changelog entry, because whether a change is a product change is judgement.
- The double hyphen, everywhere.
- A commit made from inside another interpreter, such as `bash -c "git commit …"`, whose command word is not `git`.
- A message built by command substitution. `git commit -m "$(cat msg.txt)"` presents the literal text `$(cat msg.txt)` as its message, and the message check reads that. The diff checks are unaffected.
- Text that never reaches a commit: replies to the user, PR titles and bodies, an uncommitted working tree. A PR body is shown to the user for approval before it is posted, so a human already reads it.

## Failure and silence

The hook exits 0 on every path and blocks only on a finding it can state. Input it cannot parse, a repository it cannot resolve, a diff it cannot read, a diff over the cap, its own unexpected error: every one produces silence, the way `hooks/guard.sh` falls silent without jq. A bug prints its traceback to stderr, which reaches the debug log and never the model's context.

Silence is a bypass as well as a failure mode, so the ways past the check are named rather than hidden: an unreadable repository, another interpreter, and a message the hook can read that carries an acknowledged trailer.

## What the developer reports

`agents/developer.md` carries one line for the judgement half, alongside `Reuse:` and `Retro:`:

- `Comments:` the comment lines added and removed across the branch, and what each surviving addition says that the code cannot. `Comments: +0/-6` is the normal answer.

The hook's number covers a single commit. The drift `RETRO.md` records accumulated across a whole feature, which is what the branch wide count catches. There is no `Changelog:` line: the hook covers the mechanical half, and a fourth required line is ceremony.

## Thresholds

Named constants at the top of `hooks/style.py`, and meant to move once the check has been seen firing.

| Constant | Start | Why there |
| --- | --- | --- |
| `CHANGELOG_ENTRY_CHARS` | 160 | double the length of a correct entry under the current rule, and above the median of every historical entry measured |
| `CHANGELOG_ENTRY_COUNT` | 5 | "a handful of them, often one" |
| `COMMENT_NET` | 3 | one genuinely earned comment must not trip it |
| `DIFF_LINE_CAP` | 5000 | past this a commit is an import or a vendor drop, and its prose is not ours |
| `FINDINGS_SHOWN` | 40 | enough that a real commit lists all of its findings, capped so a vendor drop that slipped the cap is still readable |

## Not doing now

Marked separately because none of it is part of the contract above.

- **A judgement pass over added comments.** A model reading the added comments of a diff would catch the narration no pattern can. It costs a model call per commit and belongs to the reviewer, not to a hook.
- **The same checks at `PostToolUse[Write|Edit]`**, catching a dash the moment a file is written. Rejected for now because it fires on every edit an agent makes rather than once per commit, which is noise against a rule the commit already catches.
- **A branch wide report**, computed at the moment the developer hands back rather than per commit. The developer's own count covers this until a mechanism exists.
- **`Vale` for documentation prose**, if the writing standards ever grow past a single character class.
