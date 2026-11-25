# Pitch Correct System and Track Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Item values start from a saved System Default (ExtState) or Track Default (track `P_EXT`) instead of only
the factory `DEFAULTS`; the pill opens on right-click too.

**Architecture:** One resolver `K.item_default(key, guid)` (track → system → factory) replaces every item-value use of
`DEFAULTS[key]`. System defaults live in `K.sys_defaults` (loaded at start, validated). Track defaults are parsed
from the track of the take and cached in `state.cache.trackdef` (dropped with the project cache).

**Tech Stack:** Lua 5.4, ReaScript, ReaImGui. Spec harness `docs/superpowers/tests/pitch_correct_spec.lua`.

**Spec:** `docs/design/pitch-correct-saved-defaults.md`

## Global Constraints

- ExtState section `FancyScripts`, keys `pitch_def_<key>` for each of `K.ITEM_KEYS`.
- Track `P_EXT:fancy_pitch_track_defaults` = JSON object of only the keys set.
- Key and Scale are never part of a default. Existing items are not changed by setting a default.
- Restore Factory Defaults only in Settings; no Clear/Restore entries in value right-click menus.
- Undo labels: "Set track default", "Set <Value> as track default", "Clear track default".

## Review Focus

- Malformed ExtState / track JSON (text, NaN, out of range, Mode 1.5) → ignored, falls through to the next level.
- Batch over items on different tracks → each item seeded from its own track.
- A per-value track default (only Tolerance) → other values fall to the system default.
- Undo of Set Track Default → cache refreshes (project state count) and the tooltip / `*` follow.
- Take with no track (gone) → system/factory default, no error.

---

### Task 1: Default levels model

**Files:** Modify `Pitch/Fancy_Pitch Correct.lua` (§ near `K.ITEM_KEYS`, `K.PERSIST` load); Test: spec file.

**Interfaces — Produces:**
- `K.item_value_valid(key, v) -> number|nil` (clamped; Mode integer 0–2).
- `K.sys_defaults` table `{ [key] = number }`; `K.sys_defaults_load()`, `K.sys_default_set(values)` (writes ExtState),
  `K.sys_defaults_clear()`.
- `K.track_defaults(track) -> table` (cached), `K.take_track(guid) -> track|nil`.
- `K.item_default(key, guid) -> value, level` with level `"track"|"system"|"factory"`.
- `K.new_item_values(guid)`, `K.item_seed(data)` (uses `data.guid`), `K.item_off_defaults(data)`,
  `K.item_reset_values(data)` all through `K.item_default`.

- [ ] Tests: `saved_defaults_levels` (factory, then system, then a track default with only tolerance),
  `saved_defaults_invalid_ignored`, `item_seed_uses_track_default`. Run spec → fail, implement, run → pass. Commit.

### Task 2: Route every item-default use through `K.item_default`

Sites: `get_effective`, `get_override_level`, `K.analysis_begin` separation, batch `K.batch_next`,
`K.adopt_new_item_values`, `K.reset_target`, Apply Keep "differs", value tooltips (`BAR_LEVELS` gets the level tag),
Mode/Separation drawing resets. Test: `reset_target_goes_to_track_default`. Commit.

### Task 3: Menus, pill right-click, Settings section

- Pill: `Theme.badge` click or `IsItemClicked(1)` opens the menu.
- Pill menu entries and value right-click entries per spec; `K.set_track_default(keys)`, `K.clear_track_default()`
  (one undo block each), `K.sys_default_request(keys)` (confirm request, as `K.form_defaults_request`).
- Settings: "Item Value Defaults" section with the values line and "Restore Factory Defaults…" (confirm).
- Test: `set_track_default_one_undo`, `sys_default_request_saves_on_confirm`. Commit.

### Task 4: Lint, changelog, version bump, real-REAPER check.
