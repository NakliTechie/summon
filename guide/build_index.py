#!/usr/bin/env python3
"""Build guide/index.html from the captured screenshots + authored captions.

Single self-contained file, themed from Summon's own design tokens, with inline
search. The source of truth is the CAPTIONS/SECTIONS data below — edit here and
rerun regenerate.sh. Never hand-edit index.html; it is regenerated output.
"""
import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
UX = ROOT / "docs" / "summon-ux-reference-006.html"
OUT = ROOT / "guide" / "index.html"

# slug -> (title, one-line "what this screen is")
CAPTIONS = {
    "launcher-fuzzy": (
        "Launcher & results",
        "⌥Space opens the bar — type to fuzzy-match apps, files, calculator, unit "
        "conversion, snippets, emoji and more. ↑↓ to navigate, ↩ to run, ⌘K for actions.",
    ),
    "alttab": (
        "Alt-tab switcher",
        "A launcher-native window switcher — running apps, filtered as you type, "
        "focused with a keystroke.",
    ),
    "launcher-staged": (
        "Answer vs. action — staged",
        "Ask the on-device AI to do something ('make a snippet', 'set the volume to "
        "30') and it stages in amber for you to Accept or Reject. Summon never "
        "auto-runs an AI action, and never claims it did one it only proposed.",
    ),
    "ai-ladder": (
        "The AI ladder",
        "Summon detects the best available on-device model — Apple Foundation Models "
        "first — and states the rung honestly. It is detected, never configured.",
    ),
    "quickfix": (
        "Quick Fix — rewrite in place",
        "Hand selected text to the on-device model; the rewrite is staged for review "
        "before it replaces anything.",
    ),
    "launcher-degraded": (
        "Degraded, still working",
        "With no AI model available, search still works; the strip says so plainly, "
        "and AI returns the moment a rung is detected.",
    ),
    "clipboard": (
        "Clipboard history",
        "⌥⇧C opens local clipboard history — text, images, HTML and RTF, all on this "
        "Mac, with an ignore list for sensitive apps.",
    ),
    "launcher-empty": (
        "First run — the empty state",
        "A brand-new, zero-data Summon: the bar is ready before you've added anything, "
        "so nothing feels broken on day one.",
    ),
    "states-gallery": (
        "Empty · error · degraded",
        "The honest state gallery — how Summon looks when there is nothing to show, "
        "something failed, or the AI is unavailable.",
    ),
    "agent-face": (
        "The agent face — CLI + socket",
        "The same core behind a second door: a local CLI and a default-off UNIX "
        "socket. Every mutating action is journaled with actor= and staged for review, "
        "never auto-applied.",
    ),
    "ext-permissions": (
        "Extension permissions",
        "Every extension capability is an explicit, reviewable grant — no ambient "
        "access. (Extensions are a development surface, not shipped in v0.6.)",
    ),
    "design-tokens": (
        "Design language",
        "The dark-glass palette, accent, and type scale the whole app is built from — "
        "the same tokens theme this guide.",
    ),
}

# ordered feature groups: (id, title, intro, [slugs])
SECTIONS = [
    ("launcher", "Launcher", "The compact ⌥Space bar and its results — the front door.",
     ["launcher-fuzzy", "alttab"]),
    ("ai", "On-device AI",
     "Answers on your Mac; actions staged for one-click Accept, never auto-run. A "
     "question can be answered on-device or by searching the web — a keyless "
     "Wikipedia floor, or your own SearXNG — and only your query ever leaves.",
     ["launcher-staged", "ai-ladder", "quickfix", "launcher-degraded"]),
    ("clipboard", "Clipboard", "Local clipboard history, private by default.",
     ["clipboard"]),
    ("firstrun", "First run & states",
     "What a new user sees, and how Summon stays honest when there is nothing — or "
     "something is wrong.",
     ["launcher-empty", "states-gallery"]),
    ("extend", "Extend & automate",
     "The agent face, and the (deferred) extension surface.",
     ["agent-face", "ext-permissions"]),
    ("design", "Design", "The tokens the product — and this guide — are built from.",
     ["design-tokens"]),
]

STATIC_CSS = """
*{box-sizing:border-box}
body{margin:0;background:var(--bg-glass);color:var(--text);
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.wrap{max-width:1080px;margin:0 auto;padding:0 24px}
header{padding:56px 0 28px;border-bottom:1px solid var(--hairline)}
header h1{margin:0;font-size:40px;font-weight:700;letter-spacing:-.02em;
  background:linear-gradient(92deg,var(--text),var(--accent));
  -webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
header .tag{margin:10px 0 0;color:var(--dim);font-size:16px;max-width:60ch}
header .install{margin-top:20px;display:inline-block;background:var(--surface);
  border:1px solid var(--hairline);border-radius:10px;padding:10px 14px;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13.5px;color:var(--text)}
header .note{margin-top:10px;color:var(--dim);font-size:12.5px}
.searchbar{position:sticky;top:0;z-index:5;background:var(--bg-glass);
  padding:16px 0;border-bottom:1px solid var(--hairline)}
#q{width:100%;background:var(--surface);border:1px solid var(--hairline);border-radius:10px;
  color:var(--text);padding:12px 14px;font-size:15px;outline:none}
#q:focus{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
.searchbar .hint{color:var(--doc-faint);font-size:12px;margin-top:6px}
.toc{display:flex;flex-wrap:wrap;gap:8px;padding:18px 0 4px}
.toc a{background:var(--surface);border:1px solid var(--hairline);border-radius:999px;
  padding:6px 12px;font-size:12.5px;color:var(--dim)}
.toc a:hover{color:var(--text);border-color:var(--accent);text-decoration:none}
.group{padding:30px 0;border-bottom:1px solid var(--hairline)}
.group h2{margin:0 0 6px;font-size:22px;font-weight:650;letter-spacing:-.01em}
.group .intro{margin:0 0 20px;color:var(--dim);max-width:72ch}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:20px}
.card{margin:0;background:var(--surface);border:1px solid var(--hairline);border-radius:14px;
  overflow:hidden;box-shadow:0 1px 0 rgba(255,255,255,.02),0 10px 30px rgba(0,0,0,.35)}
.card img{display:block;width:100%;height:auto;background:var(--raised);
  border-bottom:1px solid var(--hairline)}
.card figcaption{padding:14px 16px 16px}
.card h3{margin:0 0 6px;font-size:15px;font-weight:640}
.card p{margin:0;color:var(--dim);font-size:13px;line-height:1.5}
.hidden{display:none!important}
.nomatch{color:var(--dim);padding:40px 0;text-align:center}
footer{padding:34px 0 60px;color:var(--doc-faint);font-size:12.5px}
footer code{font-family:ui-monospace,Menlo,monospace;color:var(--dim)}
"""

SEARCH_JS = """
const q=document.getElementById('q');
const cards=[...document.querySelectorAll('.card')];
const groups=[...document.querySelectorAll('.group')];
const none=document.getElementById('nomatch');
function apply(){
  const t=q.value.trim().toLowerCase();
  let shown=0;
  cards.forEach(c=>{const hit=!t||c.dataset.search.includes(t);
    c.classList.toggle('hidden',!hit); if(hit)shown++;});
  groups.forEach(g=>{const any=[...g.querySelectorAll('.card')].some(c=>!c.classList.contains('hidden'));
    g.classList.toggle('hidden',!any);});
  none.hidden=shown>0;
}
q.addEventListener('input',apply);
document.addEventListener('keydown',e=>{
  if(e.key==='/'&&document.activeElement!==q){e.preventDefault();q.focus();}
  else if(e.key==='Escape'&&document.activeElement===q){q.value='';apply();q.blur();}
});
"""


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def card(slug: str) -> str:
    title, desc = CAPTIONS[slug]
    search = f"{title} {desc} {slug}".lower()
    return (
        f'<figure class="card" data-search="{esc(search)}">'
        f'<img loading="lazy" src="screenshots/{slug}.png" alt="{esc(title)}">'
        f'<figcaption><h3>{esc(title)}</h3><p>{esc(desc)}</p></figcaption></figure>'
    )


def main() -> None:
    root_vars = ""
    if UX.exists():
        match = re.search(r":root\{([^}]*)\}", UX.read_text())
        root_vars = match.group(1) if match else ""
    css = ":root{" + root_vars + "}" + STATIC_CSS

    toc = "".join(f'<a href="#{sid}">{esc(title)}</a>' for sid, title, _, _ in SECTIONS)
    groups = ""
    total = 0
    for sid, title, intro, slugs in SECTIONS:
        total += len(slugs)
        cards = "".join(card(s) for s in slugs)
        groups += (
            f'<section id="{sid}" class="group"><h2>{esc(title)}</h2>'
            f'<p class="intro">{esc(intro)}</p><div class="grid">{cards}</div></section>'
        )

    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Summon — Guide</title>
<style>{css}</style></head>
<body>
<div class="wrap">
<header>
  <h1>Summon</h1>
  <p class="tag">A field guide to the sovereign macOS launcher — every screen, captioned. Local-first, on-device AI, no account or telemetry.</p>
  <code class="install">brew install --cask naklitechie/tap/summon</code>
  <p class="note">Drawn from the product's UX reference. Type <b>/</b> to search, <b>Esc</b> to clear.</p>
</header>
<div class="searchbar">
  <input id="q" type="search" placeholder="Search features — try “clipboard”, “staged”, “volume”…" autocomplete="off" spellcheck="false">
  <div class="hint">Filters live across every screen below.</div>
</div>
<nav class="toc">{toc}</nav>
<main>{groups}<p id="nomatch" class="nomatch" hidden>No matching screens.</p></main>
<footer>
  Generated from <code>docs/summon-ux-reference-006.html</code> · edit
  <code>guide/build_index.py</code> + <code>guide/capture.py</code> and run
  <code>guide/regenerate.sh</code> — never hand-edit this file. ·
  <a href="https://github.com/NakliTechie/summon">github.com/NakliTechie/summon</a>
</footer>
</div>
<script>{SEARCH_JS}</script>
</body></html>
"""
    OUT.write_text(page)
    print(f"build: {total} screens across {len(SECTIONS)} sections -> {OUT}")


if __name__ == "__main__":
    main()
