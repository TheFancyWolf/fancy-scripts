# Lens: UX and design system (rules U1–U3)

**If `reaimgui-ux-review` is installed** (`.agents/skills/reaimgui-ux-review/SKILL.md` exists):
follow its review method and rule catalog in **review-only mode**. Don't apply any tiers, and
report its findings in the critic JSON format, keeping their rule IDs (HC*, ST, UC, …). Scope it to
the changed UI code plus whatever the change makes reachable.

**Otherwise** check at least:

- **U1 house conventions:**
  - HC1: text contrast under 3:1 is severity 4, and 3–4.49:1 is severity 3.
  - HC2: Ctrl/Cmd-drag gives fine adjust on value controls.
  - HC3: double-click resets a value, and Ctrl/Cmd-click lets you type one.
  - HC4: a destructive action that one undo can't fully restore needs a confirm, with Cancel first.
  - HC5: Esc goes innermost first, uses `Shortcut()` routing, and only closes a floating window.
  - HC6: Space passes through to the user's REAPER binding.
- **U2:** new colours and sizes come from `_lib/theme.lua` tokens and helpers (`Theme.*`). Hex literals and magic pixel values in non-legacy scripts are findings.
- **U3:** if `docs/design/` has a doc for the target with `Status: Approved`, the UI matches its layout, states, copy and acceptance criteria.
- Every state has a visible representation: empty, loading or analysing, error, disabled (with a tooltip saying why), and a narrow window.
- Labels and tooltips use the user's terms. Every action gives feedback (a status message, or a visible change).

Visual claims (spacing, clipping, colour in Match Theme) need a screenshot. In a session without
REAPER, report them with `"needs_live": true`.
