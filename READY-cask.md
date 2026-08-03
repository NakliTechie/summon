# READY-cask — Homebrew cask park wall

**Status:** local template + dry-run path ready. Public cask waits on the first **notarized** GitHub Release zip.

## What exists now

| Artifact | Path |
|---|---|
| Cask template | `packaging/homebrew/Casks/summon.rb` |
| Local install test | `make cask-local` → `packaging/homebrew/test-local-cask.sh` |
| App packager (ad-hoc sign) | `packaging/macos/build-app.sh` → `dist/Summon.app` |
| Bundle id | `tech.nakli.Summon` |

## Unblocked by

1. **Developer ID Application** cert + notary credentials in CI (last in queue per Chirag 2026-08-03).
2. `make release` producing `Summon-<version>.zip`, notarized + stapled.
3. GitHub Release `vX.Y.Z` with that zip.
4. Real `sha256` written into the cask; PR to `NakliTechie/homebrew-tap` (or `naklitechie/homebrew-tap`).

## Local verify (no signing keys)

```bash
make cask-local
# installs ad-hoc Summon.app via a file:// cask into Homebrew
brew uninstall --cask summon   # cleanup
```

## Install line (after first notarized release)

```bash
brew install --cask naklitechie/tap/summon
```
