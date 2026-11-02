# Homebrew cask for TokenMaccer. Template: scripts/release.sh fills in @VERSION@ and @SHA256@ (sha256 of
# TokenMaccer-VERSION.dmg) and writes dist/tokenmaccer.rb, which goes to a tap repository as Casks/tokenmaccer.rb
# (the tap does not exist yet; creating it is the maintainer's decision).
cask "tokenmaccer" do
  version "@VERSION@"
  sha256 "@SHA256@"

  # the versioned file of the release, so the checksum stays valid after the next release; the download page links
  # the same DMG under the stable name releases/latest/download/TokenMaccer.dmg
  url "https://github.com/valentinherrera/tokenmaccer/releases/download/v#{version}/TokenMaccer-#{version}.dmg"
  name "TokenMaccer"
  desc "Claude Code token usage in a desktop widget and the menu bar"
  homepage "https://github.com/valentinherrera/tokenmaccer"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle updates the app itself
  auto_updates true
  depends_on macos: ">= :sequoia"

  app "TokenMaccer.app"

  # stop the background collector (SMAppService agent) before the app goes away
  uninstall quit:   "io.github.valentinherrera.tokenmaccer",
            script: {
              executable: "#{appdir}/TokenMaccer.app/Contents/MacOS/TokenMaccer",
              args:       ["--unregister"],
            }

  # --remove-data leaves the leaderboard first (if joined), then deletes Application Support/TokenMaccer; it removes
  # nothing while leaving fails, so that folder (it holds the leaderboard state) is not in the trash list.
  # Not yet run through `brew install/uninstall --zap` (no tap yet): test before the tap goes public.
  zap script: {
        executable: "#{appdir}/TokenMaccer.app/Contents/MacOS/TokenMaccer",
        args:       ["--unregister", "--remove-data"],
      },
      trash:  [
        "~/Library/Group Containers/3KM85F22L8.tokenmaccer",
        "~/Library/Preferences/io.github.valentinherrera.tokenmaccer.plist",
      ]
end
