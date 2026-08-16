# Retro log

Learnings from sessions, one line each. Appended as they happen, reviewed on demand with the `toolkit` skill, and deleted once acted on.

A line belongs here when it is: something inefficient a toolkit change would fix, a pattern that works better than what we currently tell agents to do, or a repetition worth a new skill or plugin. Not bugs, not project notes.

Format: `- YYYY-MM-DD · <agent> · <project> — <what was inefficient, and what would be better>`

- 2026-08-14 · developer · unyt-workshop — mutation testing (mutate the production code, re-run the harness, record which assertions stay green) found four unfalsifiable assertions that three read-only review passes had missed or under-rated. Worth naming as a technique in the reviewer and developer definitions rather than being reinvented per session.
- 2026-08-15 · developer · unyt-workshop — bash 3.2 ends a `$( )` by scanning for the closing paren rather than parsing, so a `)` inside a case pattern or a comment truncates the substitution; `bash -n` cannot see it and the error surfaces at an innocent line. Any shell script that runs on a macOS runner should be checked with `docker run bash:3.2` in the local loop — two CI round trips went to this.
