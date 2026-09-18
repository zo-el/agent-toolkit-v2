---
name: diagnose
description: The loop for a bug, a failing or flaky test, or a performance regression. Build a red feedback loop, minimise it, rank falsifiable hypotheses, then fix under a regression test. Use whenever something is broken, throwing, failing, flaky, slow, or behaving unexpectedly, before proposing any fix.
---

# Diagnose

A fix without a confirmed cause is a guess. This loop finds the cause first.

## 1. Build a red loop

One command that drives the real bug path and goes red on the user's exact symptom. This step is most of the work.

- Reach for it in this order: a failing test at the nearest seam, a script against the running service, a CLI run diffed against known good output, a replayed captured payload, a throwaway harness, a fuzz loop, `git bisect run` between a good and a bad state, the same input through the old and new versions.
- Tighten it: seconds, not minutes. Deterministic: pin time, seed randomness, isolate the filesystem. Sharp: it asserts the symptom, not "did not crash".
- Flaky: raise the reproduction rate (loop it, parallelise, add load) until it fails often enough to debug.
- Done when you have run it and watched it go red. No red loop, no hypotheses. If you cannot build one, message `main` with what you tried and what access would unblock it.

## 2. Minimise

Cut inputs, callers, config and steps one at a time, re-running after each cut. Stop when every remaining piece is load-bearing. The minimal repro becomes the regression test.

## 3. Hypothesise

Write three to five ranked hypotheses before testing any. Each states its prediction: "if X is the cause, changing Y turns the loop green." A hypothesis with no prediction is discarded.

## 4. Probe

One variable per probe, each mapped to a prediction. A debugger or REPL beats logs. Tag every debug log with one prefix (`[DBG-a4f2]`) so cleanup is one grep. For a performance regression, measure a baseline first, then bisect.

## 5. Fix

- Turn the minimal repro into a failing test at a seam that exercises the real bug. Watch it fail, fix, watch it pass, then re-run the original loop.
- No seam reaches the bug: that is a finding. Report it rather than writing a test that cannot fail on it.
- Two fixes that did not hold means the cause is still unknown. Stop fixing, go back to step 3 with what they disproved, and message `main` if the approach itself looks wrong.

## Done

- The original loop is green and the regression test proves it.
- Every tagged debug log is gone.
- The commit message states the confirmed cause, so the next debugger starts from it.
