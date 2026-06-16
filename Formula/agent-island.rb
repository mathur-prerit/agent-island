# Homebrew formula — builds from source on the user's machine, so there is NO
# code-signing, notarization, Apple ID, or Gatekeeper warning involved.
#
# Use via a tap (no Apple ID needed):
#   brew tap mathur-prerit/agent-island https://github.com/mathur-prerit/agent-island
#   brew install --HEAD agent-island
#   agent-island        # launches the menu-bar widget
#
# (Until a versioned release is tagged, install with --HEAD to build from main.)
class AgentIsland < Formula
  desc "Quiet, quirky macOS status island for Claude Code agents"
  homepage "https://github.com/mathur-prerit/agent-island"
  head "https://github.com/mathur-prerit/agent-island.git", branch: "main"
  license "MIT"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--product", "AgentIslandApp", "--disable-sandbox"
    bin.install ".build/release/AgentIslandApp" => "agent-island"
  end

  test do
    assert_predicate bin/"agent-island", :exist?
  end
end
