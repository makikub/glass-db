import Foundation
import Testing
@testable import GlassDB

@Suite
struct SQLiteDriverTests {
    @Test
    func opensDatabaseAndListsTables() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "GlassDBDriverTests-\(UUID().uuidString).sqlite")
            .path
        let driver = SQLiteDriver()
        try await driver.connect(config: ConnectionConfig(name: "Test", kind: .sqlite, filePath: path))
        defer {
            Task { await driver.disconnect() }
            try? FileManager.default.removeItem(atPath: path)
        }

        _ = try await driver.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, nickname TEXT);")
        _ = try await driver.execute("INSERT INTO users (id, name, nickname) VALUES (1, 'Ada', NULL), (2, 'Grace', 'Amazing Grace');")

        let tables = try await driver.tables(in: "main")
        #expect(tables.map(\.name) == ["users"])

        let columns = try await driver.columns(of: TableRef(schema: "main", name: "users"))
        #expect(columns.map(\.name) == ["id", "name", "nickname"])
        #expect(columns.first?.isPrimaryKey == true)

        let result = try await driver.query("SELECT id, name, nickname FROM users ORDER BY id", limit: nil)
        #expect(result.rows.count == 2)
        #expect(result.rows.first?.values["name"] == .text("Ada"))
        #expect(result.rows.first?.values["nickname"] == .null)
    }

    @Test
    func sessionRowsSupportSortFilterAndCount() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "GlassDBSessionTests-\(UUID().uuidString).sqlite")
            .path
        let driver = SQLiteDriver()
        try await driver.connect(config: ConnectionConfig(name: "Test", kind: .sqlite, filePath: path))
        defer {
            Task { await driver.disconnect() }
            try? FileManager.default.removeItem(atPath: path)
        }

        _ = try await driver.execute("CREATE TABLE projects (id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT);")
        _ = try await driver.execute("""
        INSERT INTO projects (id, name, status) VALUES
        (1, 'Alpha', 'active'),
        (2, 'Beta', 'paused'),
        (3, 'Gamma', 'active');
        """)

        let session = ConnectionSession(driver: driver)
        let table = TableRef(schema: "main", name: "projects")
        let filter = FilterState(column: "status", op: .equals, value: "active")
        let sort = SortState(column: "name", direction: .descending)

        let rows = try await session.rows(in: table, pageSize: 10, page: 0, sort: sort, filter: filter)
        #expect(rows.rows.map { $0.values["name"] } == [.text("Gamma"), .text("Alpha")])

        let count = try await session.rowCount(in: table, filter: filter)
        #expect(count == 2)
    }

    @Test
    func limitedSelectToleratesTrailingSemicolon() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "GlassDBLimitTests-\(UUID().uuidString).sqlite")
            .path
        let driver = SQLiteDriver()
        try await driver.connect(config: ConnectionConfig(name: "Test", kind: .sqlite, filePath: path))
        defer {
            Task { await driver.disconnect() }
            try? FileManager.default.removeItem(atPath: path)
        }

        _ = try await driver.execute("CREATE TABLE logs (id INTEGER PRIMARY KEY);")
        _ = try await driver.execute("INSERT INTO logs (id) VALUES (1), (2), (3);")

        let result = try await driver.query("SELECT id FROM logs ORDER BY id;", limit: 2)
        #expect(result.rows.map { $0.values["id"] } == [.integer(1), .integer(2)])
    }
}
