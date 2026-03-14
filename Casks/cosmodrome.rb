cask "cosmodrome" do
  version "0.2.0"
  sha256 "4e58468dd0e2b73080e16c0947f692a35864f42a79d57efabef392497f98b2b7"

  url "https://github.com/rinaldofesta/cosmodrome/releases/download/v#{version}/Cosmodrome.dmg"
  name "Cosmodrome"
  desc "Native macOS terminal for developers running multiple AI agents in parallel"
  homepage "https://github.com/rinaldofesta/cosmodrome"

  depends_on macos: ">= :sonoma"

  app "Cosmodrome.app"

  binary "#{appdir}/Cosmodrome.app/Contents/MacOS/cosmoctl", target: "cosmoctl"

  zap trash: [
    "~/Library/Application Support/Cosmodrome",
    "~/Library/Preferences/com.cosmodrome.terminal.plist",
  ]
end
