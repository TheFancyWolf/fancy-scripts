---
name: reaper-quality-bar
description: Use when deciding whether a change to a Fancy Scripts REAPER script is good enough to ship, when writing acceptance criteria for a plan, or when a builder or critic agent needs the shared standard it is judged against.
---

# Fancy Scripts quality bar

This is **the standard**. The builder works toward it, the critics judge against it, and the
`gauntlet` loop stops when it is met. It is the only definition of "done". If a rule here is
wrong, change this file in its own commit; don't argue it away mid-loop.

A change **passes** when:

1. every **hard gate** (H1–H8) is `PASS` or an allowed `SKIP` (see H-table), **and**
2. the findings ledger has **no open, verified finding at severity 3 or 4**, **and**
3. every acceptance criterion in the plan or design doc is met, with evidence.

Severity-2 findings may stay open if they are written down as follow-ups. Severity-1 findings never block.

## Hard gates (machine-checked)

Run them all with one command (exit code 0 means pass):

```sh
python3 "$(git rev-parse --show-toplevel)/.agents/skills/reaper-gates/scripts/gates.py"
```

| ID | Gate | Allowed SKIP |
|---|---|---|
| H1 | `luacheck` reports zero warnings and zero errors on every changed `.lua` file | none (luacheck missing means FAIL; install with `brew install luacheck` or `apt-get install lua-check`) |
| H2 | Every changed package script (`FX/ Metering/ Mixing/ Pitch/ Routing/ Utility/`) has `@description`, `@author` and a semver `@version` | no package script changed |
| H3 | Every changed package script that already existed has a **higher** `@version` than on the base branch | new script |
| H4 | `CHANGELOG.md` changed when any package script or `_lib/` file changed | no shipped file changed |
| H5 | `index.xml` is not touched (CI generates it) | — |
| H6 | Nothing new gets packaged: every changed `.lua/.eel/.py/.jsfx/...` file outside the package dirs and `_lib/` is under a `--ignore` path in `.reapack-index.conf` | — |
| H7 | `ds-lint.py` (from `reaimgui-ux-review`) reports no **new** `definite` findings on changed UI scripts | ds-lint not installed on this checkout |
| H8 | Self-tests pass for any changed helper that has one (`gates.py --self-test`, `ds-lint.py --self-test`) | no such helper changed |

## Soft gates (judged by critics, severity 1–4)

Severity follows Nielsen: **4** catastrophe (data loss, crash, REAPER hang, corrupt project),
**3** major (broken feature, wrong API use, undo pollution, convention violation users will hit),
**2** minor (rough edge, inconsistency), **1** cosmetic. A finding with no concrete failure
scenario is not a finding.

Every finding **must** cite a rule ID below (or an HC/UX rule ID from `reaimgui-ux-review`) and
give evidence as `file:line` plus the concrete scenario. "Could be cleaner" is not evidence.

### API — correct use of REAPER and ReaImGui

- **A1** Every `reaper.*` and `ImGui.*` function exists, with the argument order and return values used. Verify against the `reaper-dev` MCP (`get_function_info`), or `reaimgui_api_names.txt`, never from memory.
- **A2** ReaImGui targets 0.10 (Dear ImGui 1.92). No pre-0.9 `reaper.ImGui_*` calls in new code unless the file already uses that style throughout.
- **A3** Begin/End pairs are balanced on **every** path, including an early `return`, a collapsed or clipped window, and an error. `End` is called only when `Begin` requires it (`visible` vs `open` semantics).
- **A4** Push/Pop counts match per frame, including `Theme.push`/`Theme.pop` and fonts (`local pushed = Theme.push_font(...)` … `Theme.pop_font(ctx, pushed)`).
- **A5** Handles (tracks, takes, FX, envelopes) are validated (`ValidatePtr2`) before use if they were cached across a `defer` tick.

### RT — runtime behaviour inside REAPER

- **RT1** Every user-visible change to the project is exactly one undo point, inside `Undo_BeginBlock`/`Undo_EndBlock`, with a descriptive name. No empty undo points, and none created per frame.
- **RT2** `defer` loops stop cleanly: `atexit` releases state and toolbar toggles (`SetToggleCommandState` + `RefreshToolbar2`), and the loop ends when the window closes.
- **RT3** No per-frame work that scales with project size unless it is cached or throttled. Check with `GetProjectStateChangeCount` or a timer.
- **RT4** Project switching and closing are handled: state is keyed per project (or re-read) and survives tab changes without acting on the wrong project.
- **RT5** Persistence: ExtState keys are namespaced (`Fancy_<Script>`), and stored data has a version or defaults. Corrupt or missing data falls back safely and tells the user.
- **RT6** Errors never leave a half-applied edit. A `pcall` around the risky section restores state, and error messages name the action.
- **RT7** Works on macOS, Windows and Linux. No hard-coded path separators, and modifiers use `Mod_Ctrl`/`Mod_Super` correctly.

### UX — interface (defers to `reaimgui-ux-review` when it is installed)

- **U1** House conventions HC1–HC6 (contrast, fine adjust, reset/type, destructive actions, Esc, Space).
- **U2** Uses `_lib/theme.lua` tokens and helpers. No new hard-coded colours or sizes in non-legacy scripts.
- **U3** Matches the approved design doc in `docs/design/`, if one exists with `Status: Approved`.

### R — release hygiene

- **R1** The `@changelog` in the header and the `CHANGELOG.md` entry describe what changed, in user terms, and claim nothing the code doesn't do.
- **R2** Version bump size: patch for fixes, minor for features, major for breaking changes to saved data or actions.
- **R3** `@provides` covers every file the script loads at run time (for example `[nomain] ../_lib/*.lua`).
- **R4** No dev-only files are shipped (see H6), and there are no debug `ShowConsoleMsg` leftovers.
- **R5** The README script list is updated when a script is added or renamed.

## Evidence the builder must attach for "done"

- `gates.py` output (the full table).
- For each acceptance criterion: how it was checked (`file:line`, gate output, or screenshot).
- Things that could **not** be verified in this environment, listed explicitly. In a cloud session REAPER can't run, so live behaviour (RT1, RT2, RT4, visual U1) is `not verified (no REAPER)` and goes into the hand-off notes for a check on the Mac.
