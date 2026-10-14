class Loopworker < Formula
  desc "Claims cards from a backlog and runs one claude worker per card"
  homepage "https://github.com/KojaWorks/KojaLoopWorker"
  url "https://github.com/KojaWorks/KojaLoopWorker/releases/download/v0.0.0/loopworker-0.0.0-macos-universal.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  depends_on macos: :sonoma
  depends_on "tmux"

  def install
    bin.install "loopworker"
    doc.install "licenses"
  end

  # `loopworker service install` gives a stop more time (ExitTimeOut 180) than launchd's
  # default, so force-stop can release in-flight cards. Prefer it to `brew services`.
  service do
    run [opt_bin/"loopworker", "run"]
    keep_alive successful_exit: false
    restart_delay 30
    process_type :background
    log_path var/"log/loopworker.log"
    error_log_path var/"log/loopworker.log"
    environment_variables PATH: std_service_path_env
  end

  def caveats
    <<~EOS
      Put the host config in ~/.loopworker/config.toml and the backend tokens in
      ~/.loopworker/secrets.env (NAME=value lines, mode 600: chmod 600 ~/.loopworker/secrets.env).
      Then check the host:
        loopworker doctor

      Workers need the claude CLI on PATH (Claude Code), and git-lfs for repos that use Git LFS.

      Run the Manager as a launchd service with:
        loopworker service install
      On a host where nobody logs in, make it a LaunchDaemon instead:
        loopworker service install --daemon
      Use either that or `brew services`, not both: a second Manager can't take the lock.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/loopworker --version")
  end
end
