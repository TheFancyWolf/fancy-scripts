# Pitch Correct: System and Track Defaults (short design)

Approved by the user 2026-11-25 ("Build it!"), with one change: Restore Factory Defaults lives only in Settings.

## Intent

Different singers on different tracks need different starting values. The user wants to save an item's values as
the starting point for every new analysis (System Default) or for new analyses on one track (Track Default), so a
new take of the same singer starts right. This reverses the 2026-11-24 "Always defaults" decision in
`pitch-correct-value-levels.md` (new items started at the factory `DEFAULTS`, nothing saved).

## Approaches

- **Chosen: levels factory → system → track → item → note.** System in ExtState, Track on the track (`P_EXT`, in the
  project and its undo history). A new or re-analysed item starts at its track's default, else the system's, else the
  factory value. One function (`K.item_default(key, guid)`) answers "what is this item's default" everywhere the code
  used `DEFAULTS[key]` for item values.
- Rejected: presets picked by name (more UI, the user asked for per-track automatic start), and track defaults in
  ExtState keyed by track GUID (outside the project, lost when the project moves, not undoable).

## Design

- **Pill:** left-click or right-click opens its menu.
- **Pill menu:** `Edits go to: …` · Apply to other items… · separator · **Set as System Default…** ·
  **Set as Track Default** · **Clear Track Default** · separator · Reset this item to defaults.
  Disabled with the reason beside it: not analysed ("Analyze an item first"), during an analysis, already equal
  ("Already the system default" / "Already the track default"), no track default ("No track default").
- **Value right-click menu:** Reset · Apply X to other items… · **Set X as System Default…** · **Set X as Track
  Default**. (Mode has the same.) No Clear / Restore entries here.
- **Set as System Default…** saves ExtState (`pitch_def_<key>`), not undoable → a confirm (HC4) naming the values
  ("New analyses on tracks without a track default start with: Tolerance 12¢ (was 8¢)…"), Cancel first.
- **Set as Track Default** writes JSON on the track (`P_EXT:fancy_pitch_track_defaults`, only the keys set) in one
  undo block ("Set track default"), no confirm, status message. **Clear Track Default** removes it the same way.
- **Settings:** new section **Item Value Defaults**: a line of the system defaults in effect, and a
  **Restore Factory Defaults…** button (confirm; clears the `pitch_def_*` keys; disabled "Already at the factory
  defaults"). Track defaults are not touched there.
- **What follows the item's default:** a new analysis, Re-Analyze, Analyze Selected Items (each item its own track),
  the Separation shown for an item not analysed yet, double-click / right-click Reset, Reset this item to defaults,
  the `*` mark, the "differs" test of Apply's "Keep changes", and the value tooltip
  ("Default: 12¢ (track). This item: 14¢."; "(system)"; no tag for factory).
- Key and Scale are not part of any default. Items already analysed keep their values.
- Stored values are validated: finite numbers clamped to each control's range, Mode an integer 0–2; anything else
  is ignored (falls through to the next level).

## Left to the builder

Exact copy of reasons and status lines; caching of track defaults per project state (via `state.cache`).
