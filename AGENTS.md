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
- Tracked hook assets should live in `.githooks` after explicit approval.
