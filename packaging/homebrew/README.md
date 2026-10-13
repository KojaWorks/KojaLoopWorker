# Homebrew formula

`loopworker.rb` is the source of the formula that `brew install nevyn/tap/loopworker` installs. The tap, [nevyn/homebrew-tap](https://github.com/nevyn/homebrew-tap), holds a generated copy at `Formula/loopworker.rb`; edit this file, never the tap's copy, because every release overwrites it. Its `url` and `sha256` are placeholders that `.github/workflows/release.yml` rewrites when a `v*` tag is pushed.

## `TAP_TOKEN`

The release workflow's tap job pushes to another repository, which the workflow's own `GITHUB_TOKEN` cannot. It uses the repository secret `TAP_TOKEN`: a fine-grained personal access token with access to `nevyn/homebrew-tap` only and the repository permission **Contents: Read and write**. When it is missing or expired, the tap job fails while the release itself stays published; set or renew the token and re-run the tap job.
