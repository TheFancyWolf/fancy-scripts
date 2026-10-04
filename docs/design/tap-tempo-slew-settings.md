# Design: Fancy Tap Tempo Slew Settings

Target file(s): `Transport/Fancy_Tap Tempo Slew Settings.lua` (new), `Transport/Fancy_Tap Tempo Slew.lua` (reads the settings; new "Once per group" behaviour)
Archetype(s): settings window → Settings hub / workbench; Info modal and Reset-all confirm → modals of that hub
Status: Approved
Date: 2026-10-03
Approver: TheFancyWolf (in chat)

## Summary

A small floating settings window for the tap tempo action, opened from its own action and used at setup, not during playback. It exposes the values that live in the tap script's `CONFIG` table today, plus one new choice: after the first tempo change, update the tempo on every tap (rolling) or once per group of N taps. Settings save on change to ExtState and apply on the next tap. The primary display is a one-line summary of what tapping will do; there is no primary action (save-on-change), so AR5 is n/a.

## Feature inventory

| Feature / action | REAPER state read | REAPER state written | Persistence (ExtState / JSON / file / none) | One Ctrl/Cmd+Z fully restores it incl. script state (Y/N, why) |
|---|---|---|---|---|
| Change mode: Instant / Glide | none | none | ExtState `FancyTapTempoSlew` persisted | N: ExtState is never undoable (UC3) |
| Glide rate (BPM/s) | none | none | ExtState | N: as above |
| Taps per change (N) | none | none | ExtState | N: as above |
| Update after the first change: every tap / once per N taps (new) | none | none | ExtState | N: as above |
| Restart after gap (s) | none | none | ExtState | N: as above |
| Minimum / maximum BPM | none | none | ExtState | N: as above |
| Reset one value (double-click) | none | none | ExtState | N: one visible value, retyped in one gesture; no confirm (see HC4 below) |
| Reset all | none | none | ExtState cleared to `DEFAULTS` | N: changes several values → confirm modal (HC4) |
| Theme mode, tooltips (shared widgets) | ExtState `FancyScripts` | ExtState `FancyScripts` | ExtState (shared with all Fancy scripts) | N: existing shared widgets |
| Tap action (unchanged entry point) reads the settings on every press | settings ExtState | tempo marker / project tempo | runtime taps in non-persistent ExtState | Y: one undo point "Tap tempo" per change |

The tap action terminates and relaunches on every press, so it cannot host a window; the settings are a separate script. `DEFAULTS` moves into a shared place both scripts read (see Open questions).

## References

- Native REAPER analogues: Preferences pages and the Project Settings tempo field (label column on the left, value on the right, units in the field). Conventions to match (CN6): BPM shown to 2 decimals with "BPM"; seconds as "s"; right-click context menus; Ctrl/Cmd-drag fine; Alt and Shift not repurposed. No dB, pan or time-position values in this UI.
- Redesign baseline: n/a (new window; the tap action is headless today).

## Context and job stories

Confirmed at 2b: small floating window, set at setup, rarely, not during playback; mouse with occasional typed values.

1. When I prepare a gig, I want to choose Instant or Glide and how many taps make a change, so tapping behaves the way I expect on stage.
2. When I tap through a whole song, I want the tempo to change only once per group of taps, so the project does not fill with tempo markers and each group can correct the drift on its own.
3. When my taps are sloppy, I want to set the restart gap and the BPM limits, so one stray hit cannot send the tempo to an absurd value.
4. When the band drifts mid-song, I tap my MIDI pad (the tap action, not this window), so the click follows the drummer at once. The window is closed during playback.

## Priority tiers

| Tier | Features | Why (frequency × importance) |
|---|---|---|
| 1 always visible | Change mode (+ glide rate), Taps per change, Update after the first change | Decide how every tap behaves |
| 2 one disclosure away | Limits section: restart gap, min BPM, max BPM | Set once, rarely revisited; visible below Tier 1 in the same window, collapsible |
| 3 Settings | Appearance (theme mode, tooltips) | Shared across Fancy scripts |

## Information architecture

Regions, top to bottom: header ("TAP TEMPO", right widget: Info) → summary line (primary display) → **Tapping** section (Tier 1) → **Limits** collapsing section (Tier 2) → **Appearance** collapsing section (Tier 3) → footer: status line (left) and "Reset all…" (right). Primary display: the summary line. Primary action: none; values save on change (HI4). Disclosure: one level (collapsing sections), within IA2.

## Wireframes

Default floating (`L.modal_sm` width, `Cond_FirstUseEver`):
```
┌ FANCY TAP TEMPO ─────────────────────── [Info] ┐
│ Instant change after 4 taps, then once per     │
│ group of 4. Tempo range 30–300 BPM.            │
│── TAPPING ─────────────────────────────────────│
│ Change           [ Instant ][ Glide ]          │
│ Glide rate       [ 10.0 BPM/s       ] ↺        │
│                  Used only in Glide mode       │
│ Taps per change  [ 4                ] ↺        │
│ After the first  [ Once per 4 taps     ▾]      │
│   change                                       │
│▸ LIMITS                                        │
│▸ APPEARANCE                                    │
│ Saved. Applies on your next tap.  [Reset all…] │
└────────────────────────────────────────────────┘
```
Limits expanded:
```
│▾ LIMITS                                        │
│ Restart after    [ 2.0 s            ] ↺        │
│ Minimum tempo    [ 30.00 BPM        ] ↺        │
│ Maximum tempo    [ 300.00 BPM       ] ↺        │
```
Narrow docker (~260 px): the label column shrinks to its longest label; "After the first change" wraps to two lines; fields take the remaining width; the summary wraps to 3–4 lines; status and "Reset all…" stack (status above, button right-aligned). Nothing hides.
Wide short strip (~1200×150): the summary stays one line; the Tapping section scrolls vertically (window scrolls, so no wheel adjust, EF1); sections stay collapsed by default.

## State inventory

| Region | State | What the user sees | Rule |
|---|---|---|---|
| Summary | empty | n/a: always has values (defaults) | ST6 |
| Window | working | n/a: every change is instant (< 0.1 s) | ST3 |
| Window | error | Saved settings unreadable (non-numeric ExtState) → values fall back to defaults and the status line says "Some saved settings were invalid and were reset to defaults." | ST7 |
| Glide rate | disabled with reason | Disabled in Instant mode; inline reason under it: "Used only in Glide mode" | EP2, EP5 |
| Min / max tempo | disabled with reason | n/a: each is clamped against the other (min ≤ max − 1), never disabled | EP3 |
| Labels | overflow / long names | Labels are short fixed strings; "After the first change" wraps at narrow width | LG4 |
| Window | missing dependency | ReaImGui missing → the house dependency message box (AGENTS.md) | HI7 |
| All | Fancy Dark / Match Theme | Only palette tokens; checked in both modes | CL4 |
| Summary | data honesty | Summary always reflects the saved values, including Glide ("Glides at 10 BPM/s to the average of 4 taps…") | ST4 |

## Interaction spec

| Control | Gestures (HC2, HC3, wheel EF1, context menu) | Default | Units / format / precision (RC2, CN6) | Clamp / scale (EP3) | Undo label (UC1) | Destructive policy (HC4) |
|---|---|---|---|---|---|---|
| Change: Instant / Glide | click; n/a HC2/HC3: discrete | Instant | — | discrete pair | none (ExtState) | none |
| Glide rate | Drag (NoInput, NoSpeedTweaks); Ctrl/Cmd-drag fine; double-click → default; Ctrl/Cmd-click → type; right-click → "Reset to default"; no wheel (window scrolls) | 10 | `%.1f BPM/s` | 0.5–100, AlwaysClamp, linear | none | none |
| Taps per change | same gestures (DragInt) | 4 | integer, "taps" in label | 2–16, AlwaysClamp | none | none |
| After the first change | combo; n/a HC2/HC3: discrete | Once per N taps | items: "Every tap (rolling average)", "Once per N taps" (N filled in live) | discrete | none | none |
| Restart after | same as Glide rate | 2.0 | `%.1f s` | 0.5–10, AlwaysClamp | none | none |
| Minimum tempo | same | 30 | `%.2f BPM` | 20 – (max − 1) | none | none |
| Maximum tempo | same | 300 | `%.2f BPM` | (min + 1) – 960 | none | none |
| Reset all… | click → confirm modal | — | — | — | none | Confirm: "Reset all 6 tap tempo settings to their defaults? This cannot be undone." Buttons: Cancel (first, default), Reset. Esc = Cancel |
| Info | click → Info modal (tabs: How it works · Gestures · About) | — | — | — | — | — |

Values persist on release or typed commit, never per frame (HI4). The status line confirms each save (ST2).

Keyboard map: Esc (HC5): open popup/modal closes first → active drag/type reverts → window closes only when floating (routed through `ImGui_Shortcut`). Space (HC6): forwarded to the user's Main-section Space command when no text field is active and no modal is open. No other shortcuts; all gestures listed in Info → Gestures (HP1).

## Copy deck

| Where | String |
|---|---|
| labels | "Change", "Instant", "Glide", "Glide rate", "Taps per change", "After the first change", "Restart after", "Minimum tempo", "Maximum tempo", "Reset all…", "Info", sections "TAPPING", "LIMITS", "APPEARANCE" |
| combo items | "Every tap (rolling average)", "Once per {N} taps" |
| tooltips | Instant: "The new tempo starts at the play position at once. Adds a tempo marker there." · Glide: "Moves the tempo toward the tapped value at the glide rate. Changes the tempo in effect, which can cause audible skips." · Taps per change: "How many taps make one tempo change." · After the first change: "Every tap: each new tap updates the tempo from your last {N} taps. Once per {N} taps: each new group of {N} taps makes one change." · Restart after: "A pause longer than this starts a new count from tap 1." · Min/Max: "Tapped tempos are kept inside this range." |
| summary (Instant, groups) | "Instant change after {N} taps, then once per group of {N}. Tempo range {min}–{max} BPM." |
| summary (Instant, rolling) | "Instant change after {N} taps, then on every tap. Tempo range {min}–{max} BPM." |
| summary (Glide) | "Glides at {rate} BPM/s after {N} taps, then {once per group of {N} / on every tap}. Tempo range {min}–{max} BPM." |
| disabled reason | "Used only in Glide mode" |
| confirm | title "Reset tap tempo settings"; body "Reset all 6 tap tempo settings to their defaults? This cannot be undone."; buttons "Cancel", "Reset" |
| status messages | "Saved. Applies on your next tap." · "Settings reset to defaults." · "Some saved settings were invalid and were reset to defaults." |
| undo labels | none in this window; the tap action keeps "Tap tempo" |
| close tooltip | floating: "Close (Esc)"; docked: "Close" |

## Theme mapping

| Element | `Theme.*` helper | Tokens (keys only) |
|---|---|---|
| Header | `Theme.header` (`title`, `fonts`, `right_widgets`, `show_close`, `close_tooltip`) | `L.row_h` |
| Info button | `reaper.ImGui_Button` with `###info` inside `right_widgets`, `Theme.align` | `L.btn_default` |
| Summary line | `reaper.ImGui_TextWrapped` | `P.text_dim` |
| Section headers | `Theme.section_divider` (Tapping), `Theme.collapsing_header` (Limits, Appearance) | `L.section_gap`, `L.lg` |
| Instant / Glide | `Theme.toggle_button` ×2 | `L.sm` |
| Numeric fields | `reaper.ImGui_DragDouble` / `DragInt` per the HC2/HC3 recipe, local `param_drag` helper (as Mapper Settings does) | `L.md` |
| Reset glyph ↺ per row | omitted: double-click and right-click "Reset to default" cover HC3; no glyph helper exists | — |
| After the first change | `Theme.combo` | — |
| Disabled reason | `reaper.ImGui_TextDisabled` under the control | `P.text_dim` |
| Form rows | local row helper: label column width = widest label (`CalcTextSize`) + `L.lg` (LG3), as Mapper Settings `UI.label_w` | `L.lg` |
| Appearance | `Theme.settings_widget`, `Theme.tooltip_setting_widget` | — |
| Status line | `reaper.ImGui_TextColored` | `P.text_dim` |
| Reset all… | `reaper.ImGui_Button` `###reset_all`, `Theme.right_align` | `L.btn_default` |
| Confirm / Info modals | modal recipe: `Theme.center_next_window` + `Theme.modal_scrim` + `BeginPopupModal` | `L.modal_sm` (confirm), `L.modal_md` (Info) |
| Window | `Cond_FirstUseEver` size | `L.modal_sm.w` (default width) |

The ↺ in the wireframe stands for the reset gesture, not a drawn glyph.

## Library proposals

- `L.win_min` (minimum window size for settings hubs) · there is no minimum-size token (house-patterns: Window size) · every settings hub.
- `Theme.form_row(ctx, label, label_w, draw_fn)` and `Theme.param_control(ctx, id, value, spec)` · already on the house list of proposals; this script uses local helpers until they exist.

## Acceptance criteria

- ST1: mode, N and update rule visible at rest in the summary and the Tapping section.
- ST2: every save and reset confirms in the status line; no silent returns.
- ST3: n/a: no work over 0.1 s.
- ST4: summary text is built from the saved values.
- ST5: n/a: closing the window stops nothing; the tap action works without it (said in Info → How it works).
- ST6: n/a: no empty region.
- ST7: invalid saved values → defaults + status message.
- UC1: no undo points in this window (ExtState only); the tap action keeps one "Tap tempo" point per change and none when nothing changes.
- UC2/HC5: Esc order as in the keyboard map.
- UC3: settings are ExtState and not undoable; stated in the Reset-all confirm.
- UC4: no selection changes.
- UC5/HC3: double-click and right-click reset per value; Reset all with confirm.
- EP1/HC4: Reset all confirms (consequence + count, Cancel first, Esc = Cancel); single-value reset needs no confirm (one visible value, re-entered in one gesture).
- EP2: Glide rate disabled with inline reason in Instant mode.
- EP3: AlwaysClamp on every value; min/max clamp against each other; linear scales.
- EP4: n/a: no tracks, takes or FX referenced.
- EP5: Glide rate disabled, never hidden.
- EP6: no keyboard shortcuts beyond Esc/Space; both via `Shortcut()`.
- CN1–CN3: only `Theme.*` helpers and existing tokens; no literals.
- CN4: one term per concept ("tap", "change", "group").
- CN5: Info and CHANGELOG match the handlers.
- CN6: BPM/s, BPM and s shown; Ctrl/Cmd-drag fine; Alt/Shift untouched.
- RC1: no icon-only controls besides the header close (tooltip).
- RC2: units in every field; no API names.
- HP1: Info → Gestures lists drag, Ctrl/Cmd-drag, double-click, Ctrl/Cmd-click, right-click, Esc, Space.
- EF1: no wheel adjust (window scrolls); context menus present.
- EF2/HC6: Space forwarded.
- IA1–IA3: tiers as listed; one disclosure level; summary is the primary display; ≤ 3 type sizes.
- IA4: no dead settings (every value is read by the tap action).
- LG1–LG4: section gaps ≥ 2× row gaps; `Theme.align` before row labels; widths from content; works at ~260 px and in a wide strip.
- MT1: buttons at `L.btn_default` or larger.
- MT2: n/a: no custom DrawList controls.
- CL1–CL4: palette tokens only; no colour-only state (the active toggle also changes text); checked in both theme modes.
- HI1/HI2: lifecycle per RB1; `Cond_FirstUseEver`; fixed context label.
- HI3: n/a: no toolbar toggle.
- HI4: saved on release/commit only.
- HI5: no per-frame enumeration; ExtState read once at start.
- HI6: dynamic labels ("Once per {N} taps", status) use `###` IDs.
- HI7: ReaImGui dependency check at the top.
- AR1: one `DEFAULTS` table shared by both scripts.
- AR2: label column + control + reset gesture, aligned.
- AR5: n/a: no primary CTA (save on change).

## Open questions / assumptions

- **Shared defaults.** Both scripts need the same `DEFAULTS`. Assumption: put them in a small `_lib/tap_tempo_settings.lua` (load + save + defaults) that both scripts `require`, so the tap action keeps its `CONFIG` meaning without duplication. Adding `[nomain] ../_lib/*.lua` to the tap action's `@provides` follows.
- **"Once per N taps" behaviour.** Confirmed: taps 1–N make one change, then the count starts again; each change uses only that group's taps. The restart gap still resets the count mid-group.
- **Glide mode with markers.** Glide still edits the tempo in effect (no marker), so it can skip; the Glide tooltip says so. Not changed by this design.
- **Headless feedback.** The tap action gives no visible feedback per tap (tap count, "waiting for 4 taps"). The headless archetype asks for feedback on every path; adding it is a separate decision, not part of this window.
- HC6 conflicts: None.
