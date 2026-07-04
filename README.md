# GlassDB

GlassDB is a SwiftUI macOS database viewer MVP. It currently focuses on SQLite:

- open or create a sample SQLite database
- browse tables from a sidebar
- view rows in a read-only grid
- sort, filter, page, count rows, and copy values
- run ad hoc SQL and inspect result sets

## Development

```sh
swift build -c debug
swift test
```

For local visual checks with the app bundle:

```sh
swift build -c debug
cp .build/arm64-apple-macosx/debug/GlassDB build/GlassDB.app/Contents/MacOS/GlassDB
open build/GlassDB.app
```

## Repository Guidance

- `AGENTS.md` contains durable instructions for Codex and other agents.
- `.agents/skills/apple-hig-review` contains the repo-scoped HIG review skill.
- Before committing UI changes, use `$apple-hig-review` or an approved HIG review hook.

The planned pre-commit hook can invoke `codex exec` against staged diffs. Because that can send repository code to the external Codex service, enable it only after explicit approval.
