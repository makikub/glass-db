import Foundation
import Testing
@testable import GlassDB

private let databaseIntegrationEnabled = ProcessInfo.processInfo.environment["GLASSDB_INTEGRATION_DATABASES"] == "1"

@Suite(.serialized)
struct DatabaseIntegrationTests {
    @Test
    func sqliteFixtureExercisesDriverAndSession() async throws {
        let root = ProjectPaths.root
        let fixture = root.appending(path: "Tests/Fixtures/sqlite.sql")
        let path = FileManager.default.temporaryDirectory
            .appending(path: "GlassDBIntegration-\(UUID().uuidString).sqlite")
            .path
        let driver = SQLiteDriver()
        try await driver.connect(config: ConnectionConfig(name: "SQLite fixture", kind: .sqlite, filePath: path))
        defer {
            Task { await driver.disconnect() }
            try? FileManager.default.removeItem(atPath: path)
        }

        _ = try await driver.execute(String(contentsOf: fixture, encoding: .utf8))

        let session = ConnectionSession(driver: driver)
        let tables = try await session.tables(in: "main")
        #expect(tables.map(\.name) == ["projects"])

        let table = TableRef(schema: "main", name: "projects")
        let columns = try await session.columns(of: table)
        #expect(columns.map(\.name) == ["id", "name", "status", "owner", "updated_at"])
        #expect(columns.first?.isPrimaryKey == true)

        let activeRows = try await session.rows(
            in: table,
            pageSize: 10,
            page: 0,
            sort: SortState(column: "id", direction: .ascending),
            filter: FilterState(column: "status", op: .equals, value: "active")
        )
        #expect(activeRows.rows.map { $0.values["name"] } == [.text("GlassDB MVP"), .text("Read-only grid")])

        let count = try await session.rowCount(in: table, filter: nil)
        #expect(count == 3)
    }

    @Test(
        "Docker MySQL fixture driver answers queries",
        .enabled(if: databaseIntegrationEnabled, "Set GLASSDB_INTEGRATION_DATABASES=1 to run Docker-backed database tests.")
    )
    func dockerMySQLFixtureDriverAnswersQueries() async throws {
        try await withDockerFixture(projectName: "glassdb-integration-tests-mysql-cli") { docker in
            try loadMySQLFixture(using: docker)

            let mysqlDriver = DockerSQLDriver(docker: docker, service: "mysql", dialect: .mysql)
            try await mysqlDriver.connect(config: ConnectionConfig(
                name: "MySQL fixture",
                kind: .mysql,
                host: "127.0.0.1",
                port: 33076,
                database: "glassdb",
                user: "glassdb"
            ))
            try await assertProjectsFixture(using: mysqlDriver, schema: "glassdb")
        }
    }

    @Test(
        "Production MySQL driver answers queries",
        .enabled(if: databaseIntegrationEnabled, "Set GLASSDB_INTEGRATION_DATABASES=1 to run Docker-backed database tests.")
    )
    func productionMySQLDriverAnswersQueries() async throws {
        try await withDockerFixture(projectName: "glassdb-integration-tests-mysql-driver") { docker in
            try loadMySQLFixture(using: docker)

            let productionMySQLDriver = MySQLDriver()
            try await productionMySQLDriver.connect(config: ConnectionConfig(
                name: "MySQL fixture",
                kind: .mysql,
                host: "127.0.0.1",
                port: 33076,
                database: "glassdb",
                user: "glassdb",
                password: "glassdb"
            ))
            defer {
                Task { await productionMySQLDriver.disconnect() }
            }
            try await assertProjectsFixture(using: productionMySQLDriver, schema: "glassdb")
        }
    }

    @Test(
        "Docker PostgreSQL fixture driver answers queries",
        .enabled(if: databaseIntegrationEnabled, "Set GLASSDB_INTEGRATION_DATABASES=1 to run Docker-backed database tests.")
    )
    func dockerPostgreSQLFixtureDriverAnswersQueries() async throws {
        try await withDockerFixture(projectName: "glassdb-integration-tests-postgres-cli") { docker in
            try loadPostgreSQLFixture(using: docker)

            let postgresDriver = DockerSQLDriver(docker: docker, service: "postgres", dialect: .postgresql)
            try await postgresDriver.connect(config: ConnectionConfig(
                name: "PostgreSQL fixture",
                kind: .postgresql,
                host: "127.0.0.1",
                port: 54376,
                database: "glassdb",
                user: "glassdb"
            ))
            try await assertProjectsFixture(using: postgresDriver, schema: "public")
        }
    }

    @Test(
        "Production PostgreSQL driver answers read-only queries",
        .enabled(if: databaseIntegrationEnabled, "Set GLASSDB_INTEGRATION_DATABASES=1 to run Docker-backed database tests.")
    )
    func productionPostgreSQLDriverAnswersQueries() async throws {
        try await withDockerFixture(projectName: "glassdb-integration-tests-postgres-driver") { docker in
            try loadPostgreSQLFixture(using: docker)

            let driver = PostgreSQLDriver()
            try await driver.connect(config: ConnectionConfig(
                name: "PostgreSQL fixture",
                kind: .postgresql,
                host: "127.0.0.1",
                port: 54376,
                database: "glassdb",
                user: "glassdb",
                password: "glassdb"
            ))
            defer { Task { await driver.disconnect() } }

            let schemas = try await driver.schemas()
            #expect(schemas.first == SchemaInfo(name: "public"))
            #expect(schemas.contains(SchemaInfo(name: "analytics")))
            try await assertProjectsFixture(using: driver, schema: "public")

            let publicObjects = try await driver.tables(in: "public")
            #expect(publicObjects.contains(TableInfo(schema: "public", name: "projects", kind: .table)))
            #expect(publicObjects.contains(TableInfo(schema: "public", name: "active_projects", kind: .view)))
            let analyticsObjects = try await driver.tables(in: "analytics")
            #expect(analyticsObjects == [TableInfo(schema: "analytics", name: "project_statuses", kind: .view)])

            let readOnlySetting = try await driver.query("SELECT current_setting('default_transaction_read_only') AS read_only", limit: nil)
            #expect(readOnlySetting.rows.first?.values["read_only"] == .text("on"))
            _ = try await driver.query("SELECT set_config('default_transaction_read_only', 'off', false)", limit: nil)
            let forcedReadOnlySetting = try await driver.query("SELECT current_setting('transaction_read_only') AS read_only", limit: nil)
            #expect(forcedReadOnlySetting.rows.first?.values["read_only"] == .text("on"))

            let typed = try await driver.query("""
            SELECT
                42::bigint AS integer_value,
                1.5::double precision AS double_value,
                12.340::numeric AS numeric_value,
                true AS bool_value,
                '550e8400-e29b-41d4-a716-446655440000'::uuid AS uuid_value,
                decode('00ff', 'hex') AS blob_value,
                DATE '2026-07-02' AS date_value,
                TIMESTAMP '2026-07-02 03:04:05' AS timestamp_value,
                TIMESTAMPTZ '2026-07-02 03:04:05+00' AS timestamptz_value,
                NULL::text AS null_value
            """, limit: nil)
            let values = try #require(typed.rows.first?.values)
            #expect(values["integer_value"] == .integer(42))
            #expect(values["double_value"] == .double(1.5))
            #expect(values["numeric_value"] == .text("12.34"))
            #expect(values["bool_value"] == .text("true"))
            #expect(values["uuid_value"] == .text("550e8400-e29b-41d4-a716-446655440000"))
            #expect(values["blob_value"] == .blob(Data([0x00, 0xff])))
            #expect(values["date_value"] == .text("2026-07-02T00:00:00Z"))
            #expect(values["timestamp_value"] == .text("2026-07-02T03:04:05Z"))
            #expect(values["timestamptz_value"] == .text("2026-07-02T03:04:05Z"))
            #expect(values["null_value"] == .null)

            let duplicated = try await driver.query("SELECT id AS duplicate, id AS duplicate FROM public.projects ORDER BY id", limit: nil)
            #expect(duplicated.columns.map(\.name) == ["duplicate", "duplicate_2"])
            #expect(duplicated.rows.first?.values["duplicate"] == .integer(1))
            #expect(duplicated.rows.first?.values["duplicate_2"] == .integer(1))

            let collisionColumns = try await driver.columns(of: TableRef(schema: "public", name: "primary_key_collision_source"))
            #expect(collisionColumns.first { $0.name == "id" }?.isPrimaryKey == true)
            #expect(collisionColumns.first { $0.name == "collision_value" }?.isPrimaryKey == false)

            let explicitlyLimited = try await driver.query("SELECT id\nFROM public.projects\nLIMIT 2", limit: 1000)
            #expect(explicitlyLimited.rows.map { $0.values["id"] } == [.integer(1), .integer(2)])

            do {
                _ = try await driver.query("DELETE FROM public.projects", limit: nil)
                Issue.record("PostgreSQL query unexpectedly allowed a write")
            } catch let error as DatabaseError {
                #expect(error.errorDescription?.contains("read-only") == true)
            }
            let countAfterRejectedWrite = try await driver.query("SELECT COUNT(*) AS count FROM public.projects", limit: nil)
            #expect(countAfterRejectedWrite.rows.first?.values["count"] == .integer(3))
        }
    }

    private func withDockerFixture(
        projectName: String,
        _ body: (DockerCompose) async throws -> Void
    ) async throws {
        let docker = DockerCompose(projectName: projectName, root: ProjectPaths.root)
        try? docker.down(removeVolumes: true)
        try docker.up()
        defer {
            if ProcessInfo.processInfo.environment["GLASSDB_KEEP_INTEGRATION_CONTAINERS"] != "1" {
                try? docker.down(removeVolumes: true)
            }
        }
        try await body(docker)
    }

    private func loadMySQLFixture(using docker: DockerCompose) throws {
        _ = try docker.exec(service: "mysql", arguments: [
            "sh", "-c", "mysql -uglassdb -pglassdb glassdb < /fixtures/mysql.sql"
        ])
    }

    private func loadPostgreSQLFixture(using docker: DockerCompose) throws {
        _ = try docker.exec(service: "postgres", arguments: [
            "psql", "-U", "glassdb", "-d", "glassdb", "-f", "/fixtures/postgres.sql"
        ])
    }

    private func assertProjectsFixture(using driver: some DatabaseDriver, schema: String) async throws {
        let session = ConnectionSession(driver: driver)
        let tables = try await session.tables(in: schema)
        #expect(tables.contains(TableInfo(schema: schema, name: "projects", kind: .table)))

        let table = TableRef(schema: schema, name: "projects")
        let columns = try await session.columns(of: table)
        #expect(columns.map(\.name) == ["id", "name", "status", "owner", "updated_at"])
        #expect(columns.first?.isPrimaryKey == true)
        #expect(columns.first?.isNullable == false)
        #expect(columns.first { $0.name == "owner" }?.isNullable == true)

        let allRows = try await session.query("SELECT name, status FROM projects ORDER BY id", limit: nil)
        #expect(allRows.rows.map { $0.values["name"] } == [
            .text("GlassDB MVP"),
            .text("Driver abstraction"),
            .text("Read-only grid"),
        ])
        #expect(allRows.rows.map { $0.values["status"] } == [.text("active"), .text("planned"), .text("active")])

        let activeRows = try await session.rows(
            in: table,
            pageSize: 10,
            page: 0,
            sort: SortState(column: "id", direction: .ascending),
            filter: FilterState(column: "status", op: .equals, value: "active")
        )
        #expect(activeRows.rows.map { $0.values["name"] } == [.text("GlassDB MVP"), .text("Read-only grid")])

        let count = try await session.rowCount(in: table, filter: nil)
        #expect(count == 3)
    }
}

private actor DockerSQLDriver: DatabaseDriver {
    enum Dialect {
        case mysql
        case postgresql
    }

    private let docker: DockerCompose
    private let service: String
    private let dialect: Dialect
    private var isConnected = false

    init(docker: DockerCompose, service: String, dialect: Dialect) {
        self.docker = docker
        self.service = service
        self.dialect = dialect
    }

    func connect(config: ConnectionConfig) async throws {
        switch (dialect, config.kind) {
        case (.mysql, .mysql), (.postgresql, .postgresql):
            isConnected = true
            _ = try await query("SELECT 1 AS connected", limit: nil)
        case (.mysql, _):
            throw DatabaseError.unsupported(config.kind)
        case (.postgresql, _):
            throw DatabaseError.unsupported(config.kind)
        }
    }

    func schemas() async throws -> [SchemaInfo] {
        try requireConnection()
        switch dialect {
        case .mysql:
            return [SchemaInfo(name: "glassdb")]
        case .postgresql:
            return [SchemaInfo(name: "public")]
        }
    }

    func tables(in schema: String) async throws -> [TableInfo] {
        try requireConnection()
        let result = try await query("""
        SELECT table_schema AS schema_name, table_name AS table_name, table_type AS table_type
        FROM information_schema.tables
        WHERE table_schema = '\(schema)'
          AND table_name NOT LIKE 'sqlite_%'
          AND table_type IN ('BASE TABLE', 'VIEW')
        ORDER BY table_type, table_name
        """, limit: nil)

        return result.rows.compactMap { row in
            guard let name = row.values["table_name"]?.description,
                  let rawType = row.values["table_type"]?.description else {
                return nil
            }
            return TableInfo(
                schema: row.values["schema_name"]?.description ?? schema,
                name: name,
                kind: rawType == "VIEW" ? .view : .table
            )
        }
    }

    func columns(of table: TableRef) async throws -> [ColumnInfo] {
        try requireConnection()
        let keyExpression: String
        switch dialect {
        case .mysql:
            keyExpression = "column_key"
        case .postgresql:
            keyExpression = """
            CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM information_schema.table_constraints tc
                    JOIN information_schema.key_column_usage kcu
                      ON tc.constraint_name = kcu.constraint_name
                     AND tc.table_schema = kcu.table_schema
                    WHERE tc.constraint_type = 'PRIMARY KEY'
                      AND tc.table_schema = c.table_schema
                      AND tc.table_name = c.table_name
                      AND kcu.column_name = c.column_name
                ) THEN 'PRI'
                ELSE ''
            END
            """
        }

        let result = try await query("""
        SELECT
            column_name AS column_name,
            data_type AS data_type,
            is_nullable AS is_nullable,
            \(keyExpression) AS column_key
        FROM information_schema.columns c
        WHERE table_schema = '\(table.schema)' AND table_name = '\(table.name)'
        ORDER BY ordinal_position
        """, limit: nil)

        return result.rows.compactMap { row in
            guard let name = row.values["column_name"]?.description else {
                return nil
            }
            return ColumnInfo(
                name: name,
                type: row.values["data_type"]?.description ?? "",
                isPrimaryKey: row.values["column_key"]?.description == "PRI",
                isNullable: row.values["is_nullable"]?.description == "YES"
            )
        }
    }

    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        try requireConnection()
        let finalSQL = limitedSQL(sql, limit: limit)
        let output: CommandOutput
        switch dialect {
        case .mysql:
            output = try docker.exec(service: service, arguments: [
                "mysql", "-uglassdb", "-pglassdb", "--batch", "--raw", "glassdb",
                "--execute", finalSQL,
            ])
        case .postgresql:
            output = try docker.exec(service: service, arguments: [
                "psql", "-U", "glassdb", "-d", "glassdb", "-A",
                "-F", "\t", "-P", "footer=off", "-P", "null=NULL",
                "-c", finalSQL,
            ])
        }
        return parseTabSeparatedResult(output.stdout)
    }

    func execute(_ sql: String) async throws -> Int {
        try requireConnection()
        switch dialect {
        case .mysql:
            _ = try docker.exec(service: service, arguments: [
                "mysql", "-uglassdb", "-pglassdb", "glassdb", "--execute", sql,
            ])
        case .postgresql:
            _ = try docker.exec(service: service, arguments: [
                "psql", "-U", "glassdb", "-d", "glassdb", "-c", sql,
            ])
        }
        return 0
    }

    func disconnect() async {
        isConnected = false
    }

    nonisolated func quoteIdentifier(_ identifier: String) -> String {
        switch dialect {
        case .mysql:
            return "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
        case .postgresql:
            return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    private func requireConnection() throws {
        guard isConnected else {
            throw DatabaseError.notConnected
        }
    }

    private func limitedSQL(_ sql: String, limit: Int?) -> String {
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit,
              trimmed.uppercased().hasPrefix("SELECT"),
              !trimmed.localizedCaseInsensitiveContains(" limit ") else {
            return sql
        }
        if trimmed.hasSuffix(";") {
            trimmed.removeLast()
        }
        return "\(trimmed) LIMIT \(limit)"
    }

    private func parseTabSeparatedResult(_ stdout: String) -> ResultSet {
        var lines = stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else {
            return ResultSet(columns: [], rows: [])
        }

        let names = lines.removeFirst().components(separatedBy: "\t")
        let columns = names.map { ColumnInfo(name: $0, type: "", isPrimaryKey: false, isNullable: true) }
        let rows = lines.enumerated().map { index, line in
            let values = line.components(separatedBy: "\t")
            let pairs = zip(names, values).map { name, value in
                (name, dbValue(from: value))
            }
            return ResultRow(id: index, values: Dictionary(uniqueKeysWithValues: pairs))
        }
        return ResultSet(columns: columns, rows: rows)
    }

    private func dbValue(from value: String) -> DBValue {
        if value == "NULL" {
            return .null
        }
        if let integer = Int64(value) {
            return .integer(integer)
        }
        if let double = Double(value) {
            return .double(double)
        }
        return .text(value)
    }
}

private enum ProjectPaths {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct DockerCompose {
    let projectName: String
    let root: URL
    let command: DockerComposeCommand

    init(projectName: String, root: URL, command: DockerComposeCommand = .resolved) {
        self.projectName = projectName
        self.root = root
        self.command = command
    }

    func up() throws {
        _ = try runDockerCompose(arguments: ["up", "-d", "--wait"])
    }

    func down(removeVolumes: Bool) throws {
        var arguments = ["down"]
        if removeVolumes {
            arguments.append("-v")
        }
        _ = try runDockerCompose(arguments: arguments)
    }

    func exec(service: String, arguments: [String]) throws -> CommandOutput {
        try runDockerCompose(arguments: ["exec", "-T", service] + arguments)
    }

    private func runDockerCompose(arguments: [String]) throws -> CommandOutput {
        return try Command.run(
            executable: command.executable,
            arguments: command.arguments + [
                "-p", projectName,
                "-f", "Tests/Fixtures/docker-compose.yml",
            ] + arguments,
            currentDirectory: root
        )
    }
}

private struct DockerComposeCommand: Sendable {
    let executable: String
    let arguments: [String]

    static var resolved: DockerComposeCommand {
        let fileManager = FileManager.default
        let pathCandidates = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map { String($0) + "/docker" }
        let dockerCandidates = pathCandidates + [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
        ]
        if let docker = dockerCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return DockerComposeCommand(executable: docker, arguments: ["compose"])
        }

        let composePlugin = "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-compose"
        if fileManager.isExecutableFile(atPath: composePlugin) {
            return DockerComposeCommand(executable: composePlugin, arguments: [])
        }
        return DockerComposeCommand(executable: "/usr/bin/env", arguments: ["docker", "compose"])
    }
}

private enum Command {
    static func run(executable: String, arguments: [String], currentDirectory: URL) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = CommandOutput(
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
        guard process.terminationStatus == 0 else {
            throw CommandError(
                command: ([executable] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}

private struct CommandOutput: Sendable {
    let stdout: String
    let stderr: String

    var lines: [String] {
        stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}

private struct CommandError: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let output: CommandOutput

    var description: String {
        """
        Command failed with status \(status): \(command)
        stdout:
        \(output.stdout)
        stderr:
        \(output.stderr)
        """
    }
}
