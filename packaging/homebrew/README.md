# Homebrew formula

`loopworker.rb` is the source of the formula that `brew install nevyn/tap/loopworker` installs. The tap, [nevyn/homebrew-tap](https://github.com/nevyn/homebrew-tap), holds a generated copy at `Formula/loopworker.rb`; edit this file, never the tap's copy, because every release overwrites it. Its `url` and `sha256` are placeholders that `.github/workflows/release.yml` rewrites when a `v*` tag is pushed.

## `TAP_TOKEN`

The release workflow's tap job pushes to another repository, which the workflow's own `GITHUB_TOKEN` cannot. It uses the repository secret `TAP_TOKEN`: a fine-grained personal access token with access to `nevyn/homebrew-tap` only and the repository permission **Contents: Read and write**. When it is missing or expired, the tap job fails while the release itself stays published; set or renew the token and re-run the tap job.

The release also signs the binary with a Developer ID Application certificate and notarizes it,
so Gatekeeper lets it run on hosts where nobody can answer a first-launch prompt. Secrets:
`MACOS_CERT_P12_BASE64` and `MACOS_CERT_PASSWORD` (the certificate as a base64 .p12), and
`MACOS_NOTARY_KEY_P8_BASE64`, `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID` (an App Store
Connect API key for `notarytool`). Run the workflow by hand to build, sign and notarize without
publishing.
