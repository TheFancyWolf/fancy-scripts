# Lens: REAPER runtime behaviour (rules RT1–RT7)

You think like REAPER and like a user in a real session: projects switching, undo being pressed,
the script being closed mid-action, 300-track sessions, macOS and Windows.

## Method

Trace the life cycle of the changed code: start → each `defer` tick → each user action → close
(`atexit`). For each project-modifying action, write down the undo point it creates.

## Hunt list

- **Undo (RT1).** A project change outside `Undo_BeginBlock`/`Undo_EndBlock`. An undo block opened every frame. An `Undo_EndBlock` with a flag that doesn't match what changed (`-1` vs specific flags). Undo points that are empty or one per drag tick (use `PreventUIRefresh` and commit on release). Writes to ExtState that the user would expect to undo.
- **Defer life cycle (RT2).** `atexit` missing, or not clearing toolbar toggle state (`SetToggleCommandState` + `RefreshToolbar2`). The loop keeps running after the window is closed. Re-entrancy (the script is launched again while already running) is not handled.
- **Cost (RT3).** Per-frame loops over all tracks, items or FX, chunk reads (`GetTrackStateChunk`) or string building without caching on `GetProjectStateChangeCount` or a throttle. `ShowConsoleMsg` in the loop.
- **Projects (RT4).** State cached from project tab A and used in tab B. `EnumProjects(-1)` never re-checked. Behaviour when the project closes.
- **Persistence (RT5).** ExtState keys not namespaced. `SetExtState(..., true)` writing every frame (that's a disk write). JSON decode without `pcall`. No defaults or migration for older saved data.
- **Errors (RT6).** An error between Begin and End blocks or Push and Pop leaves state broken. A partially applied multi-track edit that doesn't roll back.
- **Platform (RT7).** `/` vs `\` in paths, `Mod_Ctrl` vs `Mod_Super` on macOS, `os.execute`/`io.popen` with platform-specific commands.

Most of this lens can't be fully proven from code alone. When the answer depends on live REAPER,
report the finding with `"needs_live": true` and give the exact steps a person would take in REAPER to see it.
