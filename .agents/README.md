# Agent tooling

This folder holds the skills and agents used to develop Fancy Scripts. It is **tracked**, so
every machine and every cloud session gets the same tooling, and it is **never shipped**:
`.reapack-index.conf` ignores `.agents` and `.claude`, `.luacheckrc` excludes them, and the
`reaper-gates` H6 gate fails if either ignore line goes missing.

## Layout

```
.agents/
  skills/<name>/SKILL.md      source of truth for each skill (Claude Code + Antigravity)
  skills/<name>/references/   files the skill reads on demand
  skills/<name>/scripts/      helpers: Python 3 stdlib only, never .lua (luacheck/ReaPack safety)
  agents/<name>.md            subagent definitions (synced into .claude/agents/)
.claude/
  skills/<name> -> ../../.agents/skills/<name>   relative symlinks so Claude Code discovers them
  settings.json               shared Claude Code settings (settings.local.json stays untracked)
```

Helper paths are always resolved from the repo root:
`"$(git rev-parse --show-toplevel)/.agents/skills/<name>/scripts/<file>"`.

## Workflow skills

| Skill | Use it to |
|---|---|
| `superpowers:brainstorming` → writing-plans | Turn an idea into a spec and plan (`docs/superpowers/`). |
| `reaimgui-ux-design` | Design new UI before code (`docs/design/`). |
| `reaper-quality-bar` | The standard: hard gates H1–H8, soft rules A/RT/U/R, severity scale. |
| `reaper-gates` | Run the hard gates (`gates.py`). |
| `gauntlet` | Build → gates → blind critics → verify → fix, until the bar passes or a stop rule fires. Ledgers go in `docs/gauntlet/`. |
| `reaimgui-ux-review` | UX review. The gauntlet's UX lens uses it when it is installed. |

## Moving your existing local tooling into the repo (one time, on the Mac that has it)

Until now `.agents/`, `.claude/` and `AGENTS.md` were gitignored, so the existing skills
(`reaimgui-ux-review`, `reaimgui-ux-design`, `reaper-screenshot`, `ai-skeptic-reviewer`, …), the agents
(`ui_agent`, `qa_agent`) and `sync-claude.sh` only exist on that machine. After this branch is
merged and pulled there:

```sh
git status --short --ignored .agents .claude AGENTS.md   # see what is now visible to git
grep -rn "/Users/" .agents AGENTS.md                     # no absolute paths: use git rev-parse --show-toplevel
git add .agents .claude/skills .claude/agents AGENTS.md  # review the list before committing
python3 .agents/skills/reaper-gates/scripts/gates.py     # H6 must PASS
```

Keep per-machine files out of git: `.claude/settings.local.json` and `.mcp.json` (which may hold
local paths or tokens) stay ignored. If `.agents/sync-claude.sh` regenerates `.claude/skills/`,
make sure it keeps relative symlinks (`../../.agents/skills/<name>`). Absolute links break on any
other machine.
