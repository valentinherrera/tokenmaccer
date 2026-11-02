# Releasing the app edition

How a release is made: `scripts/release.sh` (see its header). This file records what is proven and what is still
open before the first public release, so nobody mistakes a test build for a released update.

## Sparkle feed (B1): parked, signature proven, update not yet proven

Status 2026-11-02, branch `app-distribution`, build 18.

Proven:
- `TM_NOTARIZE=0 scripts/release.sh` ran through for build 18 (14:22) with the production EdDSA key from the
  maintainer's keychain. Output in `dist/test/` (not in git, never upload): `appcast.xml`,
  `TokenMaccer-1.0.0-18.zip`, `TokenMaccer.dmg`, `tokenmaccer.rb`. The script's own checks passed (one
  `sparkle:edSignature`, `sparkle:version` 18, download URL, release notes, signature against `SUPublicEDKey`).
- Checked again by hand with the public key only:
  `xcrun swift scripts/verify_ed_signature.swift <TM_SPARKLE_PUBLIC_KEY> <edSignature> dist/test/TokenMaccer-1.0.0-18.zip`
  prints `ok`; the same zip with one byte appended prints `FAIL` (negative control).

Open (parked, needs the maintainer):
1. Notarized run: `scripts/release.sh` without `TM_NOTARIZE=0` refuses until `scripts/check_hosted_release.sh`
   passes, i.e. `docs/` is on `main` (privacy notice reachable), `supabase db push` and `supabase config push` are
   done for the hosted project. Those are production changes and wait for the maintainer's go.
2. Update N to N+1 with the production signature: install build N, publish (or serve locally) an appcast for
   build N+1, let Sparkle find, download, verify and install it on quit. Not done yet; it needs an app install
   that may be replaced, at an unlocked Mac.
3. Upload of both DMGs, the zip and `appcast.xml` to the GitHub release `vVERSION`: only with the maintainer's go.

Until 1 to 3 are done, the only `appcast.xml` is the test one in `dist/test/`, and the feed URL
(`releases/latest/download/appcast.xml`) has nothing to serve.

## Homebrew

`packaging/homebrew/tokenmaccer.rb` is filled in by `scripts/release.sh`. The tap repository
(`valentinherrera/homebrew-tap`) does not exist yet; the download page shows Homebrew as "Coming soon" and no
install command until it does.
