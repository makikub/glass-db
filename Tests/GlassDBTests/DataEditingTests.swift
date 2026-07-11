import Foundation
import Testing
@testable import GlassDB

struct DataEditingTests {
    let columns = [
        ColumnInfo(name: "tenant", type: "INTEGER", isPrimaryKey: true, isNullable: false),
        ColumnInfo(name: "id", type: "INTEGER", isPrimaryKey: true, isNullable: false),
        ColumnInfo(name: "name", type: "TEXT", isPrimaryKey: false, isNullable: false),
        ColumnInfo(name: "payload", type: "BLOB", isPrimaryKey: false, isNullable: true),
    ]

    @Test func previewUsesQuotedCompositePrimaryKeyAndSafeLiterals() throws {
        let driver = RecordingDriver(quote: "\"")
        let statements = try driver.mutationStatements(for: [
            .update(id: UUID(), originalKey: ["tenant": .integer(7), "id": .integer(9)], values: ["name": .text("O'Brien")]),
            .delete(id: UUID(), originalKey: ["tenant": .integer(7), "id": .integer(9)]),
            .insert(id: UUID(), values: ["tenant": .integer(7), "id": .integer(10), "name": .text("new"), "payload": .blob(Data([0x00, 0xff]))]),
        ], table: TableRef(schema: "main", name: "items"), columns: columns)
        #expect(statements[0].sql == "UPDATE \"main\".\"items\" SET \"name\" = 'O''Brien' WHERE \"tenant\" = 7 AND \"id\" = 9")
        #expect(statements[1].sql.hasSuffix("WHERE \"tenant\" = 7 AND \"id\" = 9"))
        #expect(statements[2].sql.contains("X'00ff'"))
    }

    @Test func mysqlUsesBackticks() throws {
        let driver = RecordingDriver(quote: "`")
        let statement = try #require(driver.mutationStatements(for: [.delete(id: UUID(), originalKey: ["tenant": .integer(1), "id": .integer(2)])], table: TableRef(schema: "glassdb", name: "items"), columns: columns).first)
        #expect(statement.sql == "DELETE FROM `glassdb`.`items` WHERE `tenant` = 1 AND `id` = 2")
        #expect(MySQLDriver().mutationLiteral(.text("\\' OR 1=1 --")) == "'\\\\'' OR 1=1 --'")
    }

    @Test func noPrimaryKeyIsReadOnly() {
        let driver = RecordingDriver(quote: "\"")
        #expect(throws: DataEditingError.self) {
            try driver.mutationStatements(for: [.delete(id: UUID(), originalKey: [:])], table: TableRef(schema: "main", name: "view"), columns: [ColumnInfo(name: "name", type: "TEXT", isPrimaryKey: false, isNullable: true)])
        }
    }

    @Test func mismatchRollsBackWholeBatch() async throws {
        let driver = RecordingDriver(quote: "\"", results: [0, 1, 0, 0])
        do { try await driver.applyMutations([MutationStatement(sql: "UPDATE x", kind: .update), MutationStatement(sql: "DELETE x", kind: .delete)]); Issue.record("Expected mismatch") }
        catch is DataEditingError { }
        #expect(await driver.executed == ["BEGIN", "UPDATE x", "DELETE x", "ROLLBACK"])
    }
}

private actor RecordingDriver: DatabaseDriver {
    let delimiter: String
    var results: [Int]
    var executed: [String] = []
    init(quote: String, results: [Int] = []) { delimiter = quote; self.results = results }
    func connect(config: ConnectionConfig) async throws {}
    func schemas() async throws -> [SchemaInfo] { [] }
    func tables(in schema: String) async throws -> [TableInfo] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { [] }
    func query(_ sql: String, limit: Int?) async throws -> ResultSet { ResultSet(columns: [], rows: []) }
    func execute(_ sql: String) async throws -> Int { executed.append(sql); return results.isEmpty ? 0 : results.removeFirst() }
    func disconnect() async {}
    nonisolated func quoteIdentifier(_ identifier: String) -> String { "\(delimiter)\(identifier)\(delimiter)" }
}
