# NAKLITECHIE-PROJECT-STATE — Summon

## Status

**M1 advanced (continuous autopilot)** · C0 · C-spine.  
`make verify` green (58 tests + cli-e2e + lint + removability). HEAD on origin: see `git log -1`.

### Landed this continuous run

- Spine, SchemaGate, journal replay, GRDB stores
- JSC shim + synthetic C0 fixtures
- Filter grammar, S1 search, object→action, apps, calc, snippets
- Clipboard (Maccy privacy types), quicklinks
- Module executor open/reveal/copy; system commands
- LauncherSession + AppKit panel; emoji seed
- Agent UNIX socket protocol (off by default)
- `summon-app` menu-bar host + ⌥Space Carbon hotkey
- CLI expanded (search/calc/snippet/clipboard/quicklink/run)

### Residual M1 (engineering, no Chirag required)

- Menu-item search (Accessibility API)
- Hyperkey / double-tap modifiers
- More Maccy parity (paste-as-plain, ignore lists, pinning UI)
- Packed `.app` / Info.plist / ad-hoc sign dry-run
- Latency + network sovereignty gates
- Real Raycast store extensions on C0 harness

### Needs Chirag (park walls / product)

- Developer ID + notary credentials → release
- Homebrew tap first notarized cask
- L1 Apple Intelligence hardware for real-rung CI
- Hotkey default if ⌥Space conflicts with your setup
- When agent socket is enabled by default in developer settings

## Chunk plan

| 1 C-spine | green |
| 2 C0 | green (synthetic) |
| 3 M1 | **advanced** — residual above |
| 4–7 | not started |

## Log

- 2026-08-03 continuous: C-spine → C0 → C1-core → M1 panel/clipboard/socket/app/system commands. All shipped to `main`.

## Dead ends
*(none)*
