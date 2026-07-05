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

## Repository Guidance

- `AGENTS.md` contains durable instructions for Codex and other agents.
- `.agents/skills/apple-hig-review` contains the repo-scoped HIG review skill.
- `.githooks/pre-commit` runs the HIG review hook for staged SwiftUI and guidance changes.

Enable hooks locally:

```sh
git config core.hooksPath .githooks
```

The HIG hook invokes `codex exec` against staged diffs, which can send repository code to the external Codex service. Set `GLASSDB_SKIP_HIG_REVIEW=1` to skip the hook for an emergency local commit. Set `GLASSDB_HIG_REVIEW_REQUIRED=1` to fail closed when `codex exec` is unavailable.
