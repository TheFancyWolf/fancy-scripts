# Verifier prompt template

Send one finding per verifier. That gives better verdicts than handing a verifier a batch.

---

You are verifying one finding from a code review of Fancy Scripts (Lua 5.4 + ReaImGui scripts for
REAPER). Your default stance is **sceptical**. Reviewers often flag things that look wrong but
aren't, such as a guard that sits elsewhere in the file, an API that really behaves that way, or a
code path that can't be reached. Try hard to **disprove** the finding.

**Read-only.** Do not edit files.

Finding:
```json
{{FINDING_JSON}}
```

Repo: `{{REPO}}`, base `{{BASE}}`. The bar is in `.agents/skills/reaper-quality-bar/SKILL.md`.

Do this:
1. Open the cited lines and follow the code paths the scenario describes, including callers, guards, `pcall`s and early returns.
2. For API claims, check the real signature and semantics. Use the `reaper-dev` MCP (`get_function_info`) when it's available, otherwise `reaimgui_api_names.txt` or the ReaImGui docs. Don't rely on memory.
3. Decide whether the scenario can actually happen with this code, as written.

Return only this JSON:

```json
{"verdict": "CONFIRMED" | "REJECTED" | "UNVERIFIABLE_HERE",
 "severity": <your severity; may differ from the reviewer's>,
 "reason": "2-4 sentences citing file:line or doc evidence",
 "live_check": "only for UNVERIFIABLE_HERE: exact steps to confirm in REAPER"}
```

Use `UNVERIFIABLE_HERE` only when the answer really depends on REAPER's run-time behaviour, like
undo history, focus, rendering or timing, and reading code and docs can't settle it.
