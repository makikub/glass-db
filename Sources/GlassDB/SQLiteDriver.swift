import Foundation
import SQLite3

actor SQLiteDriver: DatabaseDriver {
    private var db: OpaquePointer?

    func connect(config: ConnectionConfig) async throws {
        guard config.kind == .sqlite else {
            throw DatabaseError.unsupported(config.kind)
        }
        guard let path = config.filePath else {
            throw DatabaseError.missingSQLitePath
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open SQLite database."
            if let handle {
                sqlite3_close(handle)
            }
            throw DatabaseError.connectionFailed("SQLite connection failed: \(message)")
        }

        db = handle
    }

    func schemas() async throws -> [SchemaInfo] {
        _ = try requireConnection()
        return [SchemaInfo(name: "main")]
    }

    func tables(in schema: String) async throws -> [TableInfo] {
        let result = try await query(
            """
            SELECT name, type
            FROM sqlite_master
            WHERE type IN ('table', 'view')
              AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """,
            limit: nil
        )

        return result.rows.compactMap { row in
            guard let name = row.values["name"]?.description,
                  let rawType = row.values["type"]?.description else {
                return nil
            }
            let kind: TableInfo.Kind = rawType == "view" ? .view : .table
            return TableInfo(schema: schema, name: name, kind: kind)
        }
    }

    func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let sql = "PRAGMA table_info(\(quoteIdentifier(table.name)))"
        let result = try await query(sql, limit: nil)
        return result.rows.compactMap { row in
            guard let name = row.values["name"]?.description else { return nil }
            let type = row.values["type"]?.description ?? ""
            let nullable = (row.values["notnull"]?.description ?? "0") == "0"
            let primaryKey = (Int(row.values["pk"]?.description ?? "0") ?? 0) > 0
            return ColumnInfo(name: name, type: type, isPrimaryKey: primaryKey, isNullable: nullable)
        }
    }

    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        let handle = try requireConnection()
        var statement: OpaquePointer?
        let finalSQL = limitedSQL(sql, limit: limit)
        guard sqlite3_prepare_v2(handle, finalSQL, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        let columnNames = (0..<columnCount).map { index in
            String(cString: sqlite3_column_name(statement, Int32(index)))
        }
        let columns = columnNames.map { ColumnInfo(name: $0, type: "", isPrimaryKey: false, isNullable: true) }

        var rows: [ResultRow] = []
        var rowIndex = 0

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                var values: [String: DBValue] = [:]
                for index in 0..<columnCount {
                    values[columnNames[index]] = value(for: statement, at: Int32(index))
                }
                rows.append(ResultRow(id: rowIndex, values: values))
                rowIndex += 1
            } else if step == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }

        return ResultSet(columns: columns, rows: rows)
    }

    func execute(_ sql: String) async throws -> Int {
        let handle = try requireConnection()
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    func disconnect() async {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func requireConnection() throws -> OpaquePointer {
        guard let db else {
            throw DatabaseError.notConnected
        }
        return db
    }

    private func value(for statement: OpaquePointer?, at index: Int32) -> DBValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else {
                return .null
            }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else {
                return .blob(Data())
            }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .unknown("")
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
}

func quoteIdentifier(_ identifier: String) -> String {
    "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
}
