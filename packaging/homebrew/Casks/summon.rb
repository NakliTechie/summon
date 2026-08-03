# frozen_string_literal: true

# Homebrew Cask for Summon.
#
# Production: points at a GitHub Release zip (signed + notarized).
# Local test: `SUMMON_CASK_URL=file:///.../Summon.zip brew install --cask --force ./summon.rb`
#
# Tap layout: naklitechie/homebrew-tap → Casks/summon.rb (or Formula for CLI-only).
# First public install waits on notarized artifact; until then use make cask-local.

cask "summon" do
  version "0.3.0"
  # Placeholder — `make cask-local` injects the real sha256 of the local zip.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # Override at install time for local dry-runs:
  #   brew install --cask --force ./summon.rb  with url/sha256 edited by make cask-local
  url "https://github.com/NakliTechie/summon/releases/download/v#{version}/Summon-#{version}.zip"
  name "Summon"
  desc "Sovereign native launcher — no account, no server, no telemetry"
  homepage "https://github.com/NakliTechie/summon"

  depends_on macos: :sonoma

  app "Summon.app"

  # CLI sibling: optional future binary cask or linked from the app bundle.
  # binary "#{appdir}/Summon.app/Contents/MacOS/summon-cli", target: "summon"

  zap trash: [
    "~/Library/Application Support/Summon",
    "~/Library/Preferences/tech.nakli.Summon.plist",
  ]
end
