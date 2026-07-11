import Foundation
import Testing
@testable import GlassDB

@Suite("Query lifecycle")
struct QueryLifecycleTests {
    @Test @MainActor
    func timeoutInvalidatesSessionAndExposesReconnect() async throws {
        let driver = LifecycleDriver(mode: .slow)
        let model = AppModel(
            profileStore: LifecycleProfileStore(),
            passwordStore: LifecyclePasswordStore(),
            driverProvider: LifecycleDriverProvider(driver: driver),
            queryTimeoutSeconds: 1
        )
        model.mysqlDatabase = "glassdb"
        model.mysqlUser = "reader"
        await model.openMySQL()
        model.sqlText = "SELECT SLOW"

        await model.runSQL()
        await waitUntil { model.queryExecutionState == .disconnected }

        #expect(model.queryExecutionState == .disconnected)
        #expect(model.errorMessage?.contains("timed out after 1 seconds") == true)
        #expect(await driver.disconnectCount == 1)
    }

    @Test @MainActor
    func cancellationWinsOverStaleCompletion() async throws {
        let driver = LifecycleDriver(mode: .slow)
        let model = AppModel(
            profileStore: LifecycleProfileStore(),
            passwordStore: LifecyclePasswordStore(),
            driverProvider: LifecycleDriverProvider(driver: driver),
            queryTimeoutSeconds: 10
        )
        model.mysqlDatabase = "glassdb"
        model.mysqlUser = "reader"
        await model.openMySQL()
        model.sqlText = "SELECT SLOW"

        await model.runSQL()
        try await Task.sleep(for: .milliseconds(50))
        await model.cancelQuery()

        #expect(model.queryExecutionState == .disconnected)
        #expect(model.errorMessage?.hasPrefix("Query cancelled") == true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.errorMessage?.hasPrefix("Query cancelled") == true)
    }

    @Test @MainActor
    func connectionLossIsClassifiedAndRecoverable() async {
        let driver = LifecycleDriver(mode: .connectionLoss)
        let model = AppModel(
            profileStore: LifecycleProfileStore(),
            passwordStore: LifecyclePasswordStore(),
            driverProvider: LifecycleDriverProvider(driver: driver)
        )
        model.mysqlDatabase = "glassdb"
        model.mysqlUser = "reader"
        await model.openMySQL()
        model.sqlText = "SELECT LOST"

        await model.runSQL()
        await waitUntil { model.queryExecutionState == .disconnected }

        #expect(model.queryExecutionState == .disconnected)
        #expect(model.errorMessage?.contains("connection was lost") == true)
        #expect(model.errorMessage?.contains("server closed the connection") == true)
    }

    @Test @MainActor
    func metadataFailureKeepsReconnectAvailableForRetry() async {
        let driver = RetryMetadataDriver()
        let model = AppModel(
            profileStore: LifecycleProfileStore(),
            passwordStore: LifecyclePasswordStore(),
            driverProvider: RetryMetadataProvider(driver: driver)
        )
        model.mysqlDatabase = "glassdb"
        model.mysqlUser = "reader"
        await model.openMySQL()
        model.sqlText = "SELECT LOST"
        await model.runSQL()
        await waitUntil { model.queryExecutionState == .disconnected }

        await driver.failNextMetadataLoad()
        await model.reconnect()
        #expect(model.queryExecutionState == .disconnected)
        #expect(model.errorMessage?.contains("metadata unavailable") == true)

        await model.reconnect()
        #expect(model.queryExecutionState == .idle)
        #expect(model.errorMessage == nil)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor LifecycleDriver: DatabaseDriver {
    enum Mode: Sendable { case slow, connectionLoss }
    let mode: Mode
    private(set) var disconnectCount = 0
    init(mode: Mode) { self.mode = mode }
    func connect(config: ConnectionConfig) async throws {}
    func schemas() async throws -> [SchemaInfo] { [SchemaInfo(name: "glassdb")] }
    func tables(in schema: String) async throws -> [TableInfo] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { [] }
    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        guard sql.contains("SLOW") || sql.contains("LOST") else { return ResultSet(columns: [], rows: []) }
        switch mode {
        case .slow:
            try await Task.sleep(for: .seconds(60))
            return ResultSet(columns: [], rows: [])
        case .connectionLoss:
            throw DatabaseError.connectionLost("MySQL query failed: server closed the connection unexpectedly")
        }
    }
    func execute(_ sql: String) async throws -> Int { 0 }
    func applyMutations(_ statements: [MutationStatement]) async throws {}
    func disconnect() async { disconnectCount += 1 }
    nonisolated func quoteIdentifier(_ identifier: String) -> String { identifier }
    nonisolated func mutationLiteral(_ value: DBValue) -> String { value.description }
}

private struct LifecycleDriverProvider: DatabaseDriverProviding {
    let driver: LifecycleDriver
    func makeDriver(for kind: DatabaseKind) -> any DatabaseDriver { driver }
}

private struct RetryMetadataProvider: DatabaseDriverProviding {
    let driver: RetryMetadataDriver
    func makeDriver(for kind: DatabaseKind) -> any DatabaseDriver { driver }
}

private actor RetryMetadataDriver: DatabaseDriver {
    private var shouldFailMetadata = false
    func failNextMetadataLoad() { shouldFailMetadata = true }
    func connect(config: ConnectionConfig) async throws {}
    func schemas() async throws -> [SchemaInfo] {
        if shouldFailMetadata {
            shouldFailMetadata = false
            throw DatabaseError.connectionFailed("metadata unavailable")
        }
        return [SchemaInfo(name: "glassdb")]
    }
    func tables(in schema: String) async throws -> [TableInfo] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { [] }
    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        if sql.contains("LOST") { throw DatabaseError.connectionLost("MySQL connection closed") }
        return ResultSet(columns: [], rows: [])
    }
    func execute(_ sql: String) async throws -> Int { 0 }
    func applyMutations(_ statements: [MutationStatement]) async throws {}
    func disconnect() async {}
    nonisolated func quoteIdentifier(_ identifier: String) -> String { identifier }
    nonisolated func mutationLiteral(_ value: DBValue) -> String { value.description }
}

private final class LifecycleProfileStore: ConnectionProfilePersisting, @unchecked Sendable {
    func load() throws -> [ConnectionProfile] { [] }
    func save(_ profiles: [ConnectionProfile]) throws {}
}

private final class LifecyclePasswordStore: ConnectionPasswordStoring, @unchecked Sendable {
    func password(for profileID: UUID) throws -> String? { nil }
    func save(password: String, for profileID: UUID) throws {}
    func deletePassword(for profileID: UUID) throws {}
}
