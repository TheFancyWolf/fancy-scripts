#!/usr/bin/env python3
"""Hard gates H1-H8 of the Fancy Scripts quality bar (reaper-quality-bar/SKILL.md).

Checks the files changed on this branch (committed, staged, unstaged and untracked)
against the base branch. Python 3 stdlib only.

Usage:
  python3 gates.py                 # base = merge-base with origin/main (or main)
  python3 gates.py --base <ref>    # explicit base
  python3 gates.py --json          # machine-readable result
  python3 gates.py --self-test     # run embedded fixtures in a temp git repo

Exit codes: 0 = all gates PASS/SKIP, 1 = at least one FAIL, 2 = usage or environment error.
"""

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

NON_PACKAGE_DIRS = {"_lib", "docs", "toolbar_icons"}
SCRIPT_EXTS = {".lua", ".eel", ".py", ".jsfx"}
REQUIRED_IGNORES = [".agents", ".claude"]
DS_LINT = ".agents/skills/reaimgui-ux-review/scripts/ds-lint.py"
SELF = ".agents/skills/reaper-gates/scripts/gates.py"

VERSION_RE = re.compile(r"^--\s*@version\s+(\S+)", re.M)
TAG_RE = "^--\\s*@%s\\b"
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


class GateError(Exception):
    pass


def git(root, *args, check=True):
    p = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True)
    if check and p.returncode != 0:
        raise GateError("git %s failed: %s" % (" ".join(args), p.stderr.strip()))
    return p


class Ctx:
    def __init__(self, root, base):
        self.root = root
        self.base = base
        self._changed = None

    def changed(self):
        """[(status, path)] for files that differ from base, including untracked."""
        if self._changed is None:
            out = git(self.root, "diff", "--name-status", "--no-renames", self.base).stdout
            items = []
            for line in out.splitlines():
                status, _, path = line.partition("\t")
                items.append((status[0], path))
            untracked = git(self.root, "ls-files", "--others", "--exclude-standard").stdout
            items += [("A", p) for p in untracked.splitlines() if p]
            self._changed = sorted(set(items), key=lambda x: x[1])
        return self._changed

    def live(self):
        return [p for s, p in self.changed() if s != "D"]

    def read(self, path):
        with open(os.path.join(self.root, path), encoding="utf-8", errors="replace") as f:
            return f.read()

    def read_base(self, path):
        p = git(self.root, "show", "%s:%s" % (self.base, path), check=False)
        return p.stdout if p.returncode == 0 else None

    def package_scripts(self):
        return [p for p in self.live() if is_package_script(p)]


def is_package_script(path):
    parts = path.split("/")
    if len(parts) != 2:
        return False
    top = parts[0]
    if top.startswith(".") or top in NON_PACKAGE_DIRS:
        return False
    return os.path.splitext(path)[1] in SCRIPT_EXTS


def is_shipped(path):
    return is_package_script(path) or path.startswith("_lib/")


def semver(v):
    m = SEMVER_RE.match(v or "")
    return tuple(int(x) for x in m.groups()) if m else None


def header_version(text):
    m = VERSION_RE.search(text or "")
    return m.group(1) if m else None


def result(gid, status, detail):
    return {"id": gid, "status": status, "detail": detail}


# --- gates -------------------------------------------------------------------

def h1_luacheck(ctx):
    files = [p for p in ctx.live() if p.endswith(".lua")]
    if not files:
        return result("H1", "SKIP", "no .lua files changed")
    exe = shutil.which("luacheck")
    if not exe:
        return result("H1", "FAIL", "luacheck not installed (brew install luacheck / apt-get install lua-check)")
    p = subprocess.run([exe, "--formatter", "plain", "--codes", "--no-color"] + files,
                       cwd=ctx.root, capture_output=True, text=True)
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    if p.returncode == 0 and not lines:
        return result("H1", "PASS", "%d file(s) clean" % len(files))
    shown = "\n".join(lines[:20]) + ("\n... %d more" % (len(lines) - 20) if len(lines) > 20 else "")
    return result("H1", "FAIL", shown or p.stderr.strip())


def h2_headers(ctx):
    scripts = [p for p in ctx.package_scripts() if p.endswith(".lua")]
    if not scripts:
        return result("H2", "SKIP", "no package script changed")
    bad = []
    for path in scripts:
        text = ctx.read(path)
        missing = [t for t in ("description", "author", "version")
                   if not re.search(TAG_RE % t, text, re.M)]
        v = header_version(text)
        if v and not semver(v):
            missing.append("semver @version (got %s)" % v)
        if missing:
            bad.append("%s: missing %s" % (path, ", ".join(missing)))
    return result("H2", "FAIL" if bad else "PASS", "\n".join(bad) or "%d header(s) ok" % len(scripts))


def h3_version_bump(ctx):
    checked, bad = 0, []
    for path in ctx.package_scripts():
        old = ctx.read_base(path)
        if old is None:
            continue
        checked += 1
        ov, nv = semver(header_version(old)), semver(header_version(ctx.read(path)))
        if ov is None or nv is None:
            bad.append("%s: unparseable @version" % path)
        elif nv <= ov:
            bad.append("%s: @version %s not above base %s" % (
                path, ".".join(map(str, nv)), ".".join(map(str, ov))))
    if not checked and not bad:
        return result("H3", "SKIP", "no existing package script changed")
    return result("H3", "FAIL" if bad else "PASS", "\n".join(bad) or "%d bump(s) ok" % checked)


def h4_changelog(ctx):
    shipped = [p for _, p in ctx.changed() if is_shipped(p)]
    if not shipped:
        return result("H4", "SKIP", "no shipped file changed")
    if "CHANGELOG.md" in ctx.live():
        return result("H4", "PASS", "CHANGELOG.md updated")
    return result("H4", "FAIL", "shipped files changed without a CHANGELOG.md entry: " + ", ".join(shipped))


def h5_index(ctx):
    if any(p == "index.xml" for _, p in ctx.changed()):
        return result("H5", "FAIL", "index.xml changed; CI regenerates it, revert your edit")
    return result("H5", "PASS", "index.xml untouched")


def reapack_ignores(ctx):
    path = os.path.join(ctx.root, ".reapack-index.conf")
    if not os.path.exists(path):
        return []
    pats = []
    for line in ctx.read(".reapack-index.conf").splitlines():
        m = re.match(r"^\s*--ignore\s+(.+?)\s*$", line)
        if m:
            pats.append(m.group(1).rstrip("/"))
    return pats


def ignored(path, pats):
    parts = path.split("/")
    prefixes = ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]
    return any(fnmatch.fnmatchcase(c, pat) for pat in pats for c in prefixes + parts)


def h6_not_packaged(ctx):
    pats = reapack_ignores(ctx)
    bad = ["%s missing from .reapack-index.conf" % ("--ignore " + r)
           for r in REQUIRED_IGNORES if r not in pats]
    for path in ctx.live():
        if os.path.splitext(path)[1] not in SCRIPT_EXTS or path.startswith("_lib/"):
            continue
        # A package script declares itself with a ReaPack header; anything else is a dev file.
        packaged = is_package_script(path) and re.search(r"@version\s+\S", ctx.read(path)[:4000])
        if not packaged and not ignored(path, pats):
            bad.append("%s would be scanned by ReaPack; move it under an ignored path" % path)
    return result("H6", "FAIL" if bad else "PASS", "\n".join(bad) or "no dev files exposed to ReaPack")


def count_definite(stdout):
    try:
        data = json.loads(stdout)
    except ValueError:
        return None
    items = data.get("findings", []) if isinstance(data, dict) else data
    if not isinstance(items, list):
        return None
    return sum(1 for f in items if isinstance(f, dict) and "definite" in f.values())


def run_ds_lint(ctx, path):
    theme = os.path.join(ctx.root, "_lib", "theme.lua")
    p = subprocess.run([sys.executable, os.path.join(ctx.root, DS_LINT), "--json",
                        "--theme", theme, path], capture_output=True, text=True, cwd=ctx.root)
    if p.returncode == 2:
        p = subprocess.run([sys.executable, os.path.join(ctx.root, DS_LINT), path],
                           capture_output=True, text=True, cwd=ctx.root)
        return p.returncode, None
    return p.returncode, count_definite(p.stdout)


def h7_ds_lint(ctx):
    if not os.path.exists(os.path.join(ctx.root, DS_LINT)):
        return result("H7", "SKIP", "ds-lint.py not installed in this checkout")
    targets = [p for p in ctx.package_scripts() if p.endswith(".lua") and "ImGui" in ctx.read(p)]
    if not targets:
        return result("H7", "SKIP", "no changed UI script")
    bad, notes = [], []
    tmp = tempfile.mkdtemp(prefix="gates-")
    try:
        for path in targets:
            rc, n = run_ds_lint(ctx, os.path.join(ctx.root, path))
            if rc == 2:
                bad.append("%s: ds-lint error (exit 2)" % path)
                continue
            if rc == 0:
                continue
            old = ctx.read_base(path)
            if old is None:
                bad.append("%s: new script has definite ds-lint findings" % path)
                continue
            base_file = os.path.join(tmp, os.path.basename(path))
            with open(base_file, "w", encoding="utf-8") as f:
                f.write(old)
            brc, bn = run_ds_lint(ctx, base_file)
            if brc == 0:
                bad.append("%s: definite ds-lint findings introduced (base was clean)" % path)
            elif n is not None and bn is not None and n > bn:
                bad.append("%s: definite ds-lint findings rose %d -> %d" % (path, bn, n))
            else:
                notes.append("%s: pre-existing definite findings (base %s, now %s); UX lens must confirm none are new"
                             % (path, bn if bn is not None else "?", n if n is not None else "?"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        return result("H7", "FAIL", "\n".join(bad + notes))
    return result("H7", "PASS", "\n".join(notes) or "%d UI script(s) clean" % len(targets))


def h8_self_tests(ctx):
    live = set(ctx.live())
    runs = [(p, [sys.executable, os.path.join(ctx.root, p), "--self-test"])
            for p in (SELF, DS_LINT) if p in live and os.path.exists(os.path.join(ctx.root, p))]
    if not runs:
        return result("H8", "SKIP", "no self-tested helper changed")
    bad = []
    for path, cmd in runs:
        p = subprocess.run(cmd, capture_output=True, text=True, cwd=ctx.root)
        if p.returncode != 0:
            bad.append("%s --self-test exit %d\n%s" % (path, p.returncode, (p.stdout + p.stderr)[-1500:]))
    return result("H8", "FAIL" if bad else "PASS", "\n".join(bad) or "%d self-test(s) green" % len(runs))


GATES = [h1_luacheck, h2_headers, h3_version_bump, h4_changelog, h5_index,
         h6_not_packaged, h7_ds_lint, h8_self_tests]


def run_gates(ctx, gates=GATES):
    return [g(ctx) for g in gates]


def resolve_base(root, base):
    if base:
        refs = [base]
    else:
        refs = ["origin/main", "main"]
    for ref in refs:
        p = git(root, "merge-base", "HEAD", ref, check=False)
        if p.returncode == 0:
            return p.stdout.strip()
    raise GateError("cannot find a merge-base with %s; pass --base" % " or ".join(refs))


def print_table(results, base):
    print("Quality-bar hard gates (base %s)" % base[:10])
    for r in results:
        lines = r["detail"].splitlines() or [""]
        print("%-3s %-4s %s" % (r["id"], r["status"], lines[0]))
        for l in lines[1:]:
            print("         %s" % l)
    fails = [r["id"] for r in results if r["status"] == "FAIL"]
    print("RESULT %s" % ("FAIL (%s)" % ", ".join(fails) if fails else "PASS"))


# --- self-test ---------------------------------------------------------------

SCRIPT = """-- @description Fancy Test
-- @author Fancy Scripts
-- @version %s
-- @provides
--   [main] .
local x = 1
return x
"""


def _write(root, path, text):
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full) or root, exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write(text)


def _fixture():
    root = tempfile.mkdtemp(prefix="gates-selftest-")
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.email", "t@example.com")
    git(root, "config", "user.name", "t")
    _write(root, "Routing/Fancy_Test.lua", SCRIPT % "1.0.0")
    _write(root, "CHANGELOG.md", "# Changelog\n")
    _write(root, "index.xml", "<index/>\n")
    _write(root, ".reapack-index.conf", "--ignore docs\n--ignore .agents\n--ignore .claude\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    git(root, "checkout", "-q", "-b", "work")
    return root, git(root, "rev-parse", "HEAD").stdout.strip()


def _status(results, gid):
    return next(r["status"] for r in results if r["id"] == gid)


def self_test():
    gates = [h2_headers, h3_version_bump, h4_changelog, h5_index, h6_not_packaged]
    cases = []

    def case(name, edits, expect):
        root, base = _fixture()
        try:
            for path, text in edits.items():
                if text is None:
                    os.remove(os.path.join(root, path))
                else:
                    _write(root, path, text)
            res = run_gates(Ctx(root, base), gates)
            got = {gid: _status(res, gid) for gid in expect}
            cases.append((name, got == expect, expect, got))
        finally:
            shutil.rmtree(root, ignore_errors=True)

    case("no changes", {}, {"H2": "SKIP", "H3": "SKIP", "H4": "SKIP", "H5": "PASS", "H6": "PASS"})
    case("edit without bump or changelog",
         {"Routing/Fancy_Test.lua": SCRIPT % "1.0.0" + "-- edit\n"},
         {"H2": "PASS", "H3": "FAIL", "H4": "FAIL"})
    case("proper bump + changelog",
         {"Routing/Fancy_Test.lua": SCRIPT % "1.0.1", "CHANGELOG.md": "# Changelog\n- fix\n"},
         {"H2": "PASS", "H3": "PASS", "H4": "PASS"})
    case("version goes down", {"Routing/Fancy_Test.lua": SCRIPT % "0.9.9"}, {"H3": "FAIL"})
    case("non-semver version", {"Routing/Fancy_Test.lua": SCRIPT % "1.1"}, {"H2": "FAIL", "H3": "FAIL"})
    case("missing author", {"Routing/Fancy_Test.lua": (SCRIPT % "1.0.1").replace("-- @author Fancy Scripts\n", "")},
         {"H2": "FAIL"})
    case("new script needs no bump", {"FX/Fancy_New.lua": SCRIPT % "1.0.0", "CHANGELOG.md": "x\n"},
         {"H2": "PASS", "H3": "SKIP", "H4": "PASS"})
    case("lib change needs changelog", {"_lib/utils.lua": "return {}\n"}, {"H4": "FAIL", "H2": "SKIP"})
    case("index.xml edited", {"index.xml": "<index>x</index>\n"}, {"H5": "FAIL"})
    case("dev script under .agents", {".agents/skills/x/scripts/t.py": "print(1)\n"}, {"H6": "PASS"})
    case("dev script at repo root", {"tools/t.py": "print(1)\n"}, {"H6": "FAIL"})
    case("missing required ignore", {".reapack-index.conf": "--ignore docs\n--ignore .agents\n"}, {"H6": "FAIL"})
    case("deleted script", {"Routing/Fancy_Test.lua": None, "CHANGELOG.md": "x\n"},
         {"H2": "SKIP", "H3": "SKIP", "H4": "PASS"})

    # count_definite parsing
    cases.append(("count_definite list", count_definite('[{"c":"definite"},{"c":"check"}]') == 1, 1, None))
    cases.append(("count_definite dict", count_definite('{"findings":[{"c":"definite"}]}') == 1, 1, None))
    cases.append(("count_definite junk", count_definite("not json") is None, None, None))
    cases.append(("ignored nested", ignored(".claude/skills/a/b.py", [".claude"]), True, None))
    cases.append(("ignored glob", ignored("x/y.json", ["*.json"]), True, None))
    cases.append(("not ignored", not ignored("tools/a.py", [".claude", "docs"]), True, None))

    failed = 0
    for name, ok, expect, got in cases:
        print("%s  %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  expected %s got %s" % (expect, got)))
        failed += not ok
    print("RESULT %s (%d/%d)" % ("PASS" if not failed else "FAIL", len(cases) - failed, len(cases)))
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(prog="gates.py", description=__doc__.splitlines()[0])
    ap.add_argument("--base", help="base ref (default: merge-base with origin/main or main)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--self-test", action="store_true", help="run embedded fixtures")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    try:
        root = git(os.getcwd(), "rev-parse", "--show-toplevel").stdout.strip()
        base = resolve_base(root, args.base)
        results = run_gates(Ctx(root, base))
    except GateError as e:
        print("gates.py: %s" % e, file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"base": base, "results": results}, indent=2))
    else:
        print_table(results, base)
    return 1 if any(r["status"] == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
