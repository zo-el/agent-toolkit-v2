---
name: ui-review
description: The loop for showing UI work — drive the real app through its journey, save a numbered screenshot gallery, self-review every shot, then hand the gallery over and regenerate per round. Use whenever building, changing, or styling any UI, front end, screen, view, or component the user will want to see.
---

# UI review

The user reviews UI from screenshots of the real app, never from a description or a live run they have to drive themselves.

## The mechanism

- A `snap(name)` helper in the e2e harness. With an env var set (`UI_SHOTS=<dir>`) it saves a numbered screenshot; unset it is a no-op, so CI pays nothing. WebdriverIO: `browser.saveScreenshot`. Playwright: `page.screenshot`.
- Specs call `snap("w2-intro")` at each visual beat, named for the journey step, so the gallery reads as the user's path through the feature.
- A `shotsEnabled()` guard may stretch scripted mock timings so transient states — spinners, progress rows — hold still long enough to capture. That is the only conditional allowed. Never land demo pauses in a spec.

## Self-review before handing it over

Look at every shot yourself. The user's time goes on design decisions, not on bugs you could have caught. Hunt for:

- Two shots that look the same — a beat that stopped earning its place. Make each shot show its subject; open the menu that holds the disabled buttons.
- An assertion that passes invisibly. A `disabled` check on a control inside a closed menu proves nothing to someone looking at a picture.
- Styling inherited across a surface boundary — light text from a dark parent landing on a white card.
- Mock data that misrepresents the state. Mock the real happy path so shots show production appearance.
- Side effects of a state change — a rotation turning a circle into a diamond.

## Spec mechanics

- Assert transient UI from component state, not by polling DOM text. Fast flows outrun a one-second poll and the pane unmounts.
- Whitespace-normalise text matching. Formatters hard-wrap template sentences, putting newlines mid-phrase in `textContent`.
- A spec that sets persistent state cleans it before **and** after. A crashed run's leftovers must not poison the next one, and browser profiles outlive runs.
- A failure the spec depends on must not hinge on network timing to an unreachable host. Assert the state transition, not an error message that may never render.

## With the user

Present the gallery as a numbered table: shot → what they're looking at. Map each change request back to the shot it came from, and look at the regenerated shot yourself before saying it's fixed. Flag your own findings in the same round, but apply only what they asked for.
