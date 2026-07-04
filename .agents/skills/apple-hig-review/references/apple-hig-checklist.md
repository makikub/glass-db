# GlassDB Apple HIG Checklist

Official Apple HIG pages to consult when available:

- Split views: https://developer.apple.com/design/human-interface-guidelines/split-views
- Toolbars: https://developer.apple.com/design/human-interface-guidelines/toolbars
- Lists and tables: https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
- Segmented controls: https://developer.apple.com/design/human-interface-guidelines/segmented-controls
- Layout: https://developer.apple.com/design/human-interface-guidelines/layout
- Designing for macOS: https://developer.apple.com/design/human-interface-guidelines/designing-for-macos

## GlassDB Blocking Checks

- Sidebar navigation:
  - The leading split pane is for database/table navigation.
  - Table rows are easy to click and show selection state.
  - Long database paths use middle truncation instead of clipping important ends.

- Workspace header:
  - Data/SQL switching uses a standard segmented control unless there is a strong reason not to.
  - The visible button/segment area matches the actual click target.
  - The current table or SQL context is visible without crowded labels.

- Table and SQL result grids:
  - Grids start at the top-leading edge of the content area.
  - Grids do not appear as centered preview cards.
  - Horizontal overflow is scrollable.
  - Cell text is scannable; long content can truncate because the inspector shows full values.

- Filter and action controls:
  - Controls are not clipped at common window widths.
  - Buttons use standard control sizing.
  - Controls that overflow horizontally remain reachable.

- Inspector:
  - Inspector is secondary; it should not dominate the primary grid.
  - Column metadata and selected cell details are readable and grouped.

## Suggested Evidence

- `swift build -c debug`
- `swift test`
- Computer Use or screenshot pass covering:
  - Create Sample
  - open `projects`
  - switch Data/SQL
  - run SQL
  - return to Data
