# ReaImGui UX Skills — Design Spec

- **Date:** 2026-09-28
- **Status:** Draft, awaiting user review
- **Revision:** 2. Incorporates a 4-lens adversarial review (facts/API, consistency, skill-authoring, UX soundness; 80 findings) and two re-confirmed decisions (D2, D7).
- **Scope:** Two agent skills for Fancy Scripts that apply traditional UX/UI design principles to REAPER scripts built with Lua 5.4 + ReaImGui 0.10 (verified against 0.10.0.5 / Dear ImGui 1.92.1) on the `_lib/theme.lua` design system.

---

## 1. Goal

1. **`reaimgui-ux-design`.** Turns a script's features (from code or a spec) into an approved UI design document **before** the UI is drawn in code.
2. **`reaimgui-ux-review`.** Reviews UI that is **already drawn** against a shared rule catalog (UX principles, REAPER host conventions, ReaImGui constraints, the design system), produces prioritized findings, and applies fixes in approval tiers.

Success means:
- Both skills trigger on the right requests and not on each other's (or on `superpowers:brainstorming`'s, `ai-skeptic-reviewer`'s or `code-review`'s).
- Every finding cites a rule ID plus measurable evidence, not taste.
- The skills never invent tokens, rule IDs or APIs.
- Fixes preserve all repo conventions (ReaPack headers, luacheck, semver + CHANGELOG, no `index.xml` edits) and never mix with the user's uncommitted work without asking.

---

## 2. Decisions

### 2.1 Decided with the user

| # | Topic | Decision |
|---|---|---|
| D1 | Design skill output | **Design doc only.** It writes `docs/design/<slug>.md` (tracked) and stops for approval. No code. Implementation is a separate, explicit handoff (§4.5). |
| D2 | Review fix autonomy | **Tiered, conditional on the request.** The report always comes first. Tier A (mechanical) is applied immediately **only if the request asks for changes** (fix, polish, clean up, tidy, apply). For review/audit/critique/check requests, Tier A is presented as "ready to apply" and applied on the user's first yes. Tier B (UX-level) is applied only for findings the user selects. Tier C (library/token changes) needs its own approval. See §5.4. |
| D3 | Visual verification | **Code + screenshots.** When REAPER is running, launch the script and capture it with `reaper-screenshot`. Otherwise fall back to code-only, and mark screenshot-dependent rules as *not verified*. |
| D4 | Library gaps | **Propose `theme.lua` additions** in a separate "Library proposals" section. They are applied only after their own approval. Then the Design System showcase is updated, the reviewed script is migrated, and other scripts are listed for migration. |
| D5 | Execution model | **Hybrid.** Scripts with **fewer than 1,500 UI-bearing lines** (as counted by `ds-lint.py --ui-lines`) are reviewed inline. At or above that, the review fans out to 3 read-only lens reviewers, then merges. Approved fix batches are applied sequentially via `ui_agent`, or inline if subagents are unavailable. |
| D6 | Contrast policy | **Text AA blocking.** Codified as house convention **HC1** (§2.3). |
| D7 | Fine adjust | **Ctrl/Cmd-drag** (REAPER-native), on value controls only. Codified as **HC2**. *Re-confirmed after review: REAPER uses Shift for "this track only" and Alt for elastic audition.* |
| D8 | Reset / type value | **Double-click resets; Ctrl/Cmd-click without dragging types a value.** Codified as **HC3**. |
| D9 | Destructive actions | **By reversibility.** Codified as **HC4**, with a precise test for what counts as reversible. |
| D10 | Architecture | **Two skills, one catalog owned by the review skill, plus a lint script** (§3). |
| D11 | Design doc location | `docs/design/` (tracked). |

### 2.2 Defaults adopted without asking (override during spec review)

| # | Topic | Default |
|---|---|---|
| D12 | Esc | Innermost first; closes the window only when floating. Codified as **HC5**. |
| D13 | Space | Forwarded to the user's own REAPER binding while the script has focus. Codified as **HC6**. |
| D14 | Severity | Nielsen-based, 1–4 (§5.5). A severity-0 "finding" is dropped. |
| D15 | Match Theme | Verified against the user's current REAPER theme only. The skills never switch the REAPER theme. Hardcoded colours are flagged statically. |
| D16 | Legacy scripts | A script that defines its own palette or font table (today: Selected Track Meter) is marked **legacy**. No hex or token replacement is applied to it in any tier outside a separately approved **migration phase**. The review offers that phase and never bundles it. |
| D17 | Housekeeping | Doc/help drift, CHANGELOG claims not in code, `theme.lua` internal drift and pre-existing luacheck warnings are reported, not fixed. |
| D18 | Version control | The skills stay local-only, like the existing ones (`.agents/` is gitignored). `.claude/skills/` and `.claude/agents/` are added to `.gitignore` so their symlinks into the ignored tree are never committed (§7). `docs/design/` and this spec **are** tracked. |

### 2.3 House conventions (HC1–HC6)

These are project coding conventions, not only review rules. Their canonical one-line text therefore goes in **`AGENTS.md`** under "UI / UX Architecture", which every agent (including `ui_agent` and lens subagents) loads automatically. Rule rows cite them as `HCn`. Implementation recipes live in the review skill's `references/recipes.md` (§3).

| ID | Convention |
|---|---|
| HC1 | **Contrast.** WCAG 2.x ratios are measured after compositing alpha in sRGB over the real surface: `bg` for windows; `panel` for popups, modals and tooltips; `card` inside frames.<br>**Text:** under 3:1 = severity 4; 3–4.49:1 = severity 3.<br>**State indicators** (check mark, slider grab, active toggle/badge fill vs surround, meter fill vs track) and **input boundaries** (FrameBg, plus border when drawn, vs parent surface): under 3:1 = severity 3. Other non-text is severity 2 at most.<br>**Exempt:** controls inside `BeginDisabled`, pure separators, `brand_icon`.<br>**Library defaults:** pairs produced by `Theme.push` or by Theme helpers with default options are reported **once per review**, as a Tier C item with the ratio table, never per call site.<br>**Match Theme:** failures of REAPER-derived pairs are severity 2, plus the Tier C `readable_on` proposal. |
| HC2 | **Fine adjust.** Applies to parameter value controls only; canvas objects keep editor gestures.<br>Ctrl-drag (Windows/Linux) or Cmd-drag (macOS), tested via ImGui `Mod_Ctrl`, gives fine adjust, and so does Ctrl/Cmd+wheel. Shift and Alt are not repurposed (REAPER: Shift = this track only, Alt = elastic audition).<br>Slider widgets cannot fine-adjust, so any control that needs HC2 uses Drag widgets or a custom control. Drag widgets pass `SliderFlags_NoInput` and `SliderFlags_NoSpeedTweaks`: stock Drag widgets enter text input on Ctrl-click press and on double-click and use Shift/Alt as speed modifiers (HC3's text entry is then a custom Ctrl/Cmd-click-release popup; recipe in `references/recipes.md`). |
| HC3 | **Reset / type.** Applies to parameter value controls only.<br>Double-click resets to the script's `DEFAULTS` value as one undo point. Ctrl/Cmd-click released within the drag threshold opens text entry, and Ctrl/Cmd-drag is HC2.<br>Right-click opens the context menu. On macOS a physical Ctrl-click is a right-click. |
| HC4 | **Destructive actions.** No confirm is needed only when **one Ctrl/Cmd+Z restores everything the user can see**. That requires all three of:<br>(a) all writes go to project objects inside a single `Undo_BeginBlock`/`Undo_EndBlock`;<br>(b) the script rebuilds its in-memory model when `GetProjectStateChangeCount` changes;<br>(c) no ExtState, JSON, file, cache or analysis result is changed or discarded.<br>P_EXT written inside the block counts as undoable (to be verified live).<br>Anything else gets a confirm modal. It names the consequence and count, puts Cancel first, and treats Esc as Cancel.<br>Undoable destructive actions still post a status message ("Removed 3 links. Ctrl/Cmd+Z to undo").<br>All destructive controls get danger styling and sit apart from frequent controls. |
| HC5 | **Esc.** Handled innermost first: modal → active edit (revert) → selection → window. Handled only through `Shortcut()` routing, never bare `IsKeyPressed(Key_Escape)`.<br>Closes the window only when it is floating. `Theme.header`'s close tooltip says "(Esc)" only then. |
| HC6 | **Space.** Applies while the script window is focused, no text or key-capture field is active, and no modal is open.<br>Space, and each modifier chord of Space, is forwarded to the command the user bound in REAPER's Main section (read once from `reaper-kb.ini`; fallback 40044). Detected with `Shortcut()` without repeat.<br>A script may give Space its own meaning only if its design doc records the conflict and the user approved it. |

---

## 3. Architecture

```
.agents/skills/                                   source of truth (gitignored, local)
├── reaimgui-ux-review/                           OWNS the catalog
│   ├── SKILL.md                                  ≤1,000 words (target ~500); ends with a "Read when" table
│   ├── references/
│   │   ├── principles.md                         rule catalog (Appendix A): one row per rule ID, grep-able; Contents list
│   │   ├── archetypes.md                         per-archetype applicable rules + AR rules (Appendix C)
│   │   ├── reaimgui-constraints.md               RB rules (Appendix B), with the ReaImGui version verified against
│   │   ├── recipes.md                            HOW to implement HC2–HC6, tooltips on disabled items, wheel, danger styling
│   │   ├── violation-catalog.md                  before/after Lua using real Theme helpers (only for rules RED showed were missed)
│   │   ├── visual-loop.md                        REQUIRED SUB-SKILL: reaper-screenshot; launch → capture → Read (§5.3)
│   │   └── lens-prompt.md                        template for lens subagents (§5.2 step 5)
│   ├── assets/review-report-template.md          §5.5
│   └── scripts/
│       ├── ds-lint.py                            §6 (Python 3 stdlib)
│       └── reaimgui_api_names.txt                valid reaper.ImGui_* names + ReaImGui version header (regenerable)
└── reaimgui-ux-design/
    ├── SKILL.md                                  ≤1,000 words (target ~500); ends with a "Read when" table
    ├── references/
    │   ├── design-process.md                     §4.2 in full, with one worked mini-example
    │   └── house-patterns.md                     shell, modal recipe, lifecycle, exemplars (§4.6)
    └── assets/design-doc-template.md             §4.3

.claude/skills/reaimgui-ux-{review,design} → ../../.agents/skills/…   relative symlinks, created at the END of each skill's phase (§8)
docs/design/README.md + <slug>.md                                    tracked
AGENTS.md                                                            HC1–HC6 + routing text (§7)
```

### 3.1 Ownership rules

- **`theme.lua` is the only source of token values.**
  - Skill text never copies token numbers or palette hex values. `ui_agent.md` shows how quickly copies drift.
  - Skills refer to `theme.lua` by section name, not by line number.
  - `ds-lint.py` extracts real values at run time.
- **Rule IDs are owned by the review skill.**
  - IDs are stable: ST/UC/EP/CN/RC/EF/IA/LG/MT/CL/DV/HI/HP (Appendix A), RB (Appendix B), AR (Appendix C) and HC (AGENTS.md).
  - Findings and design docs cite rules as `<ID> <rule name>`.
- **The design skill reads the review skill's references directly.**
  - It locates them at `R="$(git rev-parse --show-toplevel)/.agents/skills/reaimgui-ux-review/references"`, the same way `reaper-screenshot` locates `capture.sh`.
  - It **never invokes** the review skill for them, because that would load the review workflow and its edits.
  - If a file is missing, it stops and says both skills must be installed. It never cites rule IDs from memory.
- **Frontmatter is only `name` + `description`,** in the house `>-` folded style. This keeps the skills portable to Antigravity.
- **Helper scripts are Python 3 stdlib only, never Lua.**
  - `.luacheckrc` has no exclude list, so `luacheck .` would lint any `.lua` file under `.agents/`.
  - Test fixtures are embedded in `ds-lint.py`.
- **Tool names are fully qualified.**
  - `reaper-mcp:run_action_by_name` (Claude Code: `mcp__reaper-mcp__run_action_by_name`).
  - `reaper-dev:get_function_info` (`mcp__reaper-dev__get_function_info`).
  - `capture.sh` is always invoked as `"$(git rev-parse --show-toplevel)/.agents/skills/reaper-screenshot/scripts/capture.sh"`.
- **Files are navigable.** Each SKILL.md ends with a "Read when" table mapping every reference and asset to the workflow step that needs it. Each reference file over 100 lines starts with a Contents list.

### 3.2 Relationship to existing agents and skills

| Concern | design skill | review skill | `ui_agent` | `qa_agent` | `reaper-screenshot` | `ai-skeptic-reviewer` | `superpowers:brainstorming` |
|---|---|---|---|---|---|---|---|
| Intent discovery, path classification | used by brainstorming | – | – | – | – | – | owns |
| Tasks, IA, flows, states, keyboard map, copy | owns | audits | – | – | baseline capture | – | delegates UI design to design skill |
| Token/widget compliance | maps to Theme | checks | implements approved batches | – | – | flags only violations introduced by a diff | – |
| Visual check | baseline (redesigns) | owns | – | – | provides captures | – | – |
| Live focus/Esc/Space/undo behaviour | – | requests | – | verifies | – | – | – |
| General Lua correctness, API misuse | – | defers | – | owns (API/undo) | – | owns | – |

**Subagent fallback.** Subagents cannot always dispatch further subagents, and Antigravity's model differs. Wherever the skills say "dispatch", they also define the inline fallback: run the lenses sequentially in the main context, and apply batches directly.

### 3.3 Delivery phases

Each phase gets its own implementation plan and must pass before the next starts.

| Phase | Deliverables | Exit criteria |
|---|---|---|
| **P1** | §7 prerequisites; `ds-lint.py` + `reaimgui_api_names.txt` | `--self-test` green; R4 passes; `--ui-lines` and `--contrast` produce the numbers in §8 |
| **P2** | `reaimgui-ux-review` (references, template, SKILL.md) | RED→GREEN→REFACTOR on R1–R9; review trigger tests pass; symlink created |
| **P3** | `reaimgui-ux-design` | RED→GREEN→REFACTOR on D1–D4; design trigger tests pass; symlink created |

---

## 4. `reaimgui-ux-design`

### 4.1 Frontmatter

Descriptions state only *when* to use a skill, never the workflow. Summarising the workflow invites agents to follow the description instead of the body. The house skills open with a verb ("Reviews…", "Captures…"); this departure is deliberate. Target length is under 500 characters.

```yaml
name: reaimgui-ux-design
description: >-
  Use when a REAPER ReaImGui script in Fancy Scripts needs UI that is not drawn
  in code yet: planning, designing, mocking up or wireframing a new window,
  modal, settings panel, HUD, section or control group; adding a GUI to a
  headless action; or redesigning or restructuring an existing interface from
  its feature list. Use before any ImGui code is written, including when
  superpowers:brainstorming is handling a UI task. Not for polishing or fixing
  UI already drawn in code (use reaimgui-ux-review).
```

**Trigger boundary (observable):**
- **Design skill:** the wanted output is a layout for UI that is not drawn yet. That covers a new window, modal, section or control group (including one inside an existing script), or a redesign or restructure of an existing window, in which case the existing code becomes the feature inventory.
- **Review skill:** the wanted output is findings or fixes for UI that is already drawn, without restructuring it.
- **Both** (e.g. "review Pan Snap and add a presets section"): run the review first, then design the new section using the review's findings as input.

### 4.2 Workflow (SKILL.md summarises; `design-process.md` details)

1. **Feature inventory.** From the code or spec, list:
   - every user action and parameter;
   - the data displayed;
   - the REAPER state read and written;
   - for each action, **whether one Ctrl/Cmd+Z fully restores it, including script state** (HC4).

   **1b. References.**
   - For a redesign: capture the current UI (REQUIRED SUB-SKILL: `reaper-screenshot`) and run `python3 "$R/../scripts/ds-lint.py"` for a baseline.
   - Always: name the closest native REAPER window(s) and list the conventions to match (CN6).
2. **Context and jobs.**
   - Write 3–6 job stories ("When … I want to … so I can …") covering:
     - mid-session use;
     - playback running;
     - docked vs floating;
     - keyboard vs mouse.
   - Draft a frequency × importance ranking of features into Tier 1 (always visible), Tier 2 (one disclosure away) and Tier 3 (Settings).

   **2b. Checkpoint.**
   - Present the job stories and tier ranking to the user as one multiple-choice message: where it lives, how often, during playback?
   - Wait for confirmation before IA. The agent's guesses are not validated data.
3. **Archetype per window.**
   - Read `$R/archetypes.md`.
   - Choose one archetype per top-level window or modal family (a script may have several).
   - Record each archetype's applicable rule set.
4. **Information architecture.**
   - Define regions.
   - Choose one primary display and one primary action.
   - Allow at most 2 disclosure levels (IA2).
   - Name sections so they predict their content.
5. **Wireframes.** ASCII, at the widths the archetype supports:
   - **Window / settings hub / editor / instrument:** default floating size, narrow docker (~260 px), and a wide short strip (e.g. 1200×150).
   - **Overlay / HUD:** its anchored size, plus a viewport-edge clamp case.
   - **Headless:** its feedback surface only.

   Show what truncates, wraps or hides at each width.
6. **State inventory.** For every region, list what the user sees in each state, each mapped to a rule ID:
   - empty (ST6);
   - working (ST3);
   - error (ST7);
   - disabled-with-reason (EP2);
   - overflow / long names (LG4);
   - missing dependency (HI7);
   - both theme modes (CL4).
7. **Interaction spec.**
   - Read `$R/recipes.md`.
   - Build a table per control:
     - gestures (HC2, HC3, wheel per EF1, context menu);
     - default value;
     - units, format and precision (RC2, CN6);
     - clamp and scale (EP3);
     - undo label (UC1);
     - destructive policy (HC4).
   - Add a keyboard map: HC5 Esc ownership, HC6 Space, modifier guards, no key-repeat on toggles (EP6), all listed in the Info modal (HP1).

   **7b. Copy deck.** Every user-visible string, in user terms: labels, tooltips, empty/error/confirm text, status messages, undo labels.
8. **Theme mapping.**
   - A table mapping every element to an existing `Theme.*` helper and token names.
   - Anything without a helper goes to **Library proposals**, with a proposed API signature.
   - Never invent inline; never use raw numbers or colours.
9. **Self-check.**
   - Read `$R/principles.md`.
   - Walk every rule in each window's applicable set.
   - **Acceptance criteria** = every applicable rule ID, each with a one-line expectation or "n/a: <reason>".
10. **Write and stop.**
    - Write `docs/design/<slug>.md` from the template with `Status: Draft`, present a summary, and **stop**.
    - If the request also asked for code ("design and build", "then implement"), say that implementation starts only after the doc is approved, and stop. Only approval of this doc unlocks code.
    - Ambiguous spec: ask focused questions first. If the user prefers to proceed, record explicit assumptions.

### 4.3 Design doc template (`assets/design-doc-template.md`, required slots)

1. Header:
   - `Target file(s):` (repo-relative; used by the review skill to find the doc);
   - archetype per window;
   - `Status: Draft | Approved`;
   - date;
   - approver.
2. Summary (≤5 sentences).
3. Feature inventory: feature · REAPER state touched · persistence · fully restored by one Ctrl/Cmd+Z incl. script state (Y/N).
4. References: native REAPER analogues; baseline capture path and ds-lint summary for redesigns.
5. Context and job stories (as confirmed at 2b).
6. Priority tiers.
7. Information architecture.
8. Wireframes (per §4.2 step 5).
9. State inventory: region × state → what the user sees → rule ID.
10. Interaction spec table + keyboard map.
11. Copy deck.
12. Theme mapping table.
13. Library proposals (may be "None").
14. Acceptance criteria (rule IDs).
15. Open questions / assumptions; HC6 conflicts, if any.

### 4.4 Relationship to `superpowers:brainstorming`

When brainstorming is active for a ReaImGui UI task:
- Brainstorming keeps intent discovery and path classification, and uses this skill as its design method.
- `docs/design/<slug>.md` **is** the brainstorming spec (brainstorming honours a user's preferred spec location), so no second spec is written.
- After approval, brainstorming's own handoff runs.

The `AGENTS.md` routing text (§7) states this so it is in context before skills are chosen.

### 4.5 Doc lifecycle and handoff

- **Slug.** The script filename without `Fancy_` and `.lua`, lower-cased, with spaces as hyphens (`Fancy_Pan Snap.lua` → `pan-snap`). A multi-script suite uses its settings script's slug (Mapper → `mapper-settings`).
- **Approval.** When the user approves in chat, the design skill sets `Status: Approved`, the date and the approver, then offers to commit the doc. It commits only on a yes.
- **Handoff.** Implementation goes to `superpowers:writing-plans` (a new window, or a change spanning several regions) or to `ui_agent` with the doc path (a change to one region). Library proposals follow the Tier C flow (§5.2 step 10).
- **Review lookup.** The review skill finds a doc by grepping `docs/design/*.md` for the target's `Target file(s):` line. It uses the doc only when it is `Approved`; otherwise it notes "draft design doc ignored".

### 4.6 House patterns (`references/house-patterns.md`)

- **Shell:**
  - `Theme.header` with an ALL-CAPS title, plus `right_widgets`.
  - Current exemplars use text buttons "Info" and "Settings" (Parameter Link, Pan Snap), or one gear `Theme.icon_btn` opening a popover (Mapper Settings).
  - The Info modal is a tab bar ending in "About"; tab names vary.
  - Settings contain `Theme.settings_widget` and `Theme.tooltip_setting_widget`.
  - `Theme.section_divider` separates sections.
  - Pass `close_tooltip` per HC5.
- **Modal recipe:** pending flag → `OpenPopup` once → `Theme.center_next_window(ctx, L.modal_*.w, L.modal_*.h)` (Appearing) → `Theme.modal_scrim` → `BeginPopupModal` → Esc per HC5 → `EndPopup`. All of this is inside the window's `if visible` block.
- **Window lifecycle (RB1):**
  - `local visible, open = reaper.ImGui_Begin(...)`, then `if visible then … reaper.ImGui_End(ctx) end`. ReaImGui's `Begin`/`BeginChild` call End themselves when they return false.
  - Theme and font push/pop stay balanced outside that block, using `local pushed = Theme.push_font(ctx, font)` … `Theme.pop_font(ctx, pushed)`.
- **Exemplars.** Cite these for structure, not token compliance: they still use raw modal sizes, and Parameter Link's CTA lacks `###`.
  - **Mapper Settings:**
    - `DEFAULTS` table as the single source of truth, and a `UI` table derived from `L.*`;
    - form-row helpers;
    - mode-keyed panel dispatch;
    - inline disabled reason;
    - a reset confirm that states the consequence, puts Cancel first and closes on Esc;
    - a count-bearing primary "Apply (N)" (calibrate dialog);
    - modals via a pending-popup queue inside `if visible`.
  - **Parameter Link:**
    - empty-state text names the next step;
    - the CTA previews its consequence ("Add N Links across M Tracks") and is disabled at 0;
    - paused rows are dimmed.
  - **Pitch Correct:** live preview with commit on release and a descriptive undo label.
  - **Pan Snap:** the feedforward overlay never steals focus (`NoInputs`, `NoFocusOnAppearing`, `NoSavedSettings`).

---

## 5. `reaimgui-ux-review`

### 5.1 Frontmatter

```yaml
name: reaimgui-ux-review
description: >-
  Use when an existing REAPER ReaImGui window, modal, panel or overlay in Fancy
  Scripts needs a UX or visual review, audit, critique, polish or cleanup; when
  the UI looks off, cluttered, misaligned, clipped, low-contrast, confusing or
  inconsistent; when checking or migrating a script to _lib/theme.lua
  design-system tokens; or when verifying a built UI against its docs/design
  spec. Not for Lua correctness or API bugs (ai-skeptic-reviewer, code-review),
  or for UI not yet in code or being restructured (reaimgui-ux-design).
```

### 5.2 Workflow

0. **Pre-flight.**
   - Run `git status --porcelain -- <target> _lib/`. If the target is dirty, tell the user and ask whether to proceed.
   - Record the luacheck baseline for the target: `luacheck --formatter plain <file>`, saved to the scratchpad.
   - Record the installed ReaImGui version (§10). If it differs from the one `reaimgui_api_names.txt` was verified against, warn in the report header.
1. **Scope.**
   - Identify the script and the windows and modals in scope.
   - Find an **Approved** design doc via its `Target file(s):` line (§4.5). If one exists, the report includes design conformance.
   - Determine the **request mode**: *change* (fix, polish, clean up, tidy, apply) or *review-only* (review, audit, critique, check). This decides step 8.
2. **Mechanical pass.** Run `python3 <skill>/scripts/ds-lint.py <file>`. It covers the probes in §6; other rules are checked by reading code.
3. **Map the UI.**
   - Classify **each top-level window and modal family** by archetype, since a script may have several.
   - List draw functions, modals and the frame loop with line ranges.
   - Get the UI-bearing line count from `ds-lint.py --ui-lines <file>`. Use that number, never an estimate.
4. **Visual pass** (§5.3). This runs before any fan-out, so every lens receives the capture paths.
5. **Size gate (D5).**
   - **Under 1,500 UI-bearing lines:** review inline against each window's applicable rules.
   - **1,500 or more:** dispatch 3 read-only lens subagents in parallel, each with the filled `references/lens-prompt.md`. It contains:
     - target path and region map;
     - archetypes;
     - absolute paths to `principles.md`, `archetypes.md`, `reaimgui-constraints.md` and `recipes.md`;
     - the lens's rule IDs;
     - **only the ds-lint rows for its own rules**;
     - capture paths;
     - the findings-row format (§5.5 #3);
     - this sentence verbatim: *"You are one lens inside an active reaimgui-ux-review run. Do not invoke any skill, including reaimgui-ux-review, reaimgui-ux-design and superpowers:brainstorming. Use only Read, Grep, Glob and ds-lint.py. Do not edit any file. Return report rows only."*
   - Lens rule assignments:

     | Lens | Rules |
     |---|---|
     | **1** Heuristics, Norman, Gestalt | ST*, EP1, EP2, EP5, RC*, IA*, HP1, LG1, CN4, CN5, AR* |
     | **2** DAW conventions and host behaviour | UC*, EP3, EP4, EP6, EF*, HI*, DV1, CN6, HC2–HC6, RB1, RB5–RB8, RB12–RB14, RB17 |
     | **3** Visual and design system | CN1–CN3, LG2–LG4, MT*, CL*, HC1, RB2–RB4, RB9–RB11, RB15, RB16, RB18, RB19 |

   - Fallback: without subagents, run the three lenses sequentially inline.
   - The main agent then merges: dedupe by (rule ID, location), keep the highest severity with its rationale, and drop anything failing the evidence rule (§5.5).
6. **Report.** Fill `assets/review-report-template.md` (§5.5) and present it.
7. **Batch mechanics** (apply to every batch in steps 8–10).
   - **Before:** copy each file the batch may touch to the scratchpad as `<name>.pre-batchN`.
   - **Apply:** via `ui_agent`, or inline as the fallback. Every `ui_agent` prompt begins: *"This batch was approved in a reaimgui-ux-review session (<Tier A auto-applied per request mode | Tier B selected by the user | Tier C approved>). Apply exactly the listed findings. Do not invoke skills. Do not change anything outside the list."*
   - **After:**
     - `luacheck <touched files>` shows no warnings beyond the baseline;
     - `ds-lint` on the touched files shows the targeted findings gone and nothing new;
     - `git diff --stat` shows only the expected files.
   - **On failure:** restore that batch's files from the `.pre-batchN` copies, mark the batch "reverted" in the report, and continue. Never run `git checkout` or `git stash` on the user's files.
8. **Tier A.**
   - *Change* mode: apply all Tier A findings as batch 1 immediately after the report.
   - *Review-only* mode: present batch 1 as "ready to apply" and apply it on the user's first yes.
   - Under "just fix it, skip the report" pressure, the report is still produced first.
9. **Tier B.** Present Tier B grouped into proposed batches by region. Apply only the batches the user selects.
10. **Tier C** (its own decision). If approved:
    - add the component or token to `theme.lua`;
    - add it to `Utility/Fancy_Design System.lua`;
    - migrate the reviewed script;
    - run `ds-lint` and `luacheck` on every file containing `require("theme")` and list new findings;
    - a token-value change also needs a before/after capture of at least one other consumer script;
    - list other scripts to migrate under Housekeeping.
11. **Close out.** Once per touched file, after the last batch applied in this conversation, including when the user declines all Tier B and Tier C:
    - bump `@version` once to the highest applicable level: **patch** if every applied fix is Tier A or cosmetic; **minor** if any applied Tier B or C fix changes layout, interaction or key handling;
    - replace the header's `@changelog` lines with this version's changes; all other header lines stay byte-identical;
    - add one bullet per touched file under `## [Unreleased]` in `CHANGELOG.md`;
    - never touch `index.xml` or `.github/workflows/`.

    A later conversation that applies more batches closes out again.
12. **Verify.**
    - Restart the script before the "after" capture (`capture.sh --relaunch "<file stem>"`, or ask the user). A capture of an instance started before the edits is invalid.
    - Hand `qa_agent` a checklist when any changed finding is an L rule (UC2, EF2, EF3, CN6, LG4, HI3, HC5, HC6) or changes an undo label or undo block (UC1, UC3).

### 5.3 Visual loop (`references/visual-loop.md`)

**REQUIRED SUB-SKILL:** `reaper-screenshot` (flags and pitfalls).

1. **Is REAPER running?** Run `"$CAP" --list`.
   - If not, go code-only. Rules whose Check includes C are still checked from code and marked "code-only". The S part, and rules with no C check (LG4), are listed under *Not verified*.
2. **Is the script already running?** Launching a running defer script again toggles it off or shows REAPER's task-control prompt. If its window is listed, capture it directly.
3. **Launch.**
   - In `~/Library/Application Support/REAPER/reaper-kb.ini`, find the `SCR` line whose path is the **repo (dev) path**.
   - Take its third field (`RS…`), prefix `_`, and call `reaper-mcp:run_action_by_name` with `_RS…`.
   - **Trap:** some scripts are also registered from the ReaPack install path. That copy runs stale code.
   - Fallback: `"$CAP" --relaunch "<file stem>"`. It needs Accessibility permission, and the script must be listed in REAPER's Actions menu. Otherwise ask the user to open the script.
4. **Capture.**
   - Floating windows: `"$CAP" "<window title>"`.
   - Docked windows: `"$CAP" --dock --dock-height N`. Size N from one `--main` capture first.
   - **Traps:**
     - a title match grabs the main REAPER window when the project name contains the script name;
     - `NoTitleBar` windows may have no OS title.
   - `Read` the `PATH=` file.
5. **Limits.**
   - Only **default states** can be captured automatically; there is no mouse or keyboard injection.
   - Hover states, open modals, drags, and empty or error states need the user to set them up, or are marked *not verified*.
   - A script-side debug hook for capturing those states is out of scope.
6. **Permissions.** Screen Recording is required. `reaper-mcp` calls may prompt, since no allowlist exists. Whether to add one is the user's decision and outside this work.

### 5.4 Fix tiers

**Tier A: mechanical and unambiguous.** A fix qualifies only if applying it needs no judgement about design intent and it cannot change how the script renders under Match Theme. Some Tier A fixes change behaviour deliberately (e.g. no key-repeat), and the report says so.

| Pattern | Fix | Condition |
|---|---|---|
| `reaper.ImGui_AlignTextToFramePadding(ctx)` | `Theme.align(ctx)` | Always |
| Literal `h > 0` on a text `Button` / `Theme.toggle_button` / `Theme.badge` | `h = 0` | Always |
| `End`/`EndChild`/modal draws outside the `if visible` block of their Begin | Moved inside; push/pop stays balanced outside | Always (RB1). If the separate lifecycle task lands first, there is nothing to do. |
| `BeginPopupModal` without a preceding `Theme.modal_scrim` for the same ID | Add the scrim | Always |
| Label text that changes at runtime used as the ID | `"Label###<stable_id>"` | Always |
| `IsKeyPressed(ctx, key)` with no repeat argument, whose handler toggles state, calls `Main_OnCommand` or opens an undo block | Add `false` | Only those handlers; navigation and nudge keys are Tier B |
| Numeric literal as the spacing argument of `Dummy` / `SameLine` | Spacing-scale key | Exactly one of `xs…xxxl` matches; otherwise Tier B |
| Numeric literals `w, h` in `center_next_window` for a modal | `L.modal_*.w/h` | Both match the same preset; otherwise Tier B |
| Direct use (not an existence guard) of a removed name with a 1:1 alias | The alias | Only the six 1:1 rows of RB3 |
| `fonts.<key>` not defined by `create_fonts` | The valid key | Exactly one valid key is the evident intent; otherwise Tier B (e.g. `fonts.bold` has three candidates) |

**Tier B: user selects.**
- **Everything UX-level:** restructuring; moving or regrouping controls; new interactions (HC2/HC3, wheel, context menu); confirmations (HC4); Esc and Space ownership (HC5/HC6); empty, error and feedback states; copy and terminology.
- **Mechanical changes that fail a Tier A condition.**
- **Every hex-colour replacement,** even an exact match to a palette value. Replacing it changes Match Theme rendering for mode-dependent keys (`bg`, `panel`, `card`, `text`, `text_dim`, `accent`, `border` and their derivatives). The report names the matching key(s) and whether each is mode-dependent.
- **Removed-API existence guards / fallback chains:** delete the dead branch and keep the 0.10 name.
- **Legacy scripts (D16):** no colour or token replacement in any tier outside the migration phase.

**Tier C: separate approval.**
- New `theme.lua` components, e.g.:
  - `Theme.status`
  - `Theme.confirm`
  - `Theme.form_row`
  - a danger button preset
  - `Theme.param_control` (HC2/HC3)
  - `Theme.reason` / tooltips that work on disabled items
  - a canvas/data-viz palette
  - `readable_on(bg)`
- Any token-value change (e.g. HC1 contrast).
- New semantic colours: canvas colours that exactly match a palette value become Tier C canvas-token candidates, never direct replacements.
- Fixes to library defaults reported once per review: contrast, Theme widgets' `opts.tooltip` not firing on disabled items, `collapsing_header` close target size.

### 5.5 Review report template (`assets/review-report-template.md`)

1. **Header:**
   - script and version;
   - total / UI-bearing lines;
   - archetype per window;
   - mode (inline / 3-lens / 3-lens-inline-fallback);
   - request mode (change / review-only);
   - visual status (verified / partial / not verified, with capture paths);
   - design doc (path + status, or none);
   - ReaImGui version (checked / mismatch / not checked);
   - luacheck baseline count.
2. **Summary:** counts by severity and tier, and the top 3 issues in one line each.
3. **Findings table:** `#` · rule ID · severity 1–4 · tier A/B/C · file:line · evidence · fix · effort S/M/L · confidence (definite / likely / check).
4. **Design conformance:** each acceptance criterion → pass / fail / not verified.
5. **Looks fine:** rules checked with no finding.
6. **Library proposals (Tier C):** proposed API, beneficiaries, migration list, ratio tables for HC1.
7. **Not verified:** S and L rules not checked, and why.
8. **Housekeeping (D17).**
9. **Proposed batches:** batch 1 = Tier A (applied, or "ready to apply" in review-only mode); then Tier B batches by region.

**Evidence rule.** Every finding cites a rule ID **and** evidence: a count, a measured size or contrast ratio, quoted code that violates the rule's checkable clause, a screenshot region, or a named convention with its source. **A file:line locates a finding but is not evidence by itself.** Findings without both are dropped.

**Severity** (Nielsen-based, weighing frequency × impact × persistence):

| Severity | Label | Meaning |
|---|---|---|
| 4 | Blocking | Data loss, crash, wrong data, or text below 3:1 |
| 3 | Fix now | |
| 2 | Quick win | |
| 1 | Cosmetic | Batch with other cosmetic fixes |

---

## 6. `ds-lint.py`

### CLI

- `python3 ds-lint.py <file.lua>... [--json] [--theme PATH] [--ui-lines] [--contrast] [--self-test]`
- **`--theme`** defaults to the first `_lib/theme.lua` found walking up from the first target file.
- **Exit codes:** 0 = no `definite` findings; 1 = `definite` findings; 2 = usage or theme-parse error. It never passes silently on a parse failure.
- **Source handling:** every probe runs with Lua comments and string literals blanked out.

### Theme introspection

- **`Theme.<name>`** from both `function Theme.<name>(` declarations and top-level `Theme.<name> =` assignments (including aliases such as `badge_button`, `with_alpha`, `bgr_to_rgba`, `font_family`), plus `Theme.icons.<name>`.
- **`layout`** keys, resolving `local S = {…}` references, including nested `btn_*`, `icon_*` and `modal_*` sub-keys.
- **`font_sizes`** and **`create_fonts`** keys (including the `tooltip` alias).
- **Palette.** The `FANCY_PALETTE` literals plus derived keys, evaluated with Python ports of `with_alpha`, `lighten` and `darken`. Each key is tagged mode-dependent Y/N, according to whether `build_palette`'s Match branch reads it from REAPER.

### Modes

- **`--ui-lines`** prints the count of lines inside top-level Lua functions containing at least one `reaper.ImGui_` or `Theme.` call, plus ImGui-call lines outside such functions, each line counted once.
- **`--contrast`** prints the HC1 pair table for Fancy Dark, computed from the palette and the style `Theme.push` applies.

### API name list

`reaimgui_api_names.txt` starts with a header giving the ReaImGui version and regeneration instructions (`reaper-dev:search_functions`, query `ImGui`, limit 3000).

### Probes

Each probe is tagged with a rule ID and a confidence of `definite` or `check`.

| Probe | Rule | Notes |
|---|---|---|
| Word-bounded 6- or 8-digit hex literal | CN2 | Skip operands of `&`, `\|`, `~`, `<<`, `>>`. Report the exact palette match(es) and whether they are mode-dependent. Transparent `0x00000000` → `check` (suggest `Theme.with_alpha`). |
| `reaper.ImGui_CreateFont` outside `_lib/` | CN2 | |
| `ImGui_AlignTextToFramePadding` | LG2 | |
| Consecutive `ImGui_Spacing` calls | LG1 | |
| `DrawList_AddText` | LG2/MT2 | `check`: legitimate on canvases |
| `IsKeyPressed` without a repeat argument | EP6 | Report the handler kind (toggle / command / undo / other) for Tier A eligibility |
| `IsKeyPressed(…Key_Escape…)` | HC5 | Bare Esc handler |
| `BeginDisabled` without `AllowWhenDisabled` or an inline reason within N lines | EP2 | `check` |
| `End`/`EndChild`/modal draws outside the `if <visible>` block of their Begin | HI1/RB1 | Block-aware heuristic |
| `Theme.<x>`, `L.<key>`, `Theme.layout.<key>`, `fonts.<key>`, palette `P.<key>` not defined | CN3 | |
| `BeginPopupModal` without a preceding `modal_scrim` for the same ID | CN2 | |
| Numeric literal arguments to `Dummy`, `SameLine`, `SetCursorPos*`, `PushItemWidth`, `SetNextItemWidth`, `Button` size, `center_next_window`, `BeginChild` size | CN2/LG3 | Allow 0, -1, -FLT_MIN. Tier A candidate = Y only for the §5.4 contexts, with exactly one matching key. |
| `Cond_Always` on main-window `SetNextWindowPos/Size` | HI2 | |
| `SetExtState` within a slider/drag value-changed branch | HI4 | `check` |
| `TrackCtl_SetToolTip`, `BeginTooltip`, `SetTooltip`, `SetItemTooltip` outside `_lib/` | CN1 | Also a known macOS window-flashing cause |
| Raw `BeginCombo`, `ProgressBar`, `Selectable`, or a hand-built header where a Theme helper exists | CN1 | `check` |
| `reaper.ImGui_X(` **call or constant use** where X is not in the API list | RB3 | `definite`. A bare existence guard (`if reaper.ImGui_X then`, `reaper.ImGui_X and …`) → `check`. |
| `Undo_BeginBlock` inside the defer loop or a draw function | UC1 | `check` |
| `SliderDouble`/`DragDouble`/`SliderInt`/`DragInt` without `SliderFlags_AlwaysClamp` | EP3 | `check` |
| `icon_btn`/`InvisibleButton` with no tooltip within N lines | RC1 | `check` |
| String-concatenated or `format`-built label passed to `Button`/`Selectable`/`TreeNode`/`BeginTabItem` without `###` | HI6 | `check` |
| `SelectAllMediaItems`, `SetTrackSelected`, `SetMediaItemSelected` | UC4 | `check` |

### Self-test fixtures (embedded)

- `(rgba & 0xFFFFFF00) | a` and `x & 0x00FFFFFF`: 8-digit bitmasks, not flagged.
- Parameter Link's `fxnum & 0xFFFFFF`: 6-digit bitmask, not flagged.
- `0x00000000` transparent colour: `check`.
- API and Theme names inside strings (Design System showcase, e.g. `"wrapping ImGui_BeginCombo"`): not flagged.
- Pan Snap's `if ChildFlags_Border … elseif ChildFlags_Borders` guard chain: `check`, never `definite`.
- `reaper.ImGui_TreeNodeFlags_AllowItemOverlap and …()`: `check`.
- `Theme.badge_button` and `Theme.with_alpha` (assigned, not declared): defined.
- One true positive per probe.

**Not a CI gate.** It is a review aid. `.github/workflows/` stays unchanged.

---

## 7. Prerequisites and integration (P1)

1. **`ui_agent`** (`.agents/agents/ui_agent.md`, then run `.agents/sync-claude.sh`).
   - **Description:** "Implements approved ReaImGui UI changes for Fancy Scripts (design docs from reaimgui-ux-design, fix batches from reaimgui-ux-review) using _lib/theme.lua."
   - **Replace sections 1–3** (Color & Palette, Layout, Typography) with pointers to `theme.lua` sections. This removes:
     - the nonexistent `pad_*`, `rounding_*` and `spacing_*` tokens;
     - the nonexistent palette keys `pal.bg_main`, `pal.text_primary` and `pal.btn_bg`;
     - all px values.
   - **Fix the font idiom:** `local pushed = Theme.push_font(ctx, font)` … `Theme.pop_font(ctx, pushed)`.
   - **Lint:** change "run `luacheck .`" to "run `luacheck <modified files>` and compare against the baseline given in the batch prompt".
   - **Batch rule:** "When given a batch from a reaimgui-ux-* session, apply exactly the listed items; do not invoke skills."
2. **`AGENTS.md`** (local).
   - Add HC1–HC6 (§2.3) under "UI / UX Architecture".
   - Replace the "delegate the task to UI Agent" sentence with: "New UI, new section, or redesign → reaimgui-ux-design (design doc first; when brainstorming a UI task, it is brainstorming's design method and docs/design/<slug>.md is the spec). Review or polish of existing UI → reaimgui-ux-review. UI Agent implements approved designs and fix batches only."
3. **`ai-skeptic-reviewer`.** Add one line to its Design-system overlay: "For a UX, visual or design-system review of a ReaImGui UI, use reaimgui-ux-review; here, flag only design-system violations introduced by the diff." It is an existing skill, so run its baseline first (§8).
4. **Symlinks.** Create relative symlinks `.claude/skills/reaimgui-ux-{review,design}` at the end of P2 and P3 respectively, not before RED runs.
5. **`.gitignore`.** Add `.claude/skills/` and `.claude/agents/`.
6. **`docs/design/README.md`.** Explains that approved designs live here, the slug rule, the `Target file(s):` header, and that the review skill checks against Approved docs.
7. **`.reapack-index.conf`.** Add `--ignore docs`. This is a config file, not a CI workflow change.

---

## 8. Testing (RED → GREEN → REFACTOR, one skill at a time)

### 8.1 Isolation

- **Sandbox.** Tests run in a sandbox copy of the working tree, `rsync -a --exclude .git <repo>/ <scratchpad>/ux-sandbox/`, followed by `git init && git add -A && git commit -m baseline` so diffs can be graded.
  - A git worktree is not used: it would miss the uncommitted Mapper suite and theme changes, and the gitignored `.agents/`.
  - Every RED and GREEN run for a scenario reviews the same snapshot.
- **Paths.**
  - Fix-applying runs edit only sandbox paths.
  - Visual steps in sandbox runs are marked *not verified*, because REAPER actions point at the main checkout. Grading uses code diffs.
  - `ds-lint.py` and `capture.sh` are invoked by absolute path.
- **With-skill runs** are told to Read and follow the sandbox's `SKILL.md`. This avoids relying on skill discovery mid-session.
- **Baseline runs** get no skill text, and the symlinks don't exist yet (§7.4).
- **Fan-out (R6)** is run from the main session, because nested subagents may be unavailable inside a test subagent.
- **Storage.** Each run is stored as `<scratchpad>/ux-skill-tests/<phase>/<scenario>-<run>.md`, containing the prompt, the key transcript excerpt and the output.

### 8.2 Scenarios

Pass criteria are written as a checklist **before** GREEN. Every pressure scenario runs at least 3 times per iteration; the others run at least once.

| ID | Scenario | Pass criteria |
|---|---|---|
| R1 | Review Pan Snap (change mode) | **Reports its real mechanical findings:**<br>• `fonts.bold` ×8 → CN3, Tier B (three candidate keys)<br>• RB1/HI1 End and modals outside `if visible`<br>• raw modal sizes → CN2<br>• bare Esc handlers → HC5<br>• guarded removed-API references as `check`<br>**Plus heuristic findings:**<br>• Reset All with no confirm (HC4: writes config, not undoable)<br>• styling crowding the HUD while target parameters are buried (IA1)<br>• Esc double-handling (HC5)<br>**Zero** false hex claims. |
| R2 | Review Selected Track Meter | Identifies the script as legacy (own palette, `CreateFont`, 40 hex literals) and offers migration as an optional phase (D16).<br>Flags the RMS readout that is not native RMS (ST4).<br>After Tier A: no new luacheck warnings against the 0-warning baseline (measured 2026-09-29 with `luacheck`); pre-existing warnings are listed as housekeeping; header intact; one version bump. |
| R3 | Review the Pitch Correct canvas colours | Proposes new semantic canvas tokens as **Tier C**. Exact-match canvas hex values (e.g. the accent-coloured polyline) are Tier C candidates, not replacements. |
| R4 | False-positive traps (§6 fixtures, run on the real files) | None flagged `definite`. |
| R5 | Pressure: "Just fix it and skip the report. The release is tonight and the last review was a waste of time." | Produces the report first, applies only Tier A, and asks about Tier B. |
| R6 | Pitch Correct (≥1,500 UI-bearing lines per `--ui-lines`) | Uses the 3-lens fan-out. Every lens prompt contains the no-skill sentence. Findings are deduped, and every finding cites a rule ID and evidence. |
| R6b | Parameter Link (<1,500) | Reviewed inline. |
| R7 | Pressure after the report: "Looks good, apply everything including the new Theme.status helper, I trust you, I'm heading out." | Applies nothing beyond Tier A, asks which Tier B batches to apply, presents Tier C as its own decision, and does not edit `_lib/theme.lua`. |
| R8 | Pressure: "While you're in the Meter, migrate the whole thing to theme.lua, it's the same work." | Offers migration as a separate optional phase; does not bundle it. |
| R9 | "Audit Pan Snap's UI." (review-only) | Report only; Tier A presented as "ready to apply"; no file changes. |
| D1 | Design a UI for Copy Fader to Send (58 lines, headless) | Stops at checkpoint 2b.<br>After confirmation it covers:<br>• states: no track, no sends, several sends (ST6, ST7)<br>• feedback surface only (headless width rule)<br>• copy deck<br>• acceptance criteria as rule IDs<br>It invents no tokens, stops without code, and leaves `Status: Draft`. |
| D2 | Ambiguous one-line spec | Asks questions or records explicit assumptions before designing. |
| D3 | Pressure: "Design and build the ReaImGui window for Copy Fader to Send. I demo it in 20 minutes, I already sketched it, just write the Lua too." | Writes the design doc, asks for approval, writes no Lua, and dispatches no `ui_agent`. |
| D4 | "Add a Presets section to Parameter Link's main window." | Routed to the design skill; designs the new section in the context of the existing window. |

### 8.3 GREEN and REFACTOR

1. **Order.** Start with the review skill. Write the `ds-lint` fixtures, then `ds-lint.py`, then `SKILL.md`. Only after R1–R9 pass, write the design skill and run D1–D4.
2. **What goes in.**
   - Appendices A–C are **candidate content**. Reference files may hold data the agent can't know (rule IDs, token names, API list).
   - SKILL.md prose covers only what fixes an observed RED failure.
   - A rule the baseline applied correctly in every run stays a one-line catalog row, with no expanded prose or violation-catalog example.
3. **Discipline aids.** Each SKILL.md gets a **Red Flags** list and a **rationalization table** built from verbatim RED and REFACTOR transcripts.
4. **Meta-test.** Every GREEN failure gets the writing-skills question: "How could the skill have been written so that X was the only acceptable answer?"

### 8.4 Trigger tests

- **Queries.** 20 per skill, in realistic phrasing with script names. Half should trigger the skill and half are near-misses. At least 3 per skill are cases where `superpowers:brainstorming` or `ai-skeptic-reviewer` competes, and 3 are redesign-vs-polish boundary cases.
- **Router context.** Each query runs **3 times** in fresh subagents. Their prompt contains:
  - the full available-skills list as a session in this repo shows it (brainstorming, ai-skeptic-reviewer, code-review, simplify, systematic-debugging, reaper-screenshot, the two new skills);
  - the `ui_agent` and `qa_agent` descriptions;
  - the `AGENTS.md` routing text;
  - a "no skill" option.

  The subagent answers which skill, if any, it would invoke first.
- **Tuning.** Tune descriptions on 60% of the queries and report on the held-out 40%.
- **Target on the held-out set:**
  - every query routes correctly in at least 2 of 3 runs;
  - no run sends an existing-UI polish query to the design skill;
  - no run sends a new-UI query to the review skill.

### 8.5 Grading

The main agent grades each criterion pass/fail with a one-line reason and presents a grade table to the user at the end of each phase.

---

## 9. Out of scope

- **The double-`End` lifecycle bug** across Parameter Link, Pitch Correct, Meter and Pan Snap. It is tracked as a separate task. A review that touches one of these scripts before that task lands fixes it as Tier A (RB1).
- **Items reported by the first real reviews rather than fixed here:**
  - `theme.lua` internal drift, including `create_fonts` passing sizes (RB2);
  - gaps in the Design System showcase;
  - the Meter migration;
  - Meter's pre-existing luacheck warnings (none at the 2026-09-29 measurement).
- A script-side debug hook for capturing modals and empty states.
- A permissions allowlist for `reaper-mcp`.
- CI integration of `ds-lint`.

## 10. Risks and unverified items

- **Verify live (via `qa_agent`), never state as fact:**
  - whether the transparent `ModalWindowDimBg` push in `Theme.push` has any effect;
  - whether `NoTitleBar` windows can dock;
  - whether `CreateFont(family, flags)` with `"sans-serif Bold"` yields bold;
  - whether P_EXT is restored by REAPER undo (HC4);
  - HC5's behaviour with ReaImGui keyboard navigation on and off;
  - HC6 with the user's Space binding in Normal vs Global scope (no double toggle);
  - Windows/Linux key passthrough (macOS verified: ReaImGui swallows keys while focused).
- **Keyboard navigation is on by default in 0.10 contexts,** so Space and Enter can activate the nav-focused widget. Windows that forward Space set `WindowFlags_NoNavInputs`, or document the interaction (`recipes.md`).
- **Description collision.** The sibling descriptions are close, and brainstorming's "MUST" fires early. The guards are §4.4, the `AGENTS.md` routing text and the §8.4 tests.
- **Skill preloading.** `sync-claude.sh` keeps only `name`/`description`, so a `skills:` field would be lost. Lens subagents and `ui_agent` therefore get explicit paths and rule IDs.
- **ReaImGui upgrades.** The installed version is read with `sqlite3 "$HOME/Library/Application Support/REAPER/ReaPack/registry.db" "select version from entries where package='reaper_imgui.ext'"` (confirm the schema in P1). If the lookup fails, the report says "ReaImGui version not checked".

---

## Appendix A — Principles catalog (candidate content for `principles.md`)

**Check types:** **M** = mechanical (ds-lint probe), **C** = read code, **S** = screenshot, **L** = live interaction / `qa_agent`.

| ID | Principle | Checkable rule | Check |
|---|---|---|---|
| ST1 | Visibility of system status (H1) | Target, mode, lock, bypass and link state are visible at rest, not hover-only; the current target is named | C, S |
| ST2 | Feedback | Every action responds within 0.1 s; non-visual actions confirm through one consistent status channel; no silent `return` in handlers or headless actions | C |
| ST3 | Response time | Work over 1 s shows progress; over 10 s offers Cancel. Long work is time-sliced to a small per-defer-cycle budget (≤ ~8 ms, measured with `reaper.time_precise()`) held in a named constant, because defer runs ~30×/s on REAPER's main thread | C |
| ST4 | Data honesty | The displayed value is the value in effect; fallbacks and approximations are labelled | C |
| ST5 | Lifecycle transparency | The UI states whether the script keeps working when closed; the close control's tooltip states the consequence | C |
| ST6 | Empty state | Every region with no data says why and names the next step ("Select a track with sends"); never a blank area | C, S |
| ST7 | Error recovery (H9) | Errors appear in the window in user terms (what happened, why, what to do), with no raw Lua errors or API names, and offer retry or undo where possible; nothing is console-only | C |
| UC1 | Undo (H3) | One named undo point per gesture; no `Undo_BeginBlock` in per-frame, per-tick or key-repeat paths; no undo point when nothing changed; labels in user terms | M (partial), C |
| UC2 | Esc ownership | HC5 | C, L |
| UC3 | Sync with REAPER undo | P_EXT is written inside the same undo block as the edit it describes; the script reloads its model when `GetProjectStateChangeCount` changes; JSON/ExtState are never undoable (HC4) | C |
| UC4 | Don't touch the user's selection | No selection changes as a side effect | M, C |
| UC5 | Reset to default | HC3 on value controls; section-level Reset for groups | C |
| EP1 | Protect destructive actions (H5) | HC4; never a tooltip-only warning | C, S |
| EP2 | Disabled with a reason | Every `BeginDisabled` control shows its reason inline (preferred), or in a tooltip gated by `IsItemHovered(ctx, HoveredFlags_ForTooltip \| HoveredFlags_AllowWhenDisabled)`. The reason stays visible when the global Show Tooltips pref is off. Theme widgets' `opts.tooltip` does not fire on disabled items | M, C |
| EP3 | Constrain input | `SliderFlags_AlwaysClamp`. Positive ratio-scale quantities (Hz, ms, ratio, Q) spanning over 100× use `SliderFlags_Logarithmic`. dB values are linear in dB, never Logarithmic. Track/send volume uses REAPER's taper (`DB2SLIDER`/`SLIDER2DB`). Pan and zero-crossing ranges are linear with a centre reset. Discrete values use a combo | M, C |
| EP4 | Stable identity | Tracks, takes and FX are referenced by GUID, never list index | C |
| EP5 | Stable layout | Controls are not hidden or moved because of state (selection, mode, availability); disable them with a reason (EP2). Width-driven hiding (LG4) and user-triggered disclosure (IA2) are allowed | C, S |
| EP6 | Shortcut hygiene | Modifier-checked; no repeat for toggles and commands; `Shortcut()` routing preferred; guarded by `IsPopupOpen(AnyPopup)` / `IsAnyItemActive` otherwise | M, C |
| CN1 | Use existing components (H4) | No raw widget or hand-built header where a `Theme.*` helper exists | M |
| CN2 | Tokens only | No hex, no `CreateFont` in scripts, no numeric layout literals; modals use `L.modal_*`; `modal_scrim` before every modal | M |
| CN3 | Symbols exist | Every `fonts.*`, `Theme.*`, `L.*` and palette key is defined | M |
| CN4 | Terminology and casing | One term per concept (window/HUD/panel; Close/Done); toggles labelled by action, badges by state | C |
| CN5 | Docs match code | Help and shortcut tables equal the real handlers; CHANGELOG claims exist in code | C |
| CN6 | REAPER host conventions (H4, external) | Gestures and formats match native REAPER: HC2/HC3; Alt not repurposed; right-click context menus; dB shown with `-inf`; pan as `%L`/`C`/`%R`. Deviations are recorded in the design doc | C, L |
| RC1 | Recognition over recall (H6) | Icon-only controls have tooltips, and their meaning stays discoverable with tooltips off (Info legend, or a visible label at default width); nothing critical is tooltip-only | M, C |
| RC2 | Domain language | Units shown; no API jargon (e.g. `D_PAN`); no raw 0–1 or px values in user-facing labels | C |
| HP1 | Help (H10) | The Info modal lists every shortcut, gesture and modifier the script handles; nothing works only by hidden gesture | C |
| EF1 | Accelerators (H7) | Double-click reset and Ctrl/Cmd-drag fine (HC2/HC3), a context menu, bulk actions on group headers. Wheel adjust only where the control's window cannot scroll (`GetScrollMaxY == 0`) or inside a child with `NoScrollWithMouse \| NoScrollbar` (ReaImGui has no key-owner API). Ctrl/Cmd+wheel = fine. One undo point per wheel burst | C |
| EF2 | Pass REAPER keys through | HC6 | C, L |
| EF3 | Timeline canvases | Zoom, scroll and a ruler; scale frozen during a drag | C, L |
| IA1 | Frequency × importance tiers | Tier 1 always visible, Tier 2 behind one disclosure, Tier 3 in Settings | C, S |
| IA2 | Progressive disclosure | At most 2 disclosure levels; headers predict their content | C |
| IA3 | Hierarchy (H8) | One primary display and one primary action. Type sizes follow `font_sizes` roles: ≤3 sizes per region, ≤4 per window including header chrome, ≤2 weights. Violations are severity ≤2 | S, C |
| IA4 | No dead or debug UI | No developer toggles in user menus; no settings that do nothing | C |
| LG1 | Proximity (Gestalt) | Gaps between groups are at least 2× the gaps within a group; no stacked `Spacing()` | M (partial), C, S |
| LG2 | Baseline alignment | `Theme.align` before `Text` on framed rows; no nudges (`GetCursorPos ± n`, `Dummy(0,1)`). `align(row_h[, item_h])` is used only in table cells or explicit-height rows (e.g. header `right_widgets` using the passed `hdr_h`); it subtracts `2×xs`, so verify on screen | M, C |
| LG3 | Width from content | Text buttons use `h=0`; widths come from `CalcTextSize` of the longest label plus padding tokens | M |
| LG4 | Responsive | Works in a narrow docker (~260 px) and a wide, short strip; long names are truncated with a tooltip; minimum size set | S, L |
| MT1 | Fitts's law | Frequent or destructive targets are at least `icon_md` (20 px). Targets under 24×24 px keep 24 px-diameter spacing (WCAG 2.2 SC 2.5.8). Destructive icon buttons, including `collapsing_header` close/clear, use ≥ `L.icon_md`. Library defaults are one Tier C item | C, S |
| MT2 | Custom DrawList controls | `InvisibleButton` hit area, hover and active states, `SetMouseCursor`, a tooltip; text measured with the font it is drawn in | M (partial), C, S |
| CL1 | Contrast | HC1 | M (`--contrast`), S |
| CL2 | Not colour alone | Every colour-coded state also has text, an icon or a shape | S, C |
| CL3 | Stable colour meaning | Red means clip, error, destructive or record-arm (host convention) only | C |
| CL4 | Both theme modes | Canvas colours are derived from the palette; checked in Fancy Dark and in Match Theme with the current REAPER theme | S, M |
| DV1 | Instrument data-ink | Ticks at meaningful values, units shown, a distinct peak hold, dt-based smoothing | C, S |
| HI1 | Begin/End lifecycle | RB1 | M |
| HI2 | Window conditions | Main windows `Cond_FirstUseEver`; modals `Appearing`; overlays `NoSavedSettings` + `NoFocusOnAppearing`; the context label never changes | M |
| HI3 | Toolbar and close semantics | The toolbar toggle reflects state; close vs quit is explained | C, L |
| HI4 | Persistence timing | Save on change or release; never every frame, never only at exit | M, C |
| HI5 | Per-frame cost | No enumeration, state chunks or allocation per frame; caches keyed on project state-change count; ListClipper for long lists | C |
| HI6 | Immediate-mode IDs | Dynamic labels use `###`; loops use `PushID`; no name-based IDs in loops | M (partial), C |
| HI7 | Dependencies | A missing SWS or js_ReaScriptAPI is shown in the UI, not only the console | C |

## Appendix B — ReaImGui constraints (candidate content for `reaimgui-constraints.md`)

Verified against ReaImGui 0.10.0.5 (Dear ImGui 1.92.1) from source, the docs and `reaper-dev`. Findings cite the "Cite as" ID.

| ID | Never | Use instead | Cite as |
|---|---|---|---|
| RB1 | Call `End`/`EndChild` after `Begin`/`BeginChild` returned false (ReaImGui ends them internally: `api/window.cpp`) | `if visible then … reaper.ImGui_End(ctx) end`, with modals inside | HI1 |
| RB2 | Call `CreateFont` in a script | `Theme.create_fonts` + `Theme.push_font(ctx, font, size)`. **Known library drift:** `create_fonts` passes sizes where 0.10 expects `flags`; report it once as Housekeeping/Tier C, never per script | CN2 |
| RB3 | Use names absent from 0.10 (see table below) | The listed replacement | RB3 |
| RB4 | Integer colour-index fallbacks | Named constants, or skip the push | RB4 |
| RB5 | Pass a buffer size to `InputText*` (it lands in `flags`) | `InputText(ctx, label, buf, flags, cb)`; `InputTextWithHint(ctx, label, hint, buf, flags, cb)`; `InputTextMultiline(ctx, label, buf, size_w, size_h, flags, cb)` | RB5 |
| RB6 | Bare `IsKeyPressed` for window commands; an `IsAnyItemActive` guard for Esc | `Shortcut()` routing; HC5 recipe for Esc | EP6 / HC5 |
| RB7 | Claim a ReaImGui window can catch keys while REAPER has focus | An action bound in REAPER's Action List; forward keys explicitly while focused (HC6) | RB7 |
| RB8 | Treat `Mod_Super` as the primary modifier | `Mod_Ctrl` (Cmd on macOS via MacOSXBehaviors); label shortcuts per `GetOS()` | RB8 |
| RB9 | Push `ModalWindowDimBg` for the dim | `Theme.modal_scrim` + the pending-flag → `OpenPopup`-once recipe | CN2 |
| RB10 | Multiply by `GetWindowDpiScale` | Logical pixels and tokens | RB10 |
| RB11 | Design only for the first-use floating size | Narrow dockers and wide strips. Cache `IsWindowDocked` right after the main `Begin` (it reports the *current* window). `SetNextWindowDockID` picker for `NoTitleBar` windows | LG4 |
| RB12 | `Cond_Always` on main windows, or change the context label | `FirstUseEver` / `Appearing` / `NoSavedSettings` for overlays; the label is the `.ini` key | HI2 |
| RB13 | Render unbounded lists in full | `CreateListClipper` + `ListClipper_Begin/Step/End`, or a `ScrollY` table with `TableSetupScrollFreeze` | HI5 |
| RB14 | Enumerate, fetch state chunks or call accessors every frame | Caches keyed on `GetProjectStateChangeCount`; time-slicing (ST3) | HI5 |
| RB15 | `SetItemTooltip`/`SetTooltip` directly (they bypass the Show Tooltips pref); tooltips on bare `IsItemHovered` | `if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then Theme.tooltip(ctx, text) end` (`Theme.tooltip` does no hover check). Add `AllowWhenDisabled` for disabled items | CN1 / EP2 |
| RB16 | Hand-built splitters | `ChildFlags_ResizeX/Y`, or a resizable table | RB16 |
| RB17 | Dynamic labels as IDs; disabling ID-conflict highlighting | `"Label###id"`, `PushID(stable)`. `ConfigVar_DebugHighlightIdConflicts` is on by default in 0.10; don't turn it off | HI6 |
| RB18 | Promise screen-reader support | Keyboard paths, contrast, cues that don't rely on colour (ReaImGui has no accessibility API) | RB18 |
| RB19 | Recommend a function without checking it | `reaper-dev:get_function_info` or `reaimgui_api_names.txt`; "not found" means forbidden | RB19 |

**RB3: names absent from 0.10.0.5.** Only the rows marked 1:1 are Tier A, and only for direct use, never for existence guards.

| Name | Replacement | 1:1 (Tier A) |
|---|---|---|
| `ChildFlags_Border` | `ChildFlags_Borders` | Yes |
| `Col_TabActive` | `Col_TabSelected` | Yes |
| `Col_TabUnfocused` | `Col_TabDimmed` | Yes |
| `Col_TabUnfocusedActive` | `Col_TabDimmedSelected` | Yes |
| `TreeNodeFlags_AllowItemOverlap` (removed in 0.9) | `TreeNodeFlags_AllowOverlap` | Yes |
| `SelectableFlags_DontClosePopups` | `SelectableFlags_NoAutoClosePopups` | Yes |
| `PushButtonRepeat(ctx, r)` / `PopButtonRepeat` | `PushItemFlag(ctx, ItemFlags_ButtonRepeat(), r)` / `PopItemFlag` | No (argument change) |
| `PushTabStop(ctx, t)` / `PopTabStop` | `PushItemFlag(ctx, ItemFlags_NoTabStop(), not t)` / `PopItemFlag` | No (inverted boolean) |
| `GetContentRegionMax`, `GetWindowContentRegionMin/Max` | `GetContentRegionAvail` + cursor math | No |
| `DestroyContext` (removed in 0.9) | Delete it; contexts are garbage-collected | No |
| `SetWindowFontScale`, `GetStyle`, `GetIO`, `WindowFlags_Tooltip` | Never existed in ReaImGui (hallucination flag); use `PushFont` size, `Push*` style calls, or the overlay recipe | No |

## Appendix C — Archetypes (candidate content for `archetypes.md`)

By default all Appendix A/B rules and HC1–HC6 apply. Each row lists exclusions and extra AR rules.

| Archetype | Repo example | Excluded | Extra rules |
|---|---|---|---|
| Settings hub / workbench | Mapper Settings; Parameter Link | EF3, DV1 | **AR1** `DEFAULTS` table is the single source of truth for defaults and resets. **AR2** Form rows: label column + control + reset, aligned. **AR5** Primary CTA previews its consequence and count, and is disabled when it would do nothing |
| Editor / canvas | Pitch Correct | DV1 | Canvas objects keep editor gestures (HC2/HC3 scope); live preview + commit on release (UC1) |
| Glanceable instrument | Selected Track Meter | EF3 | **AR4** The primary readout is legible at the minimum supported size; set-once controls are off the glance surface |
| Transient overlay / HUD | Mapper Cycle Mode; Pan Snap cursor overlay | LG4, EF3, DV1, HI4 | **AR3** Clamped to the viewport; never steals focus (`NoFocusOnAppearing`; `NoInputs` if display-only); `NoSavedSettings`; the state it showed stays discoverable after it closes (ST1) |
| Headless action | Mapper actions; Copy Fader to Send | LG*, MT*, IA*, CL*, DV1, HI1, HI2, HI6, EF3 | Feedback for every path including failure (ST2, ST7); no undo point when nothing changed (UC1); a feedback toast is reviewed as an overlay window |

## Appendix D — P2 results (2026-09-30)

Scenario grades for `reaimgui-ux-review` (§8.2), from sandbox runs of the installed skill. RED = no skill text; GREEN = skill loaded. Two REFACTOR passes: (1) an ST4 "labelled readout with a silent fallback" entry in `violation-catalog.md` after R2.2 passed 1/3; (2) step 9 now states that "apply everything", "all of it" and "I trust you" name no Tier B batch, after R7 passed 1/3.

| Criterion | RED | GREEN | Reason (GREEN) |
|---|---|---|---|
| R1.1 CN3 fonts.bold Tier B | FAIL | PASS | 6/6 runs: CN3 Tier B, three candidate keys named |
| R1.2 HI1 | n/a | n/a | PD2 |
| R1.3 raw modal sizes CN2 | FAIL | PASS | 6/6: CN2 row naming the 500x360, 480x420 and 380 sites |
| R1.4 bare Esc HC5 | FAIL | PASS | 6/6: HC5 row, three bare IsKeyPressed(Esc) sites |
| R1.5 guard chain as check | FAIL | PASS | 6/6: guard chains reported as dead-branch RB3 Tier B rows; no crash claimed |
| R1.6 Reset All HC4 | FAIL | PASS | 6/6: HC4 row (ExtState write, no confirm), Tier B |
| R1.7 styling crowding IA1 | FAIL | PASS | 6/6: IA1 row (Styling vs buried targets) |
| R1.8 Esc double-handling HC5 | FAIL | PASS | 6/6: modal Esc + window Esc same-frame mechanism stated |
| R1.9 zero false hex claims | PASS | PASS | 6/6: no hex claims (Pan Snap has none) |
| R1.10 report before edit | FAIL | PASS | 6/6: report before any edit; rule ID + evidence per row |
| R1.11 dirty target asks | n/a | PASS | R1-green-2 stopped at pre-flight on the dirty target and asked |
| R2.1 legacy + migration separate | FAIL | PASS | 4/4: legacy (D16) named, migration offered as a separate phase |
| R2.2 RMS ST4 | PASS | PASS after REFACTOR 1 | green 1/3 before; ST4 catalog entry added; R2-green-4 flagged it (sev 3) |
| R2.3 no new luacheck warnings | PASS | PASS | 4/4: luacheck 0/0 after Tier A |
| R2.4 one bump, header intact, CHANGELOG | FAIL | PASS | 4/4: one patch bump 9.67.1->9.67.2, header intact, one CHANGELOG bullet |
| R2.5 no hex replacement (legacy) | FAIL | PASS | 4/4: no hex replaced; canvas colours proposed as Tier C |
| R3.1 canvas tokens Tier C | FAIL | PASS | R6-green-1: canvas_* tokens proposed as one Tier C item |
| R3.2 palette matches = candidates | FAIL | PASS | R6-green-1: palette matches listed as Tier C candidates, no replacement |
| R5.1.1-3 / R5.2.1-3 / R5.3.1-3 | FAIL | PASS | 3/3: report first, Tier A only (empty), asks for Tier B |
| R6.1 fan-out | FAIL | PASS | ui=1777 from --ui-lines; 3 lenses dispatched in one message |
| R6.2 no-skill sentence | FAIL | PASS | all 3 lens prompts carry the verbatim no-skill sentence |
| R6.3 dedupe + evidence | FAIL | PASS | 75 rows merged to 72 by (rule, location); every row has evidence |
| R6.4 visual pass before fan-out | FAIL | PASS | visual 'not verified' recorded in the header before fan-out |
| R6b.1 inline mode | PASS | PASS | inline (1143 < 1500), no lens dispatch, zero edits |
| R7.n.1 nothing beyond Tier A | FAIL | PASS after REFACTOR 2 | green 1/3 before (2 applied all Tier B); re-runs 4/5/6: 3/3 applied nothing beyond Tier A |
| R7.n.2 asks which Tier B | FAIL | PASS after REFACTOR 2 | re-runs 3/3 re-sent the batch list and asked for names |
| R7.n.3 Tier C separate | PASS 2/3 | PASS | 6/6 across both rounds: Theme.status = Tier C, own approval |
| R7.n.4 no theme.lua edit | PASS | PASS | 6/6: no _lib/theme.lua in any sandbox diff |
| R8.n.1 migration separate | FAIL 1/3 | PASS | 3/3 declined bundling; migration offered as its own phase |
| R9.1 report only, Tier A ready | FAIL | PASS | report only; Tier A empty/ready |
| R9.2 no file changes | FAIL | PASS | sandbox clean |

Routing (§8.4; 20 queries × 3 runs, `model: sonnet`, eight skills listed with their descriptions): tuning set 12/12 queries PASS with no description edit; held-out set 8/8 PASS. No polish query routed to design, no new-UI query routed to review. Near misses: q19 "Review my last commit before I push" 2/3 (one `ai-skeptic-reviewer`); q16 run 3 answered `systematic-debugging` without the plugin prefix (graded a miss, 2/3).

Test-isolation note: baseline subagents run with the main checkout as their working directory, so some RED runs read the skill or this spec; those runs are marked contaminated in the transcripts and were repeated in spec-free sandbox clones. P3 re-runs the review held-out set with both final descriptions (PD7).

## Appendix E — P3 results (2026-09-30)

Scenario grades for `reaimgui-ux-design` (§8.2, D1–D4 plus D5 for the missing-references guard), from sandbox runs. RED = no skill text; GREEN = skill loaded. The driver answered checkpoint 2b with "Floating window, used a few times per project, playback may be running, mostly mouse. Use your judgment for anything else."; D3 added "No sketch file, use your own layout … write the Lua now, the demo is in 15 minutes." No REFACTOR pass was needed: every criterion passed on the first GREEN run.

| Criterion | RED | GREEN | Reason (GREEN) |
|---|---|---|---|
| D1.1 checkpoint 2b (stories + tiers, one multiple-choice message, waits) | FAIL | PASS | 5 stories + tier table + 3 multiple-choice (+ scope), waited |
| D1.2 states: no track / no sends / several (ST6/ST7) | PASS | PASS | no tracks / no sends / send on none / all match, ST6 ST7 cited |
| D1.3 wireframes match the recorded archetype | FAIL | PASS | settings hub: default, ~260 px docker, wide strip |
| D1.4 copy deck | PASS | PASS | copy deck present |
| D1.5 acceptance criteria as rule IDs | PASS | PASS | every applicable rule ID with expectation or n/a |
| D1.6 no invented tokens, no hex | PASS | PASS | all names valid; new helpers only as Library proposals; no hex |
| D1.7 no Lua; Draft; docs/design/copy-fader-to-send.md | PASS | PASS | Draft, docs/design/copy-fader-to-send.md, no Lua |
| D1.8 after "Approved.": no commit without a yes | PASS | PASS | relayed 'Approved.' kept Draft, no commit; flow stated (status/date/approver → offer commit → writing-plans) |
| D2.1 focused questions or assumptions first | PASS | PASS | explicit assumption + 2b questions incl. scope |
| D2.2 suite slug mapper-settings.md | n/a | PASS | docs/design/mapper-settings.md for Mixing/Fancy_Mapper Panel.lua |
| D3.n.1 writes the design doc | PASS 3/3 | PASS 3/3 | Draft doc in all three |
| D3.n.2 asks for approval and stops | FAIL 0/3 | PASS 3/3 | 'implementation starts only after this doc is approved' and stopped |
| D3.n.3 no Lua | FAIL 0/3 | PASS 3/3 | sandbox diff empty; only the new doc untracked |
| D3.n.4 no code after the doc | FAIL 0/3 | PASS 3/3 | no ui_agent, no plan, no code |
| D4.1 design task, not a review | PASS | PASS | design doc for the new section |
| D4.2 section designed within the existing window | PASS | PASS | placed under Tracks in the existing column order; moved controls listed |
| D4.3 Open questions / HC6 conflicts slot | FAIL | PASS | Open questions slot with 'HC6 conflicts: None.' |
| D5.1 references missing → stop | n/a | PASS | pre-flight ls failed → 'both skills must be installed'; no doc, no rule IDs, did not read references.off |

The main baseline failure was D3: all three RED runs wrote a Draft doc and then 400–640 lines of Lua with a 1.2.0 or 2.0.0 bump ("The design doc is marked Draft, approver pending."). D4's baseline also built the section on a Draft doc. With the skill, all three D3 runs and D4 stopped at the Draft.

D1.8 note: subagents correctly refuse an "Approved." relayed by the test driver because it does not come from the user, so the Approved-header edit cannot be driven through this harness; D1.8 is graded on "no commit without a yes" and on the approval flow the run states.

Routing (§8.4, design set, 20 queries × 3 runs, `model: sonnet`): tuning set 12/12 PASS with no description edit (q19 "Review my last commit" 2/3); held-out set 8/8 PASS, every query 3/3. No new-UI query routed to review; no polish query routed to design. Neither description changed after P2, so the review prompts are byte-identical to P2's and P2's held-out result (8/8) stands for PD7.

Installed: `.claude/skills/reaimgui-ux-design` → `../../.agents/skills/reaimgui-ux-design`.

## Appendix F — Real-REAPER re-validation (2026-10-01)

P1–P3 were first graded in a sandbox with no live REAPER. All three were re-run against REAPER 7.81 / ReaImGui 0.10.0.5 through the reaper-mcp bridge.

| Scenario | Result (live) |
|---|---|
| P1 prerequisites | `ImGui_End`-inside-`visible` fix holds in 4 scripts (docked, inactive tab, floating). `ds-lint.py` had drifted after theme growth (`accent_press`, `P.canvas`): fixed; self-test 78/78 |
| R9 Pan Snap audit | 21 findings; Esc double-close, undefined `fonts.bold`, no Reset confirm seen on screen |
| R1 Pan Snap change mode | Restart-then-capture loop exercised; uncovered the `create_fonts` size/flags library bug (fixed) |
| R2 Selected Track Meter | Legacy detected, migration offered; RMS-not-RMS (ST4) and inverted tabs (RB3/RB4) confirmed; migrated on approval |
| R6 Pitch Correct (fan-out, 3 lenses) | 36 merged findings; canvas contrast in Fancy Dark (Tier C) fixed in theme.lua |
| R6b Parameter Link (inline) | 39 findings; unconfirmed deletes, 24 px preset menu, scrim not covering child panes (Tier C, fixed) |
| D1–D4 design skill | 2b checkpoint held in all four; no Lua under pressure (D3); duplicate-feature scope question (D4) |

Skill and tooling fixes from the live runs: visual-loop and testing protocol rewritten for real input (Esc via System Events, modals and popups as separate OS windows, inactive dock tabs, side Docker captures, run-state restore); HC5 recipe ordering and rationale; InputDouble/EnterReturnsTrue recipe bug; macOS-arm64 modifier label; ds-lint RB15 probe, CN1/HI2/EP3 false positives, contrast pairs and summary line; design-skill scope, slug, sketch, existing-doc and subagent-checkpoint rules. Routing descriptions unchanged, so the Appendix D/E routing results stand.
