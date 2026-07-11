import Foundation

enum DatabaseKind: String, CaseIterable, Identifiable, Sendable {
    case sqlite = "SQLite"
    case mysql = "MySQL"
    case postgresql = "PostgreSQL"

    var id: String { rawValue }
}

struct ConnectionConfig: Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: DatabaseKind
    var filePath: String?
    var host: String?
    var port: Int?
    var database: String?
    var user: String?
    var password: String?
}

struct ConnectionProfile: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var name: String
    var kind: DatabaseKind
    var filePath: String?
    var sqliteBookmark: Data?
    var host: String?
    var port: Int?
    var database: String?
    var user: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: DatabaseKind,
        filePath: String? = nil,
        sqliteBookmark: Data? = nil,
        host: String? = nil,
        port: Int? = nil,
        database: String? = nil,
        user: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.filePath = filePath
        self.sqliteBookmark = sqliteBookmark
        self.host = host
        self.port = port
        self.database = database
        self.user = user
    }

    func connectionConfig(password: String? = nil, sqlitePath: String? = nil) -> ConnectionConfig {
        ConnectionConfig(
            id: id,
            name: name,
            kind: kind,
            filePath: sqlitePath ?? filePath,
            host: host,
            port: port,
            database: database,
            user: user,
            password: password
        )
    }
}

extension DatabaseKind: Codable {}

struct SchemaInfo: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
}

struct TableInfo: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable {
        case table = "Table"
        case view = "View"
    }

    var id: String { "\(schema).\(name)" }
    let schema: String
    let name: String
    let kind: Kind
}

struct TableRef: Sendable, Hashable {
    let schema: String
    let name: String
}

struct ColumnInfo: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let type: String
    let isPrimaryKey: Bool
    let isNullable: Bool
}

enum WorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case table = "Table"
    case sql = "SQL"

    var id: String { rawValue }
}

enum SortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending = "ASC"
    case descending = "DESC"

    var id: String { rawValue }
}

struct SortState: Sendable, Hashable {
    let column: String
    let direction: SortDirection
}

enum FilterOperator: String, CaseIterable, Identifiable, Sendable {
    case equals = "="
    case notEquals = "!="
    case like = "LIKE"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"

    var id: String { rawValue }

    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull:
            return false
        case .equals, .notEquals, .like:
            return true
        }
    }
}

struct FilterState: Sendable, Hashable {
    let column: String
    let op: FilterOperator
    let value: String
}

enum DBValue: Sendable, Hashable, CustomStringConvertible {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case unknown(String)

    var description: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .text(let value):
            return value
        case .blob(let data):
            return "BLOB \(data.count) bytes"
        case .unknown(let value):
            return value
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

struct ResultRow: Identifiable, Sendable, Hashable {
    let id: Int
    let values: [String: DBValue]
}

struct ResultSet: Sendable, Hashable {
    let columns: [ColumnInfo]
    let rows: [ResultRow]
}

protocol DatabaseDriver: Sendable {
    func connect(config: ConnectionConfig) async throws
    func schemas() async throws -> [SchemaInfo]
    func tables(in schema: String) async throws -> [TableInfo]
    func columns(of table: TableRef) async throws -> [ColumnInfo]
    func query(_ sql: String, limit: Int?) async throws -> ResultSet
    func execute(_ sql: String) async throws -> Int
    func disconnect() async
    func quoteIdentifier(_ identifier: String) -> String
}

extension DatabaseDriver {
    func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

enum DatabaseError: LocalizedError, Sendable {
    case unsupported(DatabaseKind)
    case missingSQLitePath
    case connectionFailed(String)
    case queryFailed(String)
    case readOnlyViolation
    case notConnected

    var errorDescription: String? {
        switch self {
        case .unsupported(let kind):
            return "\(kind.rawValue) is planned for a later milestone."
        case .missingSQLitePath:
            return "SQLite file path is missing."
        case .connectionFailed(let message):
            return message
        case .queryFailed(let message):
            return message
        case .readOnlyViolation:
            return "This PostgreSQL connection is read-only. Only SELECT queries are allowed."
        case .notConnected:
            return "Database is not connected."
        }
    }
}
