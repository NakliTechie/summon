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
OUT = ROOT / "guide" / "screenshots"

# (slug, nav section data-s, launcher sub-mode data-m or None)
ROUTE_PLAN = [
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


def main() -> None:
    if not UX.exists():
        print(f"capture: UX reference missing at {UX}", file=sys.stderr)
        sys.exit(1)
    OUT.mkdir(parents=True, exist_ok=True)
    log: list[str] = []
    ok = 0
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(
            viewport={"width": 1400, "height": 900}, device_scale_factor=2
        )
        page.goto(UX.as_uri())
        page.wait_for_load_state("load")
        page.evaluate("() => document.fonts && document.fonts.ready")
        for slug, section, mode in ROUTE_PLAN:
            page.click(f'nav button[data-s="{section}"]')
            if mode:
                page.click(f'.tg[data-m="{mode}"]')
            page.wait_for_timeout(280)
            html_len = page.evaluate(
                "() => { const s = document.querySelector('section.on');"
                " return s ? s.innerHTML.length : 0; }"
            )
            dest = OUT / f"{slug}.png"
            page.locator("section.on").screenshot(path=str(dest))
            status = "ok" if html_len > 50 else "empty"
            ok += 1 if status == "ok" else 0
            log.append(
                f"- {slug}: {status} (section=#{section}, mode={mode or '-'}, html_len={html_len})"
            )
        browser.close()
    (ROOT / "guide" / "CAPTURE-LOG.md").write_text(
        "# Capture log\n\n"
        f"{ok}/{len(ROUTE_PLAN)} screens captured ok "
        "(source: docs/summon-ux-reference-006.html)\n\n" + "\n".join(log) + "\n"
    )
    print(f"capture: {ok}/{len(ROUTE_PLAN)} ok -> {OUT}")


if __name__ == "__main__":
    main()
