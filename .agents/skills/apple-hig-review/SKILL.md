---
name: apple-hig-review
description: Review GlassDB macOS SwiftUI UI changes against Apple Human Interface Guidelines before commit, especially split views, sidebars, toolbars, segmented controls, tables, inspectors, resizing, clipping, and clickable target issues.
---

# Apple HIG Review

Use this skill when reviewing GlassDB UI changes, especially before commit.

## Inputs

- Staged diff or changed SwiftUI files.
- Optional screenshot or Computer Use observations.

## Reference

Read `references/apple-hig-checklist.md` when you need the detailed checklist.

## Review Workflow

1. Identify changed UI surfaces: sidebar, detail workspace, top bars, filter bars, grid, SQL editor, inspector, toolbar, dialogs.
2. Check whether native macOS controls are used where they fit. Prefer standard `Picker(.segmented)`, `List`, `Table` or table-like grid behavior, `NavigationSplitView`, toolbar items, and inspector patterns over custom button clusters.
3. Check layout resilience:
   - no clipped text or controls at normal desktop widths
   - controls have visible hit areas matching their actual click targets
   - primary data grids align top-leading and fill the workspace
   - sidebars leave enough room for labels and paths with sensible truncation
   - horizontal overflow is scrollable instead of hidden
4. Check workflow clarity:
   - opening a table is a direct row click
   - Data and SQL modes are obvious and reversible
   - SQL result grids use the same placement model as table grids
   - inspector content does not compete with the primary grid
5. Return a concise verdict.

## Output Format

Return exactly one of:

```text
HIG_REVIEW: PASS
```

or:

```text
HIG_REVIEW: FAIL
- [P1] file:line issue and expected fix
- [P2] file:line issue and expected fix
```

Use `FAIL` only for issues that should block a commit, such as clipped controls, unreliable click targets, accidental centered workspace grids, confusing navigation, or clear native-control regressions.
