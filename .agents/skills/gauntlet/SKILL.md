---
name: gauntlet
description: Use when the user wants a Fancy Scripts change built and hardened autonomously ("run the gauntlet", "build and critique until it's good", "iterate until it meets the bar") from an approved plan, spec or design doc, or to put an existing branch through repeated critique-and-fix rounds.
---

# Gauntlet loop

One **builder** edits the code. Independent, read-only **critics** attack it through fixed lenses,
a **verifier** throws out findings that don't hold up, and the loop repeats until the change meets
`reaper-quality-bar` or a stop rule fires. You (the main session) are the **orchestrator**.
You run the loop, keep the ledger, and are the only one who talks to the user.

```
plan ─▶ BUILD ─▶ GATES ─▶ CRITICS (parallel) ─▶ VERIFY ─▶ ledger ─▶ pass? ──yes──▶ HAND-OFF
          ▲                                                           │no
          └──────────────────────── FIX (open verified findings) ◀────┘
```

## 0. Preconditions (stop and ask if any is missing)

- **An approved input.** That means a plan (`docs/superpowers/plans/…`), a spec, a design doc with `Status: Approved`, or a precise request the user just confirmed. No input yet? Run `superpowers:brainstorming` (and `reaimgui-ux-design` for new UI) first. The gauntlet doesn't brainstorm.
- **Acceptance criteria.** Copy them from the input into the ledger. If the input has none, write 3–7 testable ones and get the user's yes before round 1.
- **A clean working state.** Do the work on a feature branch, never `main`. Check `git status`: if it shows uncommitted work the user didn't hand you, ask before touching it. Never run `git stash`, `git checkout -- .`, `git add -A` or `git add .` over it.
- **The ledger file**, created from `references/ledger-template.md` at `docs/gauntlet/<YYYY-MM-DD>-<slug>.md`. That path is tracked, so a run can be picked up on another machine, and `docs` is ignored by ReaPack.

## 1. Build (round 1) / Fix (round 2+)

- The builder is you or a single subagent (`ui_agent` for approved UI batches). **Only the builder edits files.**
- Round 1 implements the plan. Rounds 2+ fix **only** the ledger's open, verified findings (severity ≥ 2), plus anything that's needed to make a gate pass. No drive-by refactors, because each one gives the critics new surface to attack.
- The builder follows the repo conventions in `reaper-quality-bar` (R1–R5): it bumps the version and writes the CHANGELOG entry as part of the build, not at the end.
- Commit at the end of every round with the message `gauntlet r<N>: <summary>`, adding named files only. The commits give you a clean diff per round and a point to roll back to.

## 2. Gates

Run `reaper-gates`. Any FAIL goes back to the builder **before** the critics run, because there's no point critiquing code that doesn't lint. If gates fail twice in a row with the same message, that counts as a stall (§6).

## 3. Critics (parallel, read-only, blind)

Dispatch one subagent per lens with the filled `references/critic-prompt.md`. The lenses are:

| Lens | File | Runs when |
|---|---|---|
| API | `references/lens-api.md` | any `.lua` changed |
| Runtime | `references/lens-runtime.md` | any `.lua` changed |
| UX | `references/lens-ux.md` | the diff touches ImGui drawing code, or a design doc covers the target |
| Release | `references/lens-release.md` | always |

Critics are **blind** to the builder. They get the diff, the files, the bar, the acceptance
criteria and the list of findings already closed. They never get the builder's reasoning or chat,
and never the previous round's raw critic output. Being blind is the whole point: a critic that
reads the builder's rationale tends to agree with it.

Round 2+: critics review the **cumulative diff against base**, not just the last round's fix. A
fix can break something the earlier rounds got right.

**Inline fallback** (no subagents available, or running in Antigravity): run the lenses one at a
time in the main context. Re-read the bar and the lens file before each one, and don't read your
own build notes while you critique.

## 4. Verify (adversarial)

Every new finding at severity ≥ 2 goes to a verifier subagent with `references/verify-prompt.md`.
The verifier's job is to **disprove** the finding by reading the code, the API docs and REAPER's
real behaviour. Its verdict is one of:

- `CONFIRMED`: open it in the ledger.
- `REJECTED`: record the reason in the ledger. A rejected finding is never sent to the builder.
- `UNVERIFIABLE_HERE`: the finding depends on live REAPER (undo, focus, rendering). Record it under **Needs a live check**. It doesn't block the loop, but it blocks the final "done" until a live check happens on a machine with REAPER, or the user waives it.

Merge duplicates across lenses: keep the highest severity, and cite both lenses.

## 5. Ledger and pass check

Update the ledger (see the template). Every finding has a stable ID `G<round>-<n>`, a lens, a
rule ID, a severity, evidence and a status (`open`, `fixed r<N>`, `rejected`, `wontfix`,
`needs-live`). Then check the bar:

- **PASS** = gates PASS/SKIP, no `open` finding at severity ≥ 3, and every acceptance criterion shows evidence. Go to §7.
- Otherwise start the next round.

## 6. Stop rules (escalate to the user, don't keep going)

- **Round cap.** After 3 fix rounds (4 critic rounds in total) without a PASS, stop. The user can raise the cap for this run.
- **Oscillation.** A finding gets fixed, then the same rule ID re-opens at the same location. Or two findings' fixes undo each other.
- **Stall.** Gates fail with the same message twice in a row, or a round closes zero findings.
- **Scope creep.** A finding needs a change outside the plan's files, `_lib/theme.lua` token changes, saved-data format changes, or a version bump larger than the plan says.
- **Disagreement with the bar.** A critic and the bar conflict, or a CONFIRMED finding contradicts the approved design doc.

When you escalate, give the user the ledger summary, the specific blocker, and 1–3 options with your recommendation.

## 7. Hand-off

Report:

1. The gate table (pasted, not summarised).
2. Each acceptance criterion with its evidence.
3. Ledger totals: fixed, rejected, wontfix and open severity-2 items (as follow-ups).
4. The **Needs a live check** list. These are steps to run in REAPER on the Mac: what to launch, what to do, what should happen. If any of them is open, the change is "done pending live check" and not just "done".

Don't push or open a PR unless the user asked for it.
