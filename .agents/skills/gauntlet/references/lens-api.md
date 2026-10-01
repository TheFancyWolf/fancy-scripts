# Lens: API correctness (rules A1–A5)

You hunt for calls that don't do what the author thinks they do. LLM-written REAPER code most often
fails here: plausible function names that don't exist, argument orders taken from a different API,
and ReaImGui 0.8-era idioms.

## Method

1. List every distinct `reaper.*`, `ImGui.*` (or `reaper.ImGui_*`) and `Theme.*` call **in the diff**.
2. Check each one, without relying on memory:
   - `reaper-dev` MCP `get_function_info` when it's available,
   - otherwise `.agents/skills/reaimgui-ux-review/references/reaimgui_api_names.txt` for existence,
   - `_lib/theme.lua` for `Theme.*` helpers and their real parameters.
3. For each call, check the arity, argument order, types, **all return values** (REAPER often returns `retval, value`), and whether the returns are being used correctly.

## Hunt list

- Functions that don't exist, or that exist only in SWS/JS extensions with no dependency check (`BR_*`, `CF_*`, `JS_*`, `SNM_*`).
- `retval` being used as if it were the value: `local vol = reaper.GetTrackSendInfo_Value(...)` is fine, but `local name = reaper.GetTrackName(tr)` is a bug.
- Begin/End balance on every path (A3). Look at `if not visible then return end`, `Begin` inside `pcall`, child windows, tables, popups (`BeginPopup` returns false and then needs no `EndPopup`), and `BeginMenuBar`.
- Push/Pop balance (A4). Count them per path. Look for early returns between a Push and its Pop, `Theme.push` vs `Theme.pop` counts, and `push_font` without the matching `pop_font(ctx, pushed)`.
- ReaImGui 0.10 changes: no `ImGui.CreateFont`+`Attach` assumptions without checking, `ImGui.PushFont(ctx, font, size)` takes a size, and the deprecated `SetNextWindowContentSize`-style use.
- Cached MediaTrack, MediaItem, Take, FX index or envelope used in a later defer tick without `ValidatePtr2` (A5). FX indexes shift when FX are added or removed.
- Mixing 0-based and 1-based indexes, for example `GetTrack(0, i)` with a Lua `for i = 1, n` loop.
- String vs number confusion in `GetSetMediaTrackInfo_String` / P_EXT and in ExtState values, which are always strings.

Severity guide: a call to a function that doesn't exist, or a Begin/End or Push/Pop imbalance on a reachable path, is **4** (script crash). Wrong returns or arguments that produce wrong behaviour are **3**.
