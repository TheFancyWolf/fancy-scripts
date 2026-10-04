# Changelog

All notable changes to Fancy Scripts will be documented here.

## [Unreleased]

- **Fancy Tap Tempo Slew v1.0.0 (`Transport/Fancy_Tap Tempo Slew.lua`, `Transport/Fancy_Tap Tempo Slew Stop.lua`, `Transport/Fancy_Tap Tempo Slew Settings.lua`, `_lib/tap_tempo_settings.lua`)** — New scripts for following a live player:
  - **Tap action**: after a set number of taps (default 4) the tempo changes to their average. Instant mode (default) inserts a tempo marker at the play position, so what has already played keeps its timing and sounding notes are not cut and retriggered. Glide mode moves the tempo in effect toward the tapped value at a set rate. After the first change, the tempo updates once per group of taps (default) or on every tap (rolling average). A pause longer than the restart gap (default 2 s) starts a new count. Each press replaces a running glide without a prompt; one undo point per change.
  - **Stop action**: stops a glide where it is and clears the tap count.
  - **Settings window**: change mode, glide rate, taps per change, group or rolling updates, restart gap and tempo range. Changes save at once and apply on the next tap; a summary line describes what tapping will do; Reset all asks first. Settings are shared through `_lib/tap_tempo_settings.lua`.

- **Fancy Pitch Correct v2.5.0 (`Pitch/Fancy_Pitch Correct.lua`)** — UX review: safer edits, clearer interface:
  - **Undo and data safety**: the editor follows Cmd/Ctrl+Z and Redo (the note model is saved inside the same undo point as the pitch envelope); Re-Analyze, Reset all, Clear, Remove and Wipe ask before discarding edits; Wipe and Remove no longer reset a take's own pitch and Wipe is one undo step; re-analysis no longer leaves a stale envelope; holding an arrow key to nudge is one undo step; the note-menu sliders now apply their changes.
  - **Keyboard and input**: Esc closes the innermost popup or dialog, then deselects, then closes a floating window (never a docked one); Space and its Shift/Ctrl/Alt chords run the action bound in REAPER; shortcuts need exact modifiers and ignore open menus; Cmd/Ctrl-drag is fine adjust; value controls are drag widgets with fine adjust, double-click reset, Cmd/Ctrl-click typing and clamping; Block and Hop size are lists.
  - **Canvas**: timeline zoom (Cmd/Ctrl+wheel), scroll and a time ruler; the pitch scale stays fixed while dragging; higher-contrast labels, notes and handles; messages for "no pitched notes", bypassed items and too-short windows; distinct marker shapes and an edited-note mark in addition to colour; cursors and tooltips follow the zone under the pointer.
  - **Layout**: responsive header (down to about 260 px), a wrapping dock with state-aware hints and Snap / Quantize / Split / Merge buttons, a resizable Pitched Items panel that collapses in narrow windows, larger destructive targets, a first-use window wide enough for the full header.
  - **Settings and help**: form layout with per-setting and per-section Reset, "Custom" preset names, units shown, settings and layer toggles kept between sessions, a locked state while analyzing; the Info modal documents every gesture; consistent terms (Pitched Items, Correction Strength, Onset Ramp, Legato Gap).
  - **Reliability**: analysis can be cancelled and works in small time slices; an error shows an in-window message with Retry instead of the window disappearing; actions that do nothing say why; fewer per-frame lookups (cached project queries, reused buffers, list clipping); unreadable saved data is reported with a Clear action; the toolbar button reflects the running state.
  - **Theme**: the piano-roll colours now come from the shared theme (`P.canvas`), so the canvas follows Match Theme.

- **Design system (`_lib/theme.lua`)** — Shared canvas palette and widget polish: new `P.canvas` colour group (68 tokens; Fancy Dark equals the previous piano-roll colours, Match Theme derives legible colours from the REAPER theme), `Theme.layout.icon_target` (24 px target), tooltips in theme widgets respect the Show Tooltips preference and also appear on disabled items, icon buttons show the hand cursor, `Theme.badge` and `Theme.toggle_button` ids no longer change with their label, `Theme.selectable` clips labels that are too long. Contrast: dim text is lighter (`text_dim`), every frame (buttons, inputs, checkboxes, combos) now has a 1 px border in a lighter `border` colour so unchecked boxes and input boundaries are visible, and pressed buttons use a darker accent (`accent_press`); `Theme.push` now pushes one more style variable (`FrameBorderSize`), and Match Theme derives the same colours through the contrast fit. Visible in every script that uses the theme.

- **Fancy Design System v1.3.1 (`Utility/Fancy_Design System.lua`)** — Shows the canvas palette (`P.canvas`) and the `icon_target` preset.

- **Fancy Mapper Settings Reorganization v5.2.0 (`Mixing/Fancy_Mapper Settings.lua`, `_lib/mapper_engine.lua`)**:
  - **One Mode Panel**: A single "Configure Mode" dropdown shows only the selected mode's settings and its six button actions, replacing the per-mode sections and the separate Button Actions section. It opens on the dial's live mode and follows it while you're viewing it; a "Current" chip jumps back to it.
  - **Guided Calibration**: "Calibrate…" next to Ticks per Rotation opens a dialog that counts ticks from the normal dial actions while it's open, so the dial no longer has to be rebound to `Calibrate Tick` (which still works). Either direction counts, turning back corrects an overshoot, and Apply writes the result.
  - **Action Ring Mode Chips**: Toggle exactly which modes appear in the ring (minimum 3, canonical clockwise order). The Curated 8 / All 11 presets light up when they match.
  - **Per-Mode Smoothing**: Each smoothable mode has its own Smooth toggle in its panel; the Smooth Dial section keeps the engine controls, preset chips that show the active speed, and a summary of smoothed modes.
  - **Feedback Settings in General**: The value HUD toggle (previously under MIDI CC, though it applies to every mode) and the Sensitivity Up/Down toast settings now live in General; the standalone Toast and Calibrate sections are gone.
  - **Fixes**: Reset All now restores MIDI channel, auto-arm, value HUD, and velocity audition, and writes each default explicitly instead of relying on clearing the whole ExtState section; the reset dialog now dims the window behind it; values changed by Sensitivity Up/Down update live while Settings is open; long button action names no longer overlap the pick/clear controls.

- **Fancy Mapper Universal Smooth Dial & Analog Slew Daemon v5.2.0 (`Mixing/Fancy_Mapper Daemon.lua`, `_lib/mapper_engine.lua`, `Mixing/Fancy_Mapper Settings.lua`)**:
  - **Universal Smooth Dial (Producer-Consumer Slew Engine)**: Offloads discrete notched encoder clicks into continuous 60 Hz exponential slew interpolation (`1.0 - math.exp(-speed * dt)`), giving rotary dials the weighted feel of high-end analog potentiometers across continuous parameters: Volume, Pan, Width, FX Parameters, MIDI CC, Timeline Scrub, and Item Slip.
  - **Zero ReaScript Task Control Prompts**: Keeps dial actions (`Up.lua` and `Down.lua`) 100% synchronous (<0.05ms execution) by accumulating floating-point targets in ExtState and delegating all deferred interpolation to a dedicated standalone consumer daemon (`Fancy_Mapper Daemon.lua`).
  - **Option A (Lazy / Auto-Sleep Daemon)**: The background daemon auto-wakes seamlessly when turning the dial, executes 60 Hz interpolation during parameter movement, and auto-sleeps after 10 seconds of idle dial activity (0% CPU when not actively mixing).
  - **Single-Point Clean Undo**: Dial movements no longer pollute REAPER's undo history with per-frame or empty steps; a single consolidated undo point is recorded when parameter slewing settles to its target.
  - **Comprehensive Settings Hub Card**: Dedicated "Smooth Dial (Analog Slew Engine)" card in `Fancy_Mapper Settings.lua` with a live daemon status badge (`● Active (60 Hz)` / `○ Standby`), manual wake/stop button, master toggle, slew responsiveness slider (5 to 80 /s) with presets (Tape 12, Balanced 25, Snappy 45), and individual toggles for each continuous mode.
  - **Context-Aware Reset Synchronization**: Resetting any parameter via `Fancy_Mapper Reset Parameter.lua` immediately clears active slew targets in ExtState, preventing interpolation fighting on reset.
  - **Action Ring Settings Default to Off for New Users**: Directional Flick, Dwell Hover Selection, and Inactivity Auto-Close now all default to `false` out of the box, ensuring the radial ring remains open, stable, and predictable for new users until a mode is clicked or dismissed, while remaining fully customizable in Settings.

- **Fancy Mapper Linear CC Curves & 1-Click Smoothing v5.2.0 (`_lib/mapper_engine.lua`, `Mixing/Fancy_Mapper Settings.lua`, `Mixing/Fancy_Mapper Smooth CC.lua`)**:
  - **Zero Background Overhead (100% Synchronous)**: Dial movements run instantly with zero background defer tasks, completely eliminating REAPER's "ReaScript task control" prompt when turning the rotary encoder rapidly.
  - **CC Lane Linearization (`shape = 1`)**: Sets MIDI CC curves to Linear ramps instead of REAPER's default Square hold steps, connecting recorded points with smooth vector lines and enabling continuous audio-rate interpolation during playback.
  - **Active MIDI Editor Integration**: Automatically sets REAPER's active MIDI Editor default CC curve shape to Linear via Action 42087.
  - **1-Click Smoothing Tool (`Fancy_Mapper Smooth CC.lua`)**: Standalone action and dedicated button in Settings hub ("Smooth Active Take CC Lane") to instantly convert any existing take's stepped CC events into smooth linear curves.
  - **Selection-Aware Smoothing**: If CC events are selected, only selected points are smoothed; if none are selected, the entire take's CC lane is linearized.
  - **Smart Take Resolution**: Intelligently locates target takes from active MIDI editors, items under cursor, selected items, or items on the armed track.

- **Fancy Mapper Suite v5.1.0 (`Mixing/Fancy_Mapper *.lua`, `_lib/mapper_engine.lua`)** — Expanded Mode Suite & Shared Core Engine:
  - **Shared Core Engine (`_lib/mapper_engine.lua`)**: Replaced 500+ lines of duplicate code between `Fancy_Mapper Up.lua` and `Fancy_Mapper Down.lua` with a unified engine handling configuration, throttling, mode detection, context targeting (including focused FX detection), undo management, and contextual resets.
  - **Width Mode**: Nudges stereo width of track under cursor, focused FX track, or selected track. Automatically promotes track pan mode to Stereo Pan (`I_PANMODE = 5`) if track was in default or balance mode, and repaints TCP/MCP windows immediately so width knobs are visible and active.
  - **Live Multi-CC Mode**: Sends real-time MIDI signals via REAPER's Virtual MIDI Keyboard queue (`StuffMIDIMessage`) and Control Path simultaneously, allowing live real-time control of virtual instruments (e.g. CC 1 Modulation + CC 11 Expression for orchestral libraries like Pocket Strings) while playing or recording. Automatically arms and monitors target tracks. Also supports nudging selected CC events in active MIDI takes.
  - **Live Velocity Mode**: Dynamically manages live note velocity across sessions and updates `default_note_vel` in active MIDI editors for instant writing, with optional audition note preview. Also nudges selected note velocities in takes.
  - **Real-Time HUD Tooltips**: Floating on-screen HUD near cursor shows real-time values for MIDI CC, Velocity, Width, Pan, and Volume as dials turn.
  - **Track Navigation Mode**: Clockwise / counter-clockwise dial turns navigate up/down tracks in project, with automatic TCP scrolling.
  - **Marker Jump Mode**: Dial jumps edit cursor to next / previous marker or region.
  - **Transient Jump Mode**: Dial jumps edit cursor to next / previous transient in selected audio items.
  - **Item Slip Mode**: Slips audio content inside item boundaries via take start offset (`D_STARTOFFS`), leaving item position and length intact.
  - **Context-Aware Reset (`Fancy_Mapper Reset Parameter.lua`)**: Resets last-touched FX parameter (FX mode), centers pan (Pan mode), 0 dB (Volume mode), 100% stereo (Width mode), 96 velocity (Velocity mode), 0/64 CC (MIDI CC mode), and 0s offset (Item Slip mode).
  - **Extended Sensitivity Up/Down**: Sensitivity scaling added for Volume, Width, MIDI CC, Velocity, and Item Slip.
  - **Dynamic Action Ring (`Fancy_Mapper Cycle Mode.lua`)**: Radial ring mathematically adapts to any number of active modes (8 curated default modes or all 11 modes). Removed placeholder tags; cut Send mode.
  - **Settings Hub Enhancements (`Fancy_Mapper Settings.lua`)**: Added dedicated configuration sections for Width, MIDI CC (with preset quick-buttons for Mod, Expr, Mod+Expr, Vol), Velocity, Navigation & Editing, Ring Presets, and multi-mode button action mapping.


- **Fancy Mapper Cycle Mode v5.0.0 (`Mixing/Fancy_Mapper Cycle Mode.lua`)** — Radial Action Ring (Directional Gesture):
  - **Directional Flick Selection**: Hands-free mode switching without clicking or holding buttons. Move your mouse outward in the direction of the mode to select it immediately.
  - **Dwell Selection**: Resting the cursor in an active sector for 350ms (configurable) automatically confirms that mode.
  - **Full Input Flexibility**: Left-clicking an active sector or tapping the shortcut button a second time also confirms instantly.
  - **Clean Codebase**: Completely removed all legacy hold-and-release polling hacks, modifier state masks, and synthetic key detection loops.
  - **Pixel-Accurate Cursor Centering**: Centered around the mouse cursor via `PointConvertNative`.
  - **Center Dead Zone**: Moving into or clicking the center dead zone cancels with zero mode change and dynamic "Cancel" feedback.
  - **8-Mode Radial Roster**: 4 active modes (Scrub, FX Parameter, Pan, Volume) and 4 placeholder slots (Send, Width, MIDI CC, Velocity) marked with `soon` badges.
  - **Integrated Volume Mode**: Added Volume mode handling to `Fancy_Mapper Up.lua`, `Fancy_Mapper Down.lua`, and `Fancy_Mapper Settings.lua`.
  - **Action Ring Configuration in Settings**: Exposed Directional Flick toggle & threshold distance, Dwell Hover toggle & duration, and Auto-Close inactivity timeout in `Fancy_Mapper Settings.lua`.

- **Fancy Mapper v3.0.0 (`Mixing/Fancy_Mapper *.lua`)** — Settings Hub, Context Buttons, Scrub Mode:
  - **Fancy Mapper Settings** (NEW): Centralized ReaImGui settings hub — configure calibration, modes, scrub behavior, sensitivity, button actions, toast appearance, and more. No more editing script files.
  - **Mode-Aware Context Buttons** (NEW): Six assignable button scripts (`Button 1–6`) whose actions change based on the current dial mode. Configure any REAPER action per button × mode slot using REAPER's built-in Action List picker (`PromptForAction`). Enable/disable buttons individually.
  - **Scrub Mode** (default): Silent timeline jog via `MoveEditCursor`/`SetEditCurPos`. Four scrub units — Free (smooth by time), Grid (SWS `BR_GetNextGridDivision`), Beat (action-based), Measure (action-based). Configurable speed and view scrolling.
  - **FX Parameter Mode**: Migrated from deprecated `GetLastTouchedFX()` to modern `GetTouchedOrFocusedFX(0)`. Removed FX window focus gate — any touched parameter works regardless of window focus. Added item/take FX support.
  - **Pan Mode**: Adjusts pan on track under mouse cursor with selected-track fallback. Configurable sensitivity.
  - **Mode-Switch Toast**: Self-terminating ImGui overlay (configurable position, duration, enable/disable) replaces console output. Fades out gracefully, handles rapid presses via timestamp deduplication.
  - **Controller-Agnostic Design**: Removed all Logitech MX Creative Console references. Works with any hardware dial, rotary encoder, or MIDI controller.
  - **Settings-Driven Config**: All hardcoded values (ticks per rotation, throttle, step sizes, sensitivities) moved to ExtState, managed by the Settings app.
  - **Calibration Absorbed**: Standalone Calibrate window removed; calibration integrated into Settings with header shortcut button.
  - **Volume Scripts**: Now read step size and throttle from ExtState.

- **Fancy Pitch Correct v2.4.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Production UX Modern Studio Dock Layout:
  - Unified Single Top Bar: Consolidated title, settings, info, close, take badge, musical key, scale, analyze, and reset onto a single high-efficiency row, maximizing vertical canvas real estate
  - Track Color Matching: Target take badge background dynamically retrieves and displays the active track's REAPER color via `GetTrackColor()` and `Theme.bgr_to_rgba()`, with automatic luminance contrast adjustment for text
  - Eliminated Dead Vertical Spacing: Removed redundant `NewLine` and `Spacing` calls between top toolbar and piano roll canvas, and between canvas and bottom footer, ensuring seamless edge-to-edge layout
  - Bottom Footer Sizing & No Cutoff: Refactored canvas height budgeting (`total_h = math.max(60, avail_h - footer_h)`) and dynamic button right-alignment, ensuring all footer controls and text fit completely without clipping in docked windows
  - Generous Button Widths: Widened Analyze (`96px`), Reset (`66px`), Layers (`80px`), Quantize (`98px`), Split (`74px`), Merge (`78px`), Reset (`80px`), and Select All (`86px`) buttons to comfortably fit all label variations
  - Text Wrapping in Pitched Items: Replaced raw text clipping with `ImGui_TextWrapped()` when the drawer is empty
  - ReaImGui & REAPER Docker Integration: Enabled `ImGui_ConfigFlags_DockingEnable()` at context creation, restored native window title bar/dock tabs, and used `ImGui_Cond_Once()` for initial window centering so users can dock the window into any REAPER docker tab, drag between dockers, or float seamlessly
  - Redesigned Active/Bypassed State: Removed toolbar bypass toggle; added REAPER FX chain-style checkboxes to the left of each item in the Pitched Items drawer; rendered a dimmed canvas with a centered "BYPASSED" overlay badge when inactive
  - Collapsible Drawer Tag: Replaced top toolbar button with an edge tab tag button (`◀`) on the canvas boundary when the drawer is closed
  - Full-Width Item Selection Bar: Active item highlight bar now spans across the entire row encompassing checkbox, name, and delete button; removed obsolete `>` arrow marker
  - Centered Empty Canvas State: Centered "No data. Select an item and click Analyze." with a large "Analyze Item" button centered above it
  - Full Session Wipe: Added "Wipe Entire Session (All Items)" button to Settings modal to completely clear take envelopes, chunks, and metadata across all items
  - High-Contrast Text: Ensured 100% white (`0xFFFFFFFF`) text on all dropdowns, buttons, and badges for perfect legibility across all theme modes
  - Toolbar Streamlining: Removed redundant "Apply to Take" button (live auto-commit writes to take envelope continuously)
  - Display Layers Popover: Replaced 7 sprawling checkboxes with a clean, space-efficient `Layers ▾` dropdown menu
  - Bottom Contextual Inspector Dock: Real-time badges for note pitch, in/out-of-scale status, drift stability %, vibrato %, transition ms, and tuning status, alongside right-aligned quick actions (Quantize, Split, Merge, Reset, Select All)
  - Audio Engine & Settings Modal: Dedicated modal dialog (`Theme.modal_scrim`) housing Vocal Range, Detection Strictness, Quality, REAPER Pitch Shift algorithm selector, Advanced DSP parameters, theme switcher, and onset diagnostic toggle
  - Keyboard Shortcuts & Help Modal: Interactive shortcut reference dialog accessible from the header info button
  - Design System Additions (`_lib/theme.lua`): Added vector `Theme.icons.gear`, `Theme.icons.tri_left`, and `Theme.icons.tri_right` primitives

- **Fancy Pitch Correct v2.3.0 (`Pitch/Fancy_Pitch Correct.lua`)** — High-Fidelity Note Blending, Stability & Vibrato Engine:
  - S-Curve Note Blending: Seamless smoothstep Hermite transitions ($3t^2 - 2t^3$, 35ms default) across all note boundaries, including transitions to/from untouched notes and silence onsets, eliminating 1ms cliff artifacts and phase vocoder chirps
  - True Stability Drift Correction: Samples the continuous drift cancellation trajectory ($E_{\text{drift}}(t) = (\text{center} - \text{trend}(t)) \cdot (1 - \text{drift\_scale})$) into REAPER Take Pitch Envelope with sub-cent accuracy, ensuring 100% Stability audibly flattens pitch drift to match the visual preview
  - Zero-Phase Drift & Vibrato Filter: Replaces crude simple moving average (SMA) with symmetric zero-phase Gaussian filtering ($\sigma = 7.0$ frames, ~2 Hz cutoff), eliminating vibrato ripple from the trend line and preserving pristine vibrato waveforms
  - Anti-Chatter Vibrato Detection: Dual-threshold Schmitt trigger hysteresis and asymmetric envelope follower (~100ms attack, ~60ms release) prevent flickering and odd-spot vibrato highlights during sustained singing
  - Robust Core Pitch Center: Calculates `avg_note` from an RMS-energy-weighted interior window (12% to 88%), preventing onset scoops and release sags from pulling the target pitch off-center
  - Adaptive Envelope Decimation (RDP): Functional Ramer-Douglas-Peucker polyline simplification converts continuous mathematical trajectories into the minimal optimal set of REAPER Bezier points with $<1$ cent tolerance
  - UI / Audio Parity: Preview line in graph and actual take envelope points share identical mathematical formulation
  - Transition Readout: Displays transition duration in milliseconds in the active note status inspector

- **Fancy Pitch Correct v2.2.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Multi-Note Selection & Batch Operations (Milestone 4):
  - Marquee Box Select: Click and drag on empty canvas to select multiple notes with real-time accent box, note count indicator, and AABB intersection
  - Additive Marquee: Shift+drag adds newly intersected notes to existing selection without clearing prior selections
  - Multi-Note Drag: Move pitch center, stability (drift), or vibrato across all selected notes simultaneously
  - Phrase Interval Preservation: Shift-snap snaps anchor note to nearest semitone while strictly preserving the musical intervals of all other selected notes
  - Select All (Cmd/Ctrl + A): Fast phrase-wide selection via keyboard shortcut and toolbar action button
  - Cmd/Ctrl + Click: Toggle individual notes in and out of multi-selection
  - Deselect All (Escape): Instant clearing of active selection
  - Shift + Left / Right Arrow: Expand selection range across adjacent notes
  - Multi-Note Double Click: Double-clicking pitch zone snaps all selected notes to nearest semitones
  - Dynamic Status Readout: Displays total notes selected, cumulative duration, anchor note pitch, and batch tuned/untouched counter
  - Contextual Toolbar Actions: Dynamic note count indicators on Quantize (%d) (Q) and Reset (%d) buttons
  - Updated Keyboard Shortcuts Tooltip: Documents Cmd/Ctrl+A, Escape, and Marquee Drag

- **Fancy Pitch Correct v2.1.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Scale Snapping & Piano Roll In-Scale Tinting (Milestone 3):
  - Key & Scale Selector: Dropdowns for musical Key (C, D, etc.) and Scale (Major, Natural Minor, Dorian, Pentatonic, Minor Pentatonic, Chromatic)
  - Visual Piano Roll Tinting: In-scale note rows highlighted with subtle theme accent tinting; out-of-scale rows and piano keys dimmed
  - Root Key Highlighting: Distinct tonic accent strip on piano keys and enhanced tinting on root pitch rows
  - Quantize Key (Q): Snaps selected note(s) to the nearest valid in-scale pitch
  - Quantize (Q) action bar button with contextual enable/disable and dynamic key/scale tooltip
  - Batch Quantize, Snap, and Reset: Supports both single note and multi-note Shift+Click selections
  - Status display: Real-time `[In Scale]` vs `[Out of Scale]` indicator on the active note inspection bar
  - Persistence: Stores musical Key and Scale per-take in take JSON data and globally across sessions via REAPER ExtState
  - Keyboard Shortcuts Tooltip: Updated with `Q` shortcut entry

- **Fancy Pitch Correct v2.0.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Note Topology (Milestone 2):
  - Split Note (X key): Cuts a note into two independent notes at the edit cursor, automatically re-extracts features for both halves
  - Merge Notes (M key or button): Glues contiguous selected notes back into a single entity with gap frame recovery from raw analysis data
  - Edge Trimming: Drag left/right edges of any note to adjust boundaries with live preview; commits frame re-filtering and feature re-extraction on release
  - Multi-select: Shift+Click for range selection; merge operates on all selected notes
  - Tuning intent preservation: Split/merge carry forward the user's pitch offset, drift scale, and vibrato scale via `preserve_controls` parameter on `extract_note_features`
  - Visual edge handles: Small grab rectangles on note block edges, brighten on hover, accent color during drag
  - Split/Merge buttons in toolbar action bar with contextual enable/disable (greyed when unavailable)
  - Updated keyboard shortcuts info tooltip with all new interactions
  - `ResizeEW` cursor feedback when hovering edge trim handles

- **Fancy Pitch Correct v1.1.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Scalpel Keyboard Controls:
  - Arrow nudging: Up/Down = ±1 semitone, Shift+Up/Down = ±10 cents fine-tune
  - Left/Right arrow keys: Jump note selection to previous/next note in phrase
  - S key: Snap selected note to nearest exact semitone (0¢ deviation)
  - Double-click pitch zone: Snap note to nearest semitone
  - R / Backspace / Delete: Reset selected note back to [Untouched], clearing envelope points
  - Spacebar passthrough: Triggers REAPER Play/Stop even when ImGui window has focus
  - Info icon (ⓘ) in toolbar with keyboard shortcuts tooltip on hover
  - Deduplicated Reset Selected button logic via shared helper function

- **Fancy Pitch Correct v2.4.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Scale Intelligence:
  - Scale auto-detection: Krumhansl-Kessler key profiling from pitch histogram data
  - "Detect" button in toolbar: analyzes pitch frames and auto-sets root note + scale type
  - "Measured" scale entry: auto-populated with the top detected pitch classes
  - "Custom" scale: click piano keys to toggle individual pitch classes on/off
  - Scale indicator dots on piano keys showing which notes are in the active scale
  - Root note (0 / tonic) is protected — cannot be removed from Custom scale

- **Fancy Pitch Correct v2.3.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Tool System:
  - Multi-tool paradigm: Q=Selector, S=Split, J=Join, V=Shaper, X=Pan/Zoom
  - Split tool: click on a note to split at cursor position, red preview line overlay
  - Join tool: click on a note to merge with next, green boundary highlight overlay
  - Pan/Zoom tool: dedicated navigation mode (all clicks become pan/zoom, no selection)
  - Shaper tool: placeholder for future curve editing (acts like Selector)
  - Active tool indicator in toolbar with tooltip showing all hotkeys
  - Tool-specific cursor feedback and interaction dispatch

- **Fancy Pitch Correct v2.2.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Transition Blocks & Smoothing:
  - First-class transition blocks between adjacent notes (amber/gold overlay)
  - Transition tension control: drag diamond handle vertically to adjust smoothness (0 = step, 1 = smooth S-curve)
  - Transition curve rendering with cosine/linear interpolation path
  - `M` key for progressive smoothing on selected transition (+15% per press)
  - Transition data integrated into envelope writer (interpolated pitch points between note boundaries)
  - Click on transition control point to select, drag to adjust, Escape to deselect
  - Auto-generated after analysis, split, and merge operations

- **Fancy Pitch Correct v2.1.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Selection & Navigation:
  - Lasso/marquee selection: drag on empty area to select multiple notes at once
  - Shift+lasso: additive selection mode (keeps existing selection)
  - Cmd/Ctrl+click: toggle individual note without clearing selection
  - Select All (`A` key), Deselect All (`Escape`)
  - Arrow key navigation: `Left`/`Right` to step through notes sequentially
  - Shift+Arrow: extend selection left/right
  - Zoom to Selection (`Z` key, falls back to Fit All if nothing selected)
  - Keyboard Undo/Redo (`Cmd+Z`, `Shift+Cmd+Z`)
  - Lasso rectangle visual overlay with accent-colored fill and border

- **Fancy Pitch Correct v2.0.0 (`Pitch/Fancy_Pitch Correct.lua`)** — Per-Note Control Points:
  - Per-note shaping controls: Correction % (right edge), Drift (left edge), Vibrato (top center), Tilt (Alt+edge)
  - Per-frame pitch trace curve rendered within note blocks showing raw detected pitch
  - Per-frame corrected pitch envelope output with drift/vibrato separation via moving-average trend line
  - Envelope density selector: Low (20 pts/s), Medium (40 pts/s), High (100 pts/s) with persistent settings
  - Control zone hit-testing with distinct cursor feedback per zone type
  - Full shaping undo/redo support: all 6 fields (pitch_offset, correction_pct, drift_amount, vibrato_scale, level_db, tilt)
  - Info bar shows active control zone name and all shaping parameter values on hover
  - Compact pitch_frames cache serialization (v2 format, backward compatible with v1)
  - Control point visual indicators (handles) on note blocks when hovered or selected
  - Note label shows active shaping values (C%, D%, V%, T) alongside pitch name

- **Fancy Pitch Correct v1.0.0 (`Pitch/Fancy_Pitch Correct.lua`)** — NEW:
  - Monophonic pitch correction tool with visual piano-roll editor
  - Pure Lua YIN pitch detection engine (no external dependencies)
  - Audio waveform visualization rendered directly behind notes, centered along sung pitch
  - Cents detune display: shows exact cents off from perfect equal temperament pitch on note blocks and info bar
  - Full piano roll key labeling: all 12 chromatic notes labeled on keys (C, C#, D, D#, etc.)
  - Fit to Screen: one-click button and `F` hotkey to auto-zoom and center viewport horizontally and vertically
  - Drag notes up/down to adjust pitch; semitone snap (Cmd/Ctrl for fine 1-cent resolution)
  - Live preview: pitch envelope updates during drag for real-time audible feedback
  - Scale-constrained "Correct All" (10 scales: Major, Minor, Dorian, Blues, etc.)
  - Note split and merge operations
  - Script-level undo/redo stack (separate from REAPER undo)
  - Toggleable 5ms transition smoothing between notes
  - Analysis caching to JSON (notes + waveform) for instant re-open on same item
  - Non-destructive pitch adjustment via take pitch envelope (action 41612)
  - Fancy Scripts design system integration (dark/match-theme modes)
  - Requirements: REAPER 7.0+, ReaImGui, SWS Extension

- **Fancy Pan Snap v1.7.0 (`Routing/Fancy_Pan Snap.lua`)**:
  - Multi-Project Tab Switching: Automatic session switch detection via `reaper.EnumProjects(-1)`, resetting parameter tracking and tooltips to prevent cross-session pointer leaks, dead memory reads, and ReaImGui desync
  - Zero-Allocation Fast-Path Engine: Eliminated thousands of heap allocations per second during idle (avoiding table allocations, per-tick `GetTrackGUID`, per-tick `GetTrackName`, and string key concatenations)
  - Pre-Cached Track Descriptors: Cached track GUIDs, track names, and parameter keys (`tinfo.key_pan`, `tinfo.key_width`, send keys), rebuilding only on project structure/state changes (`GetProjectStateChangeCount`)
  - Mousewheel, Trackpad, and MIDI Controller Support: Implemented `mouse_down_seen` state tracking so wheel scrolling, rotary encoders, and control surfaces debounce smoothly (120ms) instead of snapping on every individual tick
  - Context Lifecycle Hardening: Guarded `is_bypass_active` to only query `ImGui_GetKeyMods` when `hud_open` is active and context is validated; used precise `JS_Mouse_GetState(40)` for Shift/Alt DAW-wide modifier detection
  - Periodic Stale Cleanup: Cleaned up deleted track pointers every 5 seconds without per-frame table scanning or allocation
  - Action Lifecycle: Re-ordered `set_action_options` and guarded `atexit` ExtState clearing to ensure rock-solid toolbar toggle and multi-instance restarts
- **Fancy Pan Snap v1.6.1 (`Routing/Fancy_Pan Snap.lua`)**:
  - Fixed intermittent `ImGui_GetKeyMods: expected a valid ImGui_Context*` runtime error occurring during background execution when HUD was closed
  - Added robust ReaImGui context lifecycle management (`ensure_imgui_context()` and `is_context_valid()`) using `reaper.ImGui_ValidatePtr` to prevent stale pointer access after ReaImGui GC
  - Wrapped `reaper.ImGui_GetKeyMods` with `reaper.ImGui_ValidatePtr` and `pcall` fallback for crash-proof modifier detection
- **Fancy Pan Snap v1.6.0 (`Routing/Fancy_Pan Snap.lua`)**:
  - Added `50%` preset button to standard step increments and replaced `12.5%` (`5%`, `10%`, `20%`, `25%`, `50%`)
  - Cleaned up header: removed "Auto Detent" subtitle and added dedicated `[Info]` and `[Settings]` modal dialog buttons matching Parameter Link layout
  - Moved target parameters (`Track Pan`, `Track Width / Dual Pan`, `Send Pans`, `Include Master Track`) into the **Settings** modal popup dialog
  - Converted the collapsible Overlay Styling drawer into an open, permanent **STYLING** section using standard section dividers
  - Removed "STATUS & MONITOR" section and repositioned Shift/Alt bypass modifier hints and background execution tip directly under the master `ACTIVE (ON)` / `PAUSED (OFF)` button
  - Added high-visibility red `[STOP]` utility button directly to the top master row beside the status monitor badge
  - Added Info & Guide modal dialog with Quick Guide, Keyboard & Controls, and About tabs
- **Fancy Pan Snap v1.5.0 (`Routing/Fancy_Pan Snap.lua`)**:
  - Added dedicated **Overlay Styling & Theme** section letting users customize floating badge appearance by selecting REAPER theme elements and roles (not raw hex colors)
  - Customizable theme elements: Background Surface (`Card`, `Panel`, `Window`, `Accent Tint`), Border Element (`Accent/Cursor`, `Secondary Blue`, `3D Frame`, `Green`, `Yellow`, `None`), Value Highlight Color, and Label Color
  - Added Corner Rounding (`Rounded 4px`, `Pill 8px`, `Sharp 0px`) and Background Opacity (`40%`–`100%`) controls
  - Built-in real-time **Live Overlay Preview** card inside the HUD demonstrating styling adjustments instantly
  - Removed theme mode dropdown from the window header and relocated it directly into the Overlay Styling section for a cleaner header bar
  - Dedicated "Reset Overlay Style" button to restore default theme element assignments
  - Seamless background execution when closing the HUD menu window (`keep_in_background = true` by default with automatic configuration migration)
  - Intelligent 3-state toggle action lifecycle (`set_action_options(3)`): re-triggering the action or clicking the toolbar button while running in the background re-opens the HUD menu immediately
  - Re-triggering the action or clicking the toolbar button while the HUD is already open toggles the script off cleanly
  - Added explicit "Stop Utility & Exit" action button in the Settings drawer to terminate background execution directly from the GUI
  - Replaced native OS tooltips (`reaper.TrackCtl_SetToolTip`) with a smooth, GPU-rendered ReaImGui floating cursor badge, eliminating macOS window flashing and white/black box artifacts
  - Completely decoupled live mouse dragging from REAPER parameter writes so native TCP/MCP knob turning remains 100% smooth without rubber-banding or value fighting
  - Real-time detent preview displayed directly beside the mouse cursor showing track name, parameter, and target snapped value (e.g. `Lead Vocal • Pan → 20% L (10%)`)
  - Clean snap-on-release execution with a single consolidated undo point (`Utils.undo_block`)
  - Background auto-snap engine quantizes Track Pan, Track Width, and Send Pans across all tracks to configurable percentage increments (default 10%)
  - Smart motion and release detection with instant snap on mouse button release (`JS_Mouse_GetState`) and fallback 120ms debounce settling timer
  - Shift/Alt key modifier detection to temporarily bypass snapping for freehand fine panning
  - Compact ReaImGui HUD interface with quick presets (5%, 10%, 12.5%, 20%, 25%), custom step slider, target selectors, and live activity card
  - Single-instance enforcement, ExtState persistence, and REAPER toolbar toggle state integration (`Utils.init_toolbar_toggle()`)
- **Global Tooltip Preference (`_lib/theme.lua`)**:
  - Added global tooltip visibility state persisted via REAPER ExtState (`FancyScripts`, `show_tooltips`) and cached in memory with cache invalidation support
  - Added `Theme.get_show_tooltips()`, `Theme.set_show_tooltips(enabled)` and developer aliases `Theme.get_tooltips_enabled()`, `Theme.set_tooltips_enabled()`, `Theme.tooltips_enabled()`
  - Added `Theme.tooltip_setting_widget(ctx, [opts])` standardized checkbox component for toggling tooltips in settings panels
  - Updated `Theme.tooltip()` to automatically suppress all tooltips across built-in widgets (`icon_btn`, `section_divider`, `badge`, `toggle_button`, `combo`, `header`) when disabled
- **Fancy Parameter Link v5.4.0**:
  - Added "Show Tooltips" preference checkbox in the Settings & Preferences modal under "UI Density & Appearance"
  - Updated "Last Touched" button custom tooltip to respect global tooltip visibility
- **Fancy Design System v1.3.0**:
  - Added live interactive demonstration for `Theme.tooltip_setting_widget()` alongside theme mode controls
- **Fancy Selected Track Meter**:
  - Updated `DrawTooltip` to respect global `Theme.get_show_tooltips()` preference
- **Shared Library (`_lib/`)** — shared modules loaded via `require()`
  - `theme.lua` — 2-mode palette builder (Fancy Dark / Match Theme), shared font management, ImGui push/pop, settings combo widget
  - `json.lua` — lightweight JSON encoder/decoder (consolidated from inline copies)
  - `utils.lua` — dependency checks, undo block wrapper, track helpers, math utilities, REAPER toolbar toggle state lifecycle helper (`Utils.init_toolbar_toggle()`)
- **Fancy Parameter Link v5.3.0** — Bundled custom 3-state horizontal strip toolbar icons across 100% (`90x30`), 150% (`135x45` in `150/`), and 200% Retina (`180x60` in `200/`), enabled automatic ReaPack `[data]` extraction to REAPER's `Data/toolbar_icons/`, and hooked action toggle command state to light up the toolbar icon while the script is active and running.
- **Design System & Theme Engine**
  - Added `Theme.header(ctx, opts)` composite widget to standardize window headers with brand icon, title, subtitle, theme dropdown, and close button with pixel-perfect alignment
  - Added `Theme.progress_bar(ctx, fraction, [opts])` for crisp value meters and progress indicators with preset support (`opts.preset = L.btn_sm`)
  - Added `Theme.toggle_button(ctx, id, label, is_active, [opts])` button-derived toggle widget supporting button size presets (`opts.preset = L.btn_sm`)
  - Added `Theme.badge(ctx, label, [opts])` button-derived status badge with centered text and preset support (`opts.preset = L.btn_sm`)
  - Added `Theme.push_button_preset(ctx, fonts, preset)` and `Theme.pop_button_preset(ctx, ...)` for seamless styling of native ImGui controls (e.g. sliders, combo boxes)
  - Added `Theme.combo(ctx, id, items, selected_idx, [opts])` for standardized, search-friendly dropdown menus
  - Added `Theme.align(ctx, [row_h], [item_h])` single unified vertical centering function supporting standard rows, table cells with automatic `CellPadding.y` compensation, and mixed-height `SameLine` rows
  - Fixed text baseline misalignment in `Theme.toggle_button()` and `Theme.badge()` by letting button heights flow naturally from `Font + FramePadding` (`h = 0`) instead of forcing fixed bounding box heights
  - Deprecated `Theme.vcenter()` as low-level escape hatch in favor of `Theme.align()`
  - Unified scale extended to `xxl=24` and `xxxl=32`
  - Streamlined theme modes to 2: **Fancy Dark** (curated palette) and **Match Theme** (extracts surfaces, text, borders, and edit cursor accent `col_cursor` from REAPER)
  - All layout tokens (`rounding`, `icon_sm/md/lg`, `row_h`, `chk_col_w`, `indent`, `section_gap`) strictly derive from scale tokens; dropdowns and combo boxes calculate reactive width dynamically via `Theme.calc_combo_width()`
  - Added blue secondary accent color `accent2` / `blue` (`0x4DA6FFFF`) to `FANCY_PALETTE` with derived states `accent2_h`/`blue_h` (80%), `accent2_d`/`blue_d` (33%), and `accent2_e`/`blue_e` (12.5%) for info indicators, links, and secondary badge highlights
  - `FANCY_PALETTE` simplified to base colors; derived states (`accent_h/d/e`, `accent2_h/d/e`, `green_h/d`, `red_h/d`, `blue_h/d/e`) computed dynamically with consistent alpha ratios (80% / 33% / 12.5%)
  - Safe color math: `icon_btn` hover uses `lighten()` and `section_divider` uses `with_alpha()`
    - Added high-contrast text tokens (`accent_l`, `accent2_l`/`blue_l`, `green_l`, `red_l`, `yellow_l`) derived via 70% lightening for WCAG AAA badge text and active controls
    - Hardened `Theme.badge()` and `Theme.toggle_button()` defaults to automatically derive high-contrast text and 33% alpha background from base semantic colors
- **Fancy Design System v1.2.0** — Added live interactive demonstrations for `Theme.progress_bar()`, `Theme.toggle_button()`, `Theme.badge()`, `Theme.combo()`, `_l` high-contrast text tokens, and `L.btn_sm` table controls, secondary accent / blue swatches and info badges, eliminated raw hex color literals
- **Fancy Parameter Link v5.2.0** — Updated Track B name labels and Track B Live Values indicators to use the secondary accent color (`P.accent2` / `P.blue`), and transitioned all badges and toolbar buttons to first-class `P.*_l` high-contrast palette tokens

### Fixed
- **Fancy Parameter Link v5.4.1 (`FX/Fancy_Parameter Link.lua`)** — ReaImGui window lifecycle correction:
  - `reaper.ImGui_End(ctx)` and the preset, info, and settings modals now run only inside `if vis then`. Previously `ImGui_End` ran even when `ImGui_Begin` returned false (window in an inactive dock tab or fully clipped), causing a double End and a ReaImGui stack error.
  - Corrects the v5.2.0 "guarantee `reaper.ImGui_End(ctx)` is called when `reaper.ImGui_Begin()` returns false" fix: that is the Dear ImGui C++ rule. ReaImGui's `Begin` and `BeginChild` already call `End`/`EndChild` themselves when they return false, so scripts must only call them when Begin returned true.
- **Fancy Pitch Correct v2.4.1 (`Pitch/Fancy_Pitch Correct.lua`)** — ReaImGui window lifecycle correction:
  - `reaper.ImGui_End(ctx)` and the settings and info modals now run only when `ImGui_Begin` returns true, fixing a double End and ReaImGui stack error when the window is in an inactive dock tab or fully clipped. The window padding and item spacing style vars are still popped every frame.
- **Fancy Selected Track Meter v9.67.1 (`Metering/Fancy_Selected Track Meter.lua`)** — ReaImGui window lifecycle correction:
  - The Track Meters, Recent Clips, and Meter Settings windows now call `reaper.ImGui_End(ctx)` only when their `ImGui_Begin` returns true, fixing a double End and ReaImGui stack error when a window is collapsed, fully clipped, or in an inactive dock tab.
- **Fancy Pan Snap v1.7.1 (`Routing/Fancy_Pan Snap.lua`)** — ReaImGui window lifecycle correction:
  - The HUD window and the floating cursor tooltip now call `reaper.ImGui_End(ctx)` (and, for the HUD, draw the info and settings modals) only when `ImGui_Begin` returns true, fixing a double End and ReaImGui stack error when the window is in an inactive dock tab or fully clipped.
- **UI Legibility & WCAG Contrast Hardening**:
  - Added first-class `_l` palette tokens (70% lightened text) and updated `Theme.badge()` / `Theme.toggle_button()` defaults to eliminate low-contrast badge text (boosting contrast ratios from ~3.3:1 – 5.5:1 up to 6.5:1 – 8.1:1, passing WCAG AAA on toolbar action buttons and badges)
  - Fixed `OFFLINE` status badge in `Fancy_Parameter Link.lua` to automatically use `P.red_l` / high-contrast red instead of unlightened `P.red` (raising contrast from 3.3:1 to 7.5:1)
- **Section Dividers & Info Tooltips (`_lib/theme.lua`)**:
  - Increased default info icon size in `Theme.section_divider()` from `icon_sm` (8px) to `icon_md` (12px) for improved visibility and legibility next to section titles (e.g. Tracks, Plugin, Link Builder)
  - Added vertical alignment using `Theme.align()` to align the section title baseline and center the info button within the frame height
- **Theme Engine Hardening & Bug Fixes (`_lib/theme.lua`)**:
  - Fixed `Theme.center_next_window()` to dynamically center relative to the active parent window (with viewport fallback) using `(0.5, 0.5)` pivot alignment, fixing off-center horizontal positioning when opening modals (e.g. Settings, Info & Guide, Preset Manager)
  - Added missing `ImGui_Col_Text`, `ImGui_Col_TextDisabled`, `ImGui_Col_Border`, and `ImGui_Col_ScrollbarGrabActive` to `Theme.push()` (updating push/pop stack parity to 32 colors)
  - Fixed 64-bit Lua 5.4 integer underflow/overflow and sign extension in `darken()`, `lighten()`, and `with_alpha()` via strict boundary clamping
  - Fixed custom REAPER color flag (bit 24) decoding in `bgr_to_rgba()` by unconditionally masking `0x00FFFFFF`
  - Eliminated per-frame closure allocations in `Theme.combo()` by factoring item label resolution to file scope
  - Eliminated per-widget C-API `reaper.GetExtState` queries by caching `_cached_mode` in memory
  - Eliminated per-frame table churn in `Theme.settings_widget()` and `Theme.header()` by using static option tables
  - Added public `Theme.get_palette()` accessor and optimized `Theme.push()` to consume cached palette
  - Fixed `Theme.layout.btn_lg.h` token from 26 to 24px to match natural button height flow (`16 + 4*2`)
  - Fixed string preset normalization in `Theme.push_button_preset()` (`"sm"`, `"small"`, `"lg"`, `"large"`)
  - Fixed `Theme.toggle_button()` crash when `id` argument is `nil`
  - Fixed `Theme.header()` right-aligned width allocation and spacing with custom widgets, and added vertical alignment for close button
  - Removed orphaned docblock above `Theme.push_button_preset()`
- **Parameter Link Engine Hardening & Optimization (`FX/Fancy_Parameter Link.lua`)**:
  - Preserved and hardened direct bidirectional parameter modulation and full-mesh topology across all linked tracks
  - Added FX GUID resolution and validation (`resolve_fx`) to guard against FX reordering, movement, or deletion
  - Added Master Track support to track caching and selector lists
  - Added project tab change detection to automatically persist and switch project configuration files
  - Fixed ReaImGui window lifecycle to guarantee `reaper.ImGui_End(ctx)` is called when `reaper.ImGui_Begin()` returns false
  - Eliminated per-frame link group table allocations with dirty-flag invalidation caching (`get_link_groups`)
  - Eliminated per-frame row string concatenations by scoping table rows with `reaper.ImGui_PushID(ctx, i)`
  - Gated `poll_last_touched()` behind integer target change checks to eliminate redundant string and regex operations
  - Added "Delete Selected" batch action button to Active Links toolbar
  - Added Enter key confirmation to Save Preset popup and Escape key dismissal across all modal dialogs
  - Standardized Live Values display with dual `Theme.badge()` indicators with natural button height flow (`preset = L.btn_sm`)
  - Fixed table cell vertical alignments using `Theme.align(ctx, row_h)` and `Theme.align(ctx, row_h, item_h)`
  - Fixed Section 10 numbering and removed phantom undo points from internal state mutations

### Changed
- **Fancy Parameter Link v5.2.0** — Complete Design System & Theme Engine migration
  - Replaced all hardcoded colors, spacing, and font definitions with `_lib/theme.lua` tokens and dynamic palette
  - Standardized Active Links table controls to `Theme.layout.btn_sm` (16px height, small typography, and frame padding across Live Values, Mode, and Strength)
  - Set Active Links parameter groups to start closed by default
  - Converted custom UI widgets to `Theme.progress_bar()`, `Theme.badge_button()`, and `Theme.combo()`
  - Set Active Links parameter groups to start closed by default
  - Standardized window header with `Theme.header()` featuring brand icon, dynamic subtitle status toasts, right widgets, and reactive theme switcher
  - Converted dialogs and modals to use `Theme.center_next_window()`, `Theme.section_divider()`, `Theme.push_font()`, and `Theme.settings_widget()`
  - Replaced custom buttons and icons with `Theme.icon_btn()`, `Theme.icon_btn_colored()`, `Theme.collapsing_header()`, and `Theme.icons.*`
  - Integrated `_lib/utils.lua` for clean undo blocks and safety guards
- **Fancy Parameter Link v5.0.0** — Major redesign
  - **Bidirectional links**: either side of a link can drive the other (no more source/target distinction)
  - **Multi-track selection**: select N tracks and link them all at once (full-mesh topology)
  - **Grouped active links**: links in the table are grouped by plugin/parameter for cleaner display
  - Presets now apply across all selected tracks (not just 2)
  - Last Touched adds tracks to selection instead of overwriting source/target
  - Data model changed from src/dst to symmetric a/b naming

## [1.0.0] - 2026-08-27

### Added
- **Fancy ParameterLink** — Link FX parameters between tracks (Follow/Inverse/adjustable strength)
- **Fancy Selected Track Meter** — Real-time visual metering for selected tracks
- **Fancy Copy Fader to Send** — Copy Main Fader volume to a Send
- ReaPack distribution with automated CI/CD pipeline
- GitHub Sponsors integration

---

*This changelog follows [Keep a Changelog](https://keepachangelog.com/) format.*
