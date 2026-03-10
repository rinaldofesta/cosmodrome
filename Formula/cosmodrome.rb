class Cosmodrome < Formula
  desc "Native macOS terminal emulator for AI agent orchestration"
  homepage "https://github.com/cosmodrome-app/cosmodrome"
  url "https://github.com/cosmodrome-app/cosmodrome/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"

  depends_on :macos
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build",
           "--configuration", "release",
           "--disable-sandbox"

    bin.install ".build/release/CosmodromeApp" => "cosmodrome"
  end

  def caveats
    <<~EOS
      Cosmodrome is a GPU-accelerated terminal emulator for macOS.

      To start Cosmodrome:
        cosmodrome

      To start with MCP server (for AI agent integration):
        cosmodrome --mcp

      Configuration: ~/.config/cosmodrome/config.yml
      Project config: cosmodrome.yml (in project root)
      Themes: ~/.config/cosmodrome/themes/

      For the full .app bundle with proper notifications and Dock icon,
      download the .dmg from the GitHub releases page.
    EOS
  end

  test do
    system "#{bin}/cosmodrome", "--version"
  end
end
