# Retro log

Learnings from sessions, one line each. Appended as they happen, reviewed on demand with the `toolkit` skill, and deleted once acted on.

A line belongs here when it is: something inefficient a toolkit change would fix, a pattern that works better than what we currently tell agents to do, or a repetition worth a new skill or plugin. Not bugs, not project notes.

Format: `- YYYY-MM-DD · <agent> · <project> — <what was inefficient, and what would be better>`

- 2026-08-14 · main · unyt-workshop — a compound `cd <dir> && …` in one Bash call silently moved the session cwd, so a later `git commit` landed in the parent repo under the submodule's message and had to be unwound. In a multi-repo tree the session should use `git -C <repo>` for every git call and never rely on cwd.
