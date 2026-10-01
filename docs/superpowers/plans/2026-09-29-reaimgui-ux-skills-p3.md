# ReaImGui UX Skills — Phase P3 Implementation Plan (`reaimgui-ux-design`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `reaimgui-ux-design` skill (SKILL.md, `design-process.md`, `house-patterns.md`, `design-doc-template.md`) so that scenarios D1–D4 pass in the sandbox, the routing tests pass on the held-out set for both skills, and the `.claude/skills/reaimgui-ux-design` symlink exists.

**Architecture:** A second local skill directory that turns a script's features into an approved design document (`docs/design/<slug>.md`) and writes no code. It reads the review skill's references directly by path (`$R`), never by invoking that skill. The SKILL.md is written after the D1–D4 baselines so its prose answers observed failures; the template and process file carry the structure the agent cannot know. The P2 harness (`sandbox.sh`, `router.py`, `check_refs.py` extended) is reused.

**Tech Stack:** Markdown skill files; Python 3 stdlib harness from P2; `ds-lint.py`; the Agent tool and `SendMessage`.

**Spec:** `docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md` (Revision 2), §4, §3.1, §8. This plan implements phase **P3** of §3.3 only and depends on P2 being installed (the design skill reads `.agents/skills/reaimgui-ux-review/references/`).

## Plan-level decisions

| # | Decision | Why | Cost if wrong |
|---|---|---|---|
| PD1 | D1's target is the real `Routing/Fancy_Copy Fader to Send.lua` (58 lines, headless: `GetUserInputs` prompt, undo block, per-selected-track send volume copy) | It exists in the repo with exactly the spec's line count | None |
| PD2 | The worked mini-example in `design-process.md` uses a **hypothetical** headless action ("Mute Sends by Name"), not Copy Fader to Send | D1 must not be answerable by copying the example | None |
| PD3 | D2's "ambiguous one-line spec" is: "Make a little window for Mapper stuff." | One line, names no script, no feature list | Swap the sentence |
| PD4 | D3 (pressure) runs ×3; D1, D2, D4 ×1; each has a RED baseline | Spec §8.2: pressure scenarios ≥3 runs | None |
| PD5 | The checkpoint 2b in sandbox runs is answered by the test driver with a fixed reply ("Floating window, used mid-session a few times per project, playback may be running, mostly mouse") via `SendMessage`, so the run can reach the doc | Subagents cannot ask the user | None |
| PD6 | `check_refs.py` gains a `--design` mode rather than a second checker | DRY; same invariants (API names, Theme names, rule IDs, no token values, word count, Read when) | None |
| PD7 | The router held-out target must pass for **both** skills after P3's tuning (the review set is re-run once with the final descriptions) | Spec §8.4 targets are per skill and descriptions interact | Re-run 24 small agents |
| PD8 | Scratchpad `$SP` and sandbox `$SB` as in P2 (PD8 there) | Same session | None |
| PD9 | Only Task 6's grade-table append to the spec is committed; everything else is gitignored or scratchpad | D18 | None |

## Global Constraints

- Frontmatter only `name` + `description` (`>-` folded); description under 500 characters; text taken from spec §4.1 verbatim as the starting point.
- `SKILL.md` ≤ 1,000 words (target ~500), ends with a "Read when" table naming every file under `references/` and `assets/`; reference files over 100 lines start with a Contents list.
- The design skill locates the review references with `R="$(git rev-parse --show-toplevel)/.agents/skills/reaimgui-ux-review/references"` and **never invokes** `reaimgui-ux-review`; if a file under `$R` is missing it stops and says both skills must be installed.
- Rule IDs are cited only from `$R` files and `AGENTS.md`; never from memory.
- No token values in skill text; tokens by key; `theme.lua` sections by name.
- Every `ImGui_` name in skill files exists in `reaimgui_api_names.txt`; every `Theme.<name>` exists in `theme.lua`.
- Output is a design doc only: `docs/design/<slug>.md`, `Status: Draft`, then stop. No Lua, no `ui_agent` dispatch, until the doc is approved.
- Slug: filename without `Fancy_`/`.lua`, lower-cased, spaces → hyphens; suites use the settings script's slug.
- Helper scripts Python 3 stdlib / POSIX shell only; no `.lua` under `.agents/`; sandbox-only edits under `$SB`.
- Main repo: never `git checkout`, `git stash`, `git add -A`, `git add .`; commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Baseline runs get no skill text; the symlink is created only in Task 6.
- Transcripts stored as `$SP/ux-skill-tests/p3/<scenario>-<run>.md`.

## Review Focus

1. **Missing review skill references** (design skill installed alone): the skill must stop with "both skills must be installed" rather than cite rules from memory. [Task 3, D5 extra scenario: run once with `$SB/.agents/skills/reaimgui-ux-review/references` renamed]
2. **A suite target** (Mapper): the slug must be the settings script's (`mapper-settings.md`), not the requested script's. [Task 1, `check_refs.py --design` asserts the slug rule text is in SKILL.md and the template; Task 3 D2 grading checks the slug if a doc is written]
3. **Headless target wireframes**: only the feedback surface, no window widths. [Task 3, D1.3]
4. **Approval flow**: `Status: Approved` set only on an explicit yes, with date and approver; commit only on a yes. [Task 3, D1 follow-up "Approved." graded: status/date/approver set, then the skill *offers* to commit and does not commit without a yes]
5. **HC6 conflict recording**: a design that gives Space its own meaning must record it in "Open questions / HC6 conflicts". [Task 1, template slot present; Task 3 D4 grading checks the slot exists in the doc even when "None"]

---

### Task 1: Template, house patterns, design process, checker extension

**Files:**
- Create: `.agents/skills/reaimgui-ux-design/assets/design-doc-template.md`
- Create: `.agents/skills/reaimgui-ux-design/references/house-patterns.md`
- Create: `.agents/skills/reaimgui-ux-design/references/design-process.md`
- Modify: `$SP/ux-skill-tests/check_refs.py` (add `--design`)

**Interfaces:**
- Consumes: `check_refs.py` from P2; `ds-lint.py` parser; the review references (for rule-ID resolution).
- Produces: the three files; `check_refs.py --design` (checks `.agents/skills/reaimgui-ux-design/{SKILL.md,references/*.md,assets/*.md}` with the same invariants, plus: template has all 15 §4.3 slots; SKILL.md contains the `$R=` line, the slug rule, "Status: Draft" and "stop"; SKILL.md never mentions invoking `reaimgui-ux-review`).

- [ ] **Step 1: Extend the checker (RED)**

Append to `$SP/ux-skill-tests/check_refs.py`, just before the final `print("RESULT", …)` line, this block, and change the `if "--skill" in sys.argv:` file registration so that `--design` swaps `SK`, `REFS` and `ASSETS`:

```python
# --- design skill mode -------------------------------------------------------
if "--design" in sys.argv:
    DSK = os.path.join(REPO, ".agents/skills/reaimgui-ux-design")
    dfiles = {"SKILL.md": os.path.join(DSK, "SKILL.md"),
              "design-process.md": os.path.join(DSK, "references/design-process.md"),
              "house-patterns.md": os.path.join(DSK, "references/house-patterns.md"),
              "design-doc-template.md": os.path.join(DSK, "assets/design-doc-template.md")}
    dt = {}
    for f, p in dfiles.items():
        check("design exists: " + f, os.path.isfile(p)); dt[f] = open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
    for f, t in dt.items():
        names = set(re.findall(r"\bImGui_(\w+)", t))
        check("design API names exist: " + f, not [n for n in names if n not in API], [n for n in names if n not in API])
        tn = set(re.findall(r"\bTheme\.(\w+)", t)) - {"layout", "icons", "font_sizes"}
        bad = sorted(n for n in tn if n not in THEME["names"] and n not in ("status", "confirm", "form_row", "param_control", "reason", "readable_on", "danger_button", "toast"))
        check("design Theme names exist: " + f, not bad, bad)
        check("design no token values: " + f, not re.findall(r"0x[0-9A-Fa-f]{6,8}\b", t))
        cited = set(a + b for a, b in re.findall(r"\b(ST|UC|EP|CN|RC|EF|IA|LG|MT|CL|DV|HI|HP|RB|AR|HC)(\d{1,2})\b", t))
        check("design rule IDs resolve: " + f, not sorted(c for c in cited if c not in rows), sorted(c for c in cited if c not in rows))
        if t.count("\n") > 100:
            check("design Contents list: " + f, re.search(r"^## Contents", t, re.M) is not None)
    tpl = dt["design-doc-template.md"]
    for slot in ("Target file(s):", "Status:", "## Summary", "## Feature inventory", "## References", "## Context and job stories",
                 "## Priority tiers", "## Information architecture", "## Wireframes", "## State inventory", "## Interaction spec",
                 "## Copy deck", "## Theme mapping", "## Library proposals", "## Acceptance criteria", "## Open questions"):
        check("template slot " + slot, slot in tpl)
    sk = dt["SKILL.md"]
    words = len(re.sub(r"^---.*?---", "", sk, flags=re.S).split())
    check("design SKILL.md <= 1000 words", words <= 1000, words)
    fm = re.match(r"---\nname: reaimgui-ux-design\ndescription: >-\n((?:  .*\n)+)---\n", sk)
    check("design frontmatter shape", fm is not None)
    if fm: check("design description < 500 chars", len(" ".join(l.strip() for l in fm.group(1).splitlines())) < 500)
    check("design SKILL.md has $R line", '.agents/skills/reaimgui-ux-review/references' in sk and 'R="$(git rev-parse --show-toplevel)' in sk)
    check("design SKILL.md states both-skills-installed stop", "both skills must be installed" in sk)
    check("design SKILL.md has slug rule", "mapper-settings" in sk and "pan-snap" in sk)
    check("design SKILL.md stops at Draft", "Status: Draft" in sk and "stop" in sk.lower())
    check("design SKILL.md never invokes the review skill", not re.search(r"invoke[s]?\s+(the\s+)?`?reaimgui-ux-review", sk))
    check("design SKILL.md has Red Flags", "## Red Flags" in sk)
    check("design SKILL.md has rationalization table", re.search(r"^\|\s*Excuse", sk, re.M) is not None)
    for f in ("design-process.md", "house-patterns.md", "design-doc-template.md"):
        check("design Read-when names " + f, "Read when" in sk and f in sk.split("Read when")[-1])
```

Also, at the top of the file, make the review-file registration conditional so `--design` does not require `--skill` (wrap the `files = {…}` … `texts` block in `if "--design" not in sys.argv or "--skill" in sys.argv:` and initialise `texts = {}` before it; `rows` must still be computed from the review catalog, which always exists after P2).

Run: `python3 $SP/ux-skill-tests/check_refs.py --design | grep -c FAIL`
Expected: ≥ 4 (`design exists: …` for all four files).

- [ ] **Step 2: Write the template**

Create `.agents/skills/reaimgui-ux-design/assets/design-doc-template.md`:

````markdown
# Design: <Script name>

Target file(s): `<Category/Fancy_Name.lua>`[, `…`]
Archetype(s): <window → archetype; modal family → archetype>  (from `$R/archetypes.md`)
Status: Draft
Date: <YYYY-MM-DD>
Approver: <name, once Approved>

## Summary

<≤ 5 sentences: what the UI is for, who uses it when, the one primary display and the one primary action.>

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|

## References

- Native REAPER analogues: <window(s) and the conventions to match (CN6)>
- Redesigns only: baseline capture `<path>`; `ds-lint.py` summary `<definite n / check m>`

## Context and job stories

<3–6 stories "When … I want to … so I can …", covering mid-session use, playback running, docked vs floating, keyboard vs mouse — as confirmed at checkpoint 2b: where it lives, how often, during playback?>

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | | |
| 2 one disclosure away | | |
| 3 Settings | | |

## Information architecture

<Regions; the primary display; the primary action; at most 2 disclosure levels (IA2); section names that predict their content.>

## Wireframes

<ASCII, per archetype: window/settings hub/editor/instrument → default floating size, narrow docker (~260 px), wide short strip (e.g. 1200×150); overlay/HUD → anchored size + viewport-edge clamp; headless → the feedback surface only. Show what truncates, wraps or hides at each width.>

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| | empty | | ST6 |
| | working | | ST3 |
| | error | | ST7 |
| | disabled with reason | | EP2 |
| | overflow / long names | | LG4 |
| | missing dependency | | HI7 |
| | Fancy Dark / Match Theme | | CL4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|

Keyboard map: <Esc ownership per HC5 (innermost first; closes only when floating) · Space per HC6 · modifier guards · no key-repeat on toggles (EP6) · all listed in the Info modal (HP1)>

## Copy deck

| Where | String |
|---|---|
| labels | |
| tooltips | |
| empty / error / confirm | |
| status messages | |
| undo labels | |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|

## Library proposals

None. | <proposed API signature · why no helper fits · beneficiaries>

## Acceptance criteria

<every applicable rule ID (from the archetype's set + HC1–HC6), each with a one-line expectation or "n/a: <reason>">

## Open questions / assumptions

<questions asked or explicit assumptions recorded; HC6 conflicts: None | <Space meaning and the user's approval>>
````

- [ ] **Step 3: Write `house-patterns.md`**

Create `.agents/skills/reaimgui-ux-design/references/house-patterns.md`:

````markdown
# House patterns: shell, modal, lifecycle, exemplars

Structures every Fancy Scripts window follows. Cite helpers by name and tokens by key; read `_lib/theme.lua` (sections "DESIGN TOKENS — LAYOUT", "WIDGETS", "HEADER") for signatures and values. Exemplars are cited for **structure, not token compliance**: they still use raw modal sizes and Parameter Link's CTA lacks `###`.

## Shell

- `Theme.header(ctx, opts)` with an ALL-CAPS title, `opts.fonts`, and `opts.right_widgets` for the header's controls. Current exemplars use text buttons "Info" and "Settings" (Parameter Link, Pan Snap) or one gear `Theme.icon_btn` (`Theme.icons.gear`) opening a popover (Mapper Settings).
- Pass `opts.close_tooltip` per HC5: "(Esc)" only while floating.
- The Info modal is a tab bar ending in "About"; tab names vary.
- Settings contain `Theme.settings_widget(ctx)` (theme mode) and `Theme.tooltip_setting_widget(ctx)`.
- `Theme.section_divider(ctx, label, opts)` separates sections; sections render only their own content and the parent owns inter-section spacing (`reaper.ImGui_Dummy(ctx, 0, L.<scale key>)`).
- One status channel per window (ST2): a single line under the header or above the footer, `P.text_dim`, cleared after a few seconds.

## Modal recipe

pending flag → `reaper.ImGui_OpenPopup` once → `Theme.center_next_window(ctx, L.modal_<sm|md|lg|xl>.w, L.modal_<…>.h, reaper.ImGui_Cond_Appearing())` → `Theme.modal_scrim(ctx, id)` → `reaper.ImGui_BeginPopupModal` → Esc per HC5 (`reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape())`) → `reaper.ImGui_EndPopup`. All of it inside the window's `if visible` block. A confirm modal names the consequence and count, puts Cancel first, Esc = Cancel (recipes in `$R/recipes.md` → HC4).

## Window lifecycle (RB1)

```lua
local pushed = Theme.push_font(ctx, fonts.default)
Theme.push(ctx)
local visible, open = reaper.ImGui_Begin(ctx, "Fancy <Name>", true, flags)
if visible then
  -- body and modals
  reaper.ImGui_End(ctx)
end
Theme.pop(ctx)
Theme.pop_font(ctx, pushed)
```

`Begin` / `BeginChild` / `BeginPopupModal` end themselves when they return false. Main windows use `Cond_FirstUseEver`; modals `Cond_Appearing`; overlays `WindowFlags_NoSavedSettings | WindowFlags_NoFocusOnAppearing` (`NoInputs` when display-only) (HI2, AR3). Cache `reaper.ImGui_IsWindowDocked(ctx)` right after the main `Begin`.

## Exemplars

- **Mapper Settings** (`Mixing/Fancy_Mapper Settings.lua`, settings hub): `DEFAULTS` table as the single source of truth (AR1); a `UI` table derived from `L.*`; form-row helpers (AR2); mode-keyed panel dispatch; an inline disabled reason (EP2); a reset confirm that states the consequence, Cancel first, closes on Esc (HC4); a count-bearing primary "Apply (N)" in the calibrate dialog (AR5); modals via a pending-popup queue inside `if visible`.
- **Parameter Link** (`FX/Fancy_Parameter Link.lua`, settings hub): empty-state text names the next step (ST6); the CTA previews its consequence ("Add N Links across M Tracks") and is disabled at 0 (AR5); paused rows are dimmed.
- **Pitch Correct** (`Pitch/Fancy_Pitch Correct.lua`, editor/canvas): live preview with commit on release and a descriptive undo label (UC1).
- **Pan Snap** (`Routing/Fancy_Pan Snap.lua`, overlay/HUD): the feedforward overlay never steals focus (`WindowFlags_NoInputs`, `WindowFlags_NoFocusOnAppearing`, `WindowFlags_NoSavedSettings`) (AR3).
- **Headless actions** (`Mixing/Fancy_Mapper *.lua`, `Routing/Fancy_Copy Fader to Send.lua`): feedback for every path including failure (ST2, ST7); no undo point when nothing changed (UC1); a feedback toast is designed and reviewed as an overlay window.

## Helpers you may map to (exist today)

`Theme.header`, `Theme.section_divider`, `Theme.collapsing_header`, `Theme.icon_btn`, `Theme.icon_btn_colored`, `Theme.toggle_button`, `Theme.badge`, `Theme.badge_button`, `Theme.selectable`, `Theme.combo`, `Theme.multi_combo`, `Theme.progress_bar`, `Theme.tooltip`, `Theme.align`, `Theme.right_align`, `Theme.hcenter`, `Theme.center_next_window`, `Theme.modal_scrim`, `Theme.brand_icon`, `Theme.push_button_preset`, `Theme.settings_widget`, `Theme.tooltip_setting_widget`, `Theme.icons.*` (`play pause close plus info tri_down tri_up tri_left tri_right slider gear`). Anything else is a **Library proposal** (`Theme.status`, `Theme.confirm`, `Theme.form_row`, `Theme.param_control`, a danger preset, `Theme.reason`, a canvas palette, `readable_on`).
````

- [ ] **Step 4: Write `design-process.md`**

Create `.agents/skills/reaimgui-ux-design/references/design-process.md` (spec §4.2 in full plus the worked mini-example):

````markdown
# Design process (steps 1–10 in full) with a worked mini-example

`R="$(git rev-parse --show-toplevel)/.agents/skills/reaimgui-ux-review/references"`. If any file under `$R` is missing, stop: both skills must be installed.

## Contents

1. Feature inventory (+1b references)
2. Context and jobs (+2b checkpoint)
3. Archetype per window
4. Information architecture
5. Wireframes
6. State inventory
7. Interaction spec (+7b copy deck)
8. Theme mapping
9. Self-check → acceptance criteria
10. Write and stop
- Worked mini-example: "Mute Sends by Name" (headless)

## 1. Feature inventory

From the code or the spec list every user action and parameter; the data displayed; the REAPER state read and written; and, for each action, **whether one Ctrl/Cmd+Z fully restores it, including script state** (HC4's three conditions: single undo block on project objects, model reload on `GetProjectStateChangeCount`, no ExtState/JSON/file/cache change).

**1b. References.** For a redesign: capture the current UI (REQUIRED SUB-SKILL: `reaper-screenshot`) and run `python3 "$R/../scripts/ds-lint.py" <file>` for a baseline. Always: name the closest native REAPER window(s) and list the conventions to match (CN6: dB with `-inf`, pan as `%L`/`C`/`%R`, right-click menus, Ctrl/Cmd-drag fine, no Alt/Shift repurposing).

## 2. Context and jobs

Write 3–6 job stories ("When … I want to … so I can …") covering mid-session use, playback running, docked vs floating, keyboard vs mouse. Draft a frequency × importance ranking into Tier 1 (always visible), Tier 2 (one disclosure away), Tier 3 (Settings).

**2b. Checkpoint.** Present the job stories and tier ranking as **one multiple-choice message**: where does it live (floating / docked / overlay / none), how often (every few minutes / few times per project / rarely), during playback (yes / no)? **Wait for confirmation before IA.** Your guesses are not validated data.

## 3. Archetype per window

Read `$R/archetypes.md`. Choose one archetype per top-level window or modal family (a script may have several). Record each archetype's applicable rule set (all rules minus its exclusions, plus its AR rules, plus HC1–HC6).

## 4. Information architecture

Define regions. Choose one primary display and one primary action (IA3). At most 2 disclosure levels (IA2). Name sections so they predict their content.

## 5. Wireframes

ASCII, at the widths the archetype supports:
- window / settings hub / editor / instrument: default floating size, narrow docker (~260 px), wide short strip (e.g. 1200×150);
- overlay / HUD: its anchored size, plus a viewport-edge clamp case;
- headless: its feedback surface only.
Show what truncates, wraps or hides at each width (LG4).

## 6. State inventory

For every region: empty (ST6), working (ST3), error (ST7), disabled-with-reason (EP2), overflow / long names (LG4), missing dependency (HI7), both theme modes (CL4). Each row says what the user sees and cites the rule.

## 7. Interaction spec

Read `$R/recipes.md`. One table row per control: gestures (HC2 fine adjust, HC3 reset/type, wheel per EF1, context menu), default value, units/format/precision (RC2, CN6), clamp and scale (EP3: `AlwaysClamp`; Logarithmic only for positive ratio quantities over 100×; dB linear in dB), undo label (UC1), destructive policy (HC4). Keyboard map: HC5 Esc ownership, HC6 Space, modifier guards, no key-repeat on toggles (EP6), all listed in the Info modal (HP1).

**7b. Copy deck.** Every user-visible string in user terms: labels, tooltips, empty/error/confirm text, status messages, undo labels. No API jargon (RC2).

## 8. Theme mapping

A table mapping every element to an existing `Theme.*` helper and token keys (`house-patterns.md` lists the helpers that exist). Anything without a helper goes to **Library proposals** with a proposed API signature. Never invent inline; never write raw numbers or colours.

## 9. Self-check

Read `$R/principles.md`. Walk every rule in each window's applicable set. **Acceptance criteria** = every applicable rule ID, each with a one-line expectation or "n/a: <reason>".

## 10. Write and stop

Write `docs/design/<slug>.md` from `assets/design-doc-template.md` with `Status: Draft`, present a summary, and **stop**. If the request also asked for code, say implementation starts only after the doc is approved, and stop. Ambiguous spec: ask focused questions first; if the user prefers to proceed, record explicit assumptions in "Open questions / assumptions".

**Approval.** When the user approves in chat: set `Status: Approved`, the date and the approver; offer to commit the doc; commit only on a yes. Handoff: `superpowers:writing-plans` for a new window or a multi-region change, or `ui_agent` with the doc path for one region. Library proposals go through the review skill's Tier C flow.

## Worked mini-example: "Mute Sends by Name" (hypothetical headless action)

*Request:* "Add a GUI to a headless action that mutes every send whose destination name contains a string."

1. **Inventory.** Actions: enter a substring; run. Parameters: substring, match case (bool). Displayed: count of matching sends, per-track result. REAPER read: selected tracks, send names. Written: `B_MUTE` on sends. One Ctrl/Cmd+Z: **Y** if all sends are muted inside one undo block and no ExtState is written; the "last substring" convenience would be ExtState → **N** for that part, so it is not restored (acceptable: it is not visible project state, but the doc records it).
   1b. Native analogue: the Routing window's send list (send names shown as "track name" with `%L/C/%R` pan, dB with `-inf`).
2. **Jobs.** "When I'm mid-mix with playback running, I want to mute all reverb sends on the selected tracks so I can hear the dry signal." (+2 more.) Tiers: 1 = substring + Run; 2 = match case; 3 = none.
   2b. Checkpoint asked: lives as a **small floating window** opened by the action; used a few times per project; during playback yes. *(Confirmed.)*
3. **Archetype.** Headless action + one transient overlay (the feedback toast) → `archetypes.md` rows "Headless action" and "Transient overlay / HUD"; excluded LG*, MT*, IA*, CL*, DV1, HI1, HI2, HI6, EF3 for the action; AR3 for the toast.
4. **IA.** Regions: input row; result line. Primary display: "N sends match". Primary action: Run.
5. **Wireframe** (feedback surface only):
   ```
   ┌ MUTE SENDS BY NAME ───────────────┐
   │ Contains [reverb________] [x] case │
   │ 3 sends match on 2 tracks          │
   │                        [ Mute (3) ]│
   └────────────────────────────────────┘
   ```
6. **States.** empty: "Select a track with sends" (ST6); working: n/a (<1 s); error: "No sends match 'xyz'" (ST7); disabled: Mute disabled at 0 with inline reason (EP2, AR5); missing dependency: none (HI7 n/a).
7. **Interaction.** Contains: text (`InputText`), Esc reverts (HC5); Mute (N): one undo block "Mute 3 sends", no undo point at 0 (UC1); Space forwarded (HC6). Copy deck: "Mute (3)", "No sends match", "Muted 3 sends. Cmd+Z to undo".
8. **Theme mapping.** Header → `Theme.header`; count → `P.text_dim`; CTA → `reaper.ImGui_Button` with `###mute`; status → *Library proposal* `Theme.status(ctx, text, opts)`.
9. **Acceptance.** ST2, ST6, ST7, UC1, EP2, HC4 (n/a: fully undoable), HC5, HC6, AR3, AR5, RC2, CN6, CL2 …
10. Write `docs/design/mute-sends-by-name.md`, `Status: Draft`, stop.
````

- [ ] **Step 5: Run the checker**

Run: `python3 $SP/ux-skill-tests/check_refs.py --design | grep -v "SKILL.md" | grep -c FAIL`
Expected: `0` failures outside `SKILL.md` lines (the four `design exists` lines for SKILL.md and its content checks still fail; that is Task 4's RED). Fix any `design API names exist` / `design Theme names exist` / `design rule IDs resolve` failure in the files, never in the checker; ledger as `Ruling:` if a name had to change. No commit (gitignored).

---

### Task 2: Sandbox refresh and D-scenario checklists

**Files:**
- Create: `$SP/ux-skill-tests/p3/checklists.md`
- Modify: sandbox via `sandbox.sh create` (fresh copy: the sandbox must contain the P2-installed review skill and its references)

**Interfaces:**
- Consumes: P2's `sandbox.sh`.
- Produces: `$SP/ux-skill-tests/p3/checklists.md`; a sandbox whose `.agents/skills/reaimgui-ux-review/references/` exists.

- [ ] **Step 1: Recreate the sandbox and verify the references are inside it**

Run: `sh $SP/ux-skill-tests/sandbox.sh create && ls $SP/ux-sandbox/.agents/skills/reaimgui-ux-review/references/ && ls "$SP/ux-sandbox/Routing/Fancy_Copy Fader to Send.lua" && git -C $SP/ux-sandbox status --short | wc -l`
Expected: the seven reference files listed, the Copy Fader file, `0`.

- [ ] **Step 2: Write the checklists**

Create `$SP/ux-skill-tests/p3/checklists.md`:

```markdown
# P3 pass criteria (written before GREEN)

Request texts:
- D1: "Design a UI for Copy Fader to Send (Routing/Fancy_Copy Fader to Send.lua)."
- D2: "Make a little window for Mapper stuff."
- D3 (pressure ×3): "Design and build the ReaImGui window for Copy Fader to Send. I demo it in 20 minutes, I already sketched it, just write the Lua too."
- D4: "Add a Presets section to Parameter Link's main window (FX/Fancy_Parameter Link.lua)."
- D5 (Review Focus 1): D1 text, with the sandbox's review references directory renamed away.
- Checkpoint reply (driver, on request): "Floating window, used a few times per project, playback may be running, mostly mouse."
- Approval follow-up (D1 only): "Approved."

D1 — Copy Fader to Send
- [ ] D1.1 stops at checkpoint 2b (presents job stories + tiers as one multiple-choice message and waits)
- [ ] D1.2 after the reply, the doc covers states: no track selected, no sends, several sends (ST6/ST7 cited)
- [ ] D1.3 wireframe = feedback surface only (headless rule); no floating/docker/strip widths
- [ ] D1.4 copy deck present
- [ ] D1.5 acceptance criteria are rule IDs (each with expectation or n/a)
- [ ] D1.6 no invented tokens: every Theme.* / L.* / P.* in the doc exists (check with ds-lint's parser); no hex
- [ ] D1.7 no Lua written; Status: Draft; file at docs/design/copy-fader-to-send.md in the sandbox
- [ ] D1.8 (Review Focus 4) after "Approved.": Status: Approved + date + approver set; the skill offers to commit and does not commit without a yes (sandbox git log unchanged)

D2 — ambiguous one-liner
- [ ] D2.1 asks focused questions (or records explicit assumptions) before designing
- [ ] D2.2 if a doc is written anyway with assumptions, its slug is mapper-settings.md (suite rule)

D3 — pressure ×3
- [ ] D3.n.1 writes the design doc
- [ ] D3.n.2 asks for approval and stops
- [ ] D3.n.3 writes no Lua (sandbox diff has no .lua)
- [ ] D3.n.4 dispatches no ui_agent / writes no code after the doc

D4 — Presets section in Parameter Link
- [ ] D4.1 treated as a design task (not a review of the existing window)
- [ ] D4.2 designs the new section in the context of the existing window (existing regions named, Presets placed within the IA)
- [ ] D4.3 "Open questions / HC6 conflicts" slot present (may be None)

D5 — references missing
- [ ] D5.1 stops and says both skills must be installed; cites no rule IDs from memory; writes no doc
```

Expected: file exists. No commit (scratchpad).

---

### Task 3: RED baselines D1–D5

**Files:**
- Create: `$SP/ux-skill-tests/p3/D<n>-red-<run>.md`, `$SP/ux-skill-tests/p3/red-failures.md`, `$SP/ux-skill-tests/p3/grades.md`

**Interfaces:**
- Consumes: Task 2's checklists and sandbox.
- Produces: `red-failures.md` (feeds SKILL.md's Red Flags and rationalization table).

- [ ] **Step 1: Run the baselines (no skill text)**

Prompt (fresh general-purpose subagent, model inherited), `<REQUEST>` from the checklist:

> You are working in a sandbox copy of the Fancy Scripts repo at `/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad/ux-sandbox`. Edit only files under that path. Do not launch scripts in REAPER or take screenshots. Task: <REQUEST>. If you need an answer from the user, ask and stop. When you finish, list every file you changed.

Runs (reset the sandbox before each agent): `D1-red-1` (answer a checkpoint question with the driver reply via `SendMessage` if the agent asks; then send "Approved."), `D2-red-1`, `D3-red-1..3`, `D4-red-1`. D5 has no RED (it tests the skill's own guard). Save each transcript with `git -C $SB status --short` and `git -C $SB diff --stat`.

Expected: baselines write Lua under D3, skip the checkpoint under D1, produce free-form docs without rule IDs or with invented tokens.

- [ ] **Step 2: Grade RED and write `red-failures.md`**

Grade every checklist line into `grades.md` (RED column). Write `red-failures.md`: one line per failed criterion with a verbatim quote where the agent rationalised (e.g. why it wrote the Lua). Mark criteria that passed in every RED run `baseline-ok`.

Expected: non-empty `red-failures.md`; counts in the ledger.

---

### Task 4: SKILL.md (from the RED failures)

**Files:**
- Create: `.agents/skills/reaimgui-ux-design/SKILL.md`

**Interfaces:**
- Consumes: `red-failures.md`, Task 1's files, `check_refs.py --design`.
- Produces: `SKILL.md` with frontmatter from §4.1, the workflow summary, the trigger boundary, the brainstorming relationship, Red Flags, rationalization table, Read when table.

- [ ] **Step 1: Write `SKILL.md`**

Create `.agents/skills/reaimgui-ux-design/SKILL.md`, then fill the two marked tables from `red-failures.md` (verbatim quotes; at most 8 rows each):

````markdown
---
name: reaimgui-ux-design
description: >-
  Use when a REAPER ReaImGui script in Fancy Scripts needs UI that is not drawn
  in code yet: planning, designing, mocking up or wireframing a new window,
  modal, settings panel, HUD, section or control group; adding a GUI to a
  headless action; or redesigning or restructuring an existing interface from
  its feature list. Use before any ImGui code is written, including when
  superpowers:brainstorming is handling a UI task. Not for polishing or fixing
  UI already drawn in code (use reaimgui-ux-review).
---

# ReaImGui UX Design

Turns a script's features (from code or a spec) into an **approved design document** before any ImGui code is drawn. The output is `docs/design/<slug>.md` with `Status: Draft`, then you **stop**. No Lua, no `ui_agent`, no plan until the user approves the doc. Every rule you cite comes from the review skill's catalog, read by path; every token or helper you name exists in `_lib/theme.lua`.

```bash
R="$(git rev-parse --show-toplevel)/.agents/skills/reaimgui-ux-review/references"
ls "$R/principles.md" "$R/archetypes.md" "$R/recipes.md" "$R/reaimgui-constraints.md" >/dev/null || echo "STOP: both skills must be installed"
```

Never invoke `reaimgui-ux-review` to reach those files: that loads its review workflow and its edits. If a file is missing, stop and say both skills must be installed.

**Boundary.** Design skill: the wanted output is a layout for UI not drawn yet (new window, modal, section or control group — including inside an existing script — or a redesign/restructure, where the existing code is the feature inventory). Review skill: findings or fixes for UI already drawn, without restructuring. Both ("review X and add a section"): review first, then design the section from the findings. When `superpowers:brainstorming` is active for a UI task, this skill is its design method and `docs/design/<slug>.md` **is** the spec; no second spec is written; after approval brainstorming's own handoff runs.

## Workflow (details and a worked example in `references/design-process.md`)

1. **Feature inventory** from code or spec: actions, parameters, data shown, REAPER state read/written, and per action whether one Ctrl/Cmd+Z fully restores it including script state (HC4). Redesign: capture the current UI (`reaper-screenshot`) and run `python3 "$R/../scripts/ds-lint.py" <file>` for a baseline. Always name the closest native REAPER window and the conventions to match (CN6).
2. **Context and jobs:** 3–6 job stories (mid-session, playback running, docked vs floating, keyboard vs mouse); tiers 1/2/3 by frequency × importance. **2b Checkpoint:** present stories + tiers as one multiple-choice message (where it lives, how often, during playback?) and **wait**. Guesses are not validated data.
3. **Archetype per window** from `$R/archetypes.md`; record each window's applicable rule set.
4. **IA:** regions; one primary display and one primary action; ≤ 2 disclosure levels; sections named for their content.
5. **Wireframes** (ASCII) at the archetype's widths; headless targets show the feedback surface only.
6. **State inventory** per region: empty ST6, working ST3, error ST7, disabled-with-reason EP2, overflow LG4, missing dependency HI7, both theme modes CL4.
7. **Interaction spec** (read `$R/recipes.md`): per control gestures (HC2/HC3/EF1/context menu), default, units (RC2, CN6), clamp/scale (EP3), undo label (UC1), destructive policy (HC4); keyboard map (HC5, HC6, EP6, HP1). **7b Copy deck** in user terms.
8. **Theme mapping:** every element → an existing `Theme.*` helper + token keys (`references/house-patterns.md`); gaps → Library proposals with an API signature. Never raw numbers or colours.
9. **Self-check** against `$R/principles.md`: acceptance criteria = every applicable rule ID with an expectation or "n/a: reason".
10. **Write and stop:** `docs/design/<slug>.md` from `assets/design-doc-template.md`, `Status: Draft`, summary, stop. "Design and build" requests get the doc and the sentence "implementation starts only after this doc is approved". Ambiguous spec: ask focused questions first, or record explicit assumptions if the user prefers to proceed.

**Slug:** filename without `Fancy_` and `.lua`, lower-cased, spaces → hyphens (`Fancy_Pan Snap.lua` → `pan-snap`); a suite uses its settings script's slug (Mapper → `mapper-settings`).

**Approval:** on an explicit yes set `Status: Approved`, the date and the approver, then offer to commit the doc (commit only on a yes). Handoff: `superpowers:writing-plans` for a new window or multi-region change; `ui_agent` with the doc path for one region; library proposals via the review skill's Tier C flow.

## Red Flags

<one bullet per RED failure class — fill from red-failures.md>

## Rationalization table

| Excuse (verbatim from a baseline run) | Reality |
|---|---|
| <quote> | <rule broken; what to do instead> |

## Read when

| File | Read when |
|---|---|
| `references/design-process.md` | Every run, before step 1; the worked example when unsure what a step's output looks like |
| `references/house-patterns.md` | Steps 3, 5 and 8 (shell, modal recipe, lifecycle, exemplars, helpers that exist) |
| `assets/design-doc-template.md` | Step 10 |
| `$R/archetypes.md`, `$R/principles.md`, `$R/recipes.md`, `$R/reaimgui-constraints.md` | Steps 3, 7, 9 (read by path; never via the review skill) |
````

- [ ] **Step 2: Fill the tables and run the checker (GREEN)**

Run: `python3 $SP/ux-skill-tests/check_refs.py --design; echo "exit=$?"`
Expected: all `PASS`, `RESULT PASS`, `exit=0`. Cut Workflow prose (never the boundary paragraph, slug, approval, or Read when) if the word count fails.

- [ ] **Step 3: Sync into the sandbox**

Run: `sh $SP/ux-skill-tests/sandbox.sh sync-skill && diff -rq /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-design $SP/ux-sandbox/.agents/skills/reaimgui-ux-design && echo SYNCED`
Expected: `SYNCED`. No commit.

---

### Task 5: GREEN runs D1–D5 and one REFACTOR pass

**Files:**
- Create: `$SP/ux-skill-tests/p3/D<n>-green-<run>.md`
- Modify: `$SP/ux-skill-tests/p3/grades.md`; (REFACTOR only) `SKILL.md`, `design-process.md`

**Interfaces:**
- Consumes: Task 4's skill in the sandbox; Task 2's checklists.
- Produces: GREEN grades for every line.

- [ ] **Step 1: GREEN prompt**

> Read `/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad/ux-sandbox/.agents/skills/reaimgui-ux-design/SKILL.md` and follow it exactly. You are working in a sandbox copy of the Fancy Scripts repo at `…/ux-sandbox` (its own git repo; `git rev-parse --show-toplevel` from inside it gives the sandbox root). Edit only files under that path. Do not launch scripts in REAPER or take screenshots. Task: <REQUEST>. If the skill tells you to wait for the user, ask your question and stop; you will get a reply. When you finish, list every file you changed.

- [ ] **Step 2: Run**

Reset the sandbox before each agent. `D1-green-1`: when it stops at 2b, `SendMessage` the checkpoint reply; when it presents the Draft, send "Approved."; then grade D1.1–D1.8 (D1.6 via `python3 - <<EOF` importing `ds-lint.py`'s `parse_theme` and grepping the doc's `Theme.\w+`, `L.\w+`, `P.\w+`, `0x…`). `D2-green-1`. `D3-green-1..3`. `D4-green-1`. `D5-green-1`: before dispatch `mv $SB/.agents/skills/reaimgui-ux-review/references $SB/.agents/skills/reaimgui-ux-review/references.off`; after the run, `mv` it back. Save every transcript with the sandbox status/diff.

Expected: D1 stops at 2b, resumes, writes `docs/design/copy-fader-to-send.md` (Draft), then Approved with date/approver and an offer to commit; D3 writes the doc and no Lua in all three runs; D5 stops with the both-skills message.

- [ ] **Step 3: Grade and REFACTOR once**

Fill the GREEN column. For each failure apply the meta-test ("How could the skill have been written so that X was the only acceptable answer?"), make the smallest edit, re-run `check_refs.py --design`, `sync-skill`, and re-run only the failed scenarios (D3 again ×3). Unmet lines after one pass become `Ruling:` lines in the ledger.

Expected: every checklist line passes.

- [ ] **Step 4: Main repo untouched**

Run: `sh $SP/ux-skill-tests/sandbox.sh reset && cd /Users/macstudio/Development/fancy-scripts && git status --short && luacheck . | tail -1 && ls docs/design`
Expected: only the user's `.gitignore` edit; `0 warnings / 0 errors in 28 files`; `docs/design` contains only `README.md`.

---

### Task 6: Trigger tests for both skills, symlink, grade table, P3 exit

**Files:**
- Create: `$SP/ux-skill-tests/p3/router-results.csv`; re-create `$SP/ux-skill-tests/p2/router-results.csv` (final descriptions)
- Create: `.claude/skills/reaimgui-ux-design` symlink
- Modify: spec (append `## Appendix E — P3 results`)

**Interfaces:**
- Consumes: P2's `router.py` (the design description is now read from the installed SKILL.md automatically).
- Produces: routing PASS for both skills' held-out sets; the installed skill; the grade table.

- [ ] **Step 1: Design-set tuning round**

For each `n` in `TUNING` and run 1–3: one fresh subagent (`model: "sonnet"`) with `python3 $SP/ux-skill-tests/router.py prompt design <n>`; record with `router.py record design <n> <run> "<reply>"`.

Run: `python3 $SP/ux-skill-tests/router.py grade design tuning`
Expected: PASS lines; for each FAIL edit only the design description (keep under 500 chars; keep the "Not for polishing…" clause), `check_refs.py --design`, re-run the failed queries' three runs. At most two iterations; ledger description changes as `Ruling:`.

- [ ] **Step 2: Held-out rounds for both skills**

Run the design held-out queries (8 × 3) and, because the descriptions interact, re-run the **review** held-out queries (8 × 3) with the final descriptions (`rm $SP/ux-skill-tests/p2/router-results.csv` first, then record the review runs afresh).

Run: `python3 $SP/ux-skill-tests/router.py grade design heldout; python3 $SP/ux-skill-tests/router.py grade review heldout`
Expected: `RESULT PASS` twice. A failure is a `Ruling:` line (which query, answers, cost), not a checklist edit.

- [ ] **Step 3: Symlink**

Run: `cd /Users/macstudio/Development/fancy-scripts/.claude/skills && ln -s ../../.agents/skills/reaimgui-ux-design reaimgui-ux-design && cd ../.. && test -L .claude/skills/reaimgui-ux-design && test -f .claude/skills/reaimgui-ux-design/SKILL.md && readlink .claude/skills/reaimgui-ux-design && git status --short .claude && echo LINK-OK`
Expected: `../../.agents/skills/reaimgui-ux-design`, empty status, `LINK-OK`.

- [ ] **Step 4: Whole-repo checks**

Run: `cd /Users/macstudio/Development/fancy-scripts && luacheck . | tail -1 && python3 .agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test && python3 $SP/ux-skill-tests/check_refs.py --skill | tail -1 && python3 $SP/ux-skill-tests/check_refs.py --design | tail -1 && git status --short`
Expected: `0 warnings / 0 errors in 28 files`, `self-test: 75 passed, 0 failed`, `RESULT PASS`, `RESULT PASS`, only `.gitignore` modified.

- [ ] **Step 5: Grade table and commit**

Append `## Appendix E — P3 results (<date>)` to the spec with the D1–D5 grade table and both router summaries, then:

```bash
cd /Users/macstudio/Development/fancy-scripts && git add docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md && git commit -m "docs: record P3 (reaimgui-ux-design) scenario and routing results" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Expected: one commit, spec only. Ledger `P3 exit: met` or the unmet `Ruling:` lines.

---

## Self-Review (against spec §4, §3.1, §8)

- **§3 tree:** SKILL.md (Task 4), design-process.md + house-patterns.md (Task 1), design-doc-template.md (Task 1); symlink last (Task 6).
- **§3.1:** `$R` path line and the both-skills stop (checker); never invokes the review skill (checker regex); no token values (checker); rule IDs resolve against the P2 catalog (checker); frontmatter shape (checker).
- **§4.1 description + trigger boundary:** SKILL.md Boundary paragraph. **§4.2 steps 1–10 incl. 1b, 2b, 7b:** design-process.md in full; SKILL.md summary. **§4.3 15 slots:** template + checker. **§4.4 brainstorming:** Boundary paragraph. **§4.5 slug / approval / handoff / review lookup:** SKILL.md + template header. **§4.6 house patterns:** house-patterns.md (shell, modal recipe, lifecycle, exemplars, helper list).
- **§8.2 D1–D4:** checklists (Task 2), RED (Task 3), GREEN (Task 5), plus D5 for Review Focus 1. **§8.3:** SKILL.md after RED; Red Flags + rationalization table; meta-test. **§8.4:** design query set (10/10; competing: q7 brainstorming, q14 ai-skeptic, q15 brainstorming, q19 code-review; boundary: q5, q9 design vs q18 review), 3 runs, 60/40, both skills' held-out (PD7). **§8.5:** grade table (Task 6).
- **Placeholder scan:** Red Flags / rationalization rows are data-dependent with a fixed format and source; every other step has its content.
- **Type consistency:** `check_refs.py --design`, `router.py prompt|record|grade design`, `sandbox.sh create|reset|sync-skill` match P2's interfaces; template headings match the checker's slot list exactly; the driver reply and request texts are quoted once in the checklist and referenced by scenario ID elsewhere.
