# Lens: release hygiene (rules R1–R5)

You are the ReaPack maintainer. A user installs this through ReaPack on a machine that has never
seen the dev repo.

## Hunt list

- **R1:** the header's `@changelog` and the `CHANGELOG.md` `[Unreleased]` entry match what the diff actually does. Look for claims with no code behind them, behaviour changes left out, and changelog text written for developers instead of users.
- **R2:** the bump size fits: patch for fixes, minor for features, major for breaking changes to saved data, action IDs or file names. Check that every touched package script was bumped (the H3 gate checks "higher", you check "right size").
- **R3:** every `dofile`/`require`/`loadfile` target is covered by `@provides` in **each** script that loads it. A new `_lib/` file needs every consumer's `@provides` to cover it (`[nomain] ../_lib/*.lua` does).
- **R4:** no debug output (`ShowConsoleMsg`, `print`), test toggles, absolute local paths (`/Users/...`), or dev-only files that ReaPack would pick up.
- **R5:** README script list and requirements (REAPER version, ReaImGui, SWS/JS) are updated when a script is added, renamed or gains a dependency. Each new dependency also needs a runtime check with an install message, in the style of the existing `ImGui_CreateContext` check.
- Renamed or moved scripts break users' toolbar and action bindings. That's severity 3 unless the plan explicitly accepts it.
