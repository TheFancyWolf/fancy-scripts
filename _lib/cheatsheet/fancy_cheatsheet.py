#!/usr/bin/env python3
# Fancy Scripts — Cheat Sheet helper
# Builds a printable cheat sheet (Markdown source + HTML) from the data that
# "Performance/Fancy_Cheat Sheet.lua" exports from a REAPER project.
#
#   python3 fancy_cheatsheet.py <input.json> [log file]     full run (from REAPER)
#   python3 fancy_cheatsheet.py --render <file.md | folder> [--open]
#                                                         HTML from the .md only
#
# Steps: transcribe the audio (cached) -> build rows from the MIDI ->
# merge with the existing Markdown (keeps hand edits) -> render HTML.
# Always writes a result JSON next to the input so the Lua side can report.
#
# Requirements: Python 3.9+, mlx-whisper (Apple Silicon), markdown, ffmpeg.
# License: GPL v3 (see LICENSE in the repository root).

import datetime
import difflib
import hashlib
import html
import json
import os
import re
import shutil
import sys
import traceback

VERSION = "1.0.0"
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULTS = {  # front matter of each .md; the first five print at the top of the sheet
    "key": "", "run_key": "", "run_direction": "", "gliss_direction": "", "trill_interval": "",
    "short": "", "scale": "",
    "hand_split": "C4", "phrase_gap": 0.75, "cue_words": 0, "auto_keys": "no",
}
MATCH_TOLERANCE = 0.5      # seconds: a moved switch within this is the same row
LYRIC_LEAD = 0.4           # seconds: a line starting this early still belongs to the next row
PART_LEAD = 0.3            # seconds: a line starting this close to the first note counts as with it
MIN_LOGPROB = -1.0         # Whisper segments less confident than this are dropped
DOMINANT = 0.5             # share of onsets that makes one shape "the" figure
FAST_GAP = 0.18            # seconds between notes: faster than this is a "run"
SLOW_GAP = 0.5             # seconds between notes: slower than this is "slow"
HOLD_MIN = 0.6             # seconds: a last note this long (and 3x the others) is "held"
MATCH_MIN = 0.6            # similarity needed to replace a heard line with the reference
MATCH_AHEAD = 10           # reference lines searched past the last match
UNSURE = " (?)"            # marks a heard line that matched no reference line
GENIUS_RECS = 6            # lines of song suggestions after "You might also like"
JUNK_LINE = re.compile(r"^\[.*\]$|^\d*\s*Contributors|Embed$|^You might also like$", re.I)
CHORD_WINDOW = 0.04        # seconds: notes starting this close form one chord
HIT_MAX = 0.25             # seconds: median length below this = hits
HELD_MIN = 0.8             # seconds: median length above this = held
LIST_MAX = 6               # notes listed before "…"
FLAG = "⚠ no longer in MIDI — check"
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
CHORDS = [  # (intervals from root, suffix); first match wins
    ((0, 4, 7, 10), "7"), ((0, 4, 7, 11), "maj7"), ((0, 3, 7, 10), "m7"),
    ((0, 4, 7), ""), ((0, 3, 7), "m"), ((0, 3, 6), "dim"), ((0, 4, 8), "aug"),
    ((0, 5, 7), "sus4"), ((0, 2, 7), "sus2"),
]


# -----------------------------------------------------------------------------
# 1. SMALL HELPERS
# -----------------------------------------------------------------------------

class SheetError(Exception):
    """An error with a message meant for the user, plus an optional code."""

    def __init__(self, message, code="error"):
        super().__init__(message)
        self.code = code


def note_name(p):
    return f"{NAMES[p % 12]}{p // 12 - 1}"


def parse_note(text):
    m = re.fullmatch(r"\s*([A-Ga-g])([#b]?)(-?\d+)\s*", str(text))
    if not m:
        raise SheetError(f"hand_split '{text}' is not a note name like C4.")
    pc = NAMES.index(m.group(1).upper())
    pc += {"#": 1, "b": -1}.get(m.group(2), 0)
    return (int(m.group(3)) + 1) * 12 + pc


def fmt_time(t):
    t = max(0.0, t)
    m, s = divmod(int(round(t)), 60)
    return f"{m}:{s:02d}"


def parse_time(text):
    m = re.match(r"\s*(\d+):(\d{1,2}(?:\.\d+)?)", text)
    return int(m.group(1)) * 60 + float(m.group(2)) if m else None


def body_hash(body):
    norm = "\n".join(line.rstrip() for line in body.strip().splitlines())
    return hashlib.sha1(norm.encode("utf-8")).hexdigest()[:8]


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


class Status:
    """Progress text the Lua side shows in REAPER's help line."""

    def __init__(self, path):
        self.path = path

    def __call__(self, text):
        print(text, flush=True)
        try:
            with open(self.path, "w", encoding="utf-8") as f:
                f.write(text)
        except OSError:
            pass


# -----------------------------------------------------------------------------
# 2. LYRICS (WHISPER, CACHED)
# -----------------------------------------------------------------------------

def transcribe(audio, cache_path, model, status):
    """Return lyric segments in PROJECT time: [{"s", "e", "t"}]."""
    path = audio["file"]
    if not os.path.isfile(path):
        raise SheetError(f"Audio file not found:\n{path}")
    st = os.stat(path)
    key = {"file": path, "size": st.st_size, "mtime": int(st.st_mtime), "model": model}

    cached = None
    if os.path.isfile(cache_path):
        try:
            with open(cache_path, encoding="utf-8") as f:
                cached = json.load(f)
        except (OSError, ValueError):
            cached = None
    if not cached or cached.get("key") != key:
        if not shutil.which("ffmpeg"):
            raise SheetError("Whisper needs ffmpeg to read audio, and it was not found.\n\n"
                             "Install it in Terminal with Homebrew:\n  brew install ffmpeg\n\n"
                             "Then run Fancy Cheat Sheet again.", "missing_ffmpeg")
        try:
            import mlx_whisper
        except ImportError:
            raise SheetError("The Python package 'mlx-whisper' is not installed.", "missing_deps")
        status("Cheat Sheet: transcribing lyrics (first run for this audio, about a minute)…")
        r = mlx_whisper.transcribe(path, path_or_hf_repo=model, language="en",
                                   word_timestamps=True)
        segs = [{"s": s["start"], "e": s["end"], "t": s["text"].strip(),
                 "nsp": round(s.get("no_speech_prob", 0.0), 3),
                 "lp": round(s.get("avg_logprob", 0.0), 3)}
                for s in r.get("segments", [])]
        cached = {"key": key, "segments": segs}
        write_json(cache_path, cached)

    pos, off = audio["item_pos"], audio["offset"]
    rate = audio.get("rate") or 1.0
    end = pos + audio["item_len"]
    out = []
    for s in cached["segments"]:
        if (len(re.findall(r"[A-Za-z]", s["t"])) < 2 or s.get("nsp", 0) > 0.6
                or s.get("lp", 0) < MIN_LOGPROB):
            continue
        ps = pos + (s["s"] - off) / rate
        pe = pos + (s["e"] - off) / rate
        if pe <= pos or ps >= end:
            continue
        out.append({"s": max(ps, pos), "e": min(pe, end), "t": s["t"]})
    return out


def _norm(text):
    text = text.lower().replace("-", " ").replace("’", "'")
    return " ".join(re.sub(r"[^a-z0-9' ]", " ", text).split())


def load_reference(path):
    """Lyric lines from the user's text file, without section tags or blank lines."""
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):   # TextEdit can save UTF-16
        text = raw.decode("utf-16")
    else:
        try:
            text = raw.decode("utf-8-sig")
        except UnicodeError:
            text = raw.decode("mac_roman")         # older Mac default; never fails
    out, skip = [], 0
    for ln in (ln.strip() for ln in text.splitlines()):
        if re.fullmatch(r"you might also like", ln, re.I):
            skip = GENIUS_RECS        # Genius pastes: song suggestions follow
            continue
        if not ln or JUNK_LINE.search(ln):
            if ln.startswith("["):
                skip = 0
            continue
        if skip:
            skip -= 1
            continue
        out.append(ln)
    return out


def _partial(heard_words, ref_line):
    """How much of a short heard fragment sits inside one reference line.

    Returns (coverage 0..1, the matching span of the reference line, reaches_end)."""
    words = ref_line.split()
    norm_words = [_norm(w) for w in words]
    sm = difflib.SequenceMatcher(None, heard_words, norm_words)
    blocks = [b for b in sm.get_matching_blocks() if b.size]
    if not blocks:
        return 0.0, "", False
    covered = sum(b.size for b in blocks)
    lo, hi = blocks[0].b, blocks[-1].b + blocks[-1].size
    return covered / len(heard_words), " ".join(words[lo:hi]), hi == len(words)


def apply_reference(lyrics, ref):
    """Replace heard lines with the closest reference lines, in song order.

    A heard segment may cover one to three reference lines, or only part of
    one ("Start now" inside "And I mean, start now"). Matching moves forward
    through the reference so repeated lines land in the right place. Reference
    lines nobody matched are placed between their neighbours' times, so the
    sheet carries the whole lyric. Heard lines that match nothing are dropped.
    Returns (lyrics, matched_count)."""
    norm_ref = [_norm(r) for r in ref]
    ptr, matched, out = 0, 0, []
    for ly in lyrics:
        heard = _norm(ly["t"])
        heard_words = heard.split()
        best = (0.0, None, None, None, True)   # score, j, k, text, reaches_end
        for j in range(max(0, ptr - 2), min(len(ref), ptr + MATCH_AHEAD)):
            for k in (1, 2, 3):
                if j + k > len(ref):
                    break
                cand = " ".join(norm_ref[j:j + k])
                score = difflib.SequenceMatcher(None, heard, cand).ratio()
                if score > best[0]:
                    best = (score, j, k, ref[j:j + k], True)
            if len(heard_words) >= 2 and len(heard_words) < len(norm_ref[j].split()):
                cover, span, at_end = _partial(heard_words, ref[j])
                if cover >= 0.8 and cover * 0.9 > best[0]:
                    best = (cover * 0.9, j, 1, [span], at_end)
        score, j, k, lines, at_end = best
        if j is not None and score >= MATCH_MIN:
            partial = lines != ref[j:j + k]
            prev = out[-1] if out else None
            if not partial and prev and prev.get("partial") and prev["ref"][0] == j:
                ly = dict(ly, s=prev["s"])     # the full line replaces its earlier fragment
                out.pop()
            out.append(dict(ly, t=" / ".join(lines), ref=(j, j + k), partial=partial))
            ptr, matched = (j + k if at_end else j), matched + 1
        # A heard line that matches nothing in the reference is left out:
        # the reference is the wording to trust.

    covered = {i for ly in out if "ref" in ly for i in range(*ly["ref"])}
    anchors = sorted((ly["ref"][0], ly["ref"][1] - 1, ly["s"], ly["e"]) for ly in out if "ref" in ly)
    if anchors:
        gap = []
        for i in range(len(ref) + 1):
            if i < len(ref) and i not in covered:
                gap.append(i)
                continue
            if gap:
                before = [a for a in anchors if a[1] < gap[0]]
                after = [a for a in anchors if a[0] > gap[-1]]
                t0 = before[-1][3] if before else (after[0][2] - 0.5 * (len(gap) + 1))
                t1 = after[0][2] if after else (t0 + 0.5 * (len(gap) + 1))
                for n, gi in enumerate(gap, 1):
                    t = t0 + (t1 - t0) * n / (len(gap) + 1)
                    out.append({"s": t, "e": t, "t": ref[gi]})
                gap = []
    out.sort(key=lambda ly: ly["s"])
    return out, matched


def lyric_lines(lines, words):
    """Split joined lines apart; with words > 0, keep only each line's first words."""
    parts = [p.strip() for ln in lines for p in ln.split(" / ") if p.strip()]
    if words <= 0:
        return parts

    def short(line):
        unsure = line.endswith(UNSURE)
        core = line[:-len(UNSURE)] if unsure else line
        w = core.split()
        core = " ".join(w[:words]) + ("…" if len(w) > words else "")
        return core + (UNSURE if unsure else "")
    return [short(p) for p in parts]


# -----------------------------------------------------------------------------
# 3. DESCRIBING WHAT THE HANDS PLAY
# -----------------------------------------------------------------------------

def chord_name(pitches):
    pcs = sorted({p % 12 for p in pitches})
    if len(pcs) < 3:
        return None
    bass = min(pitches) % 12
    for root in [bass] + [pc for pc in pcs if pc != bass]:
        rel = tuple(sorted((pc - root) % 12 for pc in pcs))
        for ivs, suffix in CHORDS:
            if rel == ivs:
                return NAMES[root] + suffix
    return None


def onsets(notes):
    """Group notes into chords: [[note, ...], ...] by start time."""
    groups = []
    for n in notes:
        if groups and n["s"] - groups[-1][0]["s"] < CHORD_WINDOW:
            groups[-1].append(n)
        else:
            groups.append([n])
    return groups


def length_word(notes):
    durs = sorted(n["e"] - n["s"] for n in notes)
    med = durs[len(durs) // 2]
    if med < HIT_MAX:
        return "hits"
    if med > HELD_MIN:
        return "held"
    return ""


def _pc(p):
    return NAMES[p % 12]


def _reg(p):
    """Register word as players say it: High from C6, Mid from C5, Low below C4."""
    if p >= 84:
        return "High "
    if p >= 72:
        return "Mid "
    if p < 60:
        return "Low "
    return ""


OCTAVE_STACK = {2: "Octave", 3: "Triple octave", 4: "Quad octave", 5: "5-octave"}


def shape_label(shape, reg=True):
    """One onset: 'Mid D', 'F# octave', 'Quad octave D', 'D chord'."""
    pcs = {p % 12 for p in shape}
    if len(shape) == 1:
        return (_reg(shape[0]) if reg else "") + _pc(shape[0])
    if len(pcs) == 1:
        if len(shape) == 2:
            return f"{_pc(shape[0])} octave"
        return f"{OCTAVE_STACK.get(len(shape), 'Octave')} {_pc(shape[0])}"
    name = chord_name(shape)
    return f"{name} chord" if name else "/".join(_pc(p) for p in shape)


def _cycle(items):
    """(cycle, times, exact) if items repeats one short cycle 2+ times, else None.

    A cut-off last pass still counts (exact=False)."""
    for period in range(1, 5):
        if len(items) < 2 * period:
            continue
        cyc = items[:period]
        if len(set(cyc)) > 1 or period == 1:
            if all(items[i] == cyc[i % period] for i in range(len(items))):
                return cyc, len(items) // period, len(items) % period == 0
    return None


def _speed(groups):
    """'fast' / 'slow' / '' from the time between onsets."""
    gaps = sorted(b[0]["s"] - a[0]["s"] for a, b in zip(groups, groups[1:]))
    if not gaps:
        return ""
    med = gaps[len(gaps) // 2]
    return "fast" if med < FAST_GAP else ("slow" if med > SLOW_GAP else "")


def describe_hand(notes, reg=True):
    """Return (text, signature) for one hand, worded the way a player marks a part."""
    groups = onsets(notes)
    shapes = [tuple(sorted({n["p"] for n in g})) for g in groups]
    count = len(groups)
    length = length_word(notes)
    shape_set = sorted(set(shapes))
    octaves = all(len(s) > 1 and len({p % 12 for p in s}) == 1 for s in shapes)

    if len(shape_set) == 1:
        sig = ("single", length) if len(shape_set[0]) == 1 else \
            ("same", tuple(sorted({p % 12 for p in shape_set[0]})), length)
        return shape_label(shape_set[0], reg), sig

    top, top_n = max(((s, shapes.count(s)) for s in shape_set), key=lambda x: x[1])
    if top_n / count >= DOMINANT and top_n > 2:
        return shape_label(top, reg), ("same", tuple(sorted({p % 12 for p in top})), length)

    # A held last note reads "then hold X".
    hold = ""
    durs = [max(n["e"] - n["s"] for n in g) for g in groups]
    if count >= 3:
        rest = sorted(durs[:-1])
        if durs[-1] >= HOLD_MIN and durs[-1] >= 3 * rest[len(rest) // 2]:
            hold = ", then hold " + (_pc(shapes[-1][0]) if octaves else shape_label(shapes[-1], reg))
            shapes, groups = shapes[:-1], groups[:-1]

    if all(len(sh) == 1 for sh in shapes):
        seq = [sh[0] for sh in shapes]
        steps = [b - a for a, b in zip(seq, seq[1:])]
        speed = _speed(groups)
        up = len(seq) >= 3 and all(0 < d <= 4 for d in steps)
        down = len(seq) >= 3 and all(-4 <= d < 0 for d in steps)
        if up or down:
            kind = ("Run " + ("up" if up else "down")) if speed == "fast" else ("Walk-up" if up else "Walk-down")
            if speed == "slow":
                kind += " slow"
            names = " ".join(_pc(p) for p in seq[:LIST_MAX + 2])
            lead = _reg(seq[0]).strip() if reg else ""
            text = f"{lead + ' ' if lead else ''}{kind.lower() if lead else kind} {names}"
            return text + hold, ("line", length)

        # Short single notes read as a line ("Slow line G D A D"); a chord's
        # notes one at a time read "D chord: D F# A D".
        name = chord_name(seq)
        arpeggio = all(d > 0 for d in steps) or all(d < 0 for d in steps)
        if name and arpeggio and len(set(p % 12 for p in seq)) >= 3 and len(seq) <= LIST_MAX:
            return f"{name} chord: " + " ".join(_pc(p) for p in _dedupe(seq)) + hold, ("line", length)
        if length != "held":
            names = _dedupe([_pc(p) for p in seq])
            cyc = _cycle(names)
            if cyc:
                listed = " ".join(cyc[0]) + (f" {cyc[1]}x" if cyc[2] else " (repeat)")
            else:
                listed = " ".join(names[:LIST_MAX]) + (" …" if len(names) > LIST_MAX else "")
            lead = (speed.capitalize() + " line") if speed else "Line"
            return f"{lead} {listed}" + hold, ("line", length)

    labels = _dedupe([_pc(sh[0]) if octaves else shape_label(sh, reg) for sh in shapes])
    cyc = _cycle(labels)
    if cyc:
        body = " → ".join(cyc[0]) + (f" {cyc[1]}x" if cyc[2] else " (repeat)")
    else:
        body = " → ".join(labels[:LIST_MAX]) + (" …" if len(labels) > LIST_MAX else "")
    if octaves:
        body = "Octaves " + body
    return body + hold, ("mixed", length)


def _dedupe(seq):
    out = []
    for x in seq:
        if not out or out[-1] != x:
            out.append(x)
    return out


def _listed(pitches):
    seq = _dedupe([p % 12 for p in pitches])
    text = " ".join(NAMES[pc] for pc in seq[:LIST_MAX])
    return text + (" …" if len(seq) > LIST_MAX else "")


def describe(notes, split):
    """Return (text, signature) for a group of notes.

    Hands are labelled only when they do different things; when both hands
    double the same notes in octaves it reads as one shape ("Quad octave D")."""
    if not notes:
        return "No notes", ("none",)
    rh = [n for n in notes if n["p"] >= split]
    lh = [n for n in notes if n["p"] < split]
    if rh and lh:
        same_pcs = {n["p"] % 12 for n in rh} == {n["p"] % 12 for n in lh}
        if same_pcs and all(len({n["p"] % 12 for n in g}) == 1 for g in onsets(notes)):
            return describe_hand(notes)
        rt, rs = describe_hand(rh)
        lt, ls = describe_hand(lh, reg=False)
        return f"LH: {lt} · RH: {rt}", (ls, rs)
    text, sig = describe_hand(rh or lh)
    return text, (("rh", sig) if rh else ("lh", sig))


# -----------------------------------------------------------------------------
# 3b. KEYBOARD DIAGRAMS
#
#   keys [LH|RH] <low>-<high>: <notes>   dots on the notes (chords, shapes)
#   line [LH|RH] <low>-<high>: <notes>   dots numbered in the order given
#
# Notes are names with an optional octave (D, C#, Bb, G2). The range reads
# upward: "B-E" is B up to the next E. Without octaves, a mark is the first
# matching key in the range.
# -----------------------------------------------------------------------------

BLACK_PCS = {1, 3, 6, 8, 10}
KEY_TOKEN = r"[A-Ga-g](?:#|b|♯|♭)?\d?"
KEY_LINE_RE = re.compile(rf"^\s*(keys|line)(?:\s+(LH|RH))?\s+({KEY_TOKEN})\s*-\s*({KEY_TOKEN})\s*:\s*(.+?)\s*$",
                         re.I)
KB_MAX_SPAN = 48           # semitones; wider ranges are refused
KB_WHITE_W, KB_H = 16, 48  # key size in px for print


def _key_token(tok):
    """'C#4' -> (pitch class, octave or None); None if not a note."""
    m = re.fullmatch(r"([A-Ga-g])(#|b|♯|♭)?(\d)?", tok.strip())
    if not m:
        return None
    pc = NAMES.index(m.group(1).upper()) + {"#": 1, "♯": 1, "b": -1, "♭": -1}.get(m.group(2) or "", 0)
    return pc % 12, (int(m.group(3)) if m.group(3) else None)


def parse_key_line(line):
    """Return (kind, hand, lo, hi, marks) for a keys/line row, or None if it isn't one."""
    m = KEY_LINE_RE.match(line)
    if not m:
        return None
    kind, hand, lo_t, hi_t, marks_t = m.groups()
    lo_k, hi_k = _key_token(lo_t), _key_token(hi_t)
    if lo_k is None or hi_k is None:
        return None
    lo = (lo_k[1] if lo_k[1] is not None else 4) * 12 + 12 + lo_k[0]
    if hi_k[1] is not None:
        hi = hi_k[1] * 12 + 12 + hi_k[0]
    else:
        hi = lo + 1 + (hi_k[0] - lo - 1) % 12
    if hi <= lo or hi - lo > KB_MAX_SPAN:
        return None
    marks = []
    for tok in re.split(r"[\s,]+", marks_t.strip()):
        if not tok:
            continue
        k = _key_token(tok)
        if k is None:
            return None
        if k[1] is not None:
            p = k[1] * 12 + 12 + k[0]
        else:
            p = next((q for q in range(lo, hi + 1) if q % 12 == k[0]), None)
            if p is None:
                return None
        lo, hi = min(lo, p), max(hi, p)
        marks.append(p)
    if lo % 12 in BLACK_PCS:
        lo -= 1
    if hi % 12 in BLACK_PCS:
        hi += 1
    return kind.lower(), (hand or "").upper(), lo, hi, marks


def keyboard_svg(lo, hi, marks, numbered, key_w=None, key_h=None):
    """A small keyboard from lo to hi (white keys at both ends) with dots."""
    whites = [p for p in range(lo, hi + 1) if p % 12 not in BLACK_PCS]
    w = key_w or (KB_WHITE_W if len(whites) <= 15 else max(11, KB_WHITE_W * 15 // len(whites)))
    h = key_h or KB_H
    bw, bh = w * 0.6, h * 0.6
    r = max(4.0, w * 0.32)
    x_of = {p: i * w for i, p in enumerate(whites)}
    width = len(whites) * w
    out = [f'<svg class="kb" xmlns="http://www.w3.org/2000/svg" width="{width + 2}" height="{h + 2}" '
           f'viewBox="-1 -1 {width + 2} {h + 2}">']
    for p in whites:
        out.append(f'<rect x="{x_of[p]}" y="0" width="{w}" height="{h}" rx="2" fill="#fff" '
                   f'stroke="#000" stroke-width="1.2"/>')
    bx = {}
    for p in range(lo, hi + 1):
        if p % 12 in BLACK_PCS:
            bx[p] = x_of[p - 1] + w - bw / 2
            out.append(f'<rect x="{bx[p]:.1f}" y="0" width="{bw:.1f}" height="{bh:.1f}" rx="1.5" fill="#000"/>')
    seen = set()
    for n, p in enumerate(marks, 1):
        if p in seen and not numbered:
            continue
        seen.add(p)
        if p in bx:
            cx, cy, fill, ink = bx[p] + bw / 2, bh - r - 3, "#fff", "#000"
        else:
            cx, cy, fill, ink = x_of[p] + w / 2, h - r - 4, "#000", "#fff"
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{fill}" stroke="#000" stroke-width="1.2"/>')
        if numbered:
            out.append(f'<text x="{cx:.1f}" y="{cy + 3.6:.1f}" font-size="{min(11, r * 1.6):.0f}" '
                       f'font-weight="bold" text-anchor="middle" fill="{ink}" '
                       f'font-family="Helvetica, Arial, sans-serif">{n}</text>')
    out.append("</svg>")
    return "".join(out)


def keyboards_in(body):
    """Turn keys/line rows into inline keyboards attached to the line above."""
    out = []
    for line in body.splitlines():
        parsed = parse_key_line(line)
        if not parsed:
            out.append(line)
            continue
        kind, hand, lo, hi, marks = parsed
        label = f'<span class="kbh">{hand}</span>' if hand else ""
        kb = f'<span class="kbw">{label}{keyboard_svg(lo, hi, marks, kind == "line")}</span>'
        if out and out[-1].strip() and not out[-1].lstrip().startswith(">"):
            out[-1] += " " + kb
        else:
            out.append(kb)
    return "\n".join(out)


def _pitch_text(p):
    return f"{NAMES[p % 12]}{p // 12 - 1}"


def auto_keys(notes, split):
    """keys/line rows for one row of notes, per hand (a first pass to edit)."""
    lines = []
    rh = [n for n in notes if n["p"] >= split]
    lh = [n for n in notes if n["p"] < split]
    for hand, group in (("LH", lh), ("RH", rh)):
        if not group:
            continue
        label = f" {hand}" if lh and rh else ""
        pitches = sorted({n["p"] for n in group})
        lo, hi = pitches[0] - 1, pitches[-1] + 1
        if hi - lo > KB_MAX_SPAN:
            continue
        lo -= 1 if lo % 12 in BLACK_PCS else 0
        hi += 1 if hi % 12 in BLACK_PCS else 0
        groups = onsets(sorted(group, key=lambda n: n["s"]))
        seq = _dedupe([g[0]["p"] for g in groups]) if all(len(g) == 1 for g in groups) else []
        steps = [b - a for a, b in zip(seq, seq[1:])]
        is_line = 3 <= len(seq) <= 8 and (all(0 < d <= 2 for d in steps) or all(-2 <= d < 0 for d in steps))
        marks = seq if is_line else pitches
        kind = "line" if is_line else "keys"
        lines.append(f"{kind}{label} {_pitch_text(lo)}-{_pitch_text(hi)}: "
                     + " ".join(_pitch_text(p) for p in marks))
    return lines


# -----------------------------------------------------------------------------
# 4. BUILDING ROWS
# -----------------------------------------------------------------------------

def build_rows(data, lyrics, settings):
    """Return rows: dicts with at, art, kind ('switch'|'phrase'), part, lyric lines.

    A new row starts only when there is something new to play; lyrics sung
    while resting stay with the row before."""
    ks_names = {int(p): name for p, name in data["keyswitches"]}
    split = parse_note(settings["hand_split"])
    phrase_gap = float(settings["phrase_gap"])

    notes = sorted(({"p": n[0], "s": n[1], "e": n[2]} for n in data["notes"]),
                   key=lambda n: (n["s"], n["p"]))
    ks = [n for n in notes if n["p"] in ks_names]
    played = [n for n in notes if n["p"] not in ks_names]

    switches = []   # (time, articulation), only real changes
    for n in ks:
        name = ks_names[n["p"]]
        if not switches or switches[-1][1] != name:
            switches.append((n["s"], name))

    def art_at(t):
        cur = None
        for st, name in switches:
            if st <= t + 0.05:
                cur = name
            else:
                break
        return cur

    # Phrases: split at gaps and at articulation changes.
    phrases = []
    end = None
    for n in played:
        art = art_at(n["s"])
        if phrases and art == phrases[-1]["art"] and n["s"] <= end + phrase_gap:
            phrases[-1]["notes"].append(n)
            end = max(end, n["e"])
        else:
            phrases.append({"art": art, "notes": [n]})
            end = n["e"]
    for ph in phrases:
        ph["s"] = ph["notes"][0]["s"]
        ph["e"] = max(n["e"] for n in ph["notes"])

    # Rows: one per articulation switch. Inside a row, each change of figure
    # is a new part, placed among the lyrics where its playing starts.
    rows = []

    def open_row(at, art, kind):
        rows.append({"at": at, "art": art, "kind": kind, "parts": []})

    sw_iter = iter(switches)
    next_sw = next(sw_iter, None)
    for ph in phrases:
        while next_sw and next_sw[0] <= ph["s"] + 0.05:
            open_row(next_sw[0], next_sw[1], "switch")
            next_sw = next(sw_iter, None)
        if not rows:
            open_row(ph["s"], ph["art"], "phrase")
        _, sig = describe(ph["notes"], split)
        parts = rows[-1]["parts"]
        if parts and parts[-1]["sig"] == sig:
            parts[-1]["notes"].extend(ph["notes"])
        else:
            parts.append({"s": ph["s"], "notes": list(ph["notes"]), "sig": sig})
    while next_sw:   # switches after the last note
        open_row(next_sw[0], next_sw[1], "switch")
        next_sw = next(sw_iter, None)

    words = int(float(settings["cue_words"] or 0))
    want_keys = str(settings.get("auto_keys", "no")).strip().lower() in ("yes", "on", "true", "1")
    for i, row in enumerate(rows):
        nxt = rows[i + 1]["at"] - LYRIC_LEAD if i + 1 < len(rows) else float("inf")
        lo = row["at"] - LYRIC_LEAD if i else float("-inf")
        # Items in time order. A lyric line sung clearly before a part's first
        # note comes before it; lines from the first note on come after it.
        items = [(ly["s"], 1, "lyric", ly["t"]) for ly in lyrics if lo <= ly["s"] < nxt]
        for part in row["parts"]:
            text = describe(part["notes"], split)[0]
            keys = auto_keys(part["notes"], split) if want_keys else []
            items.append((part["s"] - PART_LEAD, 0, "part", (text, keys)))
        items.sort(key=lambda it: (it[0], it[1]))
        row["items"] = []
        for _, _, kind, val in items:
            if kind == "lyric":
                for line in lyric_lines([val], words):
                    row["items"].append(("lyric", line))
            else:
                row["items"].append(("part", val))
    return rows, ks_names


# -----------------------------------------------------------------------------
# 5. MARKDOWN: PARSE, MERGE, WRITE
# -----------------------------------------------------------------------------

ANCHOR_RE = re.compile(r"<!--\s*at=([\d.]+)\s+auto=([0-9a-f]+)\s*-->")


def auto_body(row):
    """Lyric lines as quotes, each part as a bold line (plus keys rows), in order."""
    blocks, quote = [], []
    for kind, val in row.get("items", []):
        if kind == "lyric":
            quote.append("> " + val)
            continue
        if quote:
            blocks.append("\n".join(quote))
            quote = []
        text, keys = val
        blocks.append("\n".join([f"**{text}**"] + keys))
    if quote:
        blocks.append("\n".join(quote))
    return "\n\n".join(blocks) or "*(no notes)*"


def parse_markdown(text):
    """Return (settings, title, preamble, rows)."""
    lines = text.splitlines()
    settings = dict(DEFAULTS)
    i = 0
    if lines and lines[0].strip() == "---":
        i = 1
        while i < len(lines) and lines[i].strip() != "---":
            if ":" in lines[i]:
                k, v = lines[i].split(":", 1)
                if k.strip() in DEFAULTS:
                    settings[k.strip()] = v.strip()
            i += 1
        i += 1
    title, pre, rows, cur = None, [], [], None
    for line in lines[i:]:
        if line.startswith("## "):
            head = line[3:]
            m = ANCHOR_RE.search(head)
            label = ANCHOR_RE.sub("", head).strip()
            cur = {"label": label, "body": [],
                   "at": float(m.group(1)) if m else None,
                   "auto": m.group(2) if m else None,
                   "hide": "(hide)" in label.lower(),
                   "flagged": FLAG in label}
            rows.append(cur)
        elif cur is not None:
            cur["body"].append(line)
        elif line.startswith("# ") and title is None:
            title = line[2:].strip()
        else:
            pre.append(line)
    for r in rows:
        r["body"] = "\n".join(r["body"]).strip()
        r["edited"] = r["auto"] is None or body_hash(r["body"]) != r["auto"]
        if r["at"] is None:
            r["at_user"] = parse_time(r["label"])
    return settings, title, "\n".join(pre).strip(), rows


def row_label(at_text, art, _kind):
    return f"{at_text} · {art or '—'}"


def merge(new_rows, old_rows, origin):
    """Combine fresh rows with the user's file. Returns (rows, stats)."""
    stats = {"kept": 0, "flagged": 0, "added": 0}
    # Rows whose anchor comment was lost (some editors strip comments) are
    # matched by the time and articulation in their heading instead.
    for r in old_rows:
        if r["at"] is None and r.get("at_user") is not None:
            r["at"], r["guessed"] = origin + r["at_user"], True
    unmatched_old = [r for r in old_rows if r["at"] is not None]
    out = []
    for nr in new_rows:
        key = nr["art"] or "—"
        best = None
        for orow in unmatched_old:
            okey = orow["label"].split("·", 1)[-1].replace("(hide)", "").replace(FLAG, "").strip()
            tol = MATCH_TOLERANCE + (0.6 if orow.get("guessed") else 0)   # headings round to 1 s
            if okey == key and abs(orow["at"] - nr["at"]) <= tol:
                if best is None or abs(orow["at"] - nr["at"]) < abs(best["at"] - nr["at"]):
                    best = orow
        body = auto_body(nr)
        label = row_label(fmt_time(nr["at"] - origin), nr["art"], nr["kind"])
        entry = {"at": nr["at"], "label": label, "auto": body_hash(body), "body": body,
                 "kind": nr["kind"], "art": nr["art"], "hide": False}
        if best is not None:
            unmatched_old.remove(best)
            entry["hide"] = best["hide"]
            if best["edited"]:
                entry["body"] = best["body"]
                if best["auto"]:             # a lost anchor gets the fresh hash back
                    entry["auto"] = best["auto"]
                stats["kept"] += 1
        else:
            stats["added"] += 1
        out.append(entry)
    for orow in unmatched_old:
        if orow.get("guessed"):          # kept below as the user's own row
            continue
        if orow["edited"]:
            label = orow["label"] if orow["flagged"] else f"{orow['label']} {FLAG}"
            out.append({"at": orow["at"], "label": label, "auto": orow["auto"], "body": orow["body"],
                        "kind": "flagged", "art": None, "hide": orow["hide"]})
            stats["flagged"] += 1
    for orow in old_rows:
        if (orow.get("guessed") and orow in unmatched_old) or orow["at"] is None:
            # user rows: no anchor, timed by their heading
            t = orow.get("at_user")
            orow["at"] = None
            out.append({"at": origin + t if t is not None else float("inf"), "label": orow["label"],
                        "auto": None, "body": orow["body"], "kind": "user", "art": None,
                        "hide": orow["hide"]})
    out.sort(key=lambda r: r["at"])
    for e in out:
        if e["hide"] and "(hide)" not in e["label"]:
            e["label"] += " (hide)"
    return out, stats


def write_markdown(path, settings, title, preamble, rows):
    parts = ["---"] + [f"{k}: {settings[k]}".rstrip() for k in DEFAULTS] + ["---", "", f"# {title}", ""]
    if preamble:
        parts += [preamble, ""]
    for r in rows:
        anchor = f" <!-- at={r['at']:.3f} auto={r['auto']} -->" if r["auto"] else ""
        parts += [f"## {r['label']}{anchor}", r["body"], ""]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts).rstrip() + "\n")


# -----------------------------------------------------------------------------
# 6. HTML
# -----------------------------------------------------------------------------

CSS = """
@page { size: letter portrait; margin: 0.45in 0.5in; }
* { box-sizing: border-box; }
body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; color: #000; margin: 0; }
header { display: flex; justify-content: space-between; align-items: center;
         border-bottom: 3px solid #000; padding-bottom: 4px; }
h1 { font-size: 24pt; margin: 0; letter-spacing: -0.5px; text-transform: uppercase; }
.sub { font-size: 10.5pt; }
.pre { font-size: 11pt; margin: 6px 0 0; }
.pre p { margin: 2px 0; }
.settings { display: flex; gap: 0; margin: 8px 0; border: 1.5px solid #000; }
.settings div { flex: 1; padding: 5px 8px; border-right: 1px solid #000; font-size: 10pt; white-space: nowrap; }
.settings div:last-child { border-right: 0; }
.settings span { font-weight: bold; text-transform: uppercase; letter-spacing: 1px; margin-right: 6px; }
.settings i { font-style: normal; color: #444; font-size: 9pt; margin-right: 3px; }
.settings b { display: inline-block; min-width: 0.55in; border-bottom: 1px solid #000;
              font-size: 11.5pt; margin-right: 8px; text-align: center; }
table { width: 100%; border-collapse: collapse; }
thead { display: table-header-group; }
th { text-align: left; font-size: 8.5pt; text-transform: uppercase; letter-spacing: 1px;
     border-bottom: 1.5px solid #000; padding: 3px 6px; }
tr { break-inside: auto; }
td.body > p, td.body blockquote p { break-inside: avoid; page-break-inside: avoid; }
td.art b { break-after: avoid; }
td { padding: 5px 6px; border-bottom: 1px solid #aaa; vertical-align: top; }
td.body { font-size: 11.5pt; line-height: 1.3; }
td.body blockquote { margin: 0; font-size: 13.5pt; line-height: 1.22; }
td.body blockquote p { margin: 0; }
td.body p { margin: 0; }
td.body > p { background: #e4e4e4; border-left: 5px solid #000; padding: 3px 8px 2px;
              margin: 7px 0; font-size: 12pt; font-weight: bold;
              -webkit-print-color-adjust: exact; print-color-adjust: exact; }
td.body > p:first-child { margin-top: 0; }
.kbw { display: inline-flex; align-items: center; gap: 4px; margin: 3px 14px 1px 0; vertical-align: middle; }
td.body > p > .kbw:first-of-type { margin-left: 14px; }
.kbh { font-size: 8.5pt; font-weight: bold; }
svg.kb { display: block; }
td.body ul { margin: 0; padding-left: 18px; }
td.art { width: 1.25in; white-space: nowrap; padding-top: 6px; }
td.art b { font-size: 17pt; letter-spacing: 0.5px; }
tr.switch td { border-top: 2px solid #000; }
tr.flagged td { background: #f3f3f3; }
.flag { font-size: 9pt; font-weight: bold; }
footer { margin-top: 8px; font-size: 8pt; color: #555; }
.controls { display: flex; gap: 18px; align-items: center; margin: 0 0 10px; padding: 6px 10px;
            border: 1px dashed #888; font-size: 10.5pt; }
.controls b { font-size: 9pt; text-transform: uppercase; letter-spacing: 1px; color: #555; }
.controls label { cursor: pointer; user-select: none; }
body.hide-lyrics td.body blockquote { display: none; }
body.hide-parts td.body > p { display: none; }
body.hide-keys .kbw { display: none; }
tr.empty { display: none; }
@media print { .controls { display: none; } }
"""

# Screen-only toggles: hide lyrics / part notes / keyboards before printing.
# The choice is remembered per song in the browser (localStorage).
TOGGLE_JS = """
(function () {
  var key = "fancy-cheatsheet:" + document.body.dataset.song;
  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(key) || "{}"); } catch (e) {}
  var boxes = document.querySelectorAll(".controls input");
  function apply() {
    var state = {};
    boxes.forEach(function (b) {
      state[b.dataset.part] = b.checked;
      document.body.classList.toggle("hide-" + b.dataset.part, !b.checked);
    });
    document.querySelectorAll("tbody tr").forEach(function (tr) {
      tr.classList.remove("empty");
      if (tr.querySelector("td.art").textContent.trim()) return;
      var shown = Array.prototype.some.call(tr.querySelector("td.body").children, function (el) {
        return getComputedStyle(el).display !== "none";
      });
      tr.classList.toggle("empty", !shown);
    });
    try { localStorage.setItem(key, JSON.stringify(state)); } catch (e) {}
  }
  boxes.forEach(function (b) {
    if (b.dataset.part in saved) b.checked = saved[b.dataset.part];
    b.addEventListener("change", apply);
  });
  apply();
})();
"""


def render_html(path, title, preamble, rows, settings, md_name):
    import markdown as md

    def mdx(text):
        return md.markdown(keyboards_in(text or ""), extensions=["nl2br", "sane_lists"])

    def field(label, value):
        return f"<i>{label}</i><b>{html.escape(str(value or ''))}</b>"

    boxes = (f'<div><span>Key</span>{field("", settings["key"])}</div>'
             f'<div><span>Short</span>{field("", settings["short"])}</div>'
             f'<div><span>Run</span>{field("key", settings["run_key"])}'
             f'{field("dir", settings["run_direction"])}</div>'
             f'<div><span>Gliss</span>{field("dir", settings["gliss_direction"])}</div>'
             f'<div><span>Trill</span>{field("interval", settings["trill_interval"])}</div>')
    # One empty octave in the title bar to fill in a scale by hand; the
    # "scale" setting (e.g. "G A B C D E F#") pre-fills the dots.
    scale = [_key_token(t) for t in re.split(r"[\s,]+", str(settings.get("scale") or "").strip()) if t]
    scale_marks = [60 + k[0] for k in scale if k]
    scale_kb = keyboard_svg(60, 71, scale_marks, False, key_w=18, key_h=40)
    shown = [r for r in rows if not r["hide"]]
    trs, cur, switches = [], None, 0
    for r in shown:
        cls, art_html, art = r["kind"], "", r["art"]
        if r["kind"] == "user" and not art:
            label = r["label"].split("·", 1)[1] if "·" in r["label"] else ""
            art = label.replace("(hide)", "").strip() or None
        if r["kind"] in ("switch", "phrase", "user") and art:
            if art != cur:               # only show the name when it is time to switch
                cls = "switch"
                switches += 1
                art_html = f'<b>{html.escape(art)}</b>'
            cur = art
        flag = f'<div class="flag">{FLAG}</div>' if r["kind"] == "flagged" else ""
        trs.append(f'<tr class="{cls}"><td class="art">{art_html}</td>'
                   f'<td class="body">{flag}{mdx(r["body"])}</td></tr>')

    doc = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{html.escape(title)} — Cheat Sheet</title>
<style>{CSS}</style></head><body data-song="{html.escape(title)}">
<div class="controls"><b>Show</b>
<label><input type="checkbox" data-part="lyrics" checked> Lyrics</label>
<label><input type="checkbox" data-part="parts" checked> Part notes</label>
<label><input type="checkbox" data-part="keys" checked> Keyboards</label>
<span style="color:#666">Print shows what you see; this bar doesn't print.</span></div>
<header><h1>{html.escape(title)}</h1>
{scale_kb}</header>
{f'<div class="pre">{mdx(preamble)}</div>' if preamble else ''}
<div class="settings">{boxes}</div>
<table><thead><tr><th>Switch</th><th>Lyrics · part</th></tr></thead>
<tbody>
{chr(10).join(trs)}
</tbody></table>
<footer>Edit “{html.escape(md_name)}” and run Fancy Cheat Sheet again to update.
Generated {datetime.date.today().isoformat()}.</footer>
<script>{TOGGLE_JS}</script>
</body></html>
"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc)


# -----------------------------------------------------------------------------
# 7. MAIN
# -----------------------------------------------------------------------------

def extend_path():
    """REAPER starts us with a short PATH; add the usual tool folders (for ffmpeg)."""
    parts = os.environ.get("PATH", "").split(os.pathsep)
    for d in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"):
        if d not in parts and os.path.isdir(d):
            parts.append(d)
    os.environ["PATH"] = os.pathsep.join(p for p in parts if p)


def rows_from_markdown(md_rows):
    """Rows for rendering straight from a parsed .md, in file order."""
    rows = []
    for r in md_rows:
        art = r["label"].split("·", 1)[1] if "·" in r["label"] else ""
        art = art.replace("(hide)", "").replace(FLAG, "").strip()
        if r["flagged"]:
            kind = "flagged"
        elif r["at"] is None:
            kind = "user"
        else:
            kind = "phrase"
        rows.append({"label": r["label"], "body": r["body"], "hide": r["hide"], "kind": kind,
                     "art": None if art in ("", "—") else art})
    return rows


def render_only(md_path):
    """Re-render one .md to HTML without touching the project data or the .md."""
    with open(md_path, encoding="utf-8") as f:
        settings, title, preamble, md_rows = parse_markdown(f.read())
    title = title or os.path.splitext(os.path.basename(md_path))[0]
    html_path = os.path.splitext(md_path)[0] + ".html"
    render_html(html_path, title, preamble, rows_from_markdown(md_rows), settings,
                os.path.basename(md_path))
    return html_path


RENDER_COMMAND = "Render Cheat Sheets.command"


def write_render_command(out_dir):
    """A double-clickable file that re-renders every .md in the folder."""
    path = os.path.join(out_dir, RENDER_COMMAND)
    script = ("#!/bin/sh\n"
              "# Fancy Cheat Sheet: re-render every .md in this folder to HTML and open them.\n"
              "# Written by the Fancy Cheat Sheet action; it is replaced on each run.\n"
              'cd "$(dirname "$0")" || exit 1\n'
              f'"{sys.executable}" "{os.path.abspath(__file__)}" --render . --open\n')
    with open(path, "w", encoding="utf-8") as f:
        f.write(script)
    os.chmod(path, 0o755)


def render_cli(target, open_after):
    """--render <file.md | folder>: print what happened, open the sheets if asked."""
    if os.path.isdir(target):
        files = sorted(os.path.join(target, n) for n in os.listdir(target)
                       if n.lower().endswith(".md") and not n.startswith("."))
    else:
        files = [target]
    if not files:
        print("No .md files found.")
        return 1
    failed = 0
    for md_path in files:
        try:
            html_path = render_only(md_path)
            print(f"Rendered {os.path.basename(html_path)}")
            if open_after and sys.platform == "darwin":
                os.system(f'open "{html_path}"')
        except Exception as e:  # keep going with the other files
            failed += 1
            print(f"Could not render {os.path.basename(md_path)}: {type(e).__name__}: {e}")
    return 1 if failed else 0


def run(input_path):
    extend_path()
    with open(input_path, encoding="utf-8") as f:
        data = json.load(f)
    out_dir = data["out_dir"]
    song = data["song"]
    cache_dir = os.path.join(out_dir, ".cache")
    os.makedirs(cache_dir, exist_ok=True)
    status = Status(os.path.join(cache_dir, f"{song}.status"))

    try:
        import markdown  # noqa: F401  (checked early so the user gets one clear message)
    except ImportError:
        raise SheetError("The Python package 'markdown' is not installed.", "missing_deps")
    if not data.get("keyswitches"):
        raise SheetError("No keyswitch names found on the MIDI track.\n\n"
                         "Name the keyswitch notes in the MIDI editor's piano roll "
                         "(e.g. LEG, SHORT) and run again.", "no_keyswitches")

    md_path = os.path.join(out_dir, f"{song}.md")
    html_path = os.path.join(out_dir, f"{song}.html")
    settings, title, preamble, old_rows = DEFAULTS.copy(), song, "", []
    if os.path.isfile(md_path):
        with open(md_path, encoding="utf-8") as f:
            settings, title_found, preamble, old_rows = parse_markdown(f.read())
        title = title_found or song

    lyrics = transcribe(data["audio"], os.path.join(cache_dir, f"{song}.lyrics.json"),
                        data.get("model") or DEFAULT_MODEL, status) if data.get("audio") else []
    ref = load_reference(os.path.join(out_dir, f"{song}.lyrics.txt"))
    matched, heard = None, len(lyrics)
    if ref and lyrics:
        lyrics, matched = apply_reference(lyrics, ref)
    status("Cheat Sheet: building rows…")
    new_rows, _ = build_rows(data, lyrics, settings)
    rows, stats = merge(new_rows, old_rows, data["origin"])
    write_markdown(md_path, settings, title, preamble, rows)

    render_html(html_path, title, preamble, rows, settings, os.path.basename(md_path))
    write_render_command(out_dir)

    warnings = []
    if stats["flagged"]:
        warnings.append(f"{stats['flagged']} edited row(s) no longer match the MIDI and are marked ⚠ — check them.")
    if not lyrics:
        warnings.append("No lyrics were found in the audio.")
    elif matched is not None and matched < heard:
        warnings.append(f"{heard - matched} of {heard} lines heard in the recording are not in "
                        f"{song}.lyrics.txt and were left out (spoken lines or misheard noise).")
    if len([r for r in rows if not r["hide"]]) > 60:
        warnings.append("This sheet has many rows and may run past 3 pages. "
                        "Raise phrase_gap at the top of the .md to merge rows.")
    return {"ok": True, "html": html_path, "md": md_path, "rows": len(rows),
            "switches": sum(1 for r in rows if r["kind"] == "switch"),
            "lyrics_matched": matched, "lyrics_heard": heard,
            "edited_kept": stats["kept"], "flagged": stats["flagged"], "added": stats["added"],
            "warnings": warnings}


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--render":
        return render_cli(sys.argv[2], "--open" in sys.argv[3:])
    if len(sys.argv) not in (2, 3):
        print("usage: fancy_cheatsheet.py <input.json> [log file]\n"
              "       fancy_cheatsheet.py --render <file.md | folder> [--open]", file=sys.stderr)
        return 2
    input_path = sys.argv[1]
    if len(sys.argv) == 3:   # REAPER launches us without a console: log to a file
        log = open(sys.argv[2], "w", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = log
    result_path = re.sub(r"\.input\.json$", "", input_path) + ".result.json"
    try:
        result = run(input_path)
    except SheetError as e:
        result = {"ok": False, "code": e.code, "error": str(e)}
    except Exception as e:  # report anything else to the user, with a trace in the log
        traceback.print_exc()
        result = {"ok": False, "code": "crash", "error": f"{type(e).__name__}: {e}"}
    result["version"] = VERSION
    write_json(result_path, result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
