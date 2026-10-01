---
name: reaper-gates
description: Use before claiming a Fancy Scripts change is done, before committing or opening a PR, and on every round of a gauntlet loop, to run the quality bar's machine-checked hard gates (luacheck, ReaPack headers, version bump, CHANGELOG, index.xml, ReaPack exclusion, ds-lint).
---

# Hard gates

Run from anywhere in the repo:

```sh
python3 "$(git rev-parse --show-toplevel)/.agents/skills/reaper-gates/scripts/gates.py"
```

- Checks every file changed against the merge-base with `origin/main` (or `main`): committed, staged, unstaged **and** untracked. Pass `--base <ref>` to compare against something else, or `--json` for machine-readable output.
- Exit `0` = all PASS/SKIP, `1` = a gate FAILed, `2` = environment error (not in a git repo, no base found).
- The gate definitions (H1–H8) and what counts as an allowed SKIP live in `reaper-quality-bar`. This script is the only implementation of them.

## Rules

- **Never** edit the gates to make a change pass. If a gate is wrong, fix it in its own commit, add a self-test case that proves the fix, and run `gates.py --self-test`.
- Paste the full table into your hand-off or PR, not a summary like "gates green".
- A FAIL from H1 can't be waived. If luacheck is missing, install it (`brew install luacheck` on macOS, `apt-get install lua-check` on Debian/Ubuntu).
- H7 only runs when `reaimgui-ux-review`'s `ds-lint.py` is in the checkout. A note about "pre-existing definite findings" passes the gate, but it obliges the UX critic to confirm that none of those findings are new.
