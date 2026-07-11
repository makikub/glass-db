# GlassDB Agent Instructions

## Communication

- If the request is ambiguous, ask before making broad changes.
- Keep reports concise and honest. Avoid decorative phrasing.
- For UI work, verify with a running debug build when practical.

## Product Direction

- GlassDB is a macOS-native database viewer for developers.
- Prefer quiet, utilitarian, scan-friendly layouts over marketing-style composition.
- Use macOS-standard controls before custom controls, especially for segmented controls, tables, sidebars, toolbars, inspectors, and forms.
- Treat the table/grid as the primary workspace. It should start at the top-leading edge of the content area and should not look like a centered preview card.

## Apple HIG Review

- Before committing UI changes, run the repository HIG review or manually invoke `$apple-hig-review`.
- Check changed SwiftUI views against Apple HIG component intent:
  - split views: sidebar for navigation, detail for primary work
  - toolbars and top bars: grouped controls, clear hierarchy, no crowded hit targets
  - segmented controls: use native segmented controls for view switching
  - lists and tables: readable, selectable, scan-friendly data presentation
  - layout: resilient to resizing, no clipped controls, no accidental overlap
- If the UI is hard to click, clipped, unexpectedly centered, or relies on custom controls where native controls fit, fix that before commit.

## Build And Test

- Build debug app: `swift build -c debug`
- Test: `swift test`
- Local app bundle used for visual checks: copy `.build/arm64-apple-macosx/debug/GlassDB` to `build/GlassDB.app/Contents/MacOS/GlassDB`, then open `build/GlassDB.app`.

## Git

- Commit messages must include what changed and why.
- Keep generated build artifacts out of commits.
- Tracked hook assets live in `.githooks`.
- The HIG pre-commit hook may send staged diffs to `codex exec` for external review. Use it only where that export is acceptable.
- Enable hooks with `git config core.hooksPath .githooks`.

## GitHub CLI In Codex

- In Codex sandboxed commands, `gh` may report the GitHub token as invalid because the sandbox cannot read the macOS Keychain. This is not caused by a worktree.
- For `gh auth status` and any CLI-based GitHub PR, issue, or Actions operation, request scoped elevated execution first. Confirm `gh auth status` succeeds there before concluding authentication is broken.
- Do not run `gh auth login`, replace credentials, or alter `GH_CONFIG_DIR` based only on a sandboxed failure. Prefer the GitHub connector for ordinary metadata reads.
- Project-local rules allow `gh auth status` and read-only PR/issue/run inspection outside the sandbox. Keep GitHub mutations approval-gated.

## Codex Environment Boundaries

- Treat sandbox failures involving the macOS Keychain, Docker socket, SwiftPM/Clang caches, GUI process inspection, codesign, notarization, stapling, or Gatekeeper as environment failures until the same command is retried with scoped elevated execution.
- Run Docker-backed integration tests sequentially because the fixtures use fixed ports. Load PostgreSQL fixtures with `psql -v ON_ERROR_STOP=1`.
- For query lifecycle, cancellation, or concurrency changes, run the focused tests in release configuration in addition to the normal debug build and test suite.
- Use `$glassdb-issue-batch` for release sequencing, public artifact isolation, Computer Use evidence, and issue/goal completion gates.
