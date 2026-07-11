import Foundation
import Testing
@testable import GlassDB

@Suite("Preferences, window restoration, and commands")
struct PreferencesWindowCommandTests {
    @Test @MainActor
    func preferencesPersistAndMigrateUnsupportedValues() {
        let store = MemoryPreferencesStore(.defaults)
        let preferences = AppPreferences(store: store)
        preferences.pageSize = 500
        preferences.queryTimeoutSeconds = 60
        preferences.autoLimitSelects = false

        let restored = AppPreferences(store: store)
        #expect(restored.pageSize == 500)
        #expect(restored.queryTimeoutSeconds == 60)
        #expect(!restored.autoLimitSelects)

        store.value = AppPreferenceValues(pageSize: -1, queryTimeoutSeconds: 9_999, autoLimitSelects: true)
        let migrated = AppPreferences(store: store)
        #expect(migrated.pageSize == AppPreferenceValues.defaultPageSize)
        #expect(migrated.queryTimeoutSeconds == AppPreferenceValues.defaultQueryTimeout)
        #expect(migrated.autoLimitSelects)
        #expect(store.value == .defaults)

        migrated.pageSize = -1
        migrated.queryTimeoutSeconds = 999
        #expect(migrated.pageSize == AppPreferenceValues.defaultPageSize)
        #expect(migrated.queryTimeoutSeconds == AppPreferenceValues.defaultQueryTimeout)
    }

    @Test @MainActor
    func windowStateIsBoundedRestoredAndIsolatedByIdentity() {
        let store = MemoryWindowStateStore()
        let first = WindowState(windowID: "first", store: store)
        first.updateSidebarWidth(900)
        first.updateInspectorWidth(800)
        first.schemaName = "main"
        first.tableName = "projects"

        let second = WindowState(windowID: "second", store: store)
        second.schemaName = "analytics"
        second.tableName = "events"

        let restoredFirst = WindowState(windowID: "first", store: store)
        #expect(restoredFirst.sidebarWidth == WindowWorkspaceState.sidebarBounds.upperBound)
        #expect(restoredFirst.inspectorWidth == WindowWorkspaceState.inspectorBounds.upperBound)
        #expect(restoredFirst.schemaName == "main")
        #expect(restoredFirst.tableName == "projects")
        #expect(second.schemaName == "analytics")
        #expect(second.tableName == "events")
    }

    @Test @MainActor
    func windowIdentityReusesLastClosedSlotButSeparatesConcurrentWindows() throws {
        let suite = "GlassDBIdentityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstRun = WindowIdentityAllocator(defaults: defaults, key: "identity")
        let first = firstRun.claim()
        let second = firstRun.claim()
        #expect(first != second)

        let restarted = WindowIdentityAllocator(defaults: defaults, key: "identity")
        #expect(restarted.claim() == second)
    }

    @Test @MainActor
    func openingConnectionRestoresOnlyThatWindowsSchemaAndTable() async {
        let stateStore = MemoryWindowStateStore()
        let connectionKey = "MySQL:127.0.0.1:3306:glassdb"
        stateStore.save(WindowWorkspaceState(connectionKey: connectionKey, schemaName: "main", tableName: "projects"), windowID: "one")
        stateStore.save(WindowWorkspaceState(connectionKey: connectionKey, schemaName: "main", tableName: "people"), windowID: "two")
        let preferences = AppPreferences(store: MemoryPreferencesStore(.defaults))

        let first = makeModel(preferences: preferences, state: WindowState(windowID: "one", store: stateStore))
        let second = makeModel(preferences: preferences, state: WindowState(windowID: "two", store: stateStore))
        await first.openMySQL()
        await second.openMySQL()

        #expect(first.selectedTable?.name == "projects")
        #expect(second.selectedTable?.name == "people")
        #expect(first.selectedTable != second.selectedTable)
    }

    @Test @MainActor
    func commandAvailabilityAndFilterFocusFollowActiveModelState() async {
        let model = makeModel(
            preferences: AppPreferences(store: MemoryPreferencesStore(.defaults)),
            state: WindowState(windowID: "commands", store: MemoryWindowStateStore())
        )
        #expect(!model.canOpenSQLWorkspace)
        #expect(!model.canRefresh)
        #expect(!model.canApplyPendingChanges)
        #expect(!model.canFocusTableFilter)

        await model.openMySQL()
        #expect(model.canOpenSQLWorkspace)
        #expect(model.canRefresh)
        #expect(!model.canFocusTableFilter)

        await model.select(TableInfo(schema: "main", name: "projects", kind: .table))
        #expect(model.canFocusTableFilter)
        let request = model.filterFocusRequest
        model.requestTableFilterFocus()
        #expect(model.filterFocusRequest == request + 1)

        model.showSQLWorkspace()
        #expect(!model.canFocusTableFilter)
        #expect(!model.canApplyPendingChanges)
        model.requestTableFilterFocus()
        #expect(model.filterFocusRequest == request + 1)
    }

    @Test @MainActor
    func sharedSettingsReachCurrentModelsWithoutSharingWindowState() {
        let preferences = AppPreferences(store: MemoryPreferencesStore(.defaults))
        let first = makeModel(preferences: preferences, state: WindowState(windowID: "a", store: MemoryWindowStateStore()))
        let second = makeModel(preferences: preferences, state: WindowState(windowID: "b", store: MemoryWindowStateStore()))

        preferences.pageSize = 1_000
        preferences.queryTimeoutSeconds = 120
        preferences.autoLimitSelects = false

        #expect(first.pageSize == 1_000)
        #expect(second.queryTimeoutSeconds == 120)
        #expect(!first.autoLimitSelects)
        #expect(first.windowState.windowID != second.windowState.windowID)
    }

    @MainActor
    private func makeModel(preferences: AppPreferences, state: WindowState) -> AppModel {
        let model = AppModel(
            profileStore: EmptyProfileStore(),
            passwordStore: EmptyPasswordStore(),
            driverProvider: CommandDriverProvider(),
            preferences: preferences,
            windowState: state
        )
        model.mysqlDatabase = "glassdb"
        model.mysqlUser = "reader"
        return model
    }
}

private final class MemoryPreferencesStore: AppPreferencesPersisting {
    var value: AppPreferenceValues
    init(_ value: AppPreferenceValues) { self.value = value }
    func load() -> AppPreferenceValues {
        let result = AppPreferenceValues.sanitized(
            pageSize: value.pageSize,
            queryTimeoutSeconds: value.queryTimeoutSeconds,
            autoLimitSelects: value.autoLimitSelects
        )
        save(result)
        return result
    }
    func save(_ values: AppPreferenceValues) { value = values }
}

private final class MemoryWindowStateStore: WindowStatePersisting {
    var values: [String: WindowWorkspaceState] = [:]
    func load(windowID: String) -> WindowWorkspaceState { values[windowID]?.sanitized ?? WindowWorkspaceState() }
    func save(_ state: WindowWorkspaceState, windowID: String) { values[windowID] = state.sanitized }
}

private struct EmptyProfileStore: ConnectionProfilePersisting {
    func load() throws -> [ConnectionProfile] { [] }
    func save(_ profiles: [ConnectionProfile]) throws {}
}

private struct EmptyPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: UUID) throws -> String? { nil }
    func save(password: String, for profileID: UUID) throws {}
    func deletePassword(for profileID: UUID) throws {}
}

private struct CommandDriverProvider: DatabaseDriverProviding {
    func makeDriver(for kind: DatabaseKind) -> any DatabaseDriver { CommandDriver() }
}

private actor CommandDriver: DatabaseDriver {
    func connect(config: ConnectionConfig) async throws {}
    func schemas() async throws -> [SchemaInfo] { [SchemaInfo(name: "main")] }
    func tables(in schema: String) async throws -> [TableInfo] {
        [TableInfo(schema: schema, name: "projects", kind: .table), TableInfo(schema: schema, name: "people", kind: .table)]
    }
    func columns(of table: TableRef) async throws -> [ColumnInfo] {
        [ColumnInfo(name: "id", type: "INTEGER", isPrimaryKey: true, isNullable: false)]
    }
    func query(_ sql: String, limit: Int?) async throws -> ResultSet {
        ResultSet(columns: [ColumnInfo(name: "id", type: "INTEGER", isPrimaryKey: true, isNullable: false)], rows: [])
    }
    func execute(_ sql: String) async throws -> Int { 0 }
    func applyMutations(_ statements: [MutationStatement]) async throws {}
    func cancelCurrentQuery() async {}
    func disconnect() async {}
}
