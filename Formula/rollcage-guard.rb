class RollcageGuard < Formula
  desc "Stops AI coding agents from reading secrets, leaking keys and running destructive commands"
  homepage "https://github.com/nmaties/rollcage-guard"
  url "https://github.com/nmaties/rollcage-guard/releases/download/v1.0.0/rollcage-guard-macos.tar.gz"
  sha256 "fbe3d61165e867c527e829baa8e5b8de4417ea119b9759d60ad04bc44dc0ad68"
  license "MIT"

  depends_on :macos

  def install
    bin.install "rollcage-guard"
  end

  def caveats
    <<~EOS
      Add the hook to Claude Code, Codex, Cursor and Gemini CLI:
        rollcage-guard install
      Before uninstalling, remove it again:
        rollcage-guard uninstall
    EOS
  end

  test do
    assert_match "block", shell_output("#{bin}/rollcage-guard explain 'cat .env'")
  end
end
