# Design docs

Approved UI designs for Fancy Scripts live here, one file per script (or per script suite).

- **Written by** the `reaimgui-ux-design` skill, **before** any ImGui code is drawn. A design doc is the approved layout, states, interaction spec, copy deck and acceptance criteria for a script's UI.
- **Slug rule.** The script filename without `Fancy_` and `.lua`, lower-cased, spaces as hyphens: `Fancy_Pan Snap.lua` → `pan-snap.md`. A multi-script suite uses its settings script's slug (Mapper → `mapper-settings.md`).
- **Header.** Every doc starts with a `Target file(s):` line (repo-relative paths), the archetype per window, `Status: Draft | Approved`, the date and the approver.
- **Review.** The `reaimgui-ux-review` skill finds a doc by grepping this directory for the target's `Target file(s):` line and checks the built UI against it **only when `Status: Approved`**. Drafts are ignored.
- **Not published.** `.reapack-index.conf` ignores `docs`, so nothing here ships through ReaPack.

## Contrast

Reviews of a script's look check against this rule, which replaced the old "borders at 3:1" rule when the Reaper Tips look arrived (spec: `docs/superpowers/specs/2026-11-18-reapertips-restyle-design.md`, section 7).

- **Text and labels: 4.5:1, always**, in both theme modes (Fancy and Match Theme).
- **State that carries meaning: 3:1** against what it sits on: a toggle that is on, focus, a slider thumb, a check mark, the playhead, note borders on the canvas, and the selection bar of library rows.
- **The resting outline and face of a labelled control follow the theme, with no minimum.** The Reapertips outline is about 1.4:1 on the window and a button face about 1.3:1; the label already identifies the control. The selection tint of a row is exempt from 3:1 too: library rows add a 2 px accent bar that meets it, while rows a script draws with raw `ImGui_Selectable` or `ImGui_MenuItem` get the tint only.
