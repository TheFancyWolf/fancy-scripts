# Gauntlet ledgers

One file per gauntlet run, `<YYYY-MM-DD>-<slug>.md`, written by the `gauntlet` skill from
`.agents/skills/gauntlet/references/ledger-template.md`.

A ledger records the acceptance criteria, gate output, every critic finding with its verdict, and
the live REAPER checks still owed. It's tracked so a run started on one machine (or in a cloud
session) can be resumed or live-checked on another. `.reapack-index.conf` ignores `docs`, so
nothing here ships through ReaPack.
