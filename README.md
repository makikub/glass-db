# GlassDB

GlassDB is a SwiftUI macOS database viewer MVP. It currently supports SQLite
files and read-only MySQL connections:

- open or create a sample SQLite database
- connect to a MySQL database with host, port, database, user, and password
- browse tables from a sidebar
- view rows in a read-only grid
- sort, filter, page, count rows, and copy values
- run ad hoc SQL and inspect result sets

## Development

```sh
swift build -c debug
swift test
```

Integration tests can start real MySQL and PostgreSQL containers, load fixture
data, and verify them through `ConnectionSession` using test-only drivers backed
by the native database clients. They are opt-in because they pull Docker images
and create containers:

```sh
GLASSDB_INTEGRATION_DATABASES=1 swift test --disable-sandbox --filter DatabaseIntegrationTests
```

Set `GLASSDB_KEEP_INTEGRATION_CONTAINERS=1` to leave the containers running for
inspection after the test.

The same flow is available as:

```sh
scripts/run-database-integration-tests.sh
```

For local visual checks with the app bundle:

```sh
swift build -c debug
cp .build/arm64-apple-macosx/debug/GlassDB build/GlassDB.app/Contents/MacOS/GlassDB
open build/GlassDB.app
```

## Release

GlassDB ships outside the Mac App Store. The static landing page and Sparkle
appcast live under `docs/` and are deployed to GitHub Pages.

1. Generate the Sparkle EdDSA key once with Sparkle's `generate_keys` tool and
   keep the private key safe. The public key used by the release script is
   stored in `release/sparkle-public-key.txt`; refresh it with
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys -p` if you rotate keys.
2. Build the app icon after replacing or editing `Assets/AppIcon/GlassDBIcon.png`:

   ```sh
   scripts/make-app-icon.sh
   ```

3. Run the release harness:

   ```sh
   GLASSDB_CODESIGN_IDENTITY="Developer ID Application: ..." \
   GLASSDB_NOTARY_PROFILE=glassdb-notary \
   scripts/release.sh 0.1.0 1
   ```

   This packages the app, notarizes it when a notary profile is provided,
   regenerates the Sparkle appcast after the final archive is written, and
   verifies the release.

   For lower-level packaging only:

   ```sh
   GLASSDB_ALLOW_AD_HOC_RELEASE=1 scripts/package-release.sh 0.1.0 1
   ```

   The default feed URL is
   `https://makikub.github.io/glass-db/releases/appcast.xml`. Override it with
   `SPARKLE_FEED_URL` if the Pages URL changes. The script uses ad-hoc signing
   by default, but requires `GLASSDB_ALLOW_AD_HOC_RELEASE=1` to acknowledge a
   local-only smoke archive. For a dummy local smoke check, also set
   `GLASSDB_ALLOW_DUMMY_PUBLIC_KEY=1`. For public distribution, pass
   `GLASSDB_CODESIGN_IDENTITY="Developer ID Application: ..."`. If you have a
   notarytool keychain profile, also pass `GLASSDB_NOTARY_PROFILE=<profile>` to
   notarize and staple the app before the public zip is written.

4. Generate the appcast manually, if you used the lower-level packaging step:

   ```sh
   scripts/update-appcast.sh
   ```

   The script reads the Sparkle private key from Keychain by default. You can
   also pass `SPARKLE_ED_KEY_FILE=/path/to/private-key` or
   `SPARKLE_ED_PRIVATE_KEY=<private-key>` for CI-style signing. The default
   download prefix is `https://makikub.github.io/glass-db/releases/`. Unsigned
   appcasts fail by default; set `GLASSDB_ALLOW_UNSIGNED_APPCAST=1` only for
   local smoke checks.

5. Verify the release artifacts manually, if you used the lower-level steps:

   ```sh
   scripts/verify-release.sh 0.1.0 1
   ```

   This requires a real Sparkle public key, an EdDSA-signed appcast, and a
   non-ad-hoc app signature. Set `GLASSDB_ALLOW_AD_HOC_RELEASE=1` only for local
   smoke checks.

6. Commit the updated files under `docs/releases/`, push `main`, and enable
   GitHub Pages with the GitHub Actions source in repository settings.

Sparkle requires both a code-signed app archive and the EdDSA signature in the
appcast for update archives.

The `Release GlassDB` GitHub Actions workflow can run the public release path on
`macos-26`. Configure these repository secrets before using it:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`: base64-encoded Developer ID
  Application `.p12`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`: password for that `.p12`
- `DEVELOPER_ID_APPLICATION_IDENTITY`: exact codesign identity name, for
  example `Developer ID Application: ...`
- `SPARKLE_ED_PRIVATE_KEY`: exported Sparkle EdDSA private key
- either `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`, or
  `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, and
  `APP_STORE_CONNECT_API_KEY_BASE64`

Check local and GitHub release readiness with:

```sh
scripts/check-release-prereqs.sh
```

You can populate the GitHub secrets without printing secret values by running:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /path/to/sparkle-private-key
DEVELOPER_ID_APPLICATION_CERTIFICATE_PATH=/path/to/cert.p12 \
DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD=... \
SPARKLE_ED_KEY_FILE=/path/to/sparkle-private-key \
APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=... \
scripts/set-github-release-secrets.sh
```

## Repository Guidance

- `AGENTS.md` contains durable instructions for Codex and other agents.
- `.agents/skills/apple-hig-review` contains the repo-scoped HIG review skill.
- `.githooks/pre-commit` runs the HIG review hook for staged SwiftUI and guidance changes.

Enable hooks locally:

```sh
git config core.hooksPath .githooks
```

The HIG hook invokes `codex exec` against staged diffs, which can send repository code to the external Codex service. Set `GLASSDB_SKIP_HIG_REVIEW=1` to skip the hook for an emergency local commit. Set `GLASSDB_HIG_REVIEW_REQUIRED=1` to fail closed when `codex exec` is unavailable.
