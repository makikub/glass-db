# Batch Release Gates

Perform this phase only in the management thread after the chosen issues are merged.

1. Confirm every included issue has a merge SHA and a complete Sol handoff.
2. Confirm the notary profile outside the sandbox before building anything:

   ```bash
   xcrun notarytool history --keychain-profile glassdb-notary
   ```

   Treat a sandbox-only failure as inconclusive. If the elevated check fails, inspect existing profiles before considering re-registration. Never replace credentials or pass secrets through chat/tool arguments. Re-register only with explicit user direction and a safe local prompt.
3. Run the local release path only: `scripts/release.sh <version> <build>`, then commit and push `docs/releases` to `main`, then verify Pages. Do not substitute GitHub Actions as the build path.
4. Run codesign verification, Sparkle component Team ID checks, notarization, stapling, Gatekeeper, and release verification sequentially outside the sandbox to avoid `securityd`/Keychain contention.
5. Compare public appcast and zip data to local artifacts, including SHA-256.
6. Expand the public zip to a unique directory under `/private/tmp`. Enumerate running GlassDB processes and retain evidence that Computer Use controls that exact unmodified Developer ID-signed app. Do not change its bundle identifier.
7. Confirm every included issue's user-visible flow. Ask before terminating existing apps or clicking a destructive menu item; do not assume the UI presents a second confirmation.
8. If public validation finds a defect, route implementation back to the existing dedicated task for the affected included issue. Resume that task instead of creating another one. If no included issue owns the defect, file one issue and create exactly one dedicated task after the normal duplicate search.
9. Fix the defect through a reviewed PR. Read the public appcast, choose the next unused patch version and next build number, release again, and repeat every public gate. Do not overwrite an already published version/build.
10. Publish the corrected higher version before considering removal of the broken appcast entry. Do not yank a published artifact or issue an advisory without explicit user direction; escalate immediately when the defect risks data loss or security.
11. Close included issues and complete their dedicated goals only after every release gate passes.

For query lifecycle, cancellation, timeout, or concurrency changes, require `swift test -c release --filter <affected-test-suite-or-case>` before release. Add a deterministic stress or repetition case when the failure is lifetime-sensitive. A debug-only test pass is insufficient.

For debug-only Computer Use, use a uniquely named bundle and full path. Do not use an ad-hoc debug signature or debug-only entitlements as public-release evidence.
