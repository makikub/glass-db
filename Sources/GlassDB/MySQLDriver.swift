import Foundation
import MySQLNIO
import NIOCore
import NIOPosix

actor MySQLDriver: DatabaseDriver {
    private var connection: MySQLConnection?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var databaseName = ""

    func connect(config: ConnectionConfig) async throws {
        guard config.kind == .mysql else {
            throw DatabaseError.unsupported(config.kind)
        }
        guard let host = config.host, !host.isEmpty,
              let database = config.database, !database.isEmpty,
              let user = config.user, !user.isEmpty else {
            throw DatabaseError.connectionFailed("MySQL host, database, and user are required.")
        }

        let port = config.port ?? 3306
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
            connection = try await MySQLConnection.connect(
                to: address,
                username: user,
                database: database,
                password: config.password,
                tlsConfiguration: nil,
                on: group.next()
            ).get()
            eventLoopGroup = group
            databaseName = database
        } catch {
            try? await group.shutdownGracefully()
            throw DatabaseError.connectionFailed("MySQL connection failed: \(error)")
        }
    }

    func schemas() async throws -> [SchemaInfo] {
        _ = try requireConnection()
        return [SchemaInfo(name: databaseName)]
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
            guard let name = value(in: row, named: "table_name")?.description,
                  let rawType = value(in: row, named: "table_type")?.description else {
                return nil
            }
            return TableInfo(
                schema: value(in: row, named: "schema_name")?.description ?? schema,
                name: name,
                kind: rawType == "VIEW" ? .view : .table
            )
        }
    }

    func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let result = try await query("""
        SELECT column_name, data_type, is_nullable, column_key
        FROM information_schema.columns
        WHERE table_schema = \(quoteLiteral(table.schema))
          AND table_name = \(quoteLiteral(table.name))
        ORDER BY ordinal_position
        """, limit: nil)

        return result.rows.compactMap { row in
            guard let name = value(in: row, named: "column_name")?.description else {
                return nil
            }
            return ColumnInfo(
                name: name,
                type: value(in: row, named: "data_type")?.description ?? "",
                isPrimaryKey: value(in: row, named: "column_key")?.description == "PRI",
                isNullable: value(in: row, named: "is_nullable")?.description == "YES"
            )
        }
    }

    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        let connection = try requireConnection()
        let rows: [MySQLRow]
        do {
            rows = try await connection.simpleQuery(limitedSQL(sql, limit: limit)).get()
        } catch {
            throw DatabaseError.queryFailed("MySQL query failed: \(error)")
        }

        guard let firstRow = rows.first else {
            return ResultSet(columns: [], rows: [])
        }

        let columnNames = firstRow.columnDefinitions.map(\.name)
        let columns = firstRow.columnDefinitions.map { definition in
            ColumnInfo(
                name: definition.name,
                type: String(describing: definition.columnType),
                isPrimaryKey: false,
                isNullable: true
            )
        }
        let resultRows = rows.enumerated().map { index, row in
            let values = Dictionary(uniqueKeysWithValues: columnNames.map { name in
                (name, value(from: row.column(name)))
            })
            return ResultRow(id: index, values: values)
        }
        return ResultSet(columns: columns, rows: resultRows)
    }

    func execute(_ sql: String) async throws -> Int {
        let connection = try requireConnection()
        do {
            _ = try await connection.simpleQuery(sql).get()
            let countRows = try await connection.simpleQuery("SELECT ROW_COUNT() AS affected_rows").get()
            return countRows.first?.column("affected_rows")?.int.map { Int($0) } ?? 0
        } catch {
            throw DatabaseError.queryFailed("MySQL statement failed: \(error)")
        }
    }

    func disconnect() async {
        if let connection {
            try? await connection.close().get()
            self.connection = nil
        }
        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
            self.eventLoopGroup = nil
        }
        databaseName = ""
    }

    nonisolated func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    nonisolated func mutationLiteral(_ value: DBValue) -> String {
        if case .text(let text) = value { return "'\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''"))'" }
        if case .unknown(let text) = value { return "'\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''"))'" }
        switch value {
        case .null: return "NULL"
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .blob(let data): return "X'\(data.map { String(format: "%02x", $0) }.joined())'"
        case .text, .unknown: fatalError()
        }
    }

    private func requireConnection() throws -> MySQLConnection {
        guard let connection else {
            throw DatabaseError.notConnected
        }
        return connection
    }

    private func value(from data: MySQLData?) -> DBValue {
        guard let data, let buffer = data.buffer else {
            return .null
        }
        if let int = data.int64 {
            return .integer(int)
        }
        if let double = data.double {
            return .double(double)
        }
        if let string = data.string {
            return .text(string)
        }
        return .blob(Data(buffer.readableBytesView))
    }

    private func value(in row: ResultRow, named name: String) -> DBValue? {
        if let value = row.values[name] {
            return value
        }
        return row.values.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
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
}
