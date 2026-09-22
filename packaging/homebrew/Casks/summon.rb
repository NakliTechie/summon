# frozen_string_literal: true

# Homebrew Cask for Summon — sovereign native macOS launcher.
#
# v0.6.x ships UNSIGNED (ad-hoc, no Apple Developer ID). The postflight clears the
# download quarantine so `brew install --cask` yields a launchable app; the caveats
# disclose that it is not Apple-notarized. A notarized build replaces this once a
# Developer ID is in place.
#
# Tap: naklitechie/homebrew-tap → Casks/summon.rb
#   brew install --cask naklitechie/tap/summon
#
# Local dry-run: `make cask-local` injects a file:// url + the local zip's sha256.

cask "summon" do
  version "0.8.0"
  sha256 "7d4b4a0bb2f73aa51a62f18df5f590d6f0d5469ea00c7d119733a1d330fc623a"

  url "https://github.com/NakliTechie/summon/releases/download/v#{version}/Summon-#{version}.zip"
  name "Summon"
  desc "Sovereign native launcher — no account, no server, no telemetry"
  homepage "https://github.com/NakliTechie/summon"

  depends_on macos: :sonoma

  app "Summon.app"

  # This build is ad-hoc signed, not notarized: clear the download quarantine so
  # the app launches without a Gatekeeper block. Remove once a notarized build
  # ships. Declarative form (Homebrew 7 `brew style` rejects the legacy
  # `postflight do … end`); `{{appdir}}` is an install-time token, not Ruby.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Summon.app"]
  end

  caveats <<~EOS
    Summon #{version} is ad-hoc signed, not Apple-notarized. It is safe to run, but
    macOS cannot verify the developer. If macOS still blocks it, open it once with
    right-click → Open, or run:
      xattr -dr com.apple.quarantine "#{appdir}/Summon.app"
  EOS

  zap trash: [
    "~/Library/Application Support/Summon",
    "~/Library/Preferences/tech.nakli.Summon.plist",
  ]
end
