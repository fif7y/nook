# Release runbook (M7)

The pipeline is `scripts/release.sh` (same steps as `.github/workflows/release.yml`).
Everything below the one-time setup is: bump version → run script → publish.

## One-time setup (on the dev Mac)

1. **Developer ID Application certificate** — currently the blocker; the keychain
   has none. In Xcode → Settings → Accounts → team `YW9UY68SQ7` → Manage
   Certificates → “+” → Developer ID Application (needs Account Holder role, or
   create at developer.apple.com/account/resources/certificates). Verify:
   `security find-identity -v -p codesigning` lists `Developer ID Application: …`.

2. **Notary credentials** — create an App Store Connect API key (Developer role
   is enough), then store it once:

   ```sh
   xcrun notarytool store-credentials nook-notary \
     --key ~/Downloads/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
   ```

3. **Sparkle EdDSA keys** — after the first build fetches Sparkle via SPM:

   ```sh
   # find the tools in DerivedData
   find ~/Library/Developer/Xcode/DerivedData -path '*Sparkle/bin/generate_keys' -print -quit
   <that path>          # generates keys, stores private key in login keychain
   ```

   It prints the **public** key: paste it into `project.yml` as `SUPublicEDKey`
   (replacing the `REPLACE_WITH_…` placeholder) and re-run `xcodegen`. The
   updater code (`SparkleController`) stays disabled until this placeholder is
   replaced, so dev builds are unaffected either way.

   Back up the private key: `generate_keys -x sparkle_private_key` → store it
   somewhere safe (it is the only thing that can sign updates; losing it
   strands existing installs).

4. **Appcast hosting** — `SUFeedURL` is `https://fif7y.github.io/nook/appcast.xml`:
   enable GitHub Pages on the repo (branch `gh-pages`, root). The appcast file
   gets pushed there each release; DMGs are attached to GitHub Releases (the
   appcast’s enclosure URLs point at `github.com/fif7y/nook/releases/download/…`).

## Per-release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION` — Sparkle compares
   `CFBundleVersion`, so it must strictly increase) in `project.yml`.
2. `scripts/release.sh` — archives, exports with Developer ID, notarizes +
   staples app and DMG, writes `build/releases/Nook-<v>.dmg` + `appcast.xml`.
3. Tag and publish: create GitHub release `v<version>` with the DMG attached.
4. Push `appcast.xml` (and `*.delta` files if any) to `gh-pages`.
5. Sanity: install the previous DMG, let Sparkle offer the new version, update.

`SKIP_NOTARIZE=1 scripts/release.sh` smoke-tests the archive/export/DMG half
without credentials.

## CI

`.github/workflows/release.yml` runs the same pipeline on `v*` tags, but needs a
runner image with the macOS 27 SDK — until GitHub ships one, release locally.
Secrets it expects are listed at the top of the workflow file.
