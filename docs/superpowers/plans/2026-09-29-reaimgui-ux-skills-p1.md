# ReaImGui UX Skills — Phase P1 Implementation Plan (prerequisites + `ds-lint.py`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the P1 deliverables of the ReaImGui UX skills spec: the integration prerequisites (§7) and `ds-lint.py` with its API-name list, so P2 (`reaimgui-ux-review`) can start.

**Architecture:** One Python 3 stdlib-only script (`ds-lint.py`) under `.agents/skills/reaimgui-ux-review/scripts/`. It blanks Lua comments and strings, introspects `_lib/theme.lua` at run time (no token values are copied anywhere), and runs regex / block-aware probes tagged with rule IDs and a `definite` / `check` confidence. Its test fixtures are embedded in the script and run by `--self-test`.

**Tech Stack:** Python 3 (stdlib only), Lua 5.4 sources as *input*, `luacheck`, `git`, shell.

**Spec:** `docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md` (Revision 2). This plan implements phase **P1** of §3.3 and nothing else; P2 and P3 get their own plans, after P1's exit criteria pass.

## Plan-level decisions (made here, so the executor does not have to guess)

| # | Decision | Why | Cost if wrong |
|---|---|---|---|
| PD1 | This plan covers **P1 only** | Spec §3.3: "Each phase gets its own implementation plan and must pass before the next starts." | None |
| PD2 | `reaimgui_api_names.txt` is generated from the local ReaImGui doc (`~/Library/Application Support/REAPER/Data/reaper_imgui_doc.html`, "Generated for version 0.10.0.5") by `ds-lint.py --regen-api`, then cross-checked with `reaper-dev:get_function_info` on samples | Offline and deterministic; a single `search_functions` call with limit 3000 is an unwieldy MCP payload. The spec's §6 wording ("regeneration instructions (`reaper-dev:search_functions`…)") is honoured by the header note, which lists both routes | Regenerate from `reaper-dev` instead |
| PD3 | Tasks 2–8 touch only gitignored paths (`.agents/`, `.claude/`), so they have **no commit step**. Only Task 1 commits, adding **named files only** | D18: skills are local-only. The working tree holds the user's uncommitted work; nothing may be staged with `git add -A`/`.`, and `git stash`/`git checkout` are never used | None |
| PD4 | `AGENTS.md` is tracked (despite the `.gitignore` entry), so Task 1 commits its edit. Drop it from the `git add` if the user wants it local-only | Spec §7.2 says "(local)" but the file is tracked | One `git reset` of that path |
| PD5 | `--ui-lines` counts **non-blank lines after comment stripping** | The spec's "count of lines" is ambiguous; comments must not push a script over the 1,500 gate | Threshold moves slightly |
| PD6 | Measured baselines (2026-09-29) supersede the spec's stale numbers: Selected Track Meter has **305** luacheck warnings (spec: 307). Task 8 records the real hex-literal count too and edits spec §8 R2 to match | Numbers must come from tools, not memory | One spec line |
| PD7 | No git worktree. Work happens on branch `ux-skills-spec` in the main checkout | Spec §8.1: a worktree would miss the uncommitted Mapper suite/theme changes and the gitignored `.agents/` | None |

## Global Constraints

- Helper scripts are **Python 3 stdlib only, never Lua** (`.luacheckrc` has no exclude list; a `.lua` file under `.agents/` would be linted by `luacheck .`).
- Test fixtures are **embedded in `ds-lint.py`** (no separate fixture files).
- `theme.lua` is the **only source of token values**: no token number or palette hex is copied into skill text, docs or the script's logic. `ds-lint.py` extracts real values at run time. (The only hard-coded numbers are ports of `with_alpha` / `lighten` / `darken` ratios, guarded by a drift check.)
- Skills refer to `theme.lua` by **section name, not line number**.
- `ds-lint.py` exit codes: `0` = no `definite` findings; `1` = `definite` findings; `2` = usage or theme-parse error. It never passes silently on a parse failure.
- Every probe runs with Lua comments and string literals blanked out.
- **Not a CI gate**: `.github/workflows/` stays unchanged. Never touch `index.xml`, `_fancy_*.json`, or any script under `FX/ Metering/ Pitch/ Routing/ Utility/ Mixing/`.
- Tool names are fully qualified (`reaper-dev:get_function_info` = `mcp__reaper-dev__get_function_info`).
- `ui_agent` edits happen in `.agents/agents/ui_agent.md`, then `sh .agents/sync-claude.sh` regenerates `.claude/agents/ui_agent.md`.
- Never run `git checkout`, `git stash`, `git add -A` or `git add .` (user's uncommitted work is in the tree). No `Co-Authored-By` deviations: end commit messages with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Version facts: ReaImGui **0.10.0.5** (Dear ImGui 1.92.1); installed version query: `sqlite3 "$HOME/Library/Application Support/REAPER/ReaPack/registry.db" "select version from entries where package='reaper_imgui.ext'"`.

## Review Focus

Failure modes the spec implies that a person using `ds-lint.py` is most likely to hit. Each has a pinning test in the task named in brackets.

1. **CRLF files** (Windows-authored scripts): findings must report the same line numbers as the editor. [Task 3, fixture "CRLF keeps line numbers"]
2. **Non-UTF-8 bytes / stray `0xFF` in a script**: must be linted, not crash. [Task 3, CLI test "non-utf8 bytes"]
3. **Comment and string markers inside each other** (`"a -- b"`, `[==[ … ]==]`, `--[==[ … ]==]`, `[[ 0xFFFFFF ]]`): must not open a phantom comment or leak string contents into probes. [Task 3, fixtures]
4. **Empty file / comment-only file**: exit 0, no crash, no findings. [Task 3, CLI test + fixture]
5. **`theme.lua` missing, or drifted from the palette port** (a new `P.<key>` the port does not know): exit 2 with a message naming the key, never a silent partial result. [Task 4, unit tests + CLI test]

---

### Task 1: Integration prerequisites (§7 items 1, 2, 5, 6, 7)

**Files:**
- Modify: `.agents/agents/ui_agent.md` (local, gitignored), then regenerate `.claude/agents/ui_agent.md` via `sh .agents/sync-claude.sh`
- Modify: `AGENTS.md` (tracked; HC1–HC6 + routing text)
- Modify: `.gitignore` (add `.claude/skills/`, `.claude/agents/`)
- Modify: `.reapack-index.conf` (add `--ignore docs`)
- Create: `docs/design/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: HC1–HC6 canonical text in `AGENTS.md` (later tasks/plans cite `HCn`); the routing sentence; `ui_agent` that has no invented tokens and knows the batch rule; `docs/design/` exists for P3.

- [ ] **Step 1: Write the failing check**

Run this one command (it is the task's test; it must fail now):

```bash
cd /Users/macstudio/Development/fancy-scripts && sh -c '
set -e
grep -q "^\*\*HC1 " AGENTS.md || grep -q "HC1 Contrast" AGENTS.md
for n in 1 2 3 4 5 6; do grep -q "HC$n " AGENTS.md; done
grep -q "reaimgui-ux-design" AGENTS.md
grep -q "^\.claude/skills/$" .gitignore
grep -q "^\.claude/agents/$" .gitignore
grep -q "^--ignore docs$" .reapack-index.conf
test -f docs/design/README.md
! grep -q "pal.bg_main\|pad_xs\|rounding_sm\|spacing_sm" .agents/agents/ui_agent.md
grep -q "Implements approved ReaImGui UI changes" .agents/agents/ui_agent.md
grep -q "apply exactly the listed items" .agents/agents/ui_agent.md
grep -q "Implements approved ReaImGui UI changes" .claude/agents/ui_agent.md
echo PREREQS-OK'
```

Expected: FAIL (no `PREREQS-OK` line; first failing grep aborts with exit 1).

- [ ] **Step 2: Edit `ui_agent.md` (spec §7.1)**

Run exactly this (it rewrites the description, replaces sections 1–3 with pointers to `theme.lua`, fixes the lint wording and adds the batch rule):

```bash
cd /Users/macstudio/Development/fancy-scripts && python3 - <<'PYEOF'
import re
p = ".agents/agents/ui_agent.md"
t = open(p, encoding="utf-8").read()

t = re.sub(r"^description:.*$",
  "description: Implements approved ReaImGui UI changes for Fancy Scripts (design docs from reaimgui-ux-design, fix batches from reaimgui-ux-review) using _lib/theme.lua.",
  t, count=1, flags=re.M)

new_sections = """### 1. Color & Palette
- Colours come only from `Theme.build_palette()` / `Theme.get_palette()`. The valid keys are the `P.<key>` assignments inside `build_palette` in `_lib/theme.lua` (section "PALETTE BUILDER"); read them there instead of assuming names.
- Never hardcode a hex colour and never define a script-local colour table.

### 2. Layout Dimensions & Spacing Tokens
- Spacing, padding, rounding and sizes come from `Theme.layout.*` (`_lib/theme.lua`, section "DESIGN TOKENS — LAYOUT"): the `xs…xxxl` scale, `rounding`, `btn_*`, `icon_*`, `modal_*`, `row_h`. Read the table there for the real keys; never invent `pad_*`, `rounding_*` or `spacing_*` keys.
- Separate sections with `reaper.ImGui_Dummy(ctx, 0, Theme.layout.<scale key>)`. Do not stack consecutive `ImGui_Spacing()` calls.
- Section-drawing functions render only their own content, with no trailing spacer; the parent owns inter-section spacing.

### 3. Typography & Fonts
- Call `Theme.create_fonts()` and `Theme.attach_fonts()` once at startup. Sizes come from `Theme.font_sizes.*`; valid font keys are the `fonts.<key>` assignments in `Theme.create_fonts`.
- Switch fonts with `local pushed = Theme.push_font(ctx, font)` … `Theme.pop_font(ctx, pushed)`.
- Never call `reaper.ImGui_CreateFont()` in a script.

"""
t, n = re.subn(r"### 1\. Color & Palette.*?(?=### 4\. )", new_sections, t, count=1, flags=re.S)
assert n == 1, "sections 1-3 not found"

t = t.replace(
  "4. Perform lint validation (`luacheck .`) on any modified scripts before reporting completion.",
  "4. Run `luacheck <modified files>` and compare against the baseline given in the batch prompt before reporting completion.")
t = t.replace(
  "- **Linter**: Run `luacheck .` before finishing to verify 0 errors and no unused/undeclared variables.",
  "- **Linter**: Run `luacheck <modified files>` and compare against the baseline given in the batch prompt; introduce no new warnings.\n"
  "- **Batches**: When given a batch from a reaimgui-ux-* session, apply exactly the listed items; do not invoke skills.")
open(p, "w", encoding="utf-8").write(t)
PYEOF
sh .agents/sync-claude.sh
```

Expected: last line `Synced agents to .claude/agents/`; `grep -c "pad_xs" .agents/agents/ui_agent.md` prints `0`.

- [ ] **Step 3: Edit `AGENTS.md` (spec §7.2: HC1–HC6 + routing text)**

```bash
cd /Users/macstudio/Development/fancy-scripts && python3 - <<'PYEOF'
p = "AGENTS.md"
t = open(p, encoding="utf-8").read()
i = t.index("All graphical interfaces in Fancy Scripts use the shared design system in `_lib/theme.lua`.")
j = t.index("## ReaPack Header (mandatory)")
new = """All graphical interfaces in Fancy Scripts use the shared design system in `_lib/theme.lua`.

**Routing.** New UI, a new section, or a redesign → `reaimgui-ux-design` (design doc first; when brainstorming a UI task, it is brainstorming's design method and `docs/design/<slug>.md` is the spec). Review or polish of existing UI → `reaimgui-ux-review`. `UI Agent` (`.agents/agents/ui_agent.md`) implements approved designs and fix batches only.

### House conventions (HC1–HC6)

Rule rows in UX reviews and design docs cite these as `HCn`. Implementation recipes live in the review skill's `references/recipes.md`.

- **HC1 Contrast.** WCAG 2.x ratios measured after compositing alpha in sRGB over the real surface (`bg` windows; `panel` popups, modals, tooltips; `card` inside frames). Text under 3:1 = severity 4, 3–4.49:1 = severity 3. State indicators and input boundaries under 3:1 = severity 3. Controls inside `BeginDisabled`, pure separators and `brand_icon` are exempt.
- **HC2 Fine adjust.** Parameter value controls only: Ctrl-drag (Cmd-drag on macOS, tested via `Mod_Ctrl`) and Ctrl/Cmd+wheel fine-adjust. Never repurpose Shift or Alt (REAPER: this-track-only, elastic audition). Sliders cannot fine-adjust; use Drag widgets.
- **HC3 Reset / type.** Parameter value controls only: double-click resets to the script's `DEFAULTS` value as one undo point; Ctrl/Cmd-click released without dragging opens text entry; right-click opens the context menu.
- **HC4 Destructive actions.** No confirm only if one Ctrl/Cmd+Z restores everything the user can see: all writes inside one undo block, the model reloads when `GetProjectStateChangeCount` changes, and no ExtState/JSON/file/cache is changed. Otherwise show a confirm modal naming the consequence and count, Cancel first, Esc = Cancel. Undoable destructive actions still post a status message.
- **HC5 Esc.** Innermost first: modal → active edit (revert) → selection → window. Route through `Shortcut()`, never bare `IsKeyPressed(Key_Escape)`. Close the window only when it is floating.
- **HC6 Space.** While the window is focused, no text field is active and no modal is open, forward Space (and each modifier chord) to the command the user bound in REAPER's Main section (fallback action 40044).

"""
open(p, "w", encoding="utf-8").write(t[:i] + new + t[j:])
PYEOF
git diff --stat -- AGENTS.md
```

Expected: `AGENTS.md | NN ++++…-` (one file changed; only the "UI / UX Architecture" region).

- [ ] **Step 4: Ignore rules, ReaPack ignore, design-docs README (spec §7.5–7.7)**

```bash
cd /Users/macstudio/Development/fancy-scripts
printf '\n# Claude Code skill/agent symlinks into .agents/ (local-only, see docs/superpowers/specs)\n.claude/skills/\n.claude/agents/\n' >> .gitignore
printf -- '--ignore docs\n' >> .reapack-index.conf
mkdir -p docs/design
cat > docs/design/README.md <<'MDEOF'
# Design docs

Approved UI designs for Fancy Scripts live here, one file per script (or per script suite).

- **Written by** the `reaimgui-ux-design` skill, **before** any ImGui code is drawn. A design doc is the approved layout, states, interaction spec, copy deck and acceptance criteria for a script's UI.
- **Slug rule.** The script filename without `Fancy_` and `.lua`, lower-cased, spaces as hyphens: `Fancy_Pan Snap.lua` → `pan-snap.md`. A multi-script suite uses its settings script's slug (Mapper → `mapper-settings.md`).
- **Header.** Every doc starts with a `Target file(s):` line (repo-relative paths), the archetype per window, `Status: Draft | Approved`, the date and the approver.
- **Review.** The `reaimgui-ux-review` skill finds a doc by grepping this directory for the target's `Target file(s):` line and checks the built UI against it **only when `Status: Approved`**. Drafts are ignored.
- **Not published.** `.reapack-index.conf` ignores `docs`, so nothing here ships through ReaPack.
MDEOF
tail -4 .gitignore; tail -2 .reapack-index.conf
```

Expected: `.gitignore` ends with the two `.claude/…/` lines; `.reapack-index.conf` ends `--ignore .*` then `--ignore docs`.

- [ ] **Step 5: Re-run the Step 1 check; it must pass**

Run the same `sh -c '…'` command from Step 1.
Expected: prints `PREREQS-OK`.

Then confirm nothing else moved:

```bash
cd /Users/macstudio/Development/fancy-scripts && git status --short
```

Expected: your pre-existing modified/untracked entries, plus ` M .gitignore`, ` M .reapack-index.conf`, ` M AGENTS.md`, `?? docs/design/`, `?? docs/superpowers/plans/` (and the spec's directory as before). No script under `FX/ Metering/ Pitch/ Routing/ Utility/` changes beyond what was already listed at session start.

- [ ] **Step 6: Commit the tracked files only (PD3, PD4)**

```bash
cd /Users/macstudio/Development/fancy-scripts && git add AGENTS.md .gitignore .reapack-index.conf docs/design/README.md docs/superpowers/plans/2026-09-29-reaimgui-ux-skills-p1.md && git commit -m "docs: add HC1-HC6 conventions, UX routing, design-docs dir and ignore rules for the ReaImGui UX skills (P1 prereqs)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

Expected: one commit; `git show --stat HEAD` lists exactly those five paths.

---

### Task 2: `ai-skeptic-reviewer` routing line (spec §7.3, with the baseline first)

**Files:**
- Modify: `.agents/skills/ai-skeptic-reviewer/SKILL.md` (local, gitignored; the `.claude/skills/` symlink already points here)
- Store: `<scratchpad>/ux-skill-tests/p1/ai-skeptic-baseline.md` and `ai-skeptic-after.md`

**Interfaces:**
- Consumes: HC/routing text from Task 1 (not required by the edit itself).
- Produces: one line in the skill's "Design system (Tier 2)" bullet pointing UX reviews at `reaimgui-ux-review`.

Scratchpad root for this session: `/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/d105a67a-6ede-4b93-a374-961947e82d8f/scratchpad` (call it `$SP`).

- [ ] **Step 1: Baseline (RED). Record how the skill behaves today**

Dispatch one fresh general-purpose subagent (Agent tool) with this prompt, and save its full reply to `$SP/ux-skill-tests/p1/ai-skeptic-baseline.md`:

> Read `/Users/macstudio/Development/fancy-scripts/.agents/skills/ai-skeptic-reviewer/SKILL.md` and follow it. Task: "Do a UX and visual design review of the UI in `Routing/Fancy_Pan Snap.lua`: hierarchy, alignment, contrast, discoverability." Read-only: do not edit any file. In your reply state (a) which parts of the skill you applied and (b) whether you performed the UX review yourself or redirected it elsewhere.

Expected: the reply shows the skill performing (or attempting) the UX review itself, with no redirect. That is the failure the new line must fix. If it already redirects, note that in the ledger and still add the line (the spec requires it).

- [ ] **Step 2: Add the line**

```bash
cd /Users/macstudio/Development/fancy-scripts && python3 - <<'PYEOF'
p = ".agents/skills/ai-skeptic-reviewer/SKILL.md"
t = open(p, encoding="utf-8").read()
old = "Prefer existing `Theme`/`Utils` helpers over new widgets (Tier 2 #5)."
assert t.count(old) == 1, "anchor not unique"
new = old + "\n  For a UX, visual or design-system review of a ReaImGui UI, use reaimgui-ux-review; here, flag only design-system violations introduced by the diff."
open(p, "w", encoding="utf-8").write(t.replace(old, new))
PYEOF
grep -n "use reaimgui-ux-review; here, flag only" .agents/skills/ai-skeptic-reviewer/SKILL.md
```

Expected: one matching line, inside the "Design system (Tier 2)" bullet.

- [ ] **Step 3: Re-run the same subagent prompt (GREEN)**

Dispatch a fresh subagent with the identical prompt from Step 1 and save the reply to `$SP/ux-skill-tests/p1/ai-skeptic-after.md`.
Expected: it applies the overlay line, states that a full UX review belongs to `reaimgui-ux-review` (which does not exist until P2, so it may say "not installed yet"), and limits itself to design-system violations introduced by a diff. If it still performs an unscoped UX review, reword the line once for clarity (keep the spec's sentence intact and add a leading "IMPORTANT:"), re-run, and ledger the wording as a `Ruling:`.

- [ ] **Step 4: Confirm nothing else in the skill changed**

Run: `cd /Users/macstudio/Development/fancy-scripts && sh -c 'grep -q "use reaimgui-ux-review; here, flag only" .agents/skills/ai-skeptic-reviewer/SKILL.md && test -s "/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/d105a67a-6ede-4b93-a374-961947e82d8f/scratchpad/ux-skill-tests/p1/ai-skeptic-after.md" && echo SKEPTIC-OK'`
Expected: `SKEPTIC-OK`. No commit: the file is gitignored (PD3).

---

### Task 3: `ds-lint.py` core: lexer, CLI, self-test harness, CN2 hex probe

**Files:**
- Create: `.agents/skills/reaimgui-ux-review/scripts/ds-lint.py`

**Interfaces:**
- Consumes: nothing.
- Produces (later tasks extend these exact names):
  - `lex_lua(src) -> (nocomment, code)`; `Src(text, path)` with `.text .path .nocomment .code .is_lib`, `.line(pos) -> int (1-based)`, `.lines() -> list[str]` (of `code`)
  - `finding(src, rule, conf, msg, pos=None, line=None, **extra) -> dict` with keys `file line rule conf msg` plus extras
  - `@probe(scripts_only=False)` decorator; `PROBES`; `lint_src(src, ctx) -> list[dict]` sorted by `(line, rule)`
  - `Call` (`.pos .close .args .cargs`), `call_args(code, open_idx)`, `find_calls(src, pattern) -> iterator[Call]` (`pattern` has no trailing paren)
  - `Ctx` (stub here: `.theme = None`, `.palette_matches(val) -> []`), `make_ctx(theme_path, files) -> Ctx`
  - `SELF_TESTS` (fixture dicts: `name`, `src`, optional `path`, `want`: `[(rule, conf, line[, extras])]`, `forbid`: `[(rule, conf|None, line|None)]`), `UNIT_TESTS: [(name, fn)]`, `CLI_TESTS`
  - `main(argv)`; exit codes 0 / 1 / 2

- [ ] **Step 1: Create the harness with fixtures but no probe (RED)**

Create `/Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py` with exactly this content:

```python
#!/usr/bin/env python3
"""ds-lint: mechanical UX / design-system probes for Fancy Scripts (ReaImGui 0.10, Lua 5.4).

A review aid for the reaimgui-ux-review skill, NOT a CI gate. Python 3 stdlib only.
Exit codes: 0 = no `definite` findings, 1 = `definite` findings, 2 = usage or theme-parse error.
"""
import argparse
import bisect
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


class LintError(Exception):
    """Usage or theme-parse failure: reported on stderr, exit code 2."""


# -----------------------------------------------------------------------------
# 1. LEXER: blank Lua comments and string literals
# -----------------------------------------------------------------------------

def _blank(chars, a, b):
    for k in range(a, b):
        if chars[k] != "\n":
            chars[k] = " "


def lex_lua(src):
    """Return (nocomment, code), both the same length as src, newlines preserved.

    nocomment: comments blanked, string contents kept (for probes that read ids and labels).
    code:      comments AND string contents blanked, quotes kept (for structural probes).
    """
    n = len(src)
    nc, cd = list(src), list(src)
    i = 0
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:i + 40])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + m.end())
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            _blank(nc, i, j)
            _blank(cd, i, j)
            i = j
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            j = min(j, n)
            _blank(cd, i + 1, j)
            i = j + 1
        elif c == "[":
            m = re.match(r"\[(=*)\[", src[i:i + 40])
            if m:
                close = "]" + m.group(1) + "]"
                k = src.find(close, i + m.end())
                end = n if k < 0 else k
                _blank(cd, i + m.end(), end)
                i = n if k < 0 else k + len(close)
            else:
                i += 1
        else:
            i += 1
    return "".join(nc), "".join(cd)


class Src:
    """One Lua file: raw text plus its blanked views and a position -> line map."""

    def __init__(self, text, path):
        self.text = text
        self.path = path
        self.nocomment, self.code = lex_lua(text)
        self._nl = [m.start() for m in re.finditer("\n", text)]
        self.is_lib = "/_lib/" in path.replace("\\", "/")
        self._lines = None

    def line(self, pos):
        return bisect.bisect_left(self._nl, pos) + 1

    def lines(self):
        if self._lines is None:
            self._lines = self.code.split("\n")
        return self._lines


def finding(src, rule, conf, msg, pos=None, line=None, **extra):
    d = {"file": src.path, "line": line if line is not None else src.line(pos),
         "rule": rule, "conf": conf, "msg": msg}
    d.update(extra)
    return d


# -----------------------------------------------------------------------------
# 2. CALL PARSING AND PROBE REGISTRY
# -----------------------------------------------------------------------------

class Call:
    def __init__(self, pos, close, args, cargs):
        self.pos = pos        # offset of the call name
        self.close = close    # offset of the closing paren
        self.args = args      # argument texts, strings kept
        self.cargs = cargs    # argument texts, strings blanked


def call_args(code, open_idx):
    """open_idx points at '('. Return (close_idx, [(start, end), ...]) of the top-level arguments."""
    depth, spans, start = 0, [], open_idx + 1
    for i in range(open_idx, len(code)):
        ch = code[i]
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
            if depth == 0:
                if code[start:i].strip():
                    spans.append((start, i))
                return i, spans
        elif ch == "," and depth == 1:
            spans.append((start, i))
            start = i + 1
    return len(code) - 1, spans


def find_calls(src, pattern):
    """Yield a Call for every `pattern(` in the blanked code. `pattern` has no trailing paren."""
    rx = re.compile("(?:%s)\\s*\\(" % pattern)
    for m in rx.finditer(src.code):
        close, spans = call_args(src.code, m.end() - 1)
        yield Call(m.start(), close,
                   [src.nocomment[a:b].strip() for a, b in spans],
                   [src.code[a:b].strip() for a, b in spans])


PROBES = []


def probe(scripts_only=False):
    """Register a probe fn(src, ctx) -> list[finding]. scripts_only probes skip _lib/ files."""
    def deco(fn):
        PROBES.append((fn, scripts_only))
        return fn
    return deco


def lint_src(src, ctx):
    out = []
    for fn, scripts_only in PROBES:
        if scripts_only and src.is_lib:
            continue
        out.extend(fn(src, ctx))
    out.sort(key=lambda f: (f["line"], f["rule"]))
    return out


# -----------------------------------------------------------------------------
# 3. CONTEXT (theme introspection is added in Task 4)
# -----------------------------------------------------------------------------

class Ctx:
    def __init__(self, theme=None):
        self.theme = theme

    def palette_matches(self, val):
        return []


def make_ctx(theme_path, files):
    return Ctx()


# -----------------------------------------------------------------------------
# 4. PROBES
# -----------------------------------------------------------------------------
# (probes are added by Tasks 3, 6 and 7)


# -----------------------------------------------------------------------------
# 5. SELF-TEST FIXTURES
# -----------------------------------------------------------------------------

SELF_TESTS = [
    {"name": "hex flagged",
     "src": "local c = 0x8B70FAFF\n",
     "want": [("CN2", "definite", 1)]},
    {"name": "hex in comments and strings ignored",
     "src": ("-- 0x8B70FAFF\nlocal s = \"0x123456\" -- 0xFFFFFF\n"
             "--[==[ 0x8B70FAFF\n]==]\nlocal l = [[ 0x8B70FAFF ]]\n"),
     "forbid": [("CN2", None, None)]},
    {"name": "comment markers inside strings do not open comments",
     "src": "local s = \"a -- b\"\nlocal c = 0x8B70FAFF\n",
     "want": [("CN2", "definite", 2)]},
    {"name": "CRLF keeps line numbers",
     "src": "local a = 1\r\nlocal b = 2\r\nlocal c = 0x8B70FAFF\r\n",
     "want": [("CN2", "definite", 3)]},
    {"name": "8-digit bitmask operands not flagged",
     "src": ("local a = (rgba & 0xFFFFFF00) | alpha\nlocal b = x & 0x00FFFFFF\n"
             "local c = 0xFF000000 ~ y\n"),
     "forbid": [("CN2", None, None)]},
    {"name": "6-digit bitmask not flagged",
     "src": "local n = fxnum & 0xFFFFFF\n",
     "forbid": [("CN2", None, None)]},
    {"name": "transparent colour is check, not definite",
     "src": "local t = 0x00000000\n",
     "want": [("CN2", "check", 1)],
     "forbid": [("CN2", "definite", None)]},
    {"name": "empty file",
     "src": "",
     "forbid": [("CN2", None, None)]},
]

UNIT_TESTS = []   # (name, fn) pairs; fn raises AssertionError on failure

# (name, cli args with @F@ = temp file, input kwargs for the temp file, expected exit code, stdout substring)
CLI_TESTS = [
    ("clean file exits 0", ["@F@"], {"text": "local x = 1\n"}, 0, None),
    ("definite finding exits 1", ["@F@"], {"text": "local c = 0x8B70FAFF\n"}, 1, "CN2"),
    ("--json output", ["--json", "@F@"], {"text": "local c = 0x8B70FAFF\n"}, 1, '"rule": "CN2"'),
    ("empty file exits 0", ["@F@"], {"text": ""}, 0, None),
    ("comment-only file exits 0", ["@F@"], {"text": "-- just a comment\n--[[ block\n]]\n"}, 0, None),
    ("non-utf8 bytes are linted, not fatal", ["@F@"],
     {"raw": b"local s = '\xff\xfe'\nlocal c = 0x8B70FAFF\n"}, 1, "CN2"),
    ("missing file exits 2", ["/nonexistent/x.lua"], {}, 2, None),
]


class Tally:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def ok(self):
        self.passed += 1

    def fail(self, name, detail):
        self.failed += 1
        print("FAIL %s: %s" % (name, detail))


def _matches(f, rule, conf, line, extra):
    if f["rule"] != rule:
        return False
    if conf is not None and f["conf"] != conf:
        return False
    if line is not None and f["line"] != line:
        return False
    return all(f.get(k) == v for k, v in (extra or {}).items())


def _cli(args, text=None, raw=None):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "t.lua")
        if raw is not None:
            with open(path, "wb") as fh:
                fh.write(raw)
        elif text is not None:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
        cmd = [sys.executable, os.path.abspath(__file__)] + [a.replace("@F@", path) for a in args]
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r.returncode, r.stdout, r.stderr


def run_self_test():
    ctx = make_ctx(None, [])
    t = Tally()
    for case in SELF_TESTS:
        found = lint_src(Src(case["src"], case.get("path", "fixture.lua")), ctx)
        ok = True
        for w in case.get("want", []):
            extra = w[3] if len(w) > 3 else None
            if not any(_matches(f, w[0], w[1], w[2], extra) for f in found):
                t.fail(case["name"], "missing %s (got %s)" % (
                    (w,), [(f["rule"], f["conf"], f["line"]) for f in found]))
                ok = False
        for w in case.get("forbid", []):
            hits = [f for f in found if _matches(f, w[0], w[1], w[2], None)]
            if hits:
                t.fail(case["name"], "forbidden %s at line %d: %s" % (w[:3], hits[0]["line"], hits[0]["msg"]))
                ok = False
        if ok:
            t.ok()
    for name, fn in UNIT_TESTS:
        try:
            fn()
            t.ok()
        except AssertionError as e:
            t.fail(name, e)
    for name, args, inp, want_code, want_out in CLI_TESTS:
        code, out, err = _cli(args, **inp)
        if code != want_code:
            t.fail(name, "exit %d, wanted %d; stderr: %s" % (code, want_code, err.strip()))
        elif want_out and want_out not in out:
            t.fail(name, "stdout lacks %r" % want_out)
        else:
            t.ok()
    print("self-test: %d passed, %d failed" % (t.passed, t.failed))
    return 1 if t.failed else 0


# -----------------------------------------------------------------------------
# 6. CLI
# -----------------------------------------------------------------------------

def read_text(path):
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", errors="replace")
    except OSError as e:
        raise LintError("cannot read %s: %s" % (path, e.strerror))


def run(args, ap):
    if args.self_test:
        return run_self_test()
    if not args.files:
        ap.error("no input files")
    ctx = make_ctx(None, args.files)
    findings = []
    for path in args.files:
        findings.extend(lint_src(Src(read_text(path), path), ctx))
    if args.json:
        print(json.dumps(findings, indent=2))
    else:
        for f in findings:
            print("%s:%d: %s [%s] %s" % (f["file"], f["line"], f["rule"], f["conf"], f["msg"]))
    return 1 if any(f["conf"] == "definite" for f in findings) else 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="ds-lint.py",
        description="Mechanical UX / design-system probes for Fancy Scripts ReaImGui code.")
    ap.add_argument("files", nargs="*", help="Lua files to lint")
    ap.add_argument("--json", action="store_true", help="machine-readable findings")
    ap.add_argument("--self-test", action="store_true", help="run the embedded fixtures")
    args = ap.parse_args(argv)
    try:
        return run(args, ap)
    except LintError as e:
        print("ds-lint: error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run the self-test to see it fail**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `FAIL` lines for `hex flagged`, `comment markers inside strings do not open comments`, `CRLF keeps line numbers`, `transparent colour is check, not definite` (missing findings) and for the three CLI tests that expect exit 1 (`definite finding exits 1`, `--json output`, `non-utf8 bytes are linted, not fatal`); then `self-test: 8 passed, 7 failed` and `exit=1`. (The `forbid`-only fixtures and exit-0/2 CLI tests already pass.)

- [ ] **Step 3: Add the CN2 hex probe**

In `ds-lint.py`, replace the line `# (probes are added by Tasks 3, 6 and 7)` with:

```python
HEX_RE = re.compile(r"(?<![\w.])0[xX]([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\b")
BIT_OPS = ("&", "|", "<<", ">>")


def _bitop_operand(code, m):
    """True when the literal is an operand of &, |, ~, << or >> (a mask, not a colour)."""
    before = code[max(0, m.start() - 40):m.start()].rstrip()
    after = code[m.end():m.end() + 40].lstrip()
    if before.endswith(BIT_OPS) or before.endswith("~"):
        return True
    return after.startswith(BIT_OPS) or (after.startswith("~") and not after.startswith("~="))


@probe(scripts_only=True)
def probe_hex(src, ctx):
    out = []
    for m in HEX_RE.finditer(src.code):
        if _bitop_operand(src.code, m):
            continue
        digits = m.group(1)
        val = int(digits, 16)
        if len(digits) == 6:
            val = (val << 8) | 0xFF
        if len(digits) == 8 and val == 0:
            out.append(finding(src, "CN2", "check", "transparent 0x00000000; use Theme.with_alpha(<palette key>, 0)",
                               pos=m.start()))
            continue
        extra = {}
        keys = ctx.palette_matches(val)
        if keys:
            extra = {"palette": keys}
        out.append(finding(src, "CN2", "definite", "hex colour literal 0x%s; use a palette key" % digits,
                           pos=m.start(), **extra))
    return out
```

- [ ] **Step 4: Run the self-test to see it pass**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `self-test: 15 passed, 0 failed` and `exit=0`.

- [ ] **Step 5: Confirm luacheck is unaffected and record**

Run: `cd /Users/macstudio/Development/fancy-scripts && luacheck . 2>&1 | tail -1`
Expected: same warning/error totals as before this task (no `.lua` files were added). No commit: gitignored (PD3).

---

### Task 4: Theme introspection, palette-aware hex findings, Match-Theme dependency map

**Files:**
- Modify: `.agents/skills/reaimgui-ux-review/scripts/ds-lint.py`

**Interfaces:**
- Consumes: Task 3's `lex_lua`, `Ctx`, `make_ctx`, `SELF_TESTS`, `UNIT_TESTS`, `CLI_TESTS`, `finding`, `probe_hex`.
- Produces:
  - `parse_theme_text(text, path) -> dict` and `parse_theme(path) -> dict` with keys: `path`, `names` (set of `Theme.<name>`), `icons` (set), `layout` (`{key: None | {subkey: None}}`), `font_sizes` (set), `font_keys` (set of `fonts.<key>` from `create_fonts`), `scale` (`{xs: int, …}`), `modals` (`{modal_sm: (w, h), …}`), `palette_keys` (set), `palette` (`{key: 0xRRGGBBAA}` for Fancy Dark), `mode_dep` (set of keys that depend on REAPER's theme in Match mode)
  - `Ctx(theme)` with `.theme`, `.palette_matches(val) -> sorted list of keys`, `.is_mode_dep(keys) -> bool`
  - `find_theme(start) -> path | None`; `make_ctx(theme_path, files) -> Ctx`; CLI `--theme PATH`
  - `_subst(text, theme)` fixture placeholder expander: `@ACCENT@`, `@S:<scalekey>@`, `@MW:<modalkey>@`, `@MH:<modalkey>@`
  - `LintError` on any theme-parse failure, exit 2

- [ ] **Step 1: Write the failing fixtures and unit tests**

In `ds-lint.py`, **append** these entries to `SELF_TESTS` (before the closing `]`):

```python
    {"name": "hex matching a palette key reports the key and mode dependence",
     "src": "local c = @ACCENT@\nlocal d = 0x010203FF\n",
     "want": [("CN2", "definite", 1, {"palette": ["accent"], "mode_dependent": True}),
              ("CN2", "definite", 2)]},
```

Then add this block **after** the `UNIT_TESTS = []` line and add the CLI test shown after it:

```python
def _real_theme():
    path = find_theme(HERE)
    assert path, "no _lib/theme.lua found above %s" % HERE
    return parse_theme(path)


def _ut_theme_names():
    T = _real_theme()
    assert {"with_alpha", "badge_button", "push", "build_palette", "icon_btn"} <= T["names"], sorted(T["names"])[:8]
    assert {"gear", "plus"} <= T["icons"]


def _ut_theme_layout():
    T = _real_theme()
    assert {"xs", "sm", "md", "lg", "xl", "xxl", "xxxl"} <= set(T["layout"])
    assert T["scale"]["xs"] < T["scale"]["sm"] < T["scale"]["xxxl"]
    assert set(T["layout"]["modal_sm"]) == {"w", "h"}
    assert isinstance(T["modals"]["modal_sm"], tuple) and len(T["modals"]["modal_sm"]) == 2
    assert {"pad_x", "pad_y"} <= set(T["layout"]["btn_sm"])


def _ut_theme_fonts():
    T = _real_theme()
    assert "default_bold" in T["font_keys"] and "tooltip" in T["font_keys"]
    assert "bold" not in T["font_keys"], "fonts.bold must not be a valid key"
    assert "default" in T["font_sizes"]


def _ut_theme_palette():
    T = _real_theme()
    P = T["palette"]
    assert P["accent_d"] == (P["accent"] & 0xFFFFFF00) | 0x33   # 20% alpha
    assert P["accent_h"] == (P["accent"] & 0xFFFFFF00) | 0x66   # 40% alpha
    assert {"accent", "accent_h", "bg", "sep", "dim_bg"} <= T["mode_dep"], sorted(T["mode_dep"])
    assert not ({"green", "red_h", "yellow_l"} & T["mode_dep"])
    assert set(P) == T["palette_keys"], (set(P) ^ T["palette_keys"])


def _ut_theme_drift_detected():
    path = find_theme(HERE)
    text = open(path, encoding="utf-8").read()
    drifted = text.replace("P.slider_grab_active =", "P.mystery_key =", 1)
    assert drifted != text
    try:
        parse_theme_text(drifted, "drifted.lua")
    except LintError as e:
        assert "mystery_key" in str(e), str(e)
        return
    raise AssertionError("palette drift was not detected")


def _ut_theme_missing():
    try:
        parse_theme("/nonexistent/theme.lua")
    except LintError:
        return
    raise AssertionError("missing theme did not raise LintError")


def _ut_not_a_theme():
    try:
        parse_theme_text("local x = 1\n", "junk.lua")
    except LintError:
        return
    raise AssertionError("junk file accepted as theme.lua")


UNIT_TESTS += [
    ("theme: names and icons", _ut_theme_names),
    ("theme: layout, scale, modal presets", _ut_theme_layout),
    ("theme: font keys", _ut_theme_fonts),
    ("theme: palette values and Match-Theme dependency", _ut_theme_palette),
    ("theme: palette drift is detected", _ut_theme_drift_detected),
    ("theme: missing file raises", _ut_theme_missing),
    ("theme: junk file raises", _ut_not_a_theme),
]
```

Append to `CLI_TESTS`:

```python
    ("--theme pointing nowhere exits 2", ["--theme", "/nonexistent/theme.lua", "@F@"],
     {"text": "local x = 1\n"}, 2, None),
```

And in `run_self_test`, replace the line `found = lint_src(Src(case["src"], case.get("path", "fixture.lua")), ctx)` with:

```python
        found = lint_src(Src(_subst(case["src"], ctx.theme), case.get("path", "fixture.lua")), ctx)
```

- [ ] **Step 2: Run to see it fail**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `NameError` traceback for `_subst` (the harness change) or `find_theme`, exit non-zero. That is the RED: the functions do not exist yet.

- [ ] **Step 3: Implement theme introspection**

Add this new section **between** `# 3. CONTEXT` and `# 4. PROBES`, and **delete** the Task 3 stub `class Ctx` and `def make_ctx` (the section below replaces them):

```python
# -----------------------------------------------------------------------------
# 3. THEME INTROSPECTION (theme.lua is the only source of token values)
# -----------------------------------------------------------------------------

BASE_KEYS = ("bg", "panel", "card", "text", "text_dim", "accent", "border", "green", "red", "yellow", "blue")


def _with_alpha(c, a):
    return (c & 0xFFFFFF00) | max(0, min(255, int(a * 255 + 0.5)))


def _lighten(c, f):
    out = 0
    for shift in (24, 16, 8):
        v = (c >> shift) & 0xFF
        out |= max(0, min(255, int(v + (255 - v) * f + 0.5))) << shift
    return out | (c & 0xFF)


def _darken(c, f):
    out = 0
    for shift in (24, 16, 8):
        v = (c >> shift) & 0xFF
        out |= max(0, min(255, int(v * (1.0 - f) + 0.5))) << shift
    return out | (c & 0xFF)


# Python port of the derived keys in Theme.build_palette: (key, source keys, value fn).
# parse_theme_text() fails loudly if theme.lua assigns a P.<key> that is not listed here.
DERIVED = [
    ("accent2", ("blue",), lambda P: P["blue"]),
    ("green_h", ("green",), lambda P: _with_alpha(P["green"], 0.40)),
    ("green_d", ("green",), lambda P: _with_alpha(P["green"], 0.20)),
    ("red_h", ("red",), lambda P: _with_alpha(P["red"], 0.40)),
    ("red_d", ("red",), lambda P: _with_alpha(P["red"], 0.20)),
    ("blue_h", ("blue",), lambda P: _with_alpha(P["blue"], 0.40)),
    ("blue_d", ("blue",), lambda P: _with_alpha(P["blue"], 0.20)),
    ("blue_e", ("blue",), lambda P: _with_alpha(P["blue"], 0.125)),
    ("accent2_h", ("blue_h",), lambda P: P["blue_h"]),
    ("accent2_d", ("blue_d",), lambda P: P["blue_d"]),
    ("accent2_e", ("blue_e",), lambda P: P["blue_e"]),
    ("accent_h", ("accent",), lambda P: _with_alpha(P["accent"], 0.40)),
    ("accent_d", ("accent",), lambda P: _with_alpha(P["accent"], 0.20)),
    ("accent_e", ("accent",), lambda P: _with_alpha(P["accent"], 0.125)),
    ("accent_l", ("accent",), lambda P: _lighten(P["accent"], 0.70)),
    ("accent2_l", ("accent2",), lambda P: _lighten(P["accent2"], 0.70)),
    ("blue_l", ("accent2_l",), lambda P: P["accent2_l"]),
    ("green_l", ("green",), lambda P: _lighten(P["green"], 0.70)),
    ("red_l", ("red",), lambda P: _lighten(P["red"], 0.70)),
    ("yellow_l", ("yellow",), lambda P: _lighten(P["yellow"], 0.70)),
    ("sep", ("accent",), lambda P: _with_alpha(P["accent"], 0.20)),
    ("dim_bg", ("bg",), lambda P: _with_alpha(_darken(P["bg"], 0.70), 0.85)),
    ("table_row", ("panel",), lambda P: _darken(P["panel"], 0.10)),
    ("table_row_alt", ("panel",), lambda P: P["panel"]),
    ("slider_grab_active", ("accent",), lambda P: _lighten(P["accent"], 0.15)),
]


def brace_end(code, open_idx):
    depth = 0
    for i in range(open_idx, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    raise LintError("theme.lua: unbalanced braces")


KEY_RE = re.compile(r"\s*([A-Za-z_]\w*)\s*=(?!=)\s*")


def table_keys(code, open_idx):
    """Top-level keys of the Lua table literal whose '{' is at open_idx: {key: None | {subkey: ...}}."""
    close = brace_end(code, open_idx)
    keys, depth, i, expect = {}, 0, open_idx + 1, True
    while i < close:
        ch = code[i]
        if depth == 0 and expect:
            m = KEY_RE.match(code, i)
            if m:
                name, i = m.group(1), m.end()
                if i < close and code[i] == "{":
                    keys[name] = table_keys(code, i)
                    i = brace_end(code, i) + 1
                else:
                    keys[name] = None
                expect = False
                continue
            if not ch.isspace():
                expect = False
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        elif ch == "," and depth == 0:
            expect = True
        i += 1
    return keys


def _table_at(code, pattern, label):
    m = re.search(pattern, code, re.M)
    if not m:
        raise LintError("theme.lua: %s table not found" % label)
    return table_keys(code, m.end() - 1)


def _func_body(code, name):
    m = re.search(r"^function\s+%s\s*\(" % re.escape(name), code, re.M)
    if not m:
        raise LintError("theme.lua: function %s not found" % name)
    e = re.search(r"^end\b", code[m.end():], re.M)
    if not e:
        raise LintError("theme.lua: function %s has no closing end" % name)
    return code[m.end():m.end() + e.start()]


def parse_theme_text(text, path="theme.lua"):
    _, code = lex_lua(text)
    T = {"path": path}
    T["names"] = (set(re.findall(r"^function\s+Theme\.(\w+)\s*\(", code, re.M))
                  | set(re.findall(r"^Theme\.(\w+)\s*=", code, re.M)))
    T["icons"] = set(re.findall(r"^function\s+Theme\.icons\.(\w+)\s*\(", code, re.M))
    if len(T["names"]) < 20 or "layout" not in T["names"]:
        raise LintError("%s does not look like theme.lua (found %d Theme.* names)" % (path, len(T["names"])))
    T["layout"] = _table_at(code, r"^Theme\.layout\s*=\s*\{", "Theme.layout")
    T["font_sizes"] = set(_table_at(code, r"^Theme\.font_sizes\s*=\s*\{", "Theme.font_sizes"))
    T["font_keys"] = set(re.findall(r"\bfonts\.(\w+)\s*=", _func_body(code, "Theme.create_fonts")))
    m = re.search(r"^local S\s*=\s*\{([^}]*)\}", code, re.M)
    T["scale"] = {k: int(v) for k, v in re.findall(r"(\w+)\s*=\s*(\d+)", m.group(1))} if m else {}
    T["modals"] = {}
    for k in T["layout"]:
        if k.startswith("modal_"):
            mm = re.search(r"\b%s\s*=\s*\{\s*w\s*=\s*(\d+)\s*,\s*h\s*=\s*(\d+)" % re.escape(k), code)
            if mm:
                T["modals"][k] = (int(mm.group(1)), int(mm.group(2)))

    fm = re.search(r"^local FANCY_PALETTE\s*=\s*\{", code, re.M)
    if not fm:
        raise LintError("theme.lua: FANCY_PALETTE table not found")
    span = code[fm.end():brace_end(code, fm.end() - 1)]
    base = {k: int(v, 16) for k, v in re.findall(r"(\w+)\s*=\s*0[xX]([0-9A-Fa-f]{8})", span)}
    missing = [k for k in BASE_KEYS if k not in base]
    if missing:
        raise LintError("theme.lua: FANCY_PALETTE lacks %s" % ", ".join(missing))

    body = _func_body(code, "Theme.build_palette")
    assigned = set(re.findall(r"\bP\.(\w+)\s*=", body))
    ported = {k for k, _, _ in DERIVED}
    extra = sorted(assigned - set(BASE_KEYS) - ported)
    lost = sorted(ported - assigned)
    if extra or lost:
        raise LintError("theme.lua palette drifted from ds-lint's port of build_palette: "
                        "unknown keys %s, keys no longer assigned %s" % (extra, lost))
    P, deps = dict(base), {}
    for key, d, fn in DERIVED:
        P[key] = fn(P)
        deps[key] = d
    T["palette"] = P
    T["palette_keys"] = assigned

    mm = re.search(r"MODE_MATCH\s*then(.*?)\n  end", body, re.S)
    match_keys = set(re.findall(r"P\.(\w+)\s*=\s*overrides\.\w+\s+or\s+read_theme_color", mm.group(1))) if mm else set()
    if not match_keys:
        raise LintError("theme.lua: Match Theme branch of build_palette not found")

    def dependent(key):
        stack, seen = [key], set()
        while stack:
            k = stack.pop()
            if k in match_keys:
                return True
            if k not in seen:
                seen.add(k)
                stack.extend(deps.get(k, ()))
        return False

    T["mode_dep"] = {k for k in P if dependent(k)}
    return T


def parse_theme(path):
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        raise LintError("cannot read theme %s: %s" % (path, e.strerror))
    return parse_theme_text(text, path)


def find_theme(start):
    d = os.path.abspath(start)
    while True:
        cand = os.path.join(d, "_lib", "theme.lua")
        if os.path.isfile(cand):
            return cand
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


class Ctx:
    def __init__(self, theme):
        self.theme = theme

    def palette_matches(self, val):
        return sorted(k for k, v in self.theme["palette"].items() if v == val)

    def is_mode_dep(self, keys):
        return any(k in self.theme["mode_dep"] for k in keys)


def make_ctx(theme_path, files):
    if not theme_path:
        start = os.path.dirname(os.path.abspath(files[0])) if files else HERE
        theme_path = find_theme(start) or find_theme(HERE)
    if not theme_path:
        raise LintError("cannot find _lib/theme.lua; pass --theme PATH")
    return Ctx(parse_theme(theme_path))


def _subst(text, theme):
    """Expand fixture placeholders from the live theme: @ACCENT@, @S:lg@, @MW:modal_sm@, @MH:modal_sm@."""
    if not theme:
        return text
    text = text.replace("@ACCENT@", "0x%08X" % theme["palette"]["accent"])
    text = re.sub(r"@S:(\w+)@", lambda m: str(theme["scale"][m.group(1)]), text)
    text = re.sub(r"@MW:(\w+)@", lambda m: str(theme["modals"][m.group(1)][0]), text)
    return re.sub(r"@MH:(\w+)@", lambda m: str(theme["modals"][m.group(1)][1]), text)
```

Update `probe_hex` (Task 3) so the palette branch also reports mode dependence: replace
`extra = {"palette": keys}` with `extra = {"palette": keys, "mode_dependent": ctx.is_mode_dep(keys)}`.

In `main()` add `ap.add_argument("--theme", help="path to _lib/theme.lua (default: first found walking up)")`, and in `run()` change `ctx = make_ctx(None, args.files)` to `ctx = make_ctx(args.theme, args.files)`.

- [ ] **Step 4: Run to see it pass**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `self-test: 24 passed, 0 failed`, `exit=0` (9 fixtures + 7 unit tests + 8 CLI tests). If `_ut_theme_names` fails on a name, print `sorted(T["names"])` and check how theme.lua declares it (e.g. a `Theme.X, Theme.Y =` multi-assign); fix `parse_theme_text`, never the test's expectation, and ledger a `Ruling:` if the regex needed widening.

- [ ] **Step 5: Sanity-check against the real theme**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py /Users/macstudio/Development/fancy-scripts/_lib/theme.lua; echo "exit=$?"`
Expected: exit 0 or 1 without a traceback (theme.lua is `_lib/`, so the scripts-only probes are skipped). No commit (PD3).

---

### Task 5: `--ui-lines` and `--contrast`

**Files:**
- Modify: `.agents/skills/reaimgui-ux-review/scripts/ds-lint.py`

**Interfaces:**
- Consumes: Task 4's `Ctx.theme["palette"]`, `Src`, `parse_theme`.
- Produces:
  - `ui_line_counts(src) -> (total_nonblank_lines, ui_bearing_lines)` (PD5)
  - `contrast_ratio(rgb_a, rgb_b) -> float`; `contrast_rows(theme) -> [{"pair","fg","bg","kind","ratio","severity"}]`
  - CLI `--ui-lines FILE...` prints `FILE: total=N ui=M`; `--contrast` prints the HC1 table (exit 0); both honour `--json`

- [ ] **Step 1: Write the failing tests**

Append to `UNIT_TESTS` (after the Task 4 block):

```python
_UI_FIXTURE = "\n".join([
    "local x = 1",                       # 1
    "function a()",                      # 2
    "  reaper.ImGui_Text(ctx, 'hi')",    # 3
    "end",                               # 4
    "function b()",                      # 5
    "  return 1",                        # 6
    "end",                               # 7
    "reaper.ImGui_End(ctx)",             # 8
    "-- reaper.ImGui_Text(ctx, 'c')",    # 9 (comment: not counted)
]) + "\n"


def _ut_ui_lines():
    total, ui = ui_line_counts(Src(_UI_FIXTURE, "f.lua"))
    assert total == 8, total          # 9 lines minus the comment-only line
    assert ui == 4, ui                # function a (3 lines) + the ImGui call outside any function


def _ut_ui_lines_one_liner_and_theme_call():
    src = Src("local function f() return reaper.ImGui_Text(ctx, 'x') end\nlocal function g()\n  Theme.push(ctx)\nend\n", "f.lua")
    total, ui = ui_line_counts(src)
    assert (total, ui) == (4, 4), (total, ui)


def _ut_contrast_math():
    assert abs(contrast_ratio((255, 255, 255), (0, 0, 0)) - 21.0) < 1e-6
    assert abs(contrast_ratio((10, 20, 30), (10, 20, 30)) - 1.0) < 1e-9


def _ut_contrast_rows():
    rows = {r["pair"]: r for r in contrast_rows(_real_theme())}
    assert rows["Text on WindowBg"]["ratio"] > 15, rows["Text on WindowBg"]
    assert rows["Text on WindowBg"]["severity"] == 0
    assert {r["kind"] for r in rows.values()} == {"text", "state", "boundary"}
    assert all(r["severity"] in (0, 3, 4) for r in rows.values())


UNIT_TESTS += [
    ("ui-lines: functions, comments, outside calls", _ut_ui_lines),
    ("ui-lines: one-liner function and Theme call", _ut_ui_lines_one_liner_and_theme_call),
    ("contrast: WCAG math", _ut_contrast_math),
    ("contrast: HC1 pair table from the live palette", _ut_contrast_rows),
]
```

Append to `CLI_TESTS`:

```python
    ("--ui-lines prints counts", ["--ui-lines", "@F@"], {"text": _UI_FIXTURE}, 0, "total=8 ui=4"),
    ("--contrast prints the HC1 table", ["--contrast"], {}, 0, "Text on WindowBg"),
```

(`_UI_FIXTURE` must be defined before `CLI_TESTS`; place the `_UI_FIXTURE` definition above the `CLI_TESTS` list if the file order requires it.)

- [ ] **Step 2: Run to see it fail**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `NameError: name 'ui_line_counts' is not defined` (or `contrast_ratio`), non-zero exit.

- [ ] **Step 3: Implement**

Add a new section before `# 4. PROBES`:

```python
# -----------------------------------------------------------------------------
# 3b. METRICS: --ui-lines and --contrast
# -----------------------------------------------------------------------------

FUNC_RE = re.compile(r"^(?:local\s+)?function\b")
UI_CALL = re.compile(r"\breaper\.ImGui_\w+|\bTheme\.\w+")


def ui_line_counts(src):
    """(non-blank code lines, UI-bearing lines). A line is UI-bearing when it sits inside a top-level
    function that contains a reaper.ImGui_ or Theme. call, or is an ImGui call outside any function."""
    lines = src.lines()
    ui, in_func, i = set(), set(), 0
    while i < len(lines):
        if FUNC_RE.match(lines[i]):
            j = i
            if not re.search(r"\bend\b\s*$", lines[i]):
                j = next((k for k in range(i + 1, len(lines)) if re.match(r"end\b", lines[k])), len(lines) - 1)
            body = range(i, j + 1)
            in_func.update(body)
            if any(UI_CALL.search(lines[k]) for k in body):
                ui.update(k for k in body if lines[k].strip())
            i = j + 1
            continue
        i += 1
    for k, line in enumerate(lines):
        if k not in in_func and "reaper.ImGui_" in line:
            ui.add(k)
    return sum(1 for line in lines if line.strip()), len(ui)


def _rgb(c):
    return ((c >> 24) & 255, (c >> 16) & 255, (c >> 8) & 255)


def _over(fg, bg_rgb):
    a = (fg & 255) / 255.0
    return tuple(a * f + (1 - a) * b for f, b in zip(_rgb(fg), bg_rgb))


def _lum(rgb):
    def ch(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(x) for x in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a, b):
    hi, lo = sorted((_lum(a), _lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


# (label, foreground palette key, surface, kind). A surface is a key, or ("over", top key, base key).
# Pairs mirror what Theme.push applies. HC1: text < 3 = severity 4, 3-4.49 = 3; state/boundary < 3 = 3.
CONTRAST_PAIRS = [
    ("Text on WindowBg", "text", "bg", "text"),
    ("Text on PopupBg / tooltip", "text", "panel", "text"),
    ("Text on FrameBg", "text", "card", "text"),
    ("Dim text on WindowBg", "text_dim", "bg", "text"),
    ("Dim text on PopupBg / tooltip", "text_dim", "panel", "text"),
    ("Dim text on FrameBg", "text_dim", "card", "text"),
    ("Text on Button", "text", ("over", "accent_d", "bg"), "text"),
    ("Text on ButtonHovered", "text", ("over", "accent_h", "bg"), "text"),
    ("Text on ButtonActive", "text", "accent", "text"),
    ("Check mark / slider grab on FrameBg", "accent", "card", "state"),
    ("Accent fill on WindowBg", "accent", "bg", "state"),
    ("FrameBg on WindowBg", "card", "bg", "boundary"),
    ("FrameBg on PopupBg", "card", "panel", "boundary"),
    ("Border on WindowBg", "border", "bg", "boundary"),
]


def _severity(kind, ratio):
    if kind == "text":
        return 4 if ratio < 3 else 3 if ratio < 4.5 else 0
    return 3 if ratio < 3 else 0


def contrast_rows(theme):
    P, rows = theme["palette"], []
    for label, fg, bg, kind in CONTRAST_PAIRS:
        surf = _over(P[bg[1]], _rgb(P[bg[2]])) if isinstance(bg, tuple) else _rgb(P[bg])
        ratio = contrast_ratio(_over(P[fg], surf), surf)
        rows.append({"pair": label, "fg": fg,
                     "bg": bg if isinstance(bg, str) else "%s over %s" % (bg[1], bg[2]),
                     "kind": kind, "ratio": round(ratio, 2), "severity": _severity(kind, ratio)})
    return rows
```

Replace `run()` and extend `main()`:

```python
def run(args, ap):
    if args.self_test:
        return run_self_test()
    if args.contrast:
        rows = contrast_rows(make_ctx(args.theme, args.files).theme)
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for r in rows:
                print("%-38s %-9s %-24s %6.2f  %s" % (r["pair"], r["kind"], r["fg"] + " on " + r["bg"], r["ratio"],
                                                       "sev %d" % r["severity"] if r["severity"] else "ok"))
        return 0
    if not args.files:
        ap.error("no input files")
    if args.ui_lines:
        for path in args.files:
            total, ui = ui_line_counts(Src(read_text(path), path))
            print("%s: total=%d ui=%d" % (path, total, ui))
        return 0
    ctx = make_ctx(args.theme, args.files)
    findings = []
    for path in args.files:
        findings.extend(lint_src(Src(read_text(path), path), ctx))
    if args.json:
        print(json.dumps(findings, indent=2))
    else:
        for f in findings:
            print("%s:%d: %s [%s] %s" % (f["file"], f["line"], f["rule"], f["conf"], f["msg"]))
    return 1 if any(f["conf"] == "definite" for f in findings) else 0
```

In `main()` add:

```python
    ap.add_argument("--ui-lines", action="store_true", help="print total and UI-bearing line counts per file")
    ap.add_argument("--contrast", action="store_true", help="print the HC1 contrast table for the live palette")
```

- [ ] **Step 4: Run to see it pass**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `self-test: 30 passed, 0 failed`, `exit=0`.

- [ ] **Step 5: Look at the real numbers (they feed Task 8)**

Run: `cd /Users/macstudio/Development/fancy-scripts && S=.agents/skills/reaimgui-ux-review/scripts/ds-lint.py && python3 $S --ui-lines "Pitch/Fancy_Pitch Correct.lua" "FX/Fancy_Parameter Link.lua" "Routing/Fancy_Pan Snap.lua" "Metering/Fancy_Selected Track Meter.lua" && python3 $S --contrast`
Expected: four `total=… ui=…` lines and a 14-row table where `Text on WindowBg` is `ok`. Record all numbers in the ledger. No commit (PD3).

---

### Task 6: Probes group A (line- and call-based)

**Files:**
- Modify: `.agents/skills/reaimgui-ux-review/scripts/ds-lint.py`

**Interfaces:**
- Consumes: `find_calls`, `Call`, `finding`, `probe`, `Ctx.theme["scale"|"modals"]`, `_subst`.
- Produces, per spec §6 table (rule · confidence · extras): `LG2` align (definite, `tier="A"`), `CN2` CreateFont (definite), `LG1` stacked Spacing (definite), `LG2/MT2` DrawList text (check), `EP6` IsKeyPressed without repeat (definite; `handler` in `toggle|command|undo|other`, `tier` A when not `other`), `HC5` bare Esc (definite), `EP2` BeginDisabled (check), `HI2` Cond_Always (check), `HI4` SetExtState after a slider/drag (check), `CN1` tooltip APIs (definite) and raw widgets (check), `UC4` selection APIs (check), `EP3` missing AlwaysClamp (check), `RC1` icon button without tooltip (check), `HI6` dynamic label without `###` (check), `UC1` Undo_BeginBlock in a per-frame function (check), `CN2` numeric layout literals (definite + `tier="A"` for Dummy/SameLine spacing and `center_next_window` modal presets that match a token; otherwise check + `tier="B"`).

- [ ] **Step 1: Write the failing fixtures**

Append to `SELF_TESTS`:

```python
    {"name": "LG2 AlignTextToFramePadding is Tier A",
     "src": "reaper.ImGui_AlignTextToFramePadding(ctx)\n",
     "want": [("LG2", "definite", 1, {"tier": "A"})]},
    {"name": "CN2 CreateFont in a script, not in _lib",
     "src": "local f = reaper.ImGui_CreateFont('sans-serif', 14)\n",
     "want": [("CN2", "definite", 1)]},
    {"name": "CreateFont inside _lib is allowed",
     "src": "local f = reaper.ImGui_CreateFont('sans-serif', 14)\n", "path": "/repo/_lib/theme.lua",
     "forbid": [("CN2", None, None)]},
    {"name": "LG1 stacked Spacing",
     "src": "reaper.ImGui_Spacing(ctx)\nreaper.ImGui_Spacing(ctx)\n",
     "want": [("LG1", "definite", 2)]},
    {"name": "LG1 separated Spacing is fine",
     "src": "reaper.ImGui_Spacing(ctx)\nreaper.ImGui_Text(ctx, 'x')\nreaper.ImGui_Spacing(ctx)\n",
     "forbid": [("LG1", None, None)]},
    {"name": "DrawList text is check",
     "src": "reaper.ImGui_DrawList_AddText(dl, 1, 1, col, 'x')\n",
     "want": [("LG2/MT2", "check", 1)]},
    {"name": "EP6 toggle handler without repeat flag",
     "src": "if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then\n  playing = not playing\nend\n",
     "want": [("EP6", "definite", 1, {"handler": "toggle", "tier": "A"})]},
    {"name": "EP6 satisfied by explicit repeat=false",
     "src": "if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space(), false) then\n  playing = not playing\nend\n",
     "forbid": [("EP6", None, None)]},
    {"name": "EP6 navigation key is Tier B",
     "src": "if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then idx = idx - 1 end\n",
     "want": [("EP6", "definite", 1, {"handler": "other", "tier": "B"})]},
    {"name": "HC5 bare Esc handler",
     "src": "if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then open = false end\n",
     "want": [("HC5", "definite", 1)]},
    {"name": "EP2 BeginDisabled without a reason",
     "src": "reaper.ImGui_BeginDisabled(ctx)\nreaper.ImGui_Button(ctx, 'Go')\nreaper.ImGui_EndDisabled(ctx)\n",
     "want": [("EP2", "check", 1)]},
    {"name": "EP2 satisfied by an inline reason",
     "src": "reaper.ImGui_BeginDisabled(ctx)\nreaper.ImGui_Button(ctx, 'Go')\nreaper.ImGui_EndDisabled(ctx)\nreaper.ImGui_Text(ctx, 'Select a track first')\n",
     "forbid": [("EP2", None, None)]},
    {"name": "HI2 Cond_Always on a window position",
     "src": "reaper.ImGui_SetNextWindowPos(ctx, 10, 10, reaper.ImGui_Cond_Always())\n",
     "want": [("HI2", "check", 1)]},
    {"name": "HI4 SetExtState right after a slider, EP3 satisfied by AlwaysClamp",
     "src": ("local rv, v = reaper.ImGui_SliderDouble(ctx, 'x', v, 0, 1, '%.2f', reaper.ImGui_SliderFlags_AlwaysClamp())\n"
             "if rv then reaper.SetExtState('S', 'k', tostring(v), true) end\n"),
     "want": [("HI4", "check", 2)], "forbid": [("EP3", None, None)]},
    {"name": "EP3 drag without AlwaysClamp",
     "src": "local rv, v = reaper.ImGui_DragDouble(ctx, 'x', v, 0.1, 0, 1)\n",
     "want": [("EP3", "check", 1)]},
    {"name": "CN1 raw tooltip API is definite, Theme.tooltip is fine",
     "src": "reaper.ImGui_SetTooltip(ctx, 'hi')\nTheme.tooltip(ctx, 'hi')\n",
     "want": [("CN1", "definite", 1)], "forbid": [("CN1", None, 2)]},
    {"name": "CN1 raw widget is check",
     "src": "reaper.ImGui_ProgressBar(ctx, 0.5)\n",
     "want": [("CN1", "check", 1)]},
    {"name": "UC4 selection API",
     "src": "reaper.SetTrackSelected(tr, true)\n",
     "want": [("UC4", "check", 1)]},
    {"name": "RC1 icon button without tooltip, with tooltip",
     "src": ("Theme.icon_btn(ctx, 'a', Theme.icons.gear)\nreaper.ImGui_Text(ctx, 'x')\n"
             "reaper.ImGui_Text(ctx, 'y')\nreaper.ImGui_Text(ctx, 'z')\nreaper.ImGui_Text(ctx, 'w')\n"
             "reaper.ImGui_Text(ctx, 'v')\nreaper.ImGui_Text(ctx, 'u')\nreaper.ImGui_Text(ctx, 't')\n"
             "Theme.icon_btn(ctx, 'b', Theme.icons.gear, { tooltip = 'Settings' })\n"),
     "want": [("RC1", "check", 1)], "forbid": [("RC1", None, 9)]},
    {"name": "HI6 dynamic label without ### is check; literal and ### are fine",
     "src": ("reaper.ImGui_Button(ctx, 'Run ' .. n)\n"
             "reaper.ImGui_Button(ctx, 'Run ' .. n .. '###run')\n"
             "reaper.ImGui_Button(ctx, 'Loading...')\n"),
     "want": [("HI6", "check", 1)], "forbid": [("HI6", None, 2), ("HI6", None, 3)]},
    {"name": "UC1 Undo_BeginBlock in a per-frame function only",
     "src": ("local function draw_ui()\n  reaper.Undo_BeginBlock()\nend\n"
             "local function apply()\n  reaper.Undo_BeginBlock()\nend\n"),
     "want": [("UC1", "check", 2)], "forbid": [("UC1", None, 5)]},
    {"name": "CN2 numeric spacing that matches a token is Tier A",
     "src": ("reaper.ImGui_Dummy(ctx, 0, @S:lg@)\nreaper.ImGui_Dummy(ctx, 0, 7)\nreaper.ImGui_Dummy(ctx, 0, 0)\n"
             "reaper.ImGui_SameLine(ctx, 0, @S:md@)\n"),
     "want": [("CN2", "definite", 1, {"tier": "A"}), ("CN2", "check", 2, {"tier": "B"}),
              ("CN2", "definite", 4, {"tier": "A"})],
     "forbid": [("CN2", None, 3)]},
    {"name": "CN2 modal size literals matching a preset are Tier A, others Tier B",
     "src": "Theme.center_next_window(ctx, @MW:modal_sm@, @MH:modal_sm@)\nTheme.center_next_window(ctx, 501, 333)\n",
     "want": [("CN2", "definite", 1, {"tier": "A"}), ("CN2", "check", 2, {"tier": "B"})]},
    {"name": "CN2 numeric widths on Button/BeginChild/PushItemWidth are check",
     "src": "reaper.ImGui_Button(ctx, 'OK', 90, 0)\nreaper.ImGui_PushItemWidth(ctx, 120)\nreaper.ImGui_Button(ctx, 'OK', -1, 0)\n",
     "want": [("CN2", "check", 1), ("CN2", "check", 2)], "forbid": [("CN2", None, 3)]},
```

- [ ] **Step 2: Run to see it fail**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: a `FAIL … missing …` line for each fixture that has a `want` (about 20 lines; `forbid`-only fixtures already pass); `exit=1`.

- [ ] **Step 3: Implement the probes**

Append below `probe_hex` in the `# 4. PROBES` section:

```python
def _handler_kind(src, pos):
    """Classify what the `if` around an IsKeyPressed call does: undo | command | toggle | other."""
    lines, i = src.lines(), src.line(pos) - 1
    if re.search(r"\bend\b\s*$", lines[i]):
        window = lines[i]
    else:
        indent = len(lines[i]) - len(lines[i].lstrip())
        body = [lines[i]]
        for j in range(i + 1, min(i + 25, len(lines))):
            body.append(lines[j])
            if re.match(r"\s*end\b", lines[j]) and len(lines[j]) - len(lines[j].lstrip()) <= indent:
                break
        window = "\n".join(body)
    if "Undo_BeginBlock" in window:
        return "undo"
    if "Main_OnCommand" in window:
        return "command"
    if re.search(r"=\s*not\s", window):
        return "toggle"
    return "other"


@probe(scripts_only=True)
def probe_align(src, ctx):
    return [finding(src, "LG2", "definite", "AlignTextToFramePadding; use Theme.align(ctx)", pos=c.pos, tier="A")
            for c in find_calls(src, r"reaper\.ImGui_AlignTextToFramePadding")]


@probe()
def probe_spacing(src, ctx):
    out, prev = [], None
    for i, line in enumerate(src.lines()):
        if re.match(r"\s*reaper\.ImGui_Spacing\s*\(", line):
            if prev is not None:
                out.append(finding(src, "LG1", "definite",
                                   "stacked ImGui_Spacing calls; use one Dummy(ctx, 0, <spacing token>)", line=i + 1))
            prev = i
        elif line.strip():
            prev = None
    return out


@probe()
def probe_drawlist_text(src, ctx):
    return [finding(src, "LG2/MT2", "check", "DrawList_AddText; fine on canvases, not for standard labels", pos=c.pos)
            for c in find_calls(src, r"reaper\.ImGui_DrawList_AddText")]


@probe()
def probe_keys(src, ctx):
    out = []
    for c in find_calls(src, r"reaper\.ImGui_IsKeyPressed"):
        if len(c.args) <= 2:
            kind = _handler_kind(src, c.pos)
            out.append(finding(src, "EP6", "definite",
                               "IsKeyPressed without a repeat argument (handler: %s)" % kind,
                               pos=c.pos, handler=kind, tier="B" if kind == "other" else "A"))
        if any("Key_Escape" in a for a in c.cargs):
            out.append(finding(src, "HC5", "definite",
                               "bare IsKeyPressed(Esc); route Esc through Shortcut() per HC5", pos=c.pos))
    return out


@probe()
def probe_disabled(src, ctx):
    out, lines = [], src.lines()
    for c in find_calls(src, r"reaper\.ImGui_BeginDisabled"):
        ln = src.line(c.pos)
        window = "\n".join(lines[ln - 1:ln + 9])
        if "AllowWhenDisabled" not in window and not re.search(r"reaper\.ImGui_Text\w*\s*\(", window):
            out.append(finding(src, "EP2", "check",
                               "BeginDisabled with no inline reason or AllowWhenDisabled tooltip within 10 lines",
                               pos=c.pos))
    return out


@probe()
def probe_window_cond(src, ctx):
    return [finding(src, "HI2", "check", "Cond_Always on SetNextWindowPos/Size (main windows use FirstUseEver)",
                    pos=c.pos)
            for c in find_calls(src, r"reaper\.ImGui_SetNextWindow(?:Pos|Size)")
            if "Cond_Always" in src.code[c.pos:c.close]]


@probe()
def probe_extstate_in_drag(src, ctx):
    out, lines = [], src.lines()
    for c in find_calls(src, r"reaper\.SetExtState"):
        ln = src.line(c.pos)
        if re.search(r"reaper\.ImGui_(?:Slider|Drag)\w*\s*\(", "\n".join(lines[max(0, ln - 7):ln])):
            out.append(finding(src, "HI4", "check",
                               "SetExtState in a slider/drag value-changed branch; save on release", pos=c.pos))
    return out


@probe(scripts_only=True)
def probe_raw_tooltips(src, ctx):
    return [finding(src, "CN1", "definite",
                    "raw tooltip API bypasses the Show Tooltips pref; use Theme.tooltip after IsItemHovered(ForTooltip)",
                    pos=c.pos)
            for c in find_calls(src, r"reaper\.(?:TrackCtl_SetToolTip|ImGui_(?:BeginTooltip|SetTooltip|SetItemTooltip))")]


@probe(scripts_only=True)
def probe_raw_widgets(src, ctx):
    return [finding(src, "CN1", "check", "raw widget; check whether a Theme.* helper exists", pos=c.pos)
            for c in find_calls(src, r"reaper\.ImGui_(?:BeginCombo|ProgressBar|Selectable)")]


@probe()
def probe_selection(src, ctx):
    return [finding(src, "UC4", "check", "changes the user's selection as a side effect", pos=c.pos)
            for c in find_calls(src, r"reaper\.(?:SelectAllMediaItems|SetTrackSelected|SetMediaItemSelected)")]


@probe()
def probe_clamp(src, ctx):
    return [finding(src, "EP3", "check", "slider/drag without SliderFlags_AlwaysClamp", pos=c.pos)
            for c in find_calls(src, r"reaper\.ImGui_(?:SliderDouble|SliderInt|DragDouble|DragInt)")
            if "SliderFlags_AlwaysClamp" not in src.code[c.pos:c.close]]


@probe()
def probe_icon_tooltip(src, ctx):
    out, lines = [], src.lines()
    for c in find_calls(src, r"Theme\.icon_btn(?:_colored)?|reaper\.ImGui_InvisibleButton"):
        ln = src.line(c.pos)
        text = src.code[c.pos:c.close] + "\n".join(lines[ln - 1:ln + 6])
        if not re.search(r"[Tt]ooltip", text):
            out.append(finding(src, "RC1", "check", "icon-only control with no tooltip within 6 lines", pos=c.pos))
    return out


@probe()
def probe_dynamic_labels(src, ctx):
    out = []
    for c in find_calls(src, r"reaper\.ImGui_(?:Button|Selectable|TreeNode|BeginTabItem)"):
        if len(c.args) > 1 and re.search(r"\.\.|format", c.cargs[1]) and "###" not in c.args[1]:
            out.append(finding(src, "HI6", "check", "dynamic label used as the widget ID; use \"Label###stable_id\"",
                               pos=c.pos))
    return out


@probe()
def probe_undo_in_loop(src, ctx):
    out = []
    for c in find_calls(src, r"reaper\.Undo_BeginBlock"):
        names = re.findall(r"function\s+([\w.:]+)?\s*\(", src.code[:c.pos])
        name = names[-1] if names and names[-1] else ""
        if re.search(r"(?i)(?:^|[_.:])(?:loop|draw\w*|frame|render\w*|tick|gui|ui)(?:$|[_.:])", name):
            out.append(finding(src, "UC1", "check",
                               "Undo_BeginBlock inside per-frame function %s; open blocks per gesture, not per frame" % name,
                               pos=c.pos))
    return out


NUM_RE = re.compile(r"^-?\d+(?:\.\d+)?$")
NUM_TARGETS = [   # (call pattern, argument indexes after ctx, indexes whose token match is Tier A)
    (r"reaper\.ImGui_Dummy", (1, 2), (1, 2)),
    (r"reaper\.ImGui_SameLine", (1, 2), (2,)),
    (r"reaper\.ImGui_SetCursorPos[XY]?", (1, 2), ()),
    (r"reaper\.ImGui_PushItemWidth", (1,), ()),
    (r"reaper\.ImGui_SetNextItemWidth", (1,), ()),
    (r"reaper\.ImGui_Button", (2, 3), ()),
    (r"reaper\.ImGui_BeginChild", (2, 3), ()),
]


@probe(scripts_only=True)
def probe_numeric_literals(src, ctx):
    out = []
    by_value = {v: k for k, v in ctx.theme["scale"].items()}
    for pattern, idxs, tier_a in NUM_TARGETS:
        for c in find_calls(src, pattern):
            for i in idxs:
                if i >= len(c.args) or not NUM_RE.match(c.args[i]) or float(c.args[i]) in (0, -1):
                    continue
                key = by_value.get(int(float(c.args[i]))) if float(c.args[i]).is_integer() else None
                if i in tier_a and key:
                    out.append(finding(src, "CN2", "definite", "numeric spacing %s; use Theme.layout.%s" % (c.args[i], key),
                                       pos=c.pos, tier="A", key=key))
                else:
                    out.append(finding(src, "CN2", "check", "numeric layout literal %s; use a Theme.layout token" % c.args[i],
                                       pos=c.pos, tier="B"))
    presets = {v: k for k, v in ctx.theme["modals"].items()}
    for c in find_calls(src, r"Theme\.center_next_window"):
        if len(c.args) > 2 and NUM_RE.match(c.args[1]) and NUM_RE.match(c.args[2]):
            key = presets.get((int(float(c.args[1])), int(float(c.args[2]))))
            if key:
                out.append(finding(src, "CN2", "definite", "modal size literals match Theme.layout.%s" % key,
                                   pos=c.pos, tier="A", key=key))
            else:
                out.append(finding(src, "CN2", "check", "modal size literals match no Theme.layout.modal_* preset",
                                   pos=c.pos, tier="B"))
    return out
```

- [ ] **Step 4: Run to see it pass**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `self-test: 54 passed, 0 failed` (24 fixtures added to the earlier 30 → 30 + 24 = 54), `exit=0`. Fix probe code (not fixtures) for any failure; if a fixture is itself wrong about the spec (§6/§5.4), fix the fixture and ledger a `Ruling:`.

- [ ] **Step 5: Smoke test on a real script**

Run: `cd /Users/macstudio/Development/fancy-scripts && python3 .agents/skills/reaimgui-ux-review/scripts/ds-lint.py "Routing/Fancy_Pan Snap.lua" | head -20; echo "exit=${PIPESTATUS[0]}"`
Expected: findings print without a traceback (exit 0 or 1). No commit (PD3).

---

### Task 7: Block-aware probes, symbol checks, API-name list

**Files:**
- Modify: `.agents/skills/reaimgui-ux-review/scripts/ds-lint.py`
- Create: `.agents/skills/reaimgui-ux-review/scripts/reaimgui_api_names.txt` (generated)

**Interfaces:**
- Consumes: Task 4's theme dict (`names icons layout font_sizes font_keys palette_keys`), Task 3's probe machinery.
- Produces:
  - `regen_api(doc_path)`, `load_api() -> (set[str], version)`; `Ctx.api` (set of bare names, no `ImGui_` prefix) and `Ctx.api_version`; CLI `--regen-api [DOC_HTML]`
  - `scan_blocks(code) -> (blocks, snaps, poss)`, `stack_at(...)`
  - Probes: `HI1` (End/EndChild/EndPopup outside the `if` guarding its Begin: definite when the Begin result is bound to a variable or sits in the `if` condition, else check; `rb="RB1"`, `tier="A"`), `CN2` missing `Theme.modal_scrim` (definite for a literal popup ID, else check), `CN3` undefined symbol (definite), `RB3` name absent from ReaImGui 0.10 (definite for direct use; check for existence guards; `replacement`, `tier="A"` only for the six 1:1 aliases)

- [ ] **Step 1: Write the failing tests and fixtures**

Append to `UNIT_TESTS`:

```python
def _ut_api_list():
    names, version = load_api()
    assert version == "0.10.0.5", version
    assert {"Begin", "Button", "Key_Escape", "ChildFlags_Borders", "Col_TabSelected",
            "TreeNodeFlags_AllowOverlap", "HoveredFlags_ForTooltip", "Shortcut"} <= names
    gone = {"ChildFlags_Border", "Col_TabActive", "SetWindowFontScale", "GetStyle", "GetIO",
            "TreeNodeFlags_AllowItemOverlap", "DestroyContext"}
    assert not (gone & names), sorted(gone & names)
    assert len(names) > 900, len(names)


def _ut_api_missing_raises():
    global API_FILE
    saved, API_FILE = API_FILE, "/nonexistent/api.txt"
    try:
        load_api()
    except LintError:
        return
    finally:
        API_FILE = saved
    raise AssertionError("missing API list did not raise")


UNIT_TESTS += [
    ("api list: version, present and absent names", _ut_api_list),
    ("api list: missing file raises", _ut_api_missing_raises),
]
```

Append to `SELF_TESTS`:

```python
    {"name": "HI1 End outside the if that guards Begin",
     "src": ("local visible, open = reaper.ImGui_Begin(ctx, 'W', true)\nif visible then\n  reaper.ImGui_Text(ctx, 'x')\nend\n"
             "reaper.ImGui_End(ctx)\n"),
     "want": [("HI1", "definite", 5, {"rb": "RB1", "tier": "A"})]},
    {"name": "HI1 End inside the guard is fine",
     "src": ("local visible, open = reaper.ImGui_Begin(ctx, 'W', true)\nif visible then\n  reaper.ImGui_Text(ctx, 'x')\n"
             "  reaper.ImGui_End(ctx)\nend\n"),
     "forbid": [("HI1", None, None)]},
    {"name": "HI1 modal: End in the guard is fine; scrim missing is CN2",
     "src": "if reaper.ImGui_BeginPopupModal(ctx, 'M##m', true) then\n  reaper.ImGui_EndPopup(ctx)\nend\n",
     "want": [("CN2", "definite", 1)], "forbid": [("HI1", None, None)]},
    {"name": "modal with scrim before it is clean",
     "src": ("Theme.modal_scrim(ctx, 'M##m')\nif reaper.ImGui_BeginPopupModal(ctx, 'M##m', true) then\n"
             "  reaper.ImGui_EndPopup(ctx)\nend\n"),
     "forbid": [("CN2", None, None), ("HI1", None, None)]},
    {"name": "HI1 modal End outside any guard",
     "src": "local ok = reaper.ImGui_BeginPopupModal(ctx, 'M##m', true)\nreaper.ImGui_EndPopup(ctx)\n",
     "want": [("HI1", "definite", 2)]},
    {"name": "HI1 early-return form is not flagged",
     "src": "if not reaper.ImGui_BeginPopupModal(ctx, 'M##m', true) then return end\nreaper.ImGui_EndPopup(ctx)\n",
     "forbid": [("HI1", None, None)]},
    {"name": "HI1 child window inside a function",
     "src": ("local function f()\n  if reaper.ImGui_BeginChild(ctx, 'c') then\n    reaper.ImGui_Text(ctx, 'x')\n  end\n"
             "  reaper.ImGui_EndChild(ctx)\nend\n"),
     "want": [("HI1", "definite", 5)]},
    {"name": "CN3 undefined Theme, layout, font and palette symbols",
     "src": ("local Theme = require('theme')\nlocal fonts = Theme.create_fonts(ctx)\nlocal f = fonts.bold\n"
             "local g = fonts.default_bold\nlocal L = Theme.layout\nlocal h = L.nope\nlocal w = L.modal_sm.w\n"
             "local x = Theme.nonexistent()\nlocal P = Theme.build_palette()\nlocal c = P.accent\nlocal d = P.nope\n"
             "local i = L.modal_sm.zzz\n"),
     "want": [("CN3", "definite", 3), ("CN3", "definite", 6), ("CN3", "definite", 8),
              ("CN3", "definite", 11), ("CN3", "definite", 12)],
     "forbid": [("CN3", None, 4), ("CN3", None, 7), ("CN3", None, 10)]},
    {"name": "assigned Theme aliases are defined (badge_button, with_alpha)",
     "src": "local Theme = require('theme')\nlocal a = Theme.badge_button\nlocal b = Theme.with_alpha(0, 1)\n",
     "forbid": [("CN3", None, None)]},
    {"name": "names inside strings and comments are never flagged",
     "src": ("local s = 'wrapping ImGui_BeginCombo, Theme.nope, reaper.ImGui_GetStyle() and 0xFFFFFF'\n"
             "-- reaper.ImGui_GetIO() Theme.nope 0x8B70FAFF\n"),
     "forbid": [("CN1", None, None), ("CN3", None, None), ("RB3", None, None), ("CN2", None, None)]},
    {"name": "RB3 direct use of a removed 1:1 name is Tier A",
     "src": "local c = reaper.ImGui_Col_TabActive()\n",
     "want": [("RB3", "definite", 1, {"replacement": "Col_TabSelected", "tier": "A"})]},
    {"name": "RB3 hallucinated name is definite with no replacement",
     "src": "reaper.ImGui_SetWindowFontScale(ctx, 1.2)\n",
     "want": [("RB3", "definite", 1, {"tier": "B"})]},
    {"name": "RB3 existence-guard chain is check, never definite",
     "src": ("local flags = 0\nif reaper.ImGui_ChildFlags_Border then\n  flags = reaper.ImGui_ChildFlags_Border()\n"
             "elseif reaper.ImGui_ChildFlags_Borders then\n  flags = reaper.ImGui_ChildFlags_Borders()\nend\n"),
     "want": [("RB3", "check", 2), ("RB3", "check", 3)], "forbid": [("RB3", "definite", None)]},
    {"name": "RB3 'X and X()' form is check",
     "src": "local f = reaper.ImGui_TreeNodeFlags_AllowItemOverlap and reaper.ImGui_TreeNodeFlags_AllowItemOverlap() or 0\n",
     "want": [("RB3", "check", 1)], "forbid": [("RB3", "definite", None)]},
    {"name": "valid 0.10 names are not flagged",
     "src": "local c = reaper.ImGui_Col_TabSelected()\nreaper.ImGui_Begin(ctx, 'W')\n",
     "forbid": [("RB3", None, None)]},
```

- [ ] **Step 2: Run to see it fail**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `NameError: name 'load_api' is not defined` from the unit tests… (the whole run aborts; that is the RED).

- [ ] **Step 3: Generate the API-name list (`--regen-api`)**

Add to the file (before `# 4. PROBES`):

```python
# -----------------------------------------------------------------------------
# 3c. REAIMGUI API NAME LIST
# -----------------------------------------------------------------------------

API_FILE = os.path.join(HERE, "reaimgui_api_names.txt")
DEFAULT_DOC = os.path.expanduser("~/Library/Application Support/REAPER/Data/reaper_imgui_doc.html")


def regen_api(doc_path):
    try:
        with open(doc_path, encoding="utf-8") as fh:
            html = fh.read()
    except OSError as e:
        raise LintError("cannot read ReaImGui doc %s: %s" % (doc_path, e.strerror))
    ver = re.search(r"Generated for version ([\d.]+)", html)
    names = sorted(set(re.findall(r"<summary>(?:Function|Constant): (\w+)", html)))
    if not ver or len(names) < 500:
        raise LintError("unrecognised ReaImGui doc format in %s" % doc_path)
    header = [
        "# ReaImGui %s API names (bare names: reaper.ImGui_<name>)" % ver.group(1),
        "# Regenerate: python3 ds-lint.py --regen-api [path to reaper_imgui_doc.html]",
        "# Source: REAPER's Data/reaper_imgui_doc.html. Alternative source: reaper-dev:search_functions, query ImGui,",
        "# limit 3000. Spot-check any name with reaper-dev:get_function_info before recommending it.",
    ]
    with open(API_FILE, "w", encoding="utf-8") as fh:
        fh.write("\n".join(header + names) + "\n")
    print("wrote %d names for ReaImGui %s to %s" % (len(names), ver.group(1), API_FILE))


def load_api():
    try:
        with open(API_FILE, encoding="utf-8") as fh:
            lines = [ln.strip() for ln in fh]
    except OSError:
        raise LintError("missing %s; run: python3 ds-lint.py --regen-api" % API_FILE)
    names = {ln for ln in lines if ln and not ln.startswith("#")}
    m = next((re.search(r"ReaImGui\s+([\d.]+)", ln) for ln in lines if ln.startswith("#") and "ReaImGui" in ln), None)
    if len(names) < 500 or not m:
        raise LintError("%s looks truncated or has no version header" % API_FILE)
    return names, m.group(1)
```

In `main()` add `ap.add_argument("--regen-api", nargs="?", const=DEFAULT_DOC, metavar="DOC_HTML", help="regenerate reaimgui_api_names.txt from the ReaImGui doc")` and at the top of `run()` add:

```python
    if args.regen_api:
        regen_api(args.regen_api)
        return 0
```

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --regen-api`
Expected: `wrote NNNN names for ReaImGui 0.10.0.5 to …/reaimgui_api_names.txt` with NNNN ≈ 1000 (>900).

Then check facts three ways:

```bash
cd /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts && for n in Key_Escape ChildFlags_Borders Col_TabSelected Shortcut; do grep -qx "$n" reaimgui_api_names.txt && echo "has $n"; done; for n in ChildFlags_Border Col_TabActive SetWindowFontScale; do grep -qx "$n" reaimgui_api_names.txt && echo "UNEXPECTED $n"; done; sqlite3 "$HOME/Library/Application Support/REAPER/ReaPack/registry.db" "select version from entries where package='reaper_imgui.ext'"
```

Expected: four `has …` lines, no `UNEXPECTED`, and `0.10.0.5` from sqlite (this confirms the §10 registry-schema item: the query works as written; ledger it).

Then cross-check with the MCP: call `mcp__reaper-dev__get_function_info` for `ImGui_ChildFlags_Borders` and `ImGui_Col_TabSelected` (both must exist) and for `ImGui_ChildFlags_Border` (must not be found). Ledger the three results.

- [ ] **Step 4: Wire `Ctx` to the API list and implement the block-aware, symbol and API probes**

Replace the `Ctx` class and `make_ctx` (Task 4) with:

```python
class Ctx:
    def __init__(self, theme, api, api_version):
        self.theme = theme
        self.api = api
        self.api_version = api_version

    def palette_matches(self, val):
        return sorted(k for k, v in self.theme["palette"].items() if v == val)

    def is_mode_dep(self, keys):
        return any(k in self.theme["mode_dep"] for k in keys)


def make_ctx(theme_path, files):
    if not theme_path:
        start = os.path.dirname(os.path.abspath(files[0])) if files else HERE
        theme_path = find_theme(start) or find_theme(HERE)
    if not theme_path:
        raise LintError("cannot find _lib/theme.lua; pass --theme PATH")
    names, version = load_api()
    return Ctx(parse_theme(theme_path), names, version)
```

Note `load_api`/`API_FILE` are defined in the new section above; place that section **before** `make_ctx` in the file.

Append to the `# 4. PROBES` section:

```python
TOKEN_RE = re.compile(r"\b(function|if|elseif|for|while|do|repeat|until|end)\b")


def scan_blocks(code):
    """Walk Lua block keywords. Return (blocks, snaps, poss): blocks[id] = {kind, pos, cs, ce, extra};
    snaps[i] = tuple of open block ids after the i-th keyword; poss = keyword offsets (for bisect)."""
    blocks, stack, snaps, poss, loop = {}, [], [], [], False
    for m in TOKEN_RE.finditer(code):
        w, p = m.group(1), m.start()
        if w in ("function", "if", "repeat", "for", "while", "do") and not (w == "do" and loop):
            cs = ce = None
            if w == "if":
                t = re.compile(r"\bthen\b").search(code, m.end())
                cs, ce = m.end(), (t.start() if t else m.end())
            bid = len(blocks)
            blocks[bid] = {"kind": w, "pos": p, "cs": cs, "ce": ce, "extra": []}
            stack.append(bid)
            loop = w in ("for", "while")
        elif w == "do":
            loop = False
        elif w == "elseif" and stack:
            t = re.compile(r"\bthen\b").search(code, m.end())
            blocks[stack[-1]]["extra"].append((m.end(), t.start() if t else m.end()))
        elif w in ("end", "until") and stack:
            stack.pop()
        snaps.append(tuple(stack))
        poss.append(p)
    return blocks, snaps, poss


def _stack_at(scan, pos):
    _, snaps, poss = scan
    i = bisect.bisect_left(poss, pos)
    return snaps[i - 1] if i else ()


def _cond_text(code, b):
    spans = ([(b["cs"], b["ce"])] if b["cs"] is not None else []) + b["extra"]
    return " ".join(code[a:z] for a, z in spans)


END_OF = {"Begin": "End", "BeginChild": "EndChild", "BeginPopupModal": "EndPopup", "BeginPopup": "EndPopup"}
BEGIN_RX = re.compile(r"(?:(\w+)\s*(?:,\s*\w+\s*)?=\s*)?reaper\.ImGui_(BeginPopupModal|BeginPopup|BeginChild|Begin)\s*\(")
END_RX = re.compile(r"reaper\.ImGui_(EndPopup|EndChild|End)\s*\(")


@probe()
def probe_begin_end(src, ctx):
    """HI1 / RB1: End* must sit inside the `if` that guards its Begin* (ReaImGui ends failed windows itself)."""
    out, code = [], src.code
    scan = scan_blocks(code)
    blocks = scan[0]
    ends = [(m.start(), m.group(1)) for m in END_RX.finditer(code)]

    def fn_of(stack):
        return next((b for b in reversed(stack) if blocks[b]["kind"] == "function"), None)

    for m in BEGIN_RX.finditer(code):
        var, kind = m.group(1), m.group(2)
        cpos = m.end()
        bst = _stack_at(scan, cpos)
        guard = next((b for b in bst if blocks[b]["kind"] == "if" and blocks[b]["cs"] <= cpos <= blocks[b]["ce"]), None)
        if guard is not None and re.search(r"\bnot\s*$", code[blocks[guard]["cs"]:m.start()] or ""):
            continue                                   # `if not Begin(...) then return end` form
        want, fn = END_OF[kind], fn_of(bst)
        nxt = next(((p, n) for p, n in ends if p > cpos and n == want and fn_of(_stack_at(scan, p)) == fn), None)
        if not nxt:
            continue
        est = _stack_at(scan, nxt[0])
        if guard is not None:
            ok = guard in est
        elif var:
            ok = any(blocks[b]["kind"] == "if" and blocks[b]["pos"] > m.start()
                     and re.search(r"\b%s\b" % re.escape(var), _cond_text(code, blocks[b])) for b in est)
        else:
            ok = False
        if not ok:
            out.append(finding(src, "HI1", "definite" if (guard is not None or var) else "check",
                               "%s outside the `if` that guards its %s (RB1: ReaImGui ends failed windows itself)" % (
                                   "End" if want == "End" else want, "Begin" if kind == "Begin" else kind),
                               pos=nxt[0], rb="RB1", tier="A"))
    return out


@probe(scripts_only=True)
def probe_modal_scrim(src, ctx):
    scrims = [(src.line(c.pos), c.args[1] if len(c.args) > 1 else "") for c in find_calls(src, r"Theme\.modal_scrim")]
    out = []
    for c in find_calls(src, r"reaper\.ImGui_BeginPopupModal"):
        name, ln = (c.args[1] if len(c.args) > 1 else ""), src.line(c.pos)
        if not any(n == name and 0 <= ln - s <= 15 for s, n in scrims):
            out.append(finding(src, "CN2", "definite" if name[:1] in "\"'" else "check",
                               "BeginPopupModal without a preceding Theme.modal_scrim for the same ID", pos=c.pos,
                               tier="A"))
    return out


@probe(scripts_only=True)
def probe_symbols(src, ctx):
    """CN3: every Theme.*, layout, font and palette symbol a script uses must exist in theme.lua."""
    T, code, out = ctx.theme, src.code, []
    for m in re.finditer(r"\bTheme\.(\w+)(?:\.(\w+))?", code):
        name, sub = m.group(1), m.group(2)
        bad = None
        if name not in T["names"]:
            bad = "Theme.%s" % name
        elif sub and name == "icons" and sub not in T["icons"]:
            bad = "Theme.icons.%s" % sub
        elif sub and name == "layout" and sub not in T["layout"]:
            bad = "Theme.layout.%s" % sub
        elif sub and name == "font_sizes" and sub not in T["font_sizes"]:
            bad = "Theme.font_sizes.%s" % sub
        if bad:
            out.append(finding(src, "CN3", "definite", "%s is not defined in theme.lua" % bad, pos=m.start()))

    def aliases(pat):
        return set(re.findall(r"\b(\w+)\s*=\s*Theme\.%s" % pat, code))

    groups = [(aliases(r"layout\b(?!\.)"), T["layout"], "layout"),
              (aliases(r"create_fonts") | ({"fonts"} if re.search(r"\bTheme\b", code) else set()), T["font_keys"], "fonts"),
              (aliases(r"(?:build|get)_palette"), T["palette_keys"], "palette")]
    for names, keys, label in groups:
        for a in names:
            for m in re.finditer(r"(?<![\w.])%s\.(\w+)(?:\.(\w+))?" % re.escape(a), code):
                tail = code[m.end():m.end() + 4].lstrip()
                if tail.startswith("=") and not tail.startswith("=="):
                    continue                                   # a write, not a read
                key, sub = m.group(1), m.group(2)
                if key not in keys:
                    out.append(finding(src, "CN3", "definite", "%s.%s is not a valid %s key in theme.lua" % (a, key, label),
                                       pos=m.start()))
                elif label == "layout" and sub and isinstance(T["layout"][key], dict) and sub not in T["layout"][key]:
                    out.append(finding(src, "CN3", "definite", "%s.%s.%s is not defined in theme.lua" % (a, key, sub),
                                       pos=m.start()))
    return out


RB3_ALIAS = {   # the six 1:1 renames of spec Appendix B (Tier A for direct use only)
    "ChildFlags_Border": "ChildFlags_Borders",
    "Col_TabActive": "Col_TabSelected",
    "Col_TabUnfocused": "Col_TabDimmed",
    "Col_TabUnfocusedActive": "Col_TabDimmedSelected",
    "TreeNodeFlags_AllowItemOverlap": "TreeNodeFlags_AllowOverlap",
    "SelectableFlags_DontClosePopups": "SelectableFlags_NoAutoClosePopups",
}


@probe()
def probe_api_names(src, ctx):
    """RB3: reaper.ImGui_<name> that does not exist in the installed ReaImGui version."""
    code = src.code
    uses = [(m.group(1), m.start(), m.end()) for m in re.finditer(r"reaper\.ImGui_(\w+)", code)]
    bare = {n for n, _, e in uses if not re.match(r"\s*\(", code[e:e + 3])}   # referenced without a call: a guard
    out = []
    for name, pos, _ in uses:
        if name in ctx.api:
            continue
        guarded, rep = name in bare, RB3_ALIAS.get(name)
        out.append(finding(src, "RB3", "check" if guarded else "definite",
                           "reaper.ImGui_%s does not exist in ReaImGui %s%s" % (
                               name, ctx.api_version, " (existence guard: delete the dead branch)" if guarded else ""),
                           pos=pos, replacement=rep, tier="A" if rep and not guarded else "B"))
    return out
```

- [ ] **Step 5: Run to see it pass**

Run: `python3 /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test; echo "exit=$?"`
Expected: `self-test: 71 passed, 0 failed`, `exit=0` (54 + 15 fixtures + 2 unit tests = 71). Fix probes (not fixtures) on failure; a fixture found to contradict the spec is fixed and ledgered as a `Ruling:`.

Common trap: the `probe_begin_end` "not" guard uses `code[cs:m.start()]`; if `if not reaper.ImGui_Begin…` is reported as HI1, print that slice and adjust the regex, not the fixture.

- [ ] **Step 6: Whole-repo sanity**

Run: `cd /Users/macstudio/Development/fancy-scripts && luacheck . 2>&1 | tail -1`
Expected: unchanged totals. No commit (PD3).

---

### Task 8: Real-file validation (R4), the spec §8 numbers, and P1 exit

**Files:**
- Modify (spec numbers only if they differ): `docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md` (§8.2 R2)
- Read-only: the four UI scripts under test and `Utility/Fancy_Design System.lua`

**Interfaces:**
- Consumes: the finished `ds-lint.py` (`--json`, `--ui-lines`, `--contrast`, `--self-test`).
- Produces: a recorded pass/fail for the spec's P1 exit criteria: `--self-test` green; R4 passes on the real files; `--ui-lines` and `--contrast` produce the §8 numbers.

- [ ] **Step 1: Write the R4 check as an executable script and run it (expect it to expose any false claims)**

Create `<scratchpad>/ux-skill-tests/p1/r4_check.py` (`$SP` as in Task 2):

```python
import json, re, subprocess, sys
REPO = "/Users/macstudio/Development/fancy-scripts"
LINT = REPO + "/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py"
FILES = {
    "pl": REPO + "/FX/Fancy_Parameter Link.lua",
    "ps": REPO + "/Routing/Fancy_Pan Snap.lua",
    "ds": REPO + "/Utility/Fancy_Design System.lua",
    "meter": REPO + "/Metering/Fancy_Selected Track Meter.lua",
    "pitch": REPO + "/Pitch/Fancy_Pitch Correct.lua",
}

def lint(path):
    r = subprocess.run([sys.executable, LINT, "--json", path], capture_output=True, text=True)
    assert r.returncode in (0, 1), "ds-lint crashed on %s: %s" % (path, r.stderr)
    return json.loads(r.stdout)

def src_lines(path):
    return open(path, encoding="utf-8", errors="replace").read().split("\n")

fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" :: " + str(detail)) if detail and not cond else ""))
    if not cond:
        fails.append(name)

# R4-a: Parameter Link's `fxnum & 0xFFFFFF` bitmask is never a colour finding
pl = lint(FILES["pl"]); L = src_lines(FILES["pl"])
mask_lines = [i + 1 for i, s in enumerate(L) if re.search(r"&\s*0x[0-9A-Fa-f]{6}\b", s)]
check("R4-a mask lines exist in Parameter Link", bool(mask_lines))
check("R4-a no CN2 on bitmask lines", not [f for f in pl if f["rule"] == "CN2" and f["line"] in mask_lines],
      [f for f in pl if f["line"] in mask_lines])

# R4-b: Design System showcase strings naming APIs are never flagged
ds = lint(FILES["ds"]); L = src_lines(FILES["ds"])
str_lines = [i + 1 for i, s in enumerate(L) if re.search(r'"[^"]*(?:ImGui_BeginCombo|Theme\.\w+)[^"]*"', s) and not re.search(r"^\s*(?:reaper\.|Theme\.)", s)]
check("R4-b showcase string lines exist", bool(str_lines))
check("R4-b no CN1/CN3/RB3 findings on pure-string lines",
      not [f for f in ds if f["rule"] in ("CN1", "CN3", "RB3") and f["line"] in str_lines],
      [f for f in ds if f["line"] in str_lines])

# R4-c: Pan Snap's ChildFlags_Border guard chain is `check`, never `definite`
ps = lint(FILES["ps"]); L = src_lines(FILES["ps"])
guard_lines = [i + 1 for i, s in enumerate(L) if "ChildFlags_Border" in s]
check("R4-c guard-chain lines exist in Pan Snap", bool(guard_lines))
check("R4-c guard chain is never definite",
      not [f for f in ps if f["rule"] == "RB3" and f["line"] in guard_lines and f["conf"] == "definite"],
      [f for f in ps if f["line"] in guard_lines])

# R1 groundwork: Pan Snap's real mechanical findings are reported
bold = [f for f in ps if f["rule"] == "CN3" and "fonts.bold" in f["msg"]]
check("Pan Snap: fonts.bold x8 as CN3", len(bold) == 8, len(bold))
check("Pan Snap: HI1 findings present", any(f["rule"] == "HI1" for f in ps))
check("Pan Snap: bare Esc handlers (HC5) present", any(f["rule"] == "HC5" for f in ps))
check("Pan Snap: raw modal sizes (CN2) present", any(f["rule"] == "CN2" and "modal" in f["msg"] for f in ps))

# R2 groundwork
meter = lint(FILES["meter"])
hexes = [f for f in meter if f["rule"] == "CN2" and f["msg"].startswith("hex colour")]
print("INFO Selected Track Meter CN2 hex findings:", len(hexes))
print("INFO Selected Track Meter CreateFont findings:", len([f for f in meter if f["msg"].startswith("reaper.ImGui_CreateFont")]))

# Every real script lints without a crash (asserted inside lint()).
for k in ("pitch",):
    lint(FILES[k])
print("RESULT", "FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
```

Run: `python3 "$SP/ux-skill-tests/p1/r4_check.py"; echo "exit=$?"`
Expected on the first run: any FAIL lines identify probe false-positives/negatives on real code. Do **not** edit the check to make it pass. For each FAIL, find the cause (use superpowers:systematic-debugging), fix the probe in `ds-lint.py`, add a minimal fixture reproducing it to `SELF_TESTS` (watch it fail, then pass), and re-run. If a check's premise is wrong (e.g. Design System has no such string lines, or Pan Snap's `fonts.bold` count differs from 8 because the file changed), ledger a `Ruling:` with the measured value and the reason. Final expected: `RESULT PASS`, `exit=0`.

- [ ] **Step 2: Record the §8 numbers**

Run:

```bash
cd /Users/macstudio/Development/fancy-scripts && S=.agents/skills/reaimgui-ux-review/scripts/ds-lint.py && python3 $S --ui-lines "Pitch/Fancy_Pitch Correct.lua" "FX/Fancy_Parameter Link.lua" "Routing/Fancy_Pan Snap.lua" "Metering/Fancy_Selected Track Meter.lua" && python3 $S --contrast && luacheck --formatter plain "Metering/Fancy_Selected Track Meter.lua" | grep -c ':'
```

Expected and the checks that follow:
- Pitch Correct `ui` ≥ 1500 (scenario R6 needs the 3-lens path) and Parameter Link `ui` < 1500 (R6b needs the inline path). If either is false, this is a spec assumption the metric contradicts: **stop only if** no other script satisfies each side; otherwise ledger a `Ruling:` naming the substitute script(s) (candidates: Pan Snap, Selected Track Meter, Mapper scripts under `Mixing/`) and update spec §8.2 R6/R6b accordingly in Step 3.
- The `--contrast` table prints 14 rows; note every row with `sev 3`/`sev 4` (these become the "library defaults" Tier C table in P2's review, reported once per review).
- luacheck warning count for the Meter: measured 305 on 2026-09-29 (`luacheck` summary line: `305 warnings / 0 errors`); the `grep -c ':'` count differs by one (the summary line) so use the summary. Record the number printed now.

- [ ] **Step 3: Update spec numbers that the tools contradict (PD6)**

Only if Step 2 measured different values than the spec text, edit `docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md` §8.2 with the Edit tool:
- R2: replace `the 307-warning baseline` with `the 305-warning baseline (measured 2026-09-29)`, and replace `40 hex literals` with the count of CN2 `hex colour` findings printed by `r4_check.py` (`Selected Track Meter CN2 hex findings:`), keeping the parenthetical wording.
- R6/R6b: only if Step 2 required a substitute script.

Then commit the spec edit (tracked) with named path only, if it changed:

```bash
cd /Users/macstudio/Development/fancy-scripts && git add docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md && git commit -m "docs: correct measured baselines in the ReaImGui UX skills spec (P1 exit)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

Expected: commit lists only that file; skip the commit if nothing changed.

- [ ] **Step 4: Final P1 exit gate**

Run all three; each must hold:

```bash
cd /Users/macstudio/Development/fancy-scripts && python3 .agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test && python3 "/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/d105a67a-6ede-4b93-a374-961947e82d8f/scratchpad/ux-skill-tests/p1/r4_check.py" | tail -1 && git status --short | grep "\.lua"
```

Expected: `self-test: N passed, 0 failed` (N ≥ 71), `RESULT PASS`, and a `git status` `.lua` list identical to the one at session start (modified: Parameter Link, Selected Track Meter, Pitch Correct, Pan Snap, Design System, `_lib/theme.lua`; untracked: `Mixing/…`, `_lib/mapper_engine.lua`), i.e. this plan touched no Lua file. `luacheck . | tail -1` totals must match the pre-plan totals recorded in the ledger at setup. Ledger the P1 exit as met, and stop: P2 gets its own plan.

---

## Self-Review (against spec §3.3 P1, §6, §7)

- **§7 prerequisites:** items 1 (ui_agent), 2 (AGENTS.md HC + routing), 5 (.gitignore), 6 (docs/design/README.md), 7 (.reapack-index.conf) → Task 1. Item 3 (ai-skeptic-reviewer, with its own baseline) → Task 2. Item 4 (symlinks) is P2/P3 by spec ("at the end of P2 and P3, not before RED runs") and deliberately absent here.
- **§6 CLI/introspection/modes/probes/fixtures:** CLI + exit codes + comment/string blanking → Task 3; `--theme`, Theme/`icons`/`layout`/`font_sizes`/`create_fonts`/palette with mode dependence → Task 4; `--ui-lines`, `--contrast` → Task 5; every probe row of the §6 table → Tasks 3, 6, 7 (CN2 hex, CreateFont, AlignText, Spacing, DrawList text, IsKeyPressed, bare Esc, BeginDisabled, End-outside-if, symbol checks, modal scrim, numeric literals, Cond_Always, SetExtState, tooltip APIs, raw widgets, RB3, Undo in loop, clamp, icon tooltip, `###`, selection APIs); every "Self-test fixtures" bullet → Tasks 3, 4, 7 (bitmasks, transparent, strings, guard chains, `Theme.badge_button`/`with_alpha`, one true positive per probe); API list with version header and regeneration note → Task 7; "not a CI gate" → Global Constraints.
- **P1 exit criteria:** `--self-test` green (Tasks 3–7), R4 (Task 8 Step 1), `--ui-lines`/`--contrast` numbers (Task 8 Step 2).
- **Type consistency:** `finding(...)` extras used by tests (`tier`, `handler`, `key`, `rb`, `replacement`, `palette`, `mode_dependent`) match the probes that emit them; `Ctx` gains `api`/`api_version` in Task 7 and every earlier `Ctx` use (`palette_matches`, `is_mode_dep`, `theme`) is preserved; `find_calls` yields `Call` with `.pos .close .args .cargs` everywhere; probe rule IDs are the spec's.
- **Placeholder scan:** no TBD/TODO; every code step carries code; the only conditional steps (Task 2 reword, Task 8 substitutions) state the exact rule for deciding.
- **Known limit, recorded not hidden:** `probe_begin_end`, `probe_undo_in_loop` and `_handler_kind` are heuristics (the spec marks them "block-aware heuristic" / `check`); Task 8's real-file run is where their false-positive rate is measured.