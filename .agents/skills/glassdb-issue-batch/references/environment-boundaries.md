# Environment Boundaries

Classify failures before changing credentials, code, or fixtures.

## Retry With Scoped Elevation

Retry the same command outside the sandbox when it touches:

- macOS Keychain or `gh` keyring credentials;
- Docker daemon sockets or fixed-port fixture containers;
- SwiftPM or Clang caches outside the worktree;
- GUI process enumeration or app launch;
- Developer ID signing, notarytool, stapler, Gatekeeper, or Sparkle verification.

Do not diagnose authentication, fixture, compiler, or signing failure from the sandbox result alone. Keep escalation scoped to the exact command or safe command prefix.

## Real Database Tests

- Run fixed-port MySQL/PostgreSQL fixture projects sequentially.
- Stop only the fixture project owned by the current verification run. Once ownership is proven by the compose project name, stopping that ephemeral fixture does not require a separate confirmation.
- Use `psql -v ON_ERROR_STOP=1` so fixture SQL errors fail the test setup.
- If SwiftPM cannot write its external module cache, rerun the same test with scoped elevation before changing build code.

## Computer Use Isolation

- Enumerate GlassDB PIDs and executable paths before testing.
- Ask before terminating processes because another app instance may hold unsaved changes.
- Use a unique extraction directory and the public app's full path. Recheck the PID path after resetting Computer Use state.
- Keep debug bundles uniquely named. Never use ad-hoc entitlements, a changed bundle identifier, or a copied debug signature as public-release evidence.
- Ask immediately before any destructive context-menu action. Some actions execute without a confirmation dialog.

## Failure Loop

When public verification exposes a defect:

1. Preserve the crash report and exact public version/build evidence.
2. Reproduce with the narrowest release-configuration test when practical.
3. Resume the affected issue's existing dedicated task for implementation. Create no duplicate task. If the defect belongs to no included issue, create one issue and one task after duplicate checks.
4. Fix through a reviewed PR and rerun debug, focused release, and relevant real-DB tests.
5. Read the public appcast, select the next unused patch version and build, and repeat signing, public hash, and Computer Use gates.
6. Keep the broken published artifact intact unless the user explicitly chooses a yank or advisory. Treat security or data-loss risk as an immediate escalation.
