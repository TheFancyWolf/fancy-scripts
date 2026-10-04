# Tap Tempo Settings Implementation Plan

> docs/design/tap-tempo-slew-settings.md is Approved (2026-10-03, TheFancyWolf). Implement it exactly. Do not invoke skills.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A floating settings window for Fancy Tap Tempo Slew, plus the "Once per N taps" group behaviour in the tap action.

**Architecture:** A shared `_lib/tap_tempo_settings.lua` owns `DEFAULTS`, load (with validation) and save to ExtState. The tap action reads it on every press; the new settings script edits it. No other coupling.

**Tech Stack:** Lua 5.4, ReaScript, ReaImGui, `_lib/theme.lua`.

**Spec:** `docs/design/tap-tempo-slew-settings.md`

## Global Constraints

- AGENTS.md rules: `reaper.*` never aliased, every variable `local`, `main()` entry, numbered section banners, full ReaPack header, ReaImGui dependency check, no raw colours/sizes/fonts (Theme tokens only), `luacheck .` clean.
- No fake REAPER/ImGui test harness (AGENTS.md Working Rule 1). Verification = `luacheck` + live checks through the REAPER MCP bridge following `.agents/skills/reaper-screenshot/references/testing-protocol.md`.
- ExtState section `FancyTapTempoSlew`, persisted (`true`) for settings; runtime keys `taps`, `target`, `stop` stay non-persistent.
- DEFAULTS (spec): mode `instant`, glide rate 10, taps 4, update `group`, restart gap 2.0, min 30, max 300.
- Ranges (spec): glide 0.5–100, taps 2–16, gap 0.5–10, min 20–(max−1), max (min+1)–960.
- Copy strings are exactly the spec's Copy deck.

## Review Focus

- Hand-edited / corrupt ExtState (e.g. `taps_per_change = "abc"`, min > max) → defaults for bad keys, min/max repaired, status "Some saved settings were invalid…" (Task 1 check, Task 2 check).
- Changing N mid-sequence (taps already recorded > new N) → no crash; next tap trims to N (Task 1 check).
- Group mode: 8 quick taps → exactly 2 markers; rolling mode: 8 taps → 5 markers (Task 1 check).
- Settings window open while tapping → tap uses the just-saved values (Task 2 check).
- Narrow docker (~260 px) → nothing clipped, labels wrap (Task 2 check).

---

### Task 1: Shared settings module + tap action uses it

**Files:**
- Create: `_lib/tap_tempo_settings.lua`
- Modify: `Transport/Fancy_Tap Tempo Slew.lua` (remove `CONFIG`; bootstrap `package.path`; `@provides` gains `[nomain] ../_lib/*.lua`; stays v1.0.0, still unreleased)

**Interfaces:**
- Produces: `local S = require("tap_tempo_settings")`
  - `S.DEFAULTS` table: `{ mode="instant", glide_rate=10, taps_per_change=4, update="group", restart_gap=2.0, min_bpm=30, max_bpm=300 }`
  - `S.RANGES[key] = { lo, hi }` for numeric keys (min/max cross-clamped in `sanitize`)
  - `S.load() -> settings, had_invalid:boolean` — reads each key, falls back to default on missing/invalid, enforces ranges and min ≤ max−1.
  - `S.save(key, value)` — writes one key persisted.
  - `S.reset_all()` — deletes all keys (`DeleteExtState(..., true)`).
  - `S.EXT = "FancyTapTempoSlew"`

- [ ] **Step 1:** Implement the module per Interfaces. `mode` ∈ {instant, glide}, `update` ∈ {group, rolling}.
- [ ] **Step 2:** In the tap action, replace `CONFIG` reads with `S.load()` at the top of `main()`. Slew is used only when `mode == "glide"` (rate `glide_rate`); instant path unchanged otherwise.
- [ ] **Step 3:** Group behaviour in `register_tap`: when `update == "group"` and a target is produced, clear `taps` after computing it (so the next change needs N fresh taps). Rolling = current behaviour.
- [ ] **Step 4:** `luacheck .` → `0 warnings / 0 errors`.
- [ ] **Step 5: Live check** (bridge, project at a known tempo, playback running): group mode, 8 quick taps → `CountTempoTimeSigMarkers` grows by 2; set ExtState `update=rolling`, repeat → grows by 5; set `taps_per_change="abc"` → 4 taps still change tempo. Undo back each time.
- [ ] **Step 6: Commit** `feat: shared tap tempo settings and group update mode`

### Task 2: Settings window

**Files:**
- Create: `Transport/Fancy_Tap Tempo Slew Settings.lua`

**Interfaces:**
- Consumes: Task 1 module (`S.load`, `S.save`, `S.reset_all`, `S.DEFAULTS`, `S.RANGES`).

- [ ] **Step 1:** Scaffold: header (`[main] .`, `[nomain] ../_lib/*.lua`), ReaImGui check, bootstrap, `Theme.create_fonts`, lifecycle per house-patterns "Window lifecycle", `Cond_FirstUseEver` width `L.modal_sm.w`.
- [ ] **Step 2:** Layout exactly per spec Wireframes/Theme mapping: `Theme.header` (title "TAP TEMPO", Info button `###info`), summary (`TextWrapped`, `P.text_dim`, strings from Copy deck), TAPPING (`Theme.section_divider`), LIMITS and APPEARANCE (`Theme.collapsing_header`, collapsed by default), footer status + `Reset all…` right-aligned.
- [ ] **Step 3:** Local `param_drag` from `recipes.md` HC2/HC3 (NoInput, NoSpeedTweaks, AlwaysClamp, Ctrl/Cmd fine, double-click reset, Ctrl/Cmd-click type, right-click "Reset to default"); save on `IsItemDeactivatedAfterEdit`/typed commit only, then status "Saved. Applies on your next tap."
- [ ] **Step 4:** Glide rate `BeginDisabled` in Instant mode with inline `TextDisabled("Used only in Glide mode")`.
- [ ] **Step 5:** Modals via the house modal recipe: Reset confirm (`L.modal_sm`, Cancel first, Esc=Cancel, copy deck text); Info (`L.modal_md`, tabs How it works · Gestures · About).
- [ ] **Step 6:** Esc per HC5 via `ImGui_Shortcut`; Space per HC6 (copy the forwarding recipe in `recipes.md`).
- [ ] **Step 7:** `luacheck .` clean.
- [ ] **Step 8: Live check** (protocol: sweep, screenshot): register the script in the Action list, open window → screenshot default; toggle Glide → rate enabled; change N to 3, tap 3× via bridge → tempo changes; Reset all → confirm → Cancel leaves values, Reset restores; dock it narrow → screenshot; switch theme mode → screenshot; close; sweep.
- [ ] **Step 9: Commit** `feat: Fancy Tap Tempo Slew Settings window`

### Task 3: Docs

**Files:** `CHANGELOG.md`

- [ ] **Step 1:** Add entries for the settings window and extend the unreleased tap action entry (group mode, settings read from ExtState).
- [ ] **Step 2:** `luacheck .`; commit `docs: changelog for tap tempo settings`.
