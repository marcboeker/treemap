cask "treemap" do
  version "0.2.0"
  sha256 "e840270206b8fbf843d38777892bc0eec94893877167b4a37012f1f06d467560"

  url "https://github.com/marcboeker/treemap/releases/download/v#{version}/Treemap-macos.zip"
  name "Treemap"
  desc "Disk usage visualizer that renders folders as a treemap"
  homepage "https://github.com/marcboeker/treemap"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Treemap.app"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Treemap.app"]
  end

  # Quit the running app before Homebrew replaces the bundle on upgrade/uninstall.
  uninstall quit: "one.m8n.treemap"

  zap trash: [
    "~/Library/Preferences/one.m8n.treemap.plist",
  ]
end
