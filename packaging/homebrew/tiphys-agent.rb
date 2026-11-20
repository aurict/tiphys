# Draft Homebrew formula (PLAN K3) for a tap such as aurict/homebrew-tiphys. tools/release.sh renders it into
# release/<version>/packaging/ with the release's checksums. Publishing needs a GitHub tap repository.
class TiphysAgent < Formula
  desc "Control this Mac from the Tiphys Android app over Tailscale"
  homepage "https://github.com/aurict/tiphys"
  version "@VERSION@"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/aurict/tiphys/releases/download/v@VERSION@/tiphys-agent-@VERSION@-darwin-arm64.tar.gz"
      sha256 "@SHA_DARWIN_ARM64@"
    end
    on_intel do
      url "https://github.com/aurict/tiphys/releases/download/v@VERSION@/tiphys-agent-@VERSION@-darwin-x64.tar.gz"
      sha256 "@SHA_DARWIN_X64@"
    end
  end

  def install
    libexec.install Dir["*"]
    (bin/"tiphys-agent").write <<~EOS
      #!/bin/sh
      exec "#{opt_libexec}/node/bin/node" "#{opt_libexec}/dist/cli.js" "$@"
    EOS
  end

  service do
    run [opt_libexec/"node/bin/node", "--max-semi-space-size=1", opt_libexec/"dist/cli.js", "serve"]
    keep_alive true
    environment_variables NODE_ENV: "production"
    log_path var/"log/tiphys-agent.log"
    error_log_path var/"log/tiphys-agent.log"
  end

  def caveats
    <<~EOS
      Set up and pair (Homebrew updates this install; the agent's own self-update stays off):
        tiphys-agent init --detect
        brew services start tiphys-agent
        tailscale serve --bg --https=7443 http://127.0.0.1:7443
        tiphys-agent pair
    EOS
  end

  test do
    assert_match "komutlar", shell_output("#{bin}/tiphys-agent 2>&1", 2)
  end
end
