import Foundation

actor ConnectionSession {
    private let driver: any DatabaseDriver

    init(driver: any DatabaseDriver) {
        self.driver = driver
    }

    func connect(config: ConnectionConfig) async throws {
        try await driver.connect(config: config)
    }

    func schemas() async throws -> [SchemaInfo] {
        try await driver.schemas()
    }

    func tables(in schema: String) async throws -> [TableInfo] {
        try await driver.tables(in: schema)
    }

    func columns(of table: TableRef) async throws -> [ColumnInfo] {
        try await driver.columns(of: table)
    }

    func rows(
        in table: TableRef,
        pageSize: Int,
        page: Int,
        sort: SortState?,
        filter: FilterState?
    ) async throws -> ResultSet {
        let offset = max(0, page) * pageSize
        var sql = "SELECT * FROM \(driver.quoteIdentifier(table.name))"
        if let whereClause = whereClause(for: filter) {
            sql += " WHERE \(whereClause)"
        }
        if let sort {
            sql += " ORDER BY \(driver.quoteIdentifier(sort.column)) \(sort.direction.rawValue)"
        }
        sql += " LIMIT \(pageSize) OFFSET \(offset)"
        return try await driver.query(sql, limit: nil)
    }

    func rowCount(in table: TableRef, filter: FilterState?) async throws -> Int {
        var sql = "SELECT COUNT(*) AS count FROM \(driver.quoteIdentifier(table.name))"
        if let whereClause = whereClause(for: filter) {
            sql += " WHERE \(whereClause)"
        }
        let result = try await driver.query(sql, limit: nil)
        guard let value = result.rows.first?.values["count"] else {
            return 0
        }
        switch value {
        case .integer(let count):
            return Int(count)
        case .text(let text):
            return Int(text) ?? 0
        case .double(let double):
            return Int(double)
        case .null, .blob, .unknown:
            return 0
        }
    }

    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        try await driver.query(sql, limit: limit)
    }

    func execute(_ sql: String) async throws -> Int {
        try await driver.execute(sql)
    }

    func disconnect() async {
        await driver.disconnect()
    }

    private func whereClause(for filter: FilterState?) -> String? {
        guard let filter, !filter.column.isEmpty else { return nil }

        let column = driver.quoteIdentifier(filter.column)
        switch filter.op {
        case .isNull, .isNotNull:
            return "\(column) \(filter.op.rawValue)"
        case .equals, .notEquals, .like:
            guard !filter.value.isEmpty else { return nil }
            return "\(column) \(filter.op.rawValue) \(quoteLiteral(filter.value))"
        }
    }
}

func quoteLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}
