#!/usr/bin/env python3
"""Regenerate Sources/SummonCore/Search/EmojiCatalogSeed.swift from GitHub gemoji.

  curl -fsSL https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json -o /tmp/gemoji.json
  python3 scripts/generate-emoji-seed.py /tmp/gemoji.json

Adds colloquial ambiguity aliases (high five, pray/thanks, etc.) on top of
gemoji description + aliases + tags. Skin-tone variants and Flags omitted.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Colloquial / ambiguous search terms not always present in gemoji tags.
EXTRAS: dict[str, list[str]] = {
    "🙌": [
        "high five",
        "highfive",
        "high-five",
        "hands up",
        "raise hands",
        "praise",
        "hooray",
        "yay",
        "celebration hands",
    ],
    "🙏": [
        "pray",
        "prayer",
        "please",
        "thank you",
        "thanks",
        "namaste",
        "high five",  # common misuse of folded hands
        "hope",
        "wish",
        "folded hands",
        "gratitude",
        "amen",
    ],
    "✋": ["high five", "highfive", "stop", "hand", "raised hand", "halt"],
    "🖐️": ["hand", "raised hand", "five", "stop"],
    "🤝": ["deal", "agreement", "shake", "handshake", "partner", "agree"],
    "👋": ["hi", "hello", "bye", "wave", "hey", "goodbye"],
    "✌️": ["peace", "victory", "two", "v sign"],
    "🤞": ["fingers crossed", "luck", "hope", "cross fingers"],
    "🤟": ["love you", "ily", "rock", "i love you"],
    "🤘": ["rock on", "metal", "horns", "rock"],
    "👌": ["ok", "okay", "perfect", "nice"],
    "👍": ["thumbs up", "upvote", "+1", "like", "yes", "approve", "lgtm", "good"],
    "👎": ["thumbs down", "downvote", "-1", "dislike", "no", "reject", "bad"],
    "👊": ["fist bump", "punch", "brofist"],
    "👏": ["clap", "applause", "bravo", "clapping", "congrats"],
    "🫶": ["heart hands", "love", "care"],
    "💪": ["strong", "flex", "muscle", "gym", "workout"],
    "🤦": ["facepalm", "face palm", "duh", "smh"],
    "🤷": ["shrug", "idk", "dunno", "whatever"],
    "🧑‍💻": ["technologist", "coder", "developer", "programmer", "dev"],
    "👩‍💻": ["woman coder", "developer", "programmer", "dev"],
    "👨‍💻": ["man coder", "developer", "programmer", "dev"],
    "😂": ["joy", "lol", "rofl", "tears", "laughing", "haha"],
    "🤣": ["rofl", "lol", "rolling", "laughing"],
    "🔥": ["fire", "lit", "hot", "flame", "on fire"],
    "🚀": ["rocket", "ship", "launch", "deploy"],
    "🐛": ["bug", "debug", "issue", "insect"],
    "💡": ["idea", "lightbulb", "tip"],
    "❤️": ["heart", "love", "red heart", "like"],
    "💔": ["broken heart", "heartbreak"],
    "✅": ["check", "done", "yes", "ok", "complete", "pass"],
    "❌": ["x", "no", "cancel", "wrong", "fail"],
    "⚠️": ["warning", "alert", "caution"],
    "🤔": ["thinking", "hmm", "consider", "ponder"],
    "🫠": ["melting", "dissolve", "embarrassed"],
    "🫡": ["salute", "yes sir", "respect"],
    "🥹": ["holding back tears", "emotional", "proud", "touched"],
    "🤯": ["mind blown", "exploding head", "shocked"],
    "🥳": ["party", "celebrate", "birthday"],
    "🤖": ["robot", "bot", "ai"],
    "💻": ["laptop", "computer", "code", "dev"],
    "⚙️": ["gear", "settings", "config"],
    "🔗": ["link", "url", "href"],
    "🔒": ["lock", "secure", "private", "locked"],
    "🔑": ["key", "password"],
    "📋": ["clipboard", "paste", "copy", "list"],
    "🔍": ["search", "find", "magnify"],
    "📦": ["package", "box", "ship", "npm"],
    "🧪": ["test", "science", "lab", "experiment"],
    "🎯": ["target", "goal", "bullseye", "aim"],
    "✨": ["sparkles", "magic", "shiny", "new"],
    "🎉": ["party", "tada", "celebrate", "confetti"],
    "☕️": ["coffee", "tea", "cafe"],
    "☕": ["coffee", "tea", "cafe"],
    "🗑️": ["trash", "delete", "bin", "garbage"],
    "⏳": ["wait", "loading", "hourglass"],
    "🔄": ["refresh", "reload", "sync"],
    "⭐️": ["star", "favorite", "fav"],
    "⭐": ["star", "favorite", "fav"],
    "⚡️": ["lightning", "zap", "bolt", "fast"],
    "⚡": ["lightning", "zap", "bolt", "fast"],
}

INCLUDE_CATS = {
    "Smileys & Emotion",
    "People & Body",
    "Animals & Nature",
    "Food & Drink",
    "Travel & Places",
    "Activities",
    "Objects",
    "Symbols",
}


def is_skin_variant(e: dict) -> bool:
    g = e.get("emoji") or ""
    return any(ord(c) in range(0x1F3FB, 0x1F400) for c in g)


def plain(g: str) -> str:
    return g.replace("\ufe0f", "").replace("\ufe0e", "")


def kws(e: dict) -> list[str]:
    out: list[str] = []
    desc = e.get("description") or ""
    out.append(desc.lower())
    for a in e.get("aliases") or []:
        out.append(a.replace("_", " ").lower())
    for t in e.get("tags") or []:
        out.append(t.lower())
    for w in re.split(r"[^a-z0-9+]+", desc.lower()):
        if len(w) >= 2:
            out.append(w)
    seen: set[str] = set()
    res: list[str] = []
    for k in out:
        k = k.strip()
        if not k or k in seen:
            continue
        if len(k) == 1 and k not in {"x", "v"}:
            continue
        seen.add(k)
        res.append(k)
    return res


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main() -> int:
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/gemoji.json")
    root = Path(__file__).resolve().parents[1]
    out = root / "Sources/SummonCore/Search/EmojiCatalogSeed.swift"
    data = json.loads(src.read_text(encoding="utf-8"))

    by_glyph: dict[str, dict] = {}
    for e in data:
        if is_skin_variant(e):
            continue
        if (e.get("category") or "") not in INCLUDE_CATS:
            continue
        desc = (e.get("description") or "").lower()
        if "o’clock" in desc or "o'clock" in desc:
            continue
        if "thirty" in desc and "clock" in desc:
            continue
        g = e["emoji"]
        if g in by_glyph:
            continue
        by_glyph[g] = e

    entries: list[tuple[str, str, list[str]]] = []
    for g, e in by_glyph.items():
        name = (e.get("description") or "").strip()
        keys = kws(e)
        for k, v in EXTRAS.items():
            if plain(k) == plain(g):
                for extra in v:
                    el = extra.lower()
                    if el not in keys:
                        keys.append(el)
        keys = keys[:32]
        entries.append((g, name, keys))

    entries.sort(key=lambda x: x[1].lower())

    lines = [
        "// Auto-generated from GitHub gemoji (MIT) + colloquial ambiguity aliases.",
        "// Source: https://github.com/github/gemoji",
        "// Regenerate: python3 scripts/generate-emoji-seed.py /tmp/gemoji.json",
        "// Do not hand-edit bulk rows; add colloquial aliases in EXTRAS in the generator.",
        "",
        "import Foundation",
        "",
        "extension EmojiCatalog {",
        "    /// Compact seed row: glyph, name, search keywords (incl. ambiguities).",
        "    static let seedRows: [(String, String, [String])] = [",
    ]
    for g, name, keys in entries:
        kw = ", ".join(f'"{esc(k)}"' for k in keys)
        lines.append(f'         ("{esc(g)}", "{esc(name)}", [{kw}]),')
    lines += [
        "    ]",
        "",
        "    static var seed: [Entry] {",
        "        seedRows.map { Entry(glyph: $0.0, name: $0.1, keywords: $0.2) }",
        "    }",
        "}",
        "",
    ]
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {out} ({len(entries)} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
