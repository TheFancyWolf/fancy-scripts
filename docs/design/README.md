# Design docs

Approved UI designs for Fancy Scripts live here, one file per script (or per script suite).

- **Written by** the `reaimgui-ux-design` skill, **before** any ImGui code is drawn. A design doc is the approved layout, states, interaction spec, copy deck and acceptance criteria for a script's UI.
- **Slug rule.** The script filename without `Fancy_` and `.lua`, lower-cased, spaces as hyphens: `Fancy_Pan Snap.lua` → `pan-snap.md`. A multi-script suite uses its settings script's slug (Mapper → `mapper-settings.md`).
- **Header.** Every doc starts with a `Target file(s):` line (repo-relative paths), the archetype per window, `Status: Draft | Approved`, the date and the approver.
- **Review.** The `reaimgui-ux-review` skill finds a doc by grepping this directory for the target's `Target file(s):` line and checks the built UI against it **only when `Status: Approved`**. Drafts are ignored.
- **Not published.** `.reapack-index.conf` ignores `docs`, so nothing here ships through ReaPack.
