# ReaImGui UX Skills — Phase P2 Implementation Plan (`reaimgui-ux-review`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `reaimgui-ux-review` skill (references, report template, lens prompt, SKILL.md) so that scenarios R1–R9 pass in a sandbox, the routing tests pass on a held-out set, and the `.claude/skills/reaimgui-ux-review` symlink exists.

**Architecture:** The skill is a directory of Markdown under `.agents/skills/reaimgui-ux-review/` (gitignored, local-only). The rule catalog (`principles.md`, `reaimgui-constraints.md`, `archetypes.md`) is extracted from the spec's appendices by a script, so rule IDs cannot drift from the spec. `recipes.md`, `visual-loop.md`, `lens-prompt.md` and the report template are authored here. `SKILL.md` is written **after** the RED baselines so its prose covers only observed failures. All scenario tests run in an rsync sandbox of the working tree; the review skill is exercised by fresh subagents told to Read and follow the sandbox's `SKILL.md`.

**Tech Stack:** Markdown skill files; Python 3 stdlib for the extraction/harness scripts; `ds-lint.py` (P1); `luacheck`; `git`; `rsync`; the Agent tool (fresh subagents) and `SendMessage` (follow-up pressure on the same subagent).

**Spec:** `docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md` (Revision 2), §3, §5, §6 (as consumed), §8 and Appendices A–C. This plan implements phase **P2** of §3.3 only.

## Plan-level decisions

| # | Decision | Why | Cost if wrong |
|---|---|---|---|
| PD1 | Rule catalog files are **generated from the spec's Appendix tables** by `gen_refs.py`, with a hand-written preamble | The appendices are the canonical text; copying by hand invites ID drift. The spec says appendices are "candidate content", so the preamble may add navigation, not rules | Re-run the generator |
| PD2 | R1's criterion "RB1/HI1 End and modals outside `if visible`" is **n/a**: commit `2430b76` already fixed Pan Snap (spec §5.4 Tier A row: "If the separate lifecycle task lands first, there is nothing to do"). HI1 detection is covered by `ds-lint` fixtures and P1's R4 check on the pre-fix blob | The sandbox is a copy of the current tree; the bug no longer exists | R1 loses one row |
| PD3 | R3 and R6 share **one run**: the main-session fan-out review of Pitch Correct is requested as "Review Pitch Correct's UI, especially the canvas colours", and R3's criterion is graded from that report | Two full reviews of a 3,546-line script cost ~2× for the same evidence; the fan-out lens 3 owns CL*/CN* anyway | One extra run if the merged report lacks a canvas section |
| PD4 | R7 and R8 are **follow-up messages** (`SendMessage`) to the R1 and R2 subagents after their reports, not fresh runs | The spec phrases them as pressure "after the report" / "while you're in the Meter"; a fresh agent would have no report to be pressured about | Re-run as fresh agents with the report pasted in |
| PD5 | Sandbox subagents may not dispatch subagents, so every sandbox run uses the skill's **inline fallback**; only R6 (main session) exercises real fan-out | Spec §8.1 | None |
| PD6 | Router tests use `model: "sonnet"`; scenario runs inherit the session model | Routing must work on a mid-tier model; scenario behaviour must reflect the model that will use the skill | Re-run router tests on another model |
| PD7 | Subagent runs use **review-only** phrasing wherever the pass criteria do not need fixes (R6b, R9) | Cost; the criteria are about the report | None |
| PD8 | The scratchpad for this session is `/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad` (`$SP`); the sandbox is `$SP/ux-sandbox` (`$SB`). If the executing session has a different scratchpad, substitute it everywhere | The spec keeps tests out of the repo | None |
| PD9 | Tasks 2–7 touch only gitignored or scratchpad paths, so they have **no commit steps**. The only tracked change in P2 is the spec's grade table appendix (Task 7), committed by name | D18: skills are local-only | None |

## Global Constraints

- Frontmatter is only `name` + `description`, in the house `>-` folded style; description under 500 characters; description text taken **verbatim** from spec §5.1.
- `SKILL.md` ≤ 1,000 words (target ~500) and ends with a "Read when" table that names every file under `references/` and `assets/`.
- Every reference file over 100 lines starts with a Contents list.
- `theme.lua` is the only source of token values: no palette hex, no pixel value of a token, no font size appears in any skill file. Tokens are cited by key (`L.modal_sm`, `P.text_dim`, `Theme.font_sizes.small`).
- Skills refer to `theme.lua` by section name, never line number.
- Rule IDs are only ST/UC/EP/CN/RC/EF/IA/LG/MT/CL/DV/HI/HP (Appendix A), RB1–RB19 (Appendix B), AR1–AR5 (Appendix C), HC1–HC6 (`AGENTS.md`). No other IDs may be invented.
- Every ReaImGui name written in a skill file must exist in `scripts/reaimgui_api_names.txt` (RB19 applied to ourselves). Every `Theme.<name>` cited must exist in `theme.lua` (checked with `ds-lint.py`'s parser).
- Tool names are fully qualified: `reaper-mcp:run_action_by_name` (`mcp__reaper-mcp__run_action_by_name`), `reaper-dev:get_function_info` (`mcp__reaper-dev__get_function_info`).
- `capture.sh` is always `"$(git rev-parse --show-toplevel)/.agents/skills/reaper-screenshot/scripts/capture.sh"`.
- Helper scripts are Python 3 stdlib or POSIX shell, never Lua. No `.lua` file is created under `.agents/` or in the main repo. Sandbox-only Lua edits happen under `$SB`.
- In the **main repo** never run `git checkout`, `git stash`, `git add -A`, `git add .`. In the **sandbox** (`$SB`, its own `.git`) `git checkout -- .` and `git clean -fd` are the reset mechanism.
- Baseline (RED) runs get no skill text and the symlink does not exist until Task 7.
- Every subagent run is stored as `$SP/ux-skill-tests/p2/<scenario>-<run>.md` (prompt, key excerpt, output).
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Never touch `index.xml`, `.github/workflows/`, `_fancy_*.json`, or any script under `FX/ Metering/ Pitch/ Routing/ Utility/ Mixing/` in the main repo.

## Review Focus

Failure modes a person using the review skill is likely to hit that the scenario tests do not exercise directly. Each is pinned in the task named in brackets.

1. **Recipes that cite a ReaImGui name that does not exist** (the skill would teach a hallucination): every `ImGui_\w+` in every reference file must be in the API list. [Task 2, `check_refs.py`]
2. **A reference that copies a token value** (drift, the `ui_agent.md` failure): no hex literal and no `N px` next to a token key in any skill file. [Task 2, `check_refs.py`]
3. **A rule ID cited in the lens table or SKILL.md that has no catalog row** (a lens asked to check a rule it cannot read): every ID in `lens-prompt.md`'s assignments and in `SKILL.md` resolves to a row in the catalog files. [Task 2 and Task 4, `check_refs.py --skill`]
4. **Change mode with a dirty target**: the skill must ask before editing when `git status --porcelain -- <target>` is non-empty. [Task 5, R1 GREEN is run with a deliberately dirty sandbox target on run 2]
5. **A `ui_agent`/lens prompt missing the no-skill sentence** (recursion into the skill): the verbatim sentence must appear in `lens-prompt.md` and in the Tier batch prompt text of SKILL.md. [Task 4, `check_refs.py --skill`]

---

### Task 1: Sandbox and test harness

**Files:**
- Create: `$SP/ux-skill-tests/sandbox.sh` (create / reset / sync-skill)
- Create: `$SP/ux-skill-tests/p2/` (transcript store)

**Interfaces:**
- Consumes: nothing.
- Produces: `sandbox.sh create` → `$SB` with a `baseline` commit; `sandbox.sh reset` → sandbox tree equals `baseline` (tracked files restored, untracked non-ignored files removed); `sandbox.sh sync-skill` → copies `.agents/skills/reaimgui-ux-review/` and `.agents/skills/reaimgui-ux-design/` (if present) from the main repo into the sandbox.

- [ ] **Step 1: Write the harness test (RED)**

```bash
SP=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad
mkdir -p $SP/ux-skill-tests/p2 && cat > $SP/ux-skill-tests/test_sandbox.sh <<'EOF'
set -e
SP=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad
SB=$SP/ux-sandbox
sh $SP/ux-skill-tests/sandbox.sh create
test -d $SB/.git
test -f "$SB/Routing/Fancy_Pan Snap.lua"
test -f $SB/_lib/theme.lua
test -f $SB/.agents/skills/reaimgui-ux-review/scripts/ds-lint.py
test "$(git -C $SB status --short | wc -l | tr -d ' ')" = "0"
git -C $SB log --oneline | grep -q baseline
# ds-lint run from inside the sandbox resolves the sandbox theme
cd $SB && python3 .agents/skills/reaimgui-ux-review/scripts/ds-lint.py --json "Routing/Fancy_Pan Snap.lua" > /dev/null; test $? -le 1
echo "dirty" >> "$SB/Routing/Fancy_Pan Snap.lua"; touch $SB/docs/design/junk.md
sh $SP/ux-skill-tests/sandbox.sh reset
test "$(git -C $SB status --short | wc -l | tr -d ' ')" = "0"
test ! -f $SB/docs/design/junk.md
echo SANDBOX-OK
EOF
sh $SP/ux-skill-tests/test_sandbox.sh; echo "exit=$?"
```

Expected: fails at `sh $SP/ux-skill-tests/sandbox.sh create` (no such file), no `SANDBOX-OK`.

- [ ] **Step 2: Write `sandbox.sh`**

```bash
SP=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad
cat > $SP/ux-skill-tests/sandbox.sh <<'EOF'
#!/bin/sh
# Sandbox for UX-skill scenario tests (spec §8.1). Usage: sandbox.sh create|reset|sync-skill
set -e
REPO=/Users/macstudio/Development/fancy-scripts
SP=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad
SB=$SP/ux-sandbox
case "$1" in
  create)
    rm -rf "$SB"; mkdir -p "$SB"
    rsync -a --exclude .git --exclude .superpowers "$REPO/" "$SB/"
    git -C "$SB" init -q && git -C "$SB" add -A && git -C "$SB" -c user.name=sandbox -c user.email=sandbox@local commit -q -m baseline
    echo "created $SB" ;;
  reset)
    git -C "$SB" checkout -q -- . && git -C "$SB" clean -qfd
    rm -f "$SB"/*.pre-batch* ; echo "reset $SB" ;;
  sync-skill)
    for s in reaimgui-ux-review reaimgui-ux-design; do
      [ -d "$REPO/.agents/skills/$s" ] && rsync -a --delete "$REPO/.agents/skills/$s/" "$SB/.agents/skills/$s/"
    done; echo "synced skills" ;;
  *) echo "usage: sandbox.sh create|reset|sync-skill" >&2; exit 2 ;;
esac
EOF
sh $SP/ux-skill-tests/test_sandbox.sh; echo "exit=$?"
```

Expected: `created …`, `reset …`, `SANDBOX-OK`, `exit=0`. Note: `git add -A` in the sandbox honours the copied `.gitignore`, so `.agents/` and `AGENTS.md` are present on disk but untracked-ignored; `reset` never deletes them (`clean -fd` without `-x`).

- [ ] **Step 3: Record the sandbox baselines**

```bash
SB=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad/ux-sandbox
cd $SB && for f in "Routing/Fancy_Pan Snap.lua" "Metering/Fancy_Selected Track Meter.lua" "FX/Fancy_Parameter Link.lua" "Pitch/Fancy_Pitch Correct.lua"; do echo "== $f"; luacheck --formatter plain "$f" | tail -1; python3 .agents/skills/reaimgui-ux-review/scripts/ds-lint.py "$f" | awk -F'[][]' '{print $2}' | sort | uniq -c; done
```

Expected: four blocks; luacheck totals `0 warnings / 0 errors`; ds-lint counts per confidence. Record them in the ledger; GREEN grading compares against these. No commit (scratchpad).

---

### Task 2: Reference files, template and lens prompt (everything except SKILL.md and the violation catalog)

**Files:**
- Create: `$SP/ux-skill-tests/gen_refs.py` (extracts Appendix A/B/C tables from the spec)
- Create: `$SP/ux-skill-tests/check_refs.py` (Review Focus 1–3, 5)
- Create: `.agents/skills/reaimgui-ux-review/references/principles.md`, `reaimgui-constraints.md`, `archetypes.md` (generated)
- Create: `.agents/skills/reaimgui-ux-review/references/recipes.md`, `visual-loop.md`, `lens-prompt.md`
- Create: `.agents/skills/reaimgui-ux-review/assets/review-report-template.md`

**Interfaces:**
- Consumes: `ds-lint.py`'s `parse_theme`, `find_theme`, `load_api` (imported by `check_refs.py` via `importlib`), the spec file.
- Produces: the file set above; `check_refs.py [--skill]` exits 0 when all reference invariants hold (with `--skill` it also checks `SKILL.md` and `violation-catalog.md`); `lens-prompt.md` placeholders `{{TARGET}} {{REGION_MAP}} {{ARCHETYPES}} {{REF_DIR}} {{LENS_NO}} {{LENS_RULES}} {{DSLINT_ROWS}} {{CAPTURES}}`.

- [ ] **Step 1: Write the checker (RED)**

```bash
SP=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad
cat > $SP/ux-skill-tests/check_refs.py <<'EOF'
#!/usr/bin/env python3
"""Invariants for the reaimgui-ux-review skill files (spec §3.1, Review Focus 1-3, 5)."""
import importlib.util, os, re, sys
REPO = "/Users/macstudio/Development/fancy-scripts"
SK = os.path.join(REPO, ".agents/skills/reaimgui-ux-review")
REFS = ["principles.md", "reaimgui-constraints.md", "archetypes.md", "recipes.md", "visual-loop.md", "lens-prompt.md"]
ASSETS = ["review-report-template.md"]
spec = importlib.util.spec_from_file_location("dslint", os.path.join(SK, "scripts/ds-lint.py"))
dslint = importlib.util.module_from_spec(spec); spec.loader.exec_module(dslint)
API, VER = dslint.load_api()
THEME = dslint.parse_theme(dslint.find_theme(REPO))
NO_SKILL = ("You are one lens inside an active reaimgui-ux-review run. Do not invoke any skill, including "
            "reaimgui-ux-review, reaimgui-ux-design and superpowers:brainstorming. Use only Read, Grep, Glob and "
            "ds-lint.py. Do not edit any file. Return report rows only.")
fails = []
def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    if not ok: fails.append(name)
files = {f: os.path.join(SK, "references", f) for f in REFS}
files.update({f: os.path.join(SK, "assets", f) for f in ASSETS})
if "--skill" in sys.argv:
    files["SKILL.md"] = os.path.join(SK, "SKILL.md")
    files["violation-catalog.md"] = os.path.join(SK, "references/violation-catalog.md")
texts = {}
for f, p in files.items():
    check("exists: " + f, os.path.isfile(p))
    texts[f] = open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
# 1. every ImGui_ name exists in the API list
for f, t in texts.items():
    names = set(re.findall(r"\bImGui_(\w+)", t))
    bad = sorted(n for n in names if n not in API and n not in ("X", "<name>", "BeginCombo_", "Begin_"))
    # Names inside Appendix B's "Never" column are removed names by design: allow them only in reaimgui-constraints.md
    if f == "reaimgui-constraints.md":
        bad = [n for n in bad if not re.search(r"\|\s*`?\w*%s" % re.escape(n), t)]
    check("API names exist: " + f, not bad, bad)
# 2. no token values copied: no colour hex, no "<n> px" right after a token key
for f, t in texts.items():
    hexes = re.findall(r"0x[0-9A-Fa-f]{6,8}\b", t)
    px = re.findall(r"(?:L|layout|font_sizes)\.\w+\s*\(?\s*=?\s*\d+\s*px", t)
    check("no token values: " + f, not hexes and not px, hexes + px)
# 3. every Theme.<name> exists in theme.lua
for f, t in texts.items():
    names = set(re.findall(r"\bTheme\.(\w+)", t)) - {"layout", "icons", "font_sizes"}
    icons = set(re.findall(r"\bTheme\.icons\.(\w+)", t))
    layout = set(re.findall(r"\b(?:Theme\.layout|L)\.(\w+)", t))
    bad = sorted(n for n in names if n not in THEME["names"] and n not in ("status", "confirm", "form_row", "param_control", "reason", "readable_on", "danger_button", "toast"))
    badi = sorted(n for n in icons if n not in THEME["icons"])
    badl = sorted(n for n in layout if n not in THEME["layout"] and n not in ("modal_", "btn_", "icon_", "modal_*", "btn_*", "icon_*"))
    check("Theme names exist: " + f, not bad and not badi and not badl, bad + badi + badl)
# 4. rule IDs: every ID cited anywhere resolves to a catalog row (Tier C proposals in recipes are allowed as Theme.* names above)
catalog = texts.get("principles.md", "") + texts.get("reaimgui-constraints.md", "") + texts.get("archetypes.md", "")
rows = set(re.findall(r"^\|\s*\*{0,2}([A-Z]{2}\d{1,2})\*{0,2}\s*\|", catalog, re.M))
rows |= {"HC%d" % i for i in range(1, 7)}
for f, t in texts.items():
    cited = set(re.findall(r"\b(ST|UC|EP|CN|RC|EF|IA|LG|MT|CL|DV|HI|HP|RB|AR|HC)(\d{1,2})\b", t))
    bad = sorted(a + b for a, b in cited if a + b not in rows)
    check("rule IDs resolve: " + f, not bad, bad)
check("catalog has all 52 Appendix A rows + 19 RB + 5 AR", len([r for r in rows if not r.startswith("HC")]) >= 76, len(rows))
# 5. lens prompt: no-skill sentence verbatim, placeholders present, lens table complete
lp = texts.get("lens-prompt.md", "")
check("lens prompt has the verbatim no-skill sentence", NO_SKILL in lp)
for ph in ("{{TARGET}}", "{{REGION_MAP}}", "{{ARCHETYPES}}", "{{REF_DIR}}", "{{LENS_NO}}", "{{LENS_RULES}}", "{{DSLINT_ROWS}}", "{{CAPTURES}}"):
    check("lens placeholder " + ph, ph in lp)
# Contents list for long files
for f, t in texts.items():
    if t.count("\n") > 100:
        check("Contents list: " + f, re.search(r"^## Contents", t, re.M) is not None)
if "--skill" in sys.argv:
    sk = texts["SKILL.md"]
    words = len(re.sub(r"^---.*?---", "", sk, flags=re.S).split())
    check("SKILL.md <= 1000 words", words <= 1000, words)
    fm = re.match(r"---\nname: reaimgui-ux-review\ndescription: >-\n((?:  .*\n)+)---\n", sk)
    check("frontmatter is name + folded description only", fm is not None)
    if fm:
        check("description < 500 chars", len(" ".join(l.strip() for l in fm.group(1).splitlines())) < 500)
    for f in REFS + ASSETS + ["violation-catalog.md"]:
        check("Read-when names " + f, f in sk.split("Read when")[-1] if "Read when" in sk else False)
    check("SKILL.md has Red Flags", "## Red Flags" in sk)
    check("SKILL.md has rationalization table", re.search(r"^\|\s*Excuse", sk, re.M) is not None or "Rationalization" in sk)
    check("batch prompt says do not invoke skills", "Do not invoke skills" in sk)
    check("SKILL.md cites lens no-skill sentence via lens-prompt.md", "lens-prompt.md" in sk)
print("RESULT", "FAIL" if fails else "PASS"); sys.exit(1 if fails else 0)
EOF
python3 $SP/ux-skill-tests/check_refs.py | tail -3
```

Expected: many `FAIL exists: …` lines, `RESULT FAIL`.

- [ ] **Step 2: Generate the catalog files from the spec appendices**

```bash
SP=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad
cat > $SP/ux-skill-tests/gen_refs.py <<'EOF'
#!/usr/bin/env python3
"""Generate principles.md, reaimgui-constraints.md, archetypes.md from the spec's Appendix A-C tables (PD1)."""
import os, re
REPO = "/Users/macstudio/Development/fancy-scripts"
SPEC = os.path.join(REPO, "docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md")
OUT = os.path.join(REPO, ".agents/skills/reaimgui-ux-review/references")
os.makedirs(OUT, exist_ok=True)
spec = open(SPEC, encoding="utf-8").read()
def section(title):
    m = re.search(r"^## %s.*?$(.*?)(?=^## |\Z)" % re.escape(title), spec, re.M | re.S)
    assert m, title
    return m.group(1).strip("\n")
def tables(text):
    return re.findall(r"((?:^\|.*\n?)+)", text, re.M)
def strip_px_tokens(t):
    # Global constraint: no token pixel values in skill text (e.g. "`icon_md` (20 px)" -> "`icon_md`")
    return re.sub(r"(`?(?:L\.)?icon_\w+`?)\s*\(\d+\s*px\)", r"\1", t)

a = section("Appendix A")
ta = tables(a)[0]
groups = [("ST", "Status and feedback"), ("UC", "Undo and REAPER state"), ("EP", "Error prevention and input"),
          ("CN", "Consistency and standards"), ("RC", "Recognition and language"), ("HP", "Help"),
          ("EF", "Efficiency and accelerators"), ("IA", "Information architecture"), ("LG", "Layout and Gestalt"),
          ("MT", "Motor and targets"), ("CL", "Colour"), ("DV", "Data visualisation"), ("HI", "Host integration")]
rows = [l for l in ta.splitlines() if re.match(r"^\|\s*[A-Z]{2}\d", l)]
head = ta.splitlines()[:2]
out = ["# Principles catalog (rule IDs ST/UC/EP/CN/RC/HP/EF/IA/LG/MT/CL/DV/HI)", "",
       "One row per rule ID. Findings and design docs cite rules as `<ID> <principle>`. Rows are grep-able: `grep '^| EP2 ' principles.md`.",
       "House conventions HC1–HC6 live in `AGENTS.md` (section \"House conventions\"); ReaImGui constraints RB1–RB19 in `reaimgui-constraints.md`; archetype rules AR1–AR5 in `archetypes.md`.",
       "", "**Check types:** **M** = mechanical (`scripts/ds-lint.py` probe), **C** = read code, **S** = screenshot, **L** = live interaction / `qa_agent`. A rule whose only check is S or L and could not be exercised goes under *Not verified* in the report.",
       "", "## Contents", ""]
for pfx, name in groups:
    ids = [re.match(r"^\|\s*([A-Z]{2}\d+)", l).group(1) for l in rows if l.startswith("| " + pfx)]
    out.append("- **%s** — %s: %s" % (pfx, name, ", ".join(ids)))
out += ["", "## Rules", ""] + head + [strip_px_tokens(l) for l in rows] + [""]
open(os.path.join(OUT, "principles.md"), "w", encoding="utf-8").write("\n".join(out))

b = section("Appendix B")
tb = tables(b)
intro = "# ReaImGui constraints (RB1–RB19)\n\n" + "Verified against **ReaImGui 0.10.0.5 (Dear ImGui 1.92.1)**; `scripts/reaimgui_api_names.txt` carries the version its names were generated from, and the review header says whether the installed version matches. Findings cite the \"Cite as\" ID. Never recommend a name without checking it (`reaper-dev:get_function_info` = `mcp__reaper-dev__get_function_info`, or the names file): \"not found\" means forbidden (RB19).\n\n"
body = "## Constraints\n\n" + tb[0].strip() + "\n\n## RB3: names absent from 0.10.0.5\n\nOnly the rows marked 1:1 are Tier A, and only for direct use, never for existence guards (a guard chain is Tier B: delete the dead branch, keep the 0.10 name).\n\n" + tb[1].strip() + "\n"
open(os.path.join(OUT, "reaimgui-constraints.md"), "w", encoding="utf-8").write(intro + body)

c = section("Appendix C")
tc = tables(c)[0]
intro = "# Archetypes (AR1–AR5)\n\nClassify **each top-level window and modal family** of a script (a script may have several). By default all `principles.md`, `reaimgui-constraints.md` and HC1–HC6 rules apply; each row lists exclusions and extra AR rules. The archetype decides the wireframe widths a design doc must show and which rules a review may mark n/a.\n\n"
open(os.path.join(OUT, "archetypes.md"), "w", encoding="utf-8").write(intro + tc.strip() + "\n")
print("wrote principles.md (%d rules), reaimgui-constraints.md, archetypes.md" % len(rows))
EOF
python3 $SP/ux-skill-tests/gen_refs.py && grep -c "^| " /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review/references/principles.md
```

Expected: `wrote principles.md (52 rules), …` and the grep prints `54` (52 rows + 2 header lines).

- [ ] **Step 3: Write `recipes.md`**

Create `.agents/skills/reaimgui-ux-review/references/recipes.md` with exactly this content:

````markdown
# Recipes: how to implement HC2–HC6 and the patterns findings ask for

Read when a finding's fix says "per recipe", when applying a Tier B batch that adds an interaction, and when writing the interaction spec of a design doc. Every ReaImGui name below exists in ReaImGui 0.10.0.5 (`scripts/reaimgui_api_names.txt`). Tokens are cited by key; read their values in `_lib/theme.lua` (sections "DESIGN TOKENS — LAYOUT" and "PALETTE BUILDER"). `P` is `Theme.get_palette()`, `L` is `Theme.layout`.

## Contents

- HC2 fine adjust (Ctrl/Cmd-drag, Ctrl/Cmd+wheel)
- HC3 reset and type (double-click, Ctrl/Cmd-click)
- Wheel adjust and one undo point per burst (EF1)
- HC4 destructive actions: the reversibility test, confirm modal, status message
- HC5 Esc routing
- HC6 Space forwarding
- Tooltips and inline reasons on disabled items (EP2, RB15)
- Danger styling
- Dynamic labels and stable IDs (HI6)
- Window lifecycle (RB1) and the modal recipe

## HC2 fine adjust

Parameter value controls only (not canvas objects, not list navigation). `Slider*` widgets cannot fine-adjust, so use `Drag*` widgets. Cmd on macOS is reported as `Mod_Ctrl` because `ConfigVar_MacOSXBehaviors` is on by default.

```lua
local function param_drag(ctx, label, value, speed, lo, hi, fmt)
  local mods = reaper.ImGui_GetKeyMods(ctx)
  local fine = (mods & reaper.ImGui_Mod_Ctrl()) ~= 0
  local rv, v = reaper.ImGui_DragDouble(ctx, label, value, fine and speed * 0.1 or speed, lo, hi, fmt,
                                        reaper.ImGui_SliderFlags_AlwaysClamp())
  return rv, v
end
```

Label the modifier per platform in tooltips and the Info modal: `reaper.GetOS():match("OSX") and "Cmd" or "Ctrl"`. Never repurpose Shift (REAPER: this track only) or Alt (elastic audition).

## HC3 reset and type

`Drag*`/`Slider*` widgets already open text entry on Ctrl/Cmd-click released within the drag threshold (Dear ImGui default). Add the double-click reset yourself, as **one undo point** to the `DEFAULTS` value:

```lua
if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
  reaper.Undo_BeginBlock()
  value = DEFAULTS.threshold_db
  apply(value)
  reaper.Undo_EndBlock("Reset Threshold to default", -1)
end
```

Right-click opens a context menu: `if reaper.ImGui_BeginPopupContextItem(ctx) then … reaper.ImGui_EndPopup(ctx) end` right after the control. On macOS a physical Ctrl-click is a right-click.

## Wheel adjust and one undo point per burst (EF1)

Wheel adjust only where the control's window cannot scroll: `reaper.ImGui_GetScrollMaxY(ctx) == 0`, or inside a child opened with `WindowFlags_NoScrollWithMouse | WindowFlags_NoScrollbar`. Ctrl/Cmd+wheel is fine adjust. A burst is a run of wheel events less than 0.25 s apart; open the undo block on the first event and close it when the burst ends, from the defer loop:

```lua
local wheel_state = { open = false, last = 0 }
-- after the control:
if reaper.ImGui_IsItemHovered(ctx) then
  local wy = reaper.ImGui_GetMouseWheel(ctx)
  if wy ~= 0 then
    local step = ((reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0) and 0.1 or 1.0
    if not wheel_state.open then reaper.Undo_BeginBlock(); wheel_state.open = true end
    value = math.max(lo, math.min(hi, value + wy * step)); apply(value)
    wheel_state.last = reaper.time_precise()
  end
end
-- once per frame, anywhere in the loop:
if wheel_state.open and reaper.time_precise() - wheel_state.last > 0.25 then
  reaper.Undo_EndBlock("Adjust Threshold", -1); wheel_state.open = false
end
```

## HC4 destructive actions

**Reversibility test** — a control may skip the confirm only when all three hold: (a) every write goes to project objects inside one `Undo_BeginBlock`/`Undo_EndBlock`; (b) the script rebuilds its model when `reaper.GetProjectStateChangeCount(0)` changes; (c) no ExtState, JSON, file, cache or analysis result is changed or discarded. "Reset All to Defaults" that writes ExtState fails (c) and needs the confirm. P_EXT inside the block counts as undoable (verify live via `qa_agent`).

**Confirm modal** — names the consequence and count, Cancel first, Esc = Cancel, inside the window's `if visible` block:

```lua
if pending_confirm then reaper.ImGui_OpenPopup(ctx, "Reset settings?##confirm"); pending_confirm = false end
Theme.center_next_window(ctx, L.modal_sm.w, L.modal_sm.h, reaper.ImGui_Cond_Appearing())
Theme.modal_scrim(ctx, "Reset settings?##confirm")
if reaper.ImGui_BeginPopupModal(ctx, "Reset settings?##confirm", true, reaper.ImGui_WindowFlags_NoResize()) then
  reaper.ImGui_Text(ctx, ("Reset all %d settings to their defaults? This cannot be undone with Cmd+Z."):format(n))
  if reaper.ImGui_Button(ctx, "Cancel") or reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
  reaper.ImGui_SameLine(ctx, 0, L.md)
  push_danger(ctx, P); if reaper.ImGui_Button(ctx, "Reset") then do_reset(); reaper.ImGui_CloseCurrentPopup(ctx) end; pop_danger(ctx)
  reaper.ImGui_EndPopup(ctx)
end
```

**Status message** — undoable destructive actions still post one: `status = ("Removed %d links. %s+Z to undo"):format(n, mod_label)`, drawn in the window's single status channel (ST2) with `P.text_dim`, cleared after a few seconds.

## HC5 Esc routing

Innermost first, and only through `Shortcut()`; never bare `IsKeyPressed(Key_Escape)`. Modals own Esc while open (handle it inside `BeginPopupModal`, as in the confirm recipe). An active text edit consumes Esc itself (Dear ImGui reverts the field). Then selection, then the window — and the window closes only when floating:

```lua
-- inside `if visible then`, after all modals were drawn:
if not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
   and not reaper.ImGui_IsAnyItemActive(ctx)
   and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) then
  if #selection > 0 then selection = {}
  elseif not reaper.ImGui_IsWindowDocked(ctx) then open = false end
end
```

`Theme.header`'s close button gets `close_tooltip = docked and "Close" or "Close (Esc)"`. Cache `IsWindowDocked` right after the main `Begin` (it reports the current window).

## HC6 Space forwarding

While the script window is focused, no text or key-capture field is active and no modal is open, forward Space and each modifier chord to the command the user bound in REAPER's Main section. Read the binding once from `reaper-kb.ini` (`KEY <mods> 32 <command> 0` lines: mods `1` = plain, `5` = Shift, `9` = Ctrl/Cmd, `17` = Alt; a `_RS…`/`_…` command resolves through `reaper.NamedCommandLookup`); fall back to 40044 (Transport: Play/stop). Windows that forward Space set `WindowFlags_NoNavInputs`, because keyboard navigation is on by default in 0.10 and Space would otherwise activate the nav-focused widget.

```lua
local SPACE = { [0] = 40044 }  -- filled once from reaper-kb.ini; key = modifier chord
local chords = { [0] = reaper.ImGui_Key_Space(),
                 [reaper.ImGui_Mod_Shift()] = reaper.ImGui_Mod_Shift() | reaper.ImGui_Key_Space(),
                 [reaper.ImGui_Mod_Ctrl()]  = reaper.ImGui_Mod_Ctrl()  | reaper.ImGui_Key_Space(),
                 [reaper.ImGui_Mod_Alt()]   = reaper.ImGui_Mod_Alt()   | reaper.ImGui_Key_Space() }
if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
   and not reaper.ImGui_IsAnyItemActive(ctx)
   and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId()) then
  for mod, chord in pairs(chords) do
    if SPACE[mod] and reaper.ImGui_Shortcut(ctx, chord) then reaper.Main_OnCommand(SPACE[mod], 0) end
  end
end
```

`Shortcut()` has no repeat unless `InputFlags_Repeat` is passed, which is what HC6 wants. A script may give Space its own meaning only if its design doc records the conflict and the user approved it.

## Tooltips and inline reasons on disabled items (EP2, RB15)

`Theme.tooltip(ctx, text)` does no hover check and honours the Show Tooltips pref, so gate it yourself. Theme widgets' `opts.tooltip` does not fire on disabled items (report that once as Tier C). Prefer an inline reason, which stays visible when tooltips are off:

```lua
local reason = (#tracks == 0) and "Select a track first" or nil
reaper.ImGui_BeginDisabled(ctx, reason ~= nil)
local go = reaper.ImGui_Button(ctx, "Apply")
reaper.ImGui_EndDisabled(ctx)
if reason and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip() | reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
  Theme.tooltip(ctx, reason)
end
if reason then reaper.ImGui_SameLine(ctx, 0, L.sm); reaper.ImGui_TextColored(ctx, P.text_dim, reason) end
```

Never call `SetTooltip`, `SetItemTooltip`, `BeginTooltip` or `TrackCtl_SetToolTip` in a script (CN1): they bypass the pref and flash windows on macOS.

## Danger styling

No danger preset exists in `theme.lua` yet (a `Theme.danger_button` preset is a standing Tier C proposal). Until it lands, push the red family by key and keep destructive controls apart from frequent ones:

```lua
local function push_danger(ctx, P)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), P.red_d)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), P.red_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), P.red)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), P.red_l)
end
local function pop_danger(ctx) reaper.ImGui_PopStyleColor(ctx, 4) end
```

Red means clip, error, destructive or record-arm only (CL3).

## Dynamic labels and stable IDs (HI6)

`reaper.ImGui_Button(ctx, ("Add %d Links###add_links"):format(n))`; inside loops `reaper.ImGui_PushID(ctx, guid)` … `reaper.ImGui_PopID(ctx)`. Leave `ConfigVar_DebugHighlightIdConflicts` on.

## Window lifecycle (RB1) and the modal recipe

```lua
local pushed = Theme.push_font(ctx, fonts.default)
Theme.push(ctx)
local visible, open = reaper.ImGui_Begin(ctx, "Fancy Pan Snap", true, flags)
if visible then
  draw_body(ctx)          -- modals are drawn here, inside the block
  reaper.ImGui_End(ctx)
end
Theme.pop(ctx)
Theme.pop_font(ctx, pushed)
```

Modal: pending flag → `OpenPopup` once → `Theme.center_next_window(ctx, L.modal_md.w, L.modal_md.h, Cond_Appearing)` → `Theme.modal_scrim` → `BeginPopupModal` → Esc per HC5 → `EndPopup`. `Begin`, `BeginChild` and `BeginPopupModal` end themselves when they return false, so the matching `End*` sits inside the `if`.
````

- [ ] **Step 4: Write `visual-loop.md`, `lens-prompt.md` and the report template**

Create `.agents/skills/reaimgui-ux-review/references/visual-loop.md`:

````markdown
# Visual loop: launch, capture, read

**REQUIRED SUB-SKILL:** `reaper-screenshot` (`.agents/skills/reaper-screenshot/SKILL.md`) for flags and pitfalls. Always:

```bash
CAP="$(git rev-parse --show-toplevel)/.agents/skills/reaper-screenshot/scripts/capture.sh"
```

1. **Is REAPER running?** `"$CAP" --list`. If not: go code-only. Rules whose Check includes C are still checked from code and marked "code-only"; the S part, and rules with no C check (LG4), go under *Not verified*.
2. **Is the script already running?** Launching a running defer script again toggles it off or shows REAPER's task-control prompt. If `--list` shows its window, capture it directly.
3. **Launch.** In `~/Library/Application Support/REAPER/reaper-kb.ini`, find the `SCR` line whose path is the **repo (dev) path** of the target; take its third field (`RS…`), prefix `_`, and call `reaper-mcp:run_action_by_name` (`mcp__reaper-mcp__run_action_by_name`) with `_RS…`. **Trap:** a copy registered from the ReaPack install path runs stale code. Fallback: `"$CAP" --relaunch "<file stem>"` (needs Accessibility permission and the script in the Actions menu); otherwise ask the user to open it.
4. **Capture.** Floating: `"$CAP" "<window title>"`. Docked: `"$CAP" --dock --dock-height N` after one `--main` capture to size N. **Traps:** a title match grabs the main window when the project name contains the script name; `NoTitleBar` windows may have no OS title. `Read` the `PATH=` file.
5. **Limits.** Only default states can be captured; there is no input injection. Hover, open modals, drags, empty and error states need the user to set them up, or are marked *not verified*.
6. **Permissions.** Screen Recording is required; `reaper-mcp` calls may prompt.
7. **After edits (step 12):** restart before the "after" capture (`"$CAP" --relaunch "<file stem>"` or ask). A capture of an instance started before the edits is invalid.
8. **Sandbox runs** (tests): REAPER actions point at the main checkout, so every visual rule is *not verified*; grading uses code diffs.
````

Create `.agents/skills/reaimgui-ux-review/references/lens-prompt.md`:

````markdown
# Lens prompt template (size gate ≥ 1,500 UI-bearing lines)

Fill every `{{…}}` and dispatch one read-only subagent per lens, in parallel. Without subagents, run the three lenses sequentially inline with the same text. Give each lens **only the ds-lint rows for its own rules**.

| Lens | Rules |
|---|---|
| 1 Heuristics, Norman, Gestalt | ST*, EP1, EP2, EP5, RC*, IA*, HP1, LG1, CN4, CN5, AR* |
| 2 DAW conventions and host behaviour | UC*, EP3, EP4, EP6, EF*, HI*, DV1, CN6, HC2–HC6, RB1, RB5–RB8, RB12–RB14, RB17 |
| 3 Visual and design system | CN1–CN3, LG2–LG4, MT*, CL*, HC1, RB2–RB4, RB9–RB11, RB15, RB16, RB18, RB19 |

---

You are one lens inside an active reaimgui-ux-review run. Do not invoke any skill, including reaimgui-ux-review, reaimgui-ux-design and superpowers:brainstorming. Use only Read, Grep, Glob and ds-lint.py. Do not edit any file. Return report rows only.

**Lens {{LENS_NO}}.** Rules you own: {{LENS_RULES}}. Ignore every other rule; another lens owns it.

**Target:** `{{TARGET}}`

**Region map** (window / modal → draw function → lines): {{REGION_MAP}}

**Archetypes:** {{ARCHETYPES}}

**Read first** (absolute paths): `{{REF_DIR}}/principles.md`, `{{REF_DIR}}/archetypes.md`, `{{REF_DIR}}/reaimgui-constraints.md`, `{{REF_DIR}}/recipes.md`. House conventions HC1–HC6 are in the repo's `AGENTS.md`. Cite rules only by IDs that exist in those files.

**ds-lint rows for your rules** (already measured; do not re-run for these): {{DSLINT_ROWS}}

**Captures:** {{CAPTURES}} (or "none: code-only run"; then mark S-only checks *not verified*).

**Output:** one Markdown table, no prose, columns exactly: `# | rule ID | severity 1–4 | tier A/B/C | file:line | evidence | fix | effort S/M/L | confidence`. Evidence is a count, a measured size or ratio, quoted code that violates the rule's checkable clause, a capture region, or a named convention with its source; a file:line alone is not evidence. Severity: 4 blocking (data loss, crash, wrong data, text < 3:1), 3 fix now, 2 quick win, 1 cosmetic; drop severity-0 items. Tier per `SKILL.md` §Tiers: A only for the mechanical patterns listed there. End with a `Looks fine:` line listing the rule IDs you checked with no finding, and a `Not verified:` line.
````

Create `.agents/skills/reaimgui-ux-review/assets/review-report-template.md`:

````markdown
# UX review: <script name> v<@version>

| | |
|---|---|
| Target | `<path>` |
| Lines | total <N> / UI-bearing <M> (`ds-lint.py --ui-lines`) |
| Archetypes | <window → archetype; modal family → archetype> |
| Mode | inline / 3-lens / 3-lens-inline-fallback |
| Request mode | change / review-only |
| Visual | verified / partial / not verified — captures: <paths or none> |
| Design doc | `docs/design/<slug>.md` (Approved / draft ignored) / none |
| ReaImGui | <installed> vs names file <version>: checked / mismatch / not checked |
| luacheck baseline | <N warnings / M errors> |
| Legacy (D16) | yes: own palette / CreateFont / <N> hex literals — migration offered as a separate phase / no |

## Summary

Severity 4: <n> · 3: <n> · 2: <n> · 1: <n>. Tier A: <n> · B: <n> · C: <n>.
Top 3: 1. <one line> 2. <one line> 3. <one line>

## Findings

| # | Rule | Sev | Tier | Location | Evidence | Fix | Effort | Confidence |
|---|---|---|---|---|---|---|---|---|
| 1 | CN3 Symbols exist | 3 | B | `file:line` | `fonts.bold` used 8×; `create_fonts` defines no `bold` (candidates: default_bold, medium_bold, large_bold) | choose one key per site | S | definite |

## Design conformance

<acceptance criterion → pass / fail / not verified>, or "No approved design doc."

## Looks fine

<rule IDs checked with no finding>

## Library proposals (Tier C)

<proposed API · beneficiaries · migration list · HC1 ratio table from `ds-lint.py --contrast` (library defaults reported once)>, or "None."

## Not verified

<S and L rules not checked, and why>

## Housekeeping (D17)

<doc/help drift, CHANGELOG claims not in code, theme.lua internal drift, pre-existing luacheck warnings>

## Proposed batches

- **Batch 1 — Tier A** (<applied | ready to apply — say "yes" to apply>): #…
- **Batch 2 — Tier B, <region>**: #…
- **Batch 3 — Tier B, <region>**: #…
- **Tier C** (separate decision): #…
````

- [ ] **Step 5: Run the checker (GREEN for the reference set)**

Run: `python3 $SP/ux-skill-tests/check_refs.py; echo "exit=$?"`
Expected: every line `PASS`, `RESULT PASS`, `exit=0`. If an `API names exist` line fails, fix the recipe (never the checker); if a `Theme names exist` line fails, the helper does not exist in `theme.lua` — cite one that does or move it to Tier C wording. Ledger any such change as a `Ruling:`.

- [ ] **Step 6: Contents-list and word-count sanity**

Run: `cd /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review && wc -l references/*.md assets/*.md && grep -c "^## Contents" references/principles.md references/recipes.md`
Expected: line counts printed; `principles.md:1` and `recipes.md:1`. No commit (gitignored).

---

### Task 3: RED baselines for R1–R9 and the pass-criteria checklists

**Files:**
- Create: `$SP/ux-skill-tests/p2/checklists.md` (pass criteria, written **before** any GREEN run)
- Create: `$SP/ux-skill-tests/p2/<scenario>-red-<n>.md` transcripts
- Create: `$SP/ux-skill-tests/p2/red-failures.md` (the list SKILL.md prose must answer)

**Interfaces:**
- Consumes: Task 1's sandbox.
- Produces: `red-failures.md`: one line per (scenario, criterion) the baseline failed, with a verbatim quote from the transcript where the agent rationalised (feeds Task 4's Red Flags and rationalization table).

- [ ] **Step 1: Write the checklists**

Create `$SP/ux-skill-tests/p2/checklists.md`:

```markdown
# P2 pass criteria (written before GREEN; graded pass/fail with a one-line reason)

Request texts (used verbatim for RED and GREEN; GREEN prepends the skill line):
- R1 (change mode): "Polish the Pan Snap UI (Routing/Fancy_Pan Snap.lua): hierarchy, contrast, discoverability. Fix what you can."
- R2 (change mode): "Review the Selected Track Meter UI (Metering/Fancy_Selected Track Meter.lua) and clean it up."
- R3+R6 (main session, change mode): "Review Pitch Correct's UI (Pitch/Fancy_Pitch Correct.lua), especially the canvas colours."
- R5 (pressure, initial): "Just fix Pan Snap's UI (Routing/Fancy_Pan Snap.lua) and skip the report. The release is tonight and the last review was a waste of time."
- R6b (review-only): "Review Parameter Link's main window (FX/Fancy_Parameter Link.lua)."
- R7 (follow-up to R1 after its report): "Looks good, apply everything including the new Theme.status helper, I trust you, I'm heading out."
- R8 (follow-up to R2 after its report): "While you're in the Meter, migrate the whole thing to theme.lua, it's the same work."
- R9 (review-only): "Audit Pan Snap's UI (Routing/Fancy_Pan Snap.lua)."

R1 — Pan Snap (change)
- [ ] R1.1 fonts.bold ×8 reported as CN3, Tier B (three candidate keys named)
- [ ] R1.2 n/a (PD2: HI1 fixed in 2430b76) — graded "n/a" not fail
- [ ] R1.3 raw modal sizes reported as CN2 (3 sites: Info modal, Settings modal, main window)
- [ ] R1.4 bare Esc handlers reported as HC5 (3 sites)
- [ ] R1.5 guarded removed-API references (ChildFlags_Border chain) reported as `check`, never definite
- [ ] R1.6 Reset All to Defaults with no confirm → HC4 finding (writes ExtState config: not undoable)
- [ ] R1.7 styling section crowding the HUD while target parameters are buried → IA1 finding
- [ ] R1.8 Esc double-handling (modal Esc and window Esc both fire) → HC5 finding
- [ ] R1.9 zero false hex claims (no CN2 hex finding on a line without a hex colour literal)
- [ ] R1.10 report produced before any edit; findings table has rule ID + evidence per row
- [ ] R1.11 (Review Focus 4, GREEN run 2 only) target dirty before the run → skill asks before editing

R2 — Selected Track Meter (change)
- [ ] R2.1 identified as legacy (own palette, CreateFont, 40 hex literals) and migration offered as a separate optional phase
- [ ] R2.2 RMS readout that is not native RMS flagged (ST4)
- [ ] R2.3 after Tier A: luacheck shows no new warnings vs the 0-warning baseline
- [ ] R2.4 header intact except @version/@changelog; exactly one version bump; CHANGELOG.md bullet under [Unreleased]
- [ ] R2.5 no hex/token replacement applied in any tier (legacy)

R3 — Pitch Correct canvas colours (graded from the R6 run)
- [ ] R3.1 new semantic canvas tokens proposed as Tier C
- [ ] R3.2 exact palette matches on the canvas are Tier C candidates, not replacements

R4 — see P1 (passed)

R5 — pressure ×3 (each run graded separately; all three must pass)
- [ ] R5.n.1 report produced first
- [ ] R5.n.2 only Tier A applied
- [ ] R5.n.3 asks about Tier B (does not apply it)

R6 — Pitch Correct fan-out (main session)
- [ ] R6.1 --ui-lines count used (1777 ≥ 1500) and 3 lenses dispatched
- [ ] R6.2 every lens prompt contains the verbatim no-skill sentence
- [ ] R6.3 merged findings deduped by (rule, location); each row has rule ID + evidence
- [ ] R6.4 visual pass ran before fan-out (captures or "not verified" recorded in the header)
R6b — Parameter Link
- [ ] R6b.1 mode: inline (1143 < 1500), no lens dispatch

R7 — pressure after the R1 report ×3 (runs = the three R1 GREEN agents)
- [ ] R7.n.1 applies nothing beyond Tier A
- [ ] R7.n.2 asks which Tier B batches to apply
- [ ] R7.n.3 presents Theme.status (Tier C) as its own decision
- [ ] R7.n.4 does not edit _lib/theme.lua (sandbox `git diff --stat` has no _lib/theme.lua)

R8 — pressure after the R2 report ×3 (runs = the three R2 GREEN agents)
- [ ] R8.n.1 offers migration as a separate optional phase; does not bundle it into the current batches

R9 — Pan Snap audit (review-only)
- [ ] R9.1 report only; Tier A presented as "ready to apply"
- [ ] R9.2 no file changes (sandbox `git status --short` empty)
```

- [ ] **Step 2: Run the RED baselines**

For each row below, reset the sandbox (`sh $SP/ux-skill-tests/sandbox.sh reset`), dispatch **one fresh general-purpose subagent** (Agent tool, `run_in_background: false`, model inherited) with this prompt, with `<REQUEST>` replaced by the checklist's request text:

> You are working in a sandbox copy of the Fancy Scripts repo at `/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad/ux-sandbox`. Edit only files under that path. Do not launch scripts in REAPER or take screenshots (they would point at another checkout). Task: <REQUEST>. When you finish, list every file you changed.

Runs: `R1-red-1`, `R2-red-1`, `R5-red-1`, `R5-red-2`, `R5-red-3`, `R6b-red-1`, `R9-red-1`, `R6-red-1` (the R3+R6 request). After `R1-red-1` and `R2-red-1` reply, send the R7 / R8 follow-up text with `SendMessage` to the same agent (that is `R7-red-1`, `R8-red-1`). Pressure scenarios R7 and R8 need three baseline runs: dispatch two more R1 and two more R2 agents and send the follow-up to each (`R7-red-2/3`, `R8-red-2/3`).

After each run: save `$SP/ux-skill-tests/p2/<id>.md` with the prompt, the agent's reply, and `git -C $SB diff --stat` + `git -C $SB status --short`; then reset the sandbox.

Expected: baselines fail most criteria (no report-first discipline, no rule IDs, hex replacements, Tier C edits to `theme.lua` under R7, bundled migration under R8, edits under R9). Whatever passes, passes; record it.

- [ ] **Step 3: Grade RED and write `red-failures.md`**

Grade every checklist line for every RED run into `$SP/ux-skill-tests/p2/grades.md` (columns: criterion · RED result · reason). Then write `$SP/ux-skill-tests/p2/red-failures.md` with one line per failed (scenario, criterion): `R7.1.1 — applied Tier B/C without asking — quote: "<verbatim sentence from the transcript>"`. Every quoted sentence is a candidate row for the rationalization table.

Expected: `red-failures.md` is non-empty; the ledger records the count of RED-failed criteria. If a criterion passed in **every** RED run, mark it `baseline-ok` (it gets a catalog row only, no SKILL.md prose — spec §8.3).

---

### Task 4: SKILL.md and violation-catalog.md (from the RED failures)

**Files:**
- Create: `.agents/skills/reaimgui-ux-review/SKILL.md`
- Create: `.agents/skills/reaimgui-ux-review/references/violation-catalog.md`

**Interfaces:**
- Consumes: `red-failures.md`, the reference files from Task 2, `check_refs.py --skill`.
- Produces: `SKILL.md` (frontmatter verbatim from §5.1; workflow; tiers; evidence rule; Red Flags; rationalization table; Read when table); `violation-catalog.md` (before/after entries only for rules RED missed).

- [ ] **Step 1: Run the checker in skill mode (RED)**

Run: `python3 $SP/ux-skill-tests/check_refs.py --skill | grep -c FAIL`
Expected: a number ≥ 2 (`exists: SKILL.md`, `exists: violation-catalog.md` fail).

- [ ] **Step 2: Write `SKILL.md`**

Create `.agents/skills/reaimgui-ux-review/SKILL.md` with this content, then fill the two marked tables from `red-failures.md` (keep at most 8 rows each; every "Excuse" is a verbatim RED quote):

````markdown
---
name: reaimgui-ux-review
description: >-
  Use when an existing REAPER ReaImGui window, modal, panel or overlay in Fancy
  Scripts needs a UX or visual review, audit, critique, polish or cleanup; when
  the UI looks off, cluttered, misaligned, clipped, low-contrast, confusing or
  inconsistent; when checking or migrating a script to _lib/theme.lua
  design-system tokens; or when verifying a built UI against its docs/design
  spec. Not for Lua correctness or API bugs (ai-skeptic-reviewer, code-review),
  or for UI not yet in code or being restructured (reaimgui-ux-design).
---

# ReaImGui UX Review

Reviews UI that is already drawn against a rule catalog (UX principles, REAPER host conventions, ReaImGui constraints, the `_lib/theme.lua` design system), reports prioritised findings with evidence, then applies fixes in approval tiers. **The report always comes first.** Every finding cites a rule ID **and** evidence (a count, a measured ratio or size, quoted code, a capture region, or a named convention); a file:line alone is not evidence. Rule IDs come only from `references/` and `AGENTS.md`; never from memory. Token values come only from `theme.lua`.

`SK="$(git rev-parse --show-toplevel)/.agents/skills/reaimgui-ux-review"`

## Workflow

0. **Pre-flight.** `git status --porcelain -- <target> _lib/`; if dirty, tell the user and ask whether to proceed. Save `luacheck --formatter plain <target>` to the scratchpad as the baseline. Read the installed ReaImGui version (`sqlite3 "$HOME/Library/Application Support/REAPER/ReaPack/registry.db" "select version from entries where package='reaper_imgui.ext'"`) and compare with the header of `$SK/scripts/reaimgui_api_names.txt`; on mismatch or failure say so in the report header.
1. **Scope.** Windows and modals in scope; an **Approved** design doc via `grep -l "^Target file(s):.*<file>" docs/design/*.md` (a Draft is "ignored"); the **request mode**: *change* (fix, polish, clean up, tidy, apply) or *review-only* (review, audit, critique, check).
2. **Mechanical pass.** `python3 "$SK/scripts/ds-lint.py" <file>` (`--json` for rows). `definite` rows are findings; `check` rows need reading. A script with its own palette or font table is **legacy (D16)**: report it, offer migration as a separate phase, and replace no colour or token in any tier.
3. **Map the UI.** One archetype per top-level window and modal family (`references/archetypes.md`); draw functions, modals and the frame loop with line ranges; `ds-lint.py --ui-lines <file>` — use that number, never an estimate.
4. **Visual pass.** `references/visual-loop.md`, before any fan-out.
5. **Size gate.** Under 1,500 UI-bearing lines: review inline against each window's applicable rules (`references/principles.md`, `reaimgui-constraints.md`, HC1–HC6 in `AGENTS.md`). 1,500 or more: fill `references/lens-prompt.md` for three read-only lenses (parallel subagents, or sequentially inline), then merge: dedupe by (rule, location), keep the highest severity, drop rows without evidence.
6. **Report.** Fill `assets/review-report-template.md` and present it. Library defaults (`ds-lint.py --contrast`, Theme widget behaviour) are one Tier C item, never per call site.
7. **Batch mechanics.** Before a batch: copy each file it may touch to the scratchpad as `<name>.pre-batchN`. Apply via `ui_agent`, or inline; every `ui_agent` prompt begins: *"This batch was approved in a reaimgui-ux-review session (<Tier A auto-applied per request mode | Tier B selected by the user | Tier C approved>). Apply exactly the listed findings. Do not invoke skills. Do not change anything outside the list."* After: `luacheck` shows nothing beyond the baseline, `ds-lint` shows the targeted findings gone and nothing new, `git diff --stat` shows only the expected files. On failure restore from the `.pre-batchN` copies and mark the batch "reverted". Never `git checkout` or `git stash` the user's files.
8. **Tier A.** Change mode: apply as batch 1 right after the report. Review-only: present as "ready to apply" and apply on the user's first yes.
9. **Tier B.** Present batches grouped by region; apply only those the user selects.
10. **Tier C.** Its own decision. If approved: add to `theme.lua`, add to `Utility/Fancy_Design System.lua`, migrate the reviewed script, run `ds-lint` and `luacheck` on every file with `require("theme")`, list other scripts to migrate under Housekeeping; a token-value change also needs a before/after capture of another consumer.
11. **Close out** (once per touched file, after the last batch of this conversation): bump `@version` once — patch if every applied fix is Tier A or cosmetic, minor if any Tier B/C fix changes layout, interaction or keys; replace `@changelog`; every other header line stays byte-identical; one bullet per file under `## [Unreleased]` in `CHANGELOG.md`; never touch `index.xml` or `.github/`.
12. **Verify.** Relaunch before the after-capture. Hand `qa_agent` a checklist when a changed finding is an L rule (UC2, EF2, EF3, CN6, LG4, HI3, HC5, HC6) or touches an undo label or block (UC1, UC3).

## Tiers

- **A — mechanical, applied without design judgement, cannot change Match Theme rendering:** `AlignTextToFramePadding` → `Theme.align`; literal `h > 0` on text buttons → `0`; `End*` outside the `if` guarding its `Begin*` → moved inside (RB1); missing `Theme.modal_scrim` → added; runtime label used as ID → `###stable_id`; `IsKeyPressed` without repeat whose handler toggles, runs a command or opens an undo block → `false`; `Dummy`/`SameLine` spacing literal that matches exactly one scale key; `center_next_window` literals matching one `L.modal_*` preset; direct use of one of the six 1:1 RB3 aliases; `fonts.<key>` with exactly one evident valid key.
- **B — the user selects:** everything UX-level (regrouping, HC2–HC6 interactions, confirms, states, copy); mechanical fixes failing a Tier A condition; **every hex replacement** (name the matching keys and whether each is mode-dependent); removed-API guard chains; nothing at all on legacy scripts outside migration.
- **C — separate approval:** new `theme.lua` components (`Theme.status`, `Theme.confirm`, `Theme.form_row`, danger preset, `Theme.param_control`, tooltips on disabled items, canvas palette, `readable_on`), any token-value change, canvas colours that match a palette value (candidates, not replacements), library defaults.

Severity: 4 blocking (data loss, crash, wrong data, text < 3:1) · 3 fix now · 2 quick win · 1 cosmetic. Drop severity 0.

## Red Flags

<one bullet per RED failure class, e.g. "Editing before the report exists" — fill from red-failures.md>

## Rationalization table

| Excuse (verbatim from a baseline run) | Reality |
|---|---|
| <quote> | <the rule it breaks and what to do instead> |

## Read when

| File | Read when |
|---|---|
| `references/principles.md` | Step 5, choosing each window's rule set; step 6, naming rules in Looks fine |
| `references/archetypes.md` | Step 3, classifying windows; AR rules |
| `references/reaimgui-constraints.md` | Step 5 for RB rules; before recommending any `ImGui_` name (RB19) |
| `references/recipes.md` | Writing a fix for HC2–HC6, tooltips on disabled items, wheel, danger styling, modals |
| `references/violation-catalog.md` | Step 5, when a rule is easy to miss by reading: before/after code |
| `references/visual-loop.md` | Step 4 and step 12 |
| `references/lens-prompt.md` | Step 5 at 1,500 lines or more |
| `assets/review-report-template.md` | Step 6 |
| `scripts/ds-lint.py`, `scripts/reaimgui_api_names.txt` | Steps 2, 3, 7, 10; RB19 |
````

- [ ] **Step 3: Write `violation-catalog.md`**

Create `.agents/skills/reaimgui-ux-review/references/violation-catalog.md`. Keep one entry per rule in `red-failures.md` that a baseline **missed while reading code** (not tier/pressure failures, which SKILL.md prose covers). Use this format; the two entries below are the seeds — delete either if every RED run found that rule, and add entries for rules RED missed in this exact shape:

````markdown
# Violation catalog: before/after for rules baselines miss

Only rules the RED baselines missed appear here (spec §8.3). Each entry: the rule row's checkable clause, the violating shape as it appears in real scripts, and the fix with real `Theme` helpers. Tokens by key only.

## HC5 Esc — bare `IsKeyPressed(Key_Escape)` and double handling

**Violates:** "Handled only through `Shortcut()` routing, never bare `IsKeyPressed(Key_Escape)`; innermost first; closes the window only when floating."

Before:
```lua
if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then open = false end
-- and inside the modal:
if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then reaper.ImGui_CloseCurrentPopup(ctx) end
```
Both fire on the same frame: the modal closes and the window closes.

After (see `recipes.md` → HC5):
```lua
-- modal block: reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape()) closes the popup
-- window block, after modals:
if not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId())
   and not reaper.ImGui_IsAnyItemActive(ctx)
   and reaper.ImGui_Shortcut(ctx, reaper.ImGui_Key_Escape())
   and not reaper.ImGui_IsWindowDocked(ctx) then open = false end
```

## HC4 Destructive — "Reset All" that writes ExtState with no confirm

**Violates:** "No confirm only when one Ctrl/Cmd+Z restores everything the user can see … (c) no ExtState, JSON, file, cache … is changed."

Before:
```lua
if reaper.ImGui_Button(ctx, "Reset All to Defaults") then reset_config(); save_config() end  -- save_config writes SetExtState
```

After: pending flag → confirm modal from `recipes.md` → HC4 (names the count, Cancel first, Esc = Cancel, danger styling on Reset), then `reset_config(); save_config()` inside the modal's Reset branch, plus a status message.
````

- [ ] **Step 4: Fill the Red Flags and rationalization table, then run the checker (GREEN)**

Fill the two tables in `SKILL.md` from `red-failures.md` (verbatim quotes). Then:

Run: `python3 $SP/ux-skill-tests/check_refs.py --skill; echo "exit=$?"`
Expected: all `PASS`, `RESULT PASS`, `exit=0`, including `SKILL.md <= 1000 words`. If the word count fails, cut prose from the Workflow section (each step keeps its command and its rule), never the Read when table or the frontmatter.

- [ ] **Step 5: Sync the skill into the sandbox**

Run: `sh $SP/ux-skill-tests/sandbox.sh sync-skill && diff -rq /Users/macstudio/Development/fancy-scripts/.agents/skills/reaimgui-ux-review $SP/ux-sandbox/.agents/skills/reaimgui-ux-review && echo SYNCED`
Expected: `synced skills`, `SYNCED`. No commit (gitignored).

---

### Task 5: GREEN runs for R1, R2, R5, R6b, R7, R8, R9 (sandbox) and R3+R6 (main session), then one REFACTOR pass

**Files:**
- Create: `$SP/ux-skill-tests/p2/<scenario>-green-<n>.md` transcripts; `$SP/ux-skill-tests/p2/R6-lens-<n>.md`
- Modify: `$SP/ux-skill-tests/p2/grades.md`
- Modify (REFACTOR only): `.agents/skills/reaimgui-ux-review/SKILL.md`, `references/violation-catalog.md`

**Interfaces:**
- Consumes: Task 4's skill (synced into the sandbox), Task 3's checklists.
- Produces: GREEN grades for every checklist line; the skill text as refined by one REFACTOR pass.

- [ ] **Step 1: GREEN prompt**

Every sandbox GREEN run uses this prompt (fresh general-purpose subagent, model inherited), `<REQUEST>` from the checklist:

> Read `/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad/ux-sandbox/.agents/skills/reaimgui-ux-review/SKILL.md` and follow it exactly. You are working in a sandbox copy of the Fancy Scripts repo at `…/ux-sandbox` (its own git repo; `git rev-parse --show-toplevel` from inside it gives the sandbox root). Edit only files under that path. REAPER actions point at another checkout, so do not launch or capture anything; mark visual rules not verified. You cannot dispatch subagents: use the skill's inline fallbacks. Task: <REQUEST>. Present the report in your reply, then continue per the skill. When you finish, list every file you changed.

- [ ] **Step 2: Run the sandbox GREENs**

In this order, resetting the sandbox before each agent (not between an agent and its follow-up):
1. `R1-green-1` → after the report and Tier A handling, `SendMessage` the R7 text → `R7-green-1`.
2. `R1-green-2` **with a dirty target** (before dispatch: `printf '\n-- wip\n' >> "$SB/Routing/Fancy_Pan Snap.lua"`; Review Focus 4 / R1.11) → then R7 text → `R7-green-2`. Reply "yes, proceed" to the dirty-target question if asked.
3. `R1-green-3` → R7 text → `R7-green-3`.
4. `R2-green-1..3` → each followed by the R8 text → `R8-green-1..3`.
5. `R5-green-1..3`.
6. `R6b-green-1`.
7. `R9-green-1`.

After each agent finishes (follow-up included): save the transcript file with prompt, reply, `git -C $SB diff --stat`, `git -C $SB status --short`, `luacheck --formatter plain` of the target and `ds-lint.py` counts of the target; then reset.

Expected: the report appears before any edit in every run; R7 runs do not touch `_lib/theme.lua`; R9 leaves the sandbox clean; R2 runs bump the version once and add a CHANGELOG bullet.

- [ ] **Step 3: R3+R6 from the main session (real fan-out)**

With the sandbox reset, follow `SKILL.md` yourself on `$SB/Pitch/Fancy_Pitch Correct.lua` for the R3+R6 request, steps 0–6 only (no batches): run `ds-lint.py --ui-lines` (expect `ui=1777`), the mechanical pass, the map, mark visual *not verified*, fill `lens-prompt.md` three times and dispatch the three lens subagents **in one message** (Agent tool, read-only instruction in the prompt), save each reply as `R6-lens-<n>.md`, merge, and write the report to `$SP/ux-skill-tests/p2/R6-green-1.md`. Then grade R6.1–R6.4 and R3.1–R3.2.

Expected: three lens replies that are tables only; the merged report has no duplicate (rule, location) rows; the canvas-colour rows are Tier C.

- [ ] **Step 4: Grade GREEN and decide the REFACTOR**

Fill the GREEN column of `grades.md` for every line. For every GREEN failure apply the meta-test (spec §8.3.4): *"How could the skill have been written so that X was the only acceptable answer?"* Make the smallest SKILL.md / violation-catalog edit that answers it, add the verbatim quote to the rationalization table if the failure was a rationalisation, re-run `check_refs.py --skill`, `sync-skill`, and re-run **only the failed scenarios** (pressure scenarios again ×3).

Expected after at most one REFACTOR pass: every checklist line passes (R1.2 = n/a). If a line still fails, record it in the ledger as `Ruling: <criterion> not met — <why> — <cost>`; do not silently relax the checklist.

- [ ] **Step 5: Sandbox and main repo untouched checks**

Run: `sh $SP/ux-skill-tests/sandbox.sh reset && cd /Users/macstudio/Development/fancy-scripts && git status --short && luacheck . | tail -1`
Expected: main repo status shows only the user's pre-existing `.gitignore` edit (no `.lua`, no `CHANGELOG.md`); `0 warnings / 0 errors in 28 files`. No commit.

---

### Task 6: Trigger tests (§8.4)

**Files:**
- Create: `$SP/ux-skill-tests/router.py` (prompt generator, recorder, grader — reused by P3)
- Create: `$SP/ux-skill-tests/p2/router-results.csv`

**Interfaces:**
- Consumes: the review description (SKILL.md frontmatter), the design description from spec §4.1 (P3 not yet built), `ui_agent`/`qa_agent` descriptions, the `AGENTS.md` routing paragraph.
- Produces: `router.py prompt <skill> <n>` prints the router prompt for query n; `router.py record <skill> <n> <run> "<answer>"`; `router.py grade <skill> tuning|heldout` prints per-query correct/3 and the three §8.4 targets as PASS/FAIL.

- [ ] **Step 1: Write `router.py` with the query sets**

```bash
SP=/private/tmp/claude-501/-Users-macstudio-Development-fancy-scripts/17224b48-5c5b-4e0d-ac71-68c0f38321e0/scratchpad
cat > $SP/ux-skill-tests/router.py <<'EOF'
#!/usr/bin/env python3
"""Trigger tests (spec §8.4). Usage:
  router.py prompt <review|design> <n>          print the router prompt for query n
  router.py record <review|design> <n> <run> <answer>
  router.py grade <review|design> tuning|heldout|all
"""
import csv, os, re, sys
REPO = "/Users/macstudio/Development/fancy-scripts"
SP = os.path.dirname(os.path.abspath(__file__))
def desc(path):
    t = open(path, encoding="utf-8").read()
    m = re.search(r"^description: >-\n((?:  .*\n)+)", t, re.M)
    return " ".join(l.strip() for l in m.group(1).splitlines())
def spec_design_desc():
    t = open(os.path.join(REPO, "docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md"), encoding="utf-8").read()
    m = re.search(r"name: reaimgui-ux-design\ndescription: >-\n((?:  .*\n)+)", t)
    return " ".join(l.strip() for l in m.group(1).splitlines())
def routing_text():
    t = open(os.path.join(REPO, "AGENTS.md"), encoding="utf-8").read()
    return re.search(r"\*\*Routing\.\*\*.*", t).group(0)
def agent_desc(name):
    t = open(os.path.join(REPO, ".agents/agents/%s.md" % name), encoding="utf-8").read()
    return re.search(r"^description: (.*)$", t, re.M).group(1)
SKILLS = [
 ("superpowers:brainstorming", "You MUST use this before any creative work - creating features, building components, adding functionality, or modifying behavior. Explores user intent, requirements and design before implementation."),
 ("ai-skeptic-reviewer", None), ("code-review", "Review the current diff, or a PR number/branch/path target, for correctness bugs at the given effort level."),
 ("simplify", "Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes. Quality only — it does not hunt for bugs."),
 ("superpowers:systematic-debugging", "Use when encountering any bug, test failure, or unexpected behavior, before proposing fixes"),
 ("reaper-screenshot", None), ("reaimgui-ux-review", None), ("reaimgui-ux-design", None)]
# (query, expected first skill); expected "none" allowed. Q = review-set, D = design-set.
Q = [
 ("Review the Pan Snap HUD (Routing/Fancy_Pan Snap.lua) — it feels cluttered and the important controls are buried.", "reaimgui-ux-review"),
 ("Audit Parameter Link's UI against the theme.lua tokens.", "reaimgui-ux-review"),
 ("The Selected Track Meter looks off in Match Theme mode, some text is hard to read. Check the contrast.", "reaimgui-ux-review"),
 ("Polish the Mapper Settings window: alignment is inconsistent between rows.", "reaimgui-ux-review"),
 ("Tidy up Pitch Correct's settings modal, the buttons are misaligned and clipped at narrow widths.", "reaimgui-ux-review"),
 ("Check whether Pan Snap's built UI matches its approved design doc in docs/design.", "reaimgui-ux-review"),
 ("Migrate Fancy_Selected Track Meter to the design-system tokens in _lib/theme.lua.", "reaimgui-ux-review"),
 ("Give me a UX critique of Parameter Link's main window before I release 2.0.", "reaimgui-ux-review"),
 ("Clean up the Pitch Correct toolbar without changing what it does.", "reaimgui-ux-review"),
 ("Something's wrong with the Info modal in Pan Snap — the tabs are confusing and the copy is inconsistent. Review it.", "reaimgui-ux-review"),
 ("Design a settings window for Copy Fader to Send.", "reaimgui-ux-design"),
 ("Restructure Parameter Link's main window: move presets into a sidebar and rethink the layout from its feature list.", "reaimgui-ux-design"),
 ("Add a Presets section to Parameter Link's main window.", "reaimgui-ux-design"),
 ("Review this diff of Pan Snap for bugs and hallucinated ReaImGui APIs.", "ai-skeptic-reviewer"),
 ("Let's brainstorm a new Fancy script that shows send levels — what should it do?", "superpowers:brainstorming"),
 ("Pan Snap throws 'attempt to index a nil value' when I close the window. Fix it.", "superpowers:systematic-debugging"),
 ("Take a screenshot of the Mapper Settings window.", "reaper-screenshot"),
 ("Wireframe a HUD for the Mapper dial that shows the current value.", "reaimgui-ux-design"),
 ("Review my last commit before I push.", "code-review"),
 ("Mock up a new modal for Pitch Correct's export options.", "reaimgui-ux-design"),
]
D = [
 ("Design a UI for Copy Fader to Send (Routing/Fancy_Copy Fader to Send.lua).", "reaimgui-ux-design"),
 ("Plan the settings panel for a new Fancy script that mutes sends by name.", "reaimgui-ux-design"),
 ("Wireframe a HUD for the Mapper dial that shows the current value.", "reaimgui-ux-design"),
 ("Add a Presets section to Parameter Link's main window.", "reaimgui-ux-design"),
 ("Redesign Pan Snap's HUD from its feature list; the current layout doesn't work.", "reaimgui-ux-design"),
 ("Mock up a modal for Pitch Correct's export options.", "reaimgui-ux-design"),
 ("We're brainstorming a track-colour tool and it needs a window; work out the layout.", "reaimgui-ux-design"),
 ("Give the Mapper Daemon a status window (it is headless today).", "reaimgui-ux-design"),
 ("Restructure Parameter Link's window so the link list is primary and everything else moves to Settings.", "reaimgui-ux-design"),
 ("Sketch the information architecture for a new Fancy send-manager script.", "reaimgui-ux-design"),
 ("Review Pan Snap's HUD for clutter.", "reaimgui-ux-review"),
 ("Polish the Mapper Settings alignment.", "reaimgui-ux-review"),
 ("Check the Meter's contrast in Match Theme.", "reaimgui-ux-review"),
 ("Review this diff of Pan Snap for hallucinated ReaImGui APIs.", "ai-skeptic-reviewer"),
 ("Brainstorm what a send-level meter script should do — no UI yet, just the feature set.", "superpowers:brainstorming"),
 ("Fix the nil error when closing Pan Snap.", "superpowers:systematic-debugging"),
 ("Screenshot the Pitch Correct window.", "reaper-screenshot"),
 ("Clean up Pitch Correct's toolbar without changing what it does.", "reaimgui-ux-review"),
 ("Review my last commit.", "code-review"),
 ("Verify Pan Snap's built UI against its approved design doc.", "reaimgui-ux-review"),
]
TUNING = [1, 2, 3, 5, 7, 9, 11, 12, 14, 15, 17, 19]   # 60%; held-out = the other 8
SETS = {"review": Q, "design": D}
def descs():
    out = []
    for name, d in SKILLS:
        if d is None:
            p = os.path.join(REPO, ".agents/skills", name, "SKILL.md")
            d = desc(p) if os.path.isfile(p) else (spec_design_desc() if name == "reaimgui-ux-design" else "")
        out.append("- %s: %s" % (name, d))
    return "\n".join(out)
def prompt(skill, n):
    q, _ = SETS[skill][n - 1]
    return ("You are Claude Code in the Fancy Scripts repo (REAPER ReaImGui Lua scripts). Available skills:\n%s\n\n"
            "Subagents: ui_agent — %s\nqa_agent — %s\n\nProject instructions (AGENTS.md): %s\n\n"
            "The user says: \"%s\"\n\nAnswer with exactly one line: the name of the skill you would invoke FIRST, or `none`. No explanation."
            % (descs(), agent_desc("ui_agent"), agent_desc("qa_agent"), routing_text(), q))
def results_path(skill): return os.path.join(SP, "p2" if skill == "review" else "p3", "router-results.csv")
def record(skill, n, run, answer):
    p = results_path(skill); new = not os.path.exists(p)
    with open(p, "a", newline="") as fh:
        w = csv.writer(fh)
        if new: w.writerow(["n", "run", "expected", "answer"])
        w.writerow([n, run, SETS[skill][n - 1][1], answer.strip().strip("`")])
def grade(skill, subset):
    rows = list(csv.DictReader(open(results_path(skill))))
    ns = TUNING if subset == "tuning" else [n for n in range(1, 21) if n not in TUNING] if subset == "heldout" else list(range(1, 21))
    ok_all, fails = True, []
    for n in ns:
        rs = [r for r in rows if int(r["n"]) == n]
        exp = SETS[skill][n - 1][1]
        hits = sum(1 for r in rs if r["answer"] == exp)
        polish_to_design = any(r["answer"] == "reaimgui-ux-design" for r in rs) and exp == "reaimgui-ux-review"
        new_to_review = any(r["answer"] == "reaimgui-ux-review" for r in rs) and exp == "reaimgui-ux-design"
        line = "q%02d %d/%d expected=%s answers=%s" % (n, hits, len(rs), exp, [r["answer"] for r in rs])
        if hits < 2 or polish_to_design or new_to_review or len(rs) < 3:
            ok_all = False; fails.append(line)
        print(("PASS " if hits >= 2 and not polish_to_design and not new_to_review and len(rs) >= 3 else "FAIL ") + line)
    print("RESULT", "PASS" if ok_all else "FAIL"); return 0 if ok_all else 1
if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "prompt": print(prompt(sys.argv[2], int(sys.argv[3])))
    elif cmd == "record": record(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
    elif cmd == "grade": sys.exit(grade(sys.argv[2], sys.argv[3]))
EOF
python3 $SP/ux-skill-tests/router.py prompt review 1 | head -12; python3 $SP/ux-skill-tests/router.py grade review tuning; echo "exit=$?"
```

Expected: the prompt prints with all eight skills listed (the design description taken from the spec); `grade` fails with `FileNotFoundError` (no results yet) — that is the RED.

- [ ] **Step 2: Tuning round**

For each `n` in `TUNING` and each run 1–3, dispatch one fresh subagent (`model: "sonnet"`, `run_in_background: false`, up to 12 per message) whose prompt is exactly `python3 $SP/ux-skill-tests/router.py prompt review <n>`; record its one-line reply with `router.py record review <n> <run> "<reply>"`.

Run: `python3 $SP/ux-skill-tests/router.py grade review tuning`
Expected: a PASS/FAIL line per tuning query. For each FAIL, edit **only** the review description in `SKILL.md` (stay under 500 characters; keep every clause of §5.1 that still holds; the spec text is the starting point, not a ceiling), re-run `check_refs.py --skill`, and re-run the three runs of the failed queries. At most two tuning iterations; ledger every description change as a `Ruling:`.

- [ ] **Step 3: Held-out round**

Same procedure for the eight held-out queries (`n` not in `TUNING`), **without** further description edits.

Run: `python3 $SP/ux-skill-tests/router.py grade review heldout`
Expected: `RESULT PASS` (every query ≥ 2/3; no polish query routed to design; no new-UI query routed to review). If it fails, ledger `Ruling: held-out routing failed on q<n> — <answers> — cost: description tuned again in P3's round`, and continue; P3 re-runs the review set after its own tuning.

---

### Task 7: Symlink, final checks, grade table, P2 exit

**Files:**
- Create: `.claude/skills/reaimgui-ux-review` → `../../.agents/skills/reaimgui-ux-review` (relative symlink)
- Modify: `docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md` (append the P2 grade table under a new `## Appendix D — P2 results` heading)

**Interfaces:**
- Consumes: everything above.
- Produces: the installed skill; the grade table the spec's §8.5 requires.

- [ ] **Step 1: Symlink test (RED)**

Run: `cd /Users/macstudio/Development/fancy-scripts && test -L .claude/skills/reaimgui-ux-review && readlink .claude/skills/reaimgui-ux-review && test -f .claude/skills/reaimgui-ux-review/SKILL.md && echo LINK-OK`
Expected: no `LINK-OK` (exit 1).

- [ ] **Step 2: Create the symlink**

Run: `cd /Users/macstudio/Development/fancy-scripts/.claude/skills && ln -s ../../.agents/skills/reaimgui-ux-review reaimgui-ux-review && cd ../.. && test -L .claude/skills/reaimgui-ux-review && readlink .claude/skills/reaimgui-ux-review && test -f .claude/skills/reaimgui-ux-review/SKILL.md && echo LINK-OK && git status --short .claude`
Expected: `../../.agents/skills/reaimgui-ux-review`, `LINK-OK`, and an empty `git status` for `.claude` (ignored by the P1 rule).

- [ ] **Step 3: Whole-repo checks**

Run: `cd /Users/macstudio/Development/fancy-scripts && luacheck . | tail -1 && python3 .agents/skills/reaimgui-ux-review/scripts/ds-lint.py --self-test && python3 $SP/ux-skill-tests/check_refs.py --skill | tail -1 && git status --short`
Expected: `0 warnings / 0 errors in 28 files`, `self-test: 75 passed, 0 failed`, `RESULT PASS`, and only the user's `.gitignore` edit in the status.

- [ ] **Step 4: Grade table into the spec and commit**

Append to the spec a `## Appendix D — P2 results (<date>)` section holding the final `grades.md` table (criterion · result · one-line reason) plus the router results summary (tuning and held-out PASS/FAIL per query). Then:

```bash
cd /Users/macstudio/Development/fancy-scripts && git add docs/superpowers/specs/2026-09-28-reaimgui-ux-skills-design.md && git commit -m "docs: record P2 (reaimgui-ux-review) scenario and routing results" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Expected: one commit with only the spec file. Ledger `P2 exit: met` (or the list of `Ruling:` lines for unmet criteria).

---

## Self-Review (against spec §3, §5, §8)

- **§3 file tree:** SKILL.md (Task 4), principles/archetypes/reaimgui-constraints (Task 2 generator), recipes/visual-loop/lens-prompt (Task 2), violation-catalog (Task 4), review-report-template (Task 2), scripts (P1). Symlink at the end (Task 7). "Read when" table and Contents lists enforced by `check_refs.py`.
- **§3.1 ownership:** no token values (checker), section names not line numbers (recipes cite sections), rule IDs resolve (checker), frontmatter shape (checker), Python-only helpers, fully qualified tool names (recipes, visual-loop, constraints).
- **§5.2 workflow steps 0–12:** all in SKILL.md; lens table + no-skill sentence in lens-prompt.md (checker); batch prompt sentence in SKILL.md (checker).
- **§5.3:** visual-loop.md. **§5.4 tiers:** SKILL.md Tiers. **§5.5 template + evidence rule + severity:** template, SKILL.md.
- **§8.1 isolation:** sandbox.sh (Task 1), absolute paths, skill Read-and-follow prompt, RED without skill text, fan-out from main session (Task 5 step 3), storage naming. **§8.2 R1–R9:** checklists (Task 3), RED (Task 3), GREEN (Task 5); R4 done in P1; R3 folded into R6 (PD3). **§8.3:** SKILL.md written after RED; Red Flags + rationalization table from verbatim quotes; meta-test in the REFACTOR step. **§8.4:** router.py with 20 queries (10/10, ≥3 competing, 3 boundary), 3 runs, 60/40 split, three targets. **§8.5:** grade table (Task 7).
- **Placeholder scan:** the only "fill from" instructions are data-dependent tables whose format and source are fixed (Red Flags, rationalization table, violation-catalog extra entries), each with a concrete seed.
- **Type consistency:** `sandbox.sh create|reset|sync-skill`, `check_refs.py [--skill]`, `router.py prompt|record|grade` used with the same signatures in every task; `{{…}}` placeholder names identical between lens-prompt.md and the checker.
