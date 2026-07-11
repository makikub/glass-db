import Foundation
import Logging
import PostgresNIO

actor PostgreSQLDriver: DatabaseDriver {
    nonisolated var cancellationClosesConnection: Bool { true }
    private static let logger = Logger(label: "GlassDB.PostgreSQLDriver")
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?

    func connect(config: ConnectionConfig) async throws {
        guard config.kind == .postgresql else {
            throw DatabaseError.unsupported(config.kind)
        }
        guard let host = config.host, !host.isEmpty,
              let database = config.database, !database.isEmpty,
              let user = config.user, !user.isEmpty else {
            throw DatabaseError.connectionFailed("PostgreSQL host, database, and user are required.")
        }

        var configuration = PostgresClient.Configuration(
            host: host,
            port: config.port ?? 5432,
            username: user,
            password: config.password,
            database: database,
            tls: .disable
        )
        configuration.options.maximumConnections = 1

        let client = PostgresClient(configuration: configuration)
        let runTask = Task { await client.run() }
        self.client = client
        self.runTask = runTask

        do {
            _ = try await query("SELECT 1 AS connected", limit: nil)
        } catch {
            await disconnect()
            throw DatabaseError.connectionFailed("PostgreSQL connection failed: \(error.localizedDescription)")
        }
    }

    func schemas() async throws -> [SchemaInfo] {
        let result = try await query("""
        SELECT schema_name
        FROM information_schema.schemata
        WHERE schema_name NOT IN ('pg_catalog', 'information_schema')
          AND schema_name NOT LIKE 'pg_toast%'
          AND schema_name NOT LIKE 'pg_temp_%'
        ORDER BY CASE WHEN schema_name = 'public' THEN 0 ELSE 1 END, schema_name
        """, limit: nil)
        return result.rows.compactMap { row in
            row.values["schema_name"].map { SchemaInfo(name: $0.description) }
        }
    }

    func tables(in schema: String) async throws -> [TableInfo] {
        let result = try await query("""
        SELECT table_schema AS schema_name, table_name, table_type
        FROM information_schema.tables
        WHERE table_schema = \(quoteLiteral(schema))
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
        let result = try await query("""
        SELECT
            c.column_name,
            c.data_type,
            c.is_nullable,
            CASE WHEN EXISTS (
                SELECT 1
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                  ON tc.constraint_name = kcu.constraint_name
                 AND tc.constraint_schema = kcu.constraint_schema
                 AND tc.table_schema = kcu.table_schema
                 AND tc.table_name = kcu.table_name
                WHERE tc.constraint_type = 'PRIMARY KEY'
                  AND tc.table_schema = c.table_schema
                  AND tc.table_name = c.table_name
                  AND kcu.column_name = c.column_name
            ) THEN 'PRI' ELSE '' END AS column_key
        FROM information_schema.columns c
        WHERE c.table_schema = \(quoteLiteral(table.schema))
          AND c.table_name = \(quoteLiteral(table.name))
        ORDER BY c.ordinal_position
        """, limit: nil)

        return result.rows.compactMap { row in
            guard let name = row.values["column_name"]?.description else { return nil }
            return ColumnInfo(
                name: name,
                type: row.values["data_type"]?.description ?? "",
                isPrimaryKey: row.values["column_key"]?.description == "PRI",
                isNullable: row.values["is_nullable"]?.description == "YES"
            )
        }
    }

    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        guard Self.isReadOnlyQuery(sql) else { throw DatabaseError.readOnlyViolation }
        guard let client else {
            throw DatabaseError.notConnected
        }

        let rows: [PostgresRow]
        do {
            rows = try await client.withTransaction(logger: Self.logger) { connection in
                let sequence = try await connection.query(
                    PostgresQuery(unsafeSQL: Self.limitedSQL(sql, limit: limit)),
                    logger: Self.logger
                )
                return try await sequence.collect()
            }
        } catch {
            throw classifiedDriverQueryError(driver: "PostgreSQL", error: error)
        }

        guard let first = rows.first else {
            return ResultSet(columns: [], rows: [])
        }
        let firstCells = Array(first)
        let columnNames = Self.uniqueColumnNames(firstCells.map(\.columnName))
        let columns = zip(firstCells, columnNames).map { cell, name in
            ColumnInfo(
                name: name,
                type: String(describing: cell.dataType),
                isPrimaryKey: false,
                isNullable: true
            )
        }
        let resultRows = rows.enumerated().map { index, row in
            let values = Dictionary(uniqueKeysWithValues: zip(row, columnNames).map { cell, name in
                (name, value(from: cell))
            })
            return ResultRow(id: index, values: values)
        }
        return ResultSet(columns: columns, rows: resultRows)
    }

    func execute(_ sql: String) async throws -> Int {
        throw DatabaseError.readOnlyViolation
    }

    func applyMutations(_ statements: [MutationStatement]) async throws {
        guard let client else { throw DatabaseError.notConnected }
        do {
            try await client.withTransaction(logger: Self.logger) { connection in
                for statement in statements {
                    let suffix = statement.kind == .insert ? "" : " RETURNING 1 AS affected"
                    let rows = try await connection.query(PostgresQuery(unsafeSQL: statement.sql + suffix), logger: Self.logger).collect()
                    if statement.kind != .insert && rows.count != 1 {
                        throw DataEditingError.affectedRows(expected: 1, actual: rows.count)
                    }
                }
            }
        } catch let error as DataEditingError { throw error }
        catch {
            let classified = classifiedDriverQueryError(driver: "PostgreSQL", error: error)
            if case .queryFailed(let detail) = classified {
                throw DatabaseError.queryFailed(detail.replacingOccurrences(of: "query failed", with: "mutation batch failed"))
            }
            throw classified
        }
    }

    func disconnect() async {
        runTask?.cancel()
        if let runTask {
            await runTask.value
        }
        runTask = nil
        client = nil
    }

    func cancelCurrentQuery() async { await disconnect() }

    nonisolated func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    nonisolated func mutationLiteral(_ value: DBValue) -> String {
        if case .blob(let data) = value { return "'\\\\x\(data.map { String(format: "%02x", $0) }.joined())'::bytea" }
        return switch value {
        case .null: "NULL"
        case .integer(let value): String(value)
        case .double(let value): value.isFinite ? String(value) : "NULL"
        case .text(let value), .unknown(let value): quoteLiteral(value)
        case .blob: fatalError()
        }
    }

    nonisolated static func isReadOnlyQuery(_ sql: String) -> Bool {
        var remainder = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while remainder.hasPrefix("--") {
            guard let newline = remainder.firstIndex(of: "\n") else { return false }
            remainder = String(remainder[remainder.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard remainder.uppercased().hasPrefix("SELECT") else { return false }
        return !remainder.dropLastIfSemicolon().contains(";")
    }

    nonisolated static func limitedSQL(_ sql: String, limit: Int?) -> String {
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit,
              trimmed.range(of: #"\blimit\b"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            return sql
        }
        if trimmed.hasSuffix(";") {
            trimmed.removeLast()
        }
        return "\(trimmed) LIMIT \(limit)"
    }

    nonisolated static func uniqueColumnNames(_ names: [String]) -> [String] {
        let reservedNames = Set(names)
        var usedNames: Set<String> = []
        var nextSuffix: [String: Int] = [:]
        return names.map { name in
            guard usedNames.contains(name) else {
                usedNames.insert(name)
                nextSuffix[name] = 2
                return name
            }

            var suffix = nextSuffix[name] ?? 2
            var candidate = "\(name)_\(suffix)"
            while reservedNames.contains(candidate) || usedNames.contains(candidate) {
                suffix += 1
                candidate = "\(name)_\(suffix)"
            }
            nextSuffix[name] = suffix + 1
            usedNames.insert(candidate)
            return candidate
        }
    }

    private nonisolated func value(from cell: PostgresCell) -> DBValue {
        guard cell.bytes != nil else { return .null }
        do {
            switch cell.dataType {
            case .int2, .int4, .int8:
                return .integer(try cell.decode(Int64.self))
            case .float4, .float8:
                return .double(try cell.decode(Double.self))
            case .numeric:
                return .text(NSDecimalNumber(decimal: try cell.decode(Decimal.self)).stringValue)
            case .bytea:
                return .blob(try cell.decode(Data.self))
            case .bool:
                return .text(try cell.decode(Bool.self) ? "true" : "false")
            case .uuid:
                return .text(try cell.decode(UUID.self).uuidString.lowercased())
            case .date, .timestamp, .timestamptz:
                return .text(ISO8601DateFormatter().string(from: try cell.decode(Date.self)))
            default:
                return .text(try cell.decode(String.self))
            }
        } catch {
            return .unknown("<\(String(describing: cell.dataType))>")
        }
    }
}

private extension String {
    func dropLastIfSemicolon() -> Substring {
        hasSuffix(";") ? dropLast() : self[...]
    }
}
