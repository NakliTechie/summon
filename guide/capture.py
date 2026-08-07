#!/usr/bin/env python3
"""Capture Summon's drawn product into guide/screenshots/.

Summon is a native macOS launcher — it has no browsable web surface and its
LSUIElement panel can't be pixel-driven. Its authoritative visual is the UX
reference mockup (docs/summon-ux-reference-006.html, "the drawn product"), a
self-contained HTML file whose <section>s are the app's screens. We screenshot
those. Edit ROUTE_PLAN here + CAPTIONS in build_index.py, then regenerate — never
hand-edit guide/index.html.
"""
import pathlib
import sys

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
UX = ROOT / "docs" / "summon-ux-reference-006.html"
SUPPLEMENT = ROOT / "guide" / "supplement.html"
OUT = ROOT / "guide" / "screenshots"

# The drawn product (docs/summon-ux-reference-006.html), rev 006.
# (slug, nav section data-s, launcher sub-mode data-m or None)
UX_ROUTES = [
    ("launcher-fuzzy", "launcher", "fuzzy"),
    ("launcher-staged", "launcher", "staged"),
    ("launcher-degraded", "launcher", "degraded"),
    ("launcher-empty", "launcher", "empty"),
    ("quickfix", "quickfix", None),
    ("alttab", "alttab", None),
    ("clipboard", "clipboard", None),
    ("ai-ladder", "ladder", None),
    ("ext-permissions", "perms", None),
    ("states-gallery", "states", None),
    ("design-tokens", "tokens", None),
    ("agent-face", "agent", None),
]

# Guide-owned mockups for features shipped after the rev-006 reference
# (web search, staged mutating actions, search preferences). Same tokens/classes.
SUPPLEMENT_ROUTES = [
    ("web-search", "websearch", None),
    ("staged-volume", "volume", None),
    ("search-preferences", "prefs", None),
]


def walk(page, source, routes, log):
    """Walk one HTML source's route-plan, screenshotting each active section."""
    page.goto(source.as_uri())
    page.wait_for_load_state("load")
    page.evaluate("() => document.fonts && document.fonts.ready")
    ok = 0
    for slug, section, mode in routes:
        page.click(f'nav button[data-s="{section}"]')
        if mode:
            page.click(f'.tg[data-m="{mode}"]')
        page.wait_for_timeout(280)
        html_len = page.evaluate(
            "() => { const s = document.querySelector('section.on');"
            " return s ? s.innerHTML.length : 0; }"
        )
        page.locator("section.on").screenshot(path=str(OUT / f"{slug}.png"))
        status = "ok" if html_len > 50 else "empty"
        ok += 1 if status == "ok" else 0
        log.append(
            f"- {slug}: {status} ({source.name}#{section}, mode={mode or '-'}, "
            f"html_len={html_len})"
        )
    return ok


def main() -> None:
    for path in (UX, SUPPLEMENT):
        if not path.exists():
            print(f"capture: source missing at {path}", file=sys.stderr)
            sys.exit(1)
    OUT.mkdir(parents=True, exist_ok=True)
    log: list[str] = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(
            viewport={"width": 1400, "height": 900}, device_scale_factor=2
        )
        ok = walk(page, UX, UX_ROUTES, log)
        ok += walk(page, SUPPLEMENT, SUPPLEMENT_ROUTES, log)
        browser.close()
    total = len(UX_ROUTES) + len(SUPPLEMENT_ROUTES)
    (ROOT / "guide" / "CAPTURE-LOG.md").write_text(
        "# Capture log\n\n"
        f"{ok}/{total} screens captured ok "
        "(sources: docs/summon-ux-reference-006.html + guide/supplement.html)\n\n"
        + "\n".join(log) + "\n"
    )
    print(f"capture: {ok}/{total} ok -> {OUT}")


if __name__ == "__main__":
    main()
