# Gauntlet: {{TITLE}}

- **Input:** {{path to plan / spec / design doc}}
- **Branch / base:** {{branch}} / {{base sha}}
- **Started:** {{YYYY-MM-DD}} on {{machine}}
- **Status:** running | PASS | PASS pending live check | escalated: {{reason}}
- **Round:** {{N}} of max 4 critic rounds

## Acceptance criteria

| # | Criterion | Evidence | Met |
|---|---|---|---|
| AC1 | | | ☐ |

## Gates (latest round)

```
{{paste gates.py table}}
```

## Findings

| ID | Lens | Rule | Sev | Location | Title | Status | Notes |
|---|---|---|---|---|---|---|---|
| G1-1 | API | A3 | 3 | `Routing/Fancy_Pan Snap.lua:412` | End() skipped when clipped | fixed r2 | |

Status values: `open`, `fixed rN`, `rejected` (put the verifier's reason in Notes), `wontfix` (put the user's decision in Notes), `needs-live`.

## Needs a live check (REAPER)

| ID | Steps | Expected | Result |
|---|---|---|---|

## Round log

| Round | Commit | Gates | New | Confirmed | Rejected | Fixed | Open ≥3 |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
