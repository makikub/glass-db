import Foundation
import AppKit
import Observation

private enum SQLExecutionOutcome: Sendable {
    case result(ResultSet)
    case changed(Int, [TableInfo])
}

@MainActor
@Observable
final class AppModel {
    enum Screen {
        case welcome
        case database
    }

    var screen: Screen = .welcome
    var databasePath = ""
    var connectionName = "SQLite Database"
    var mysqlHost = "127.0.0.1"
    var mysqlPort = "3306"
    var mysqlDatabase = ""
    var mysqlUser = ""
    var mysqlPassword = ""
    var postgresqlHost = "127.0.0.1"
    var postgresqlPort = "5432"
    var postgresqlDatabase = ""
    var postgresqlUser = ""
    var postgresqlPassword = ""
    var serverKind: DatabaseKind = .mysql
    var schemas: [SchemaInfo] = []
    var selectedSchema: SchemaInfo?
    var tables: [TableInfo] = []
    var filterText = ""
    var selectedTable: TableInfo?
    var tableColumns: [ColumnInfo] = []
    var resultSet = ResultSet(columns: [], rows: [])
    var selectedCell: CellSelection?
    var isLoading = false
    var errorMessage: String?
    var infoMessage: String?
    var page = 0
    var pageSize: Int { preferences.pageSize }
    var totalRows: Int?
    var workspaceMode: WorkspaceMode = .table
    var sortState: SortState?
    var filterColumn = ""
    var filterOperator: FilterOperator = .equals
    var filterValue = ""
    var sqlText = "SELECT name, type FROM sqlite_master ORDER BY type, name"
    var sqlStatusMessage = ""
    var sqlHistory: [String] = []
    var autoLimitSelects: Bool {
        get { preferences.autoLimitSelects }
        set { preferences.autoLimitSelects = newValue }
    }
    var connectionProfiles: [ConnectionProfile] = []
    var pendingChanges: [PendingChange] = []
    var mutationSQLPreview = ""
    var isApplyingMutations = false
    var queryExecutionState: QueryExecutionState = .idle
    var queryTimeoutSeconds: Int { queryTimeoutOverride ?? preferences.queryTimeoutSeconds }
    var filterFocusRequest = 0

    private var session: ConnectionSession?
    private var activeSecurityScopedResource: SQLiteSecurityScopedResource?
    private var activeConnectionKind: DatabaseKind?
    private var activeProfile: ConnectionProfile?
    private var activeConnectionConfig: ConnectionConfig?
    private var queryGeneration = 0
    private var activeQueryTask: Task<Void, Never>?
    private var queryTimeoutTask: Task<Void, Never>?
    private var queryTeardownTask: Task<Void, Never>?
    private let profileStore: any ConnectionProfilePersisting
    private let passwordStore: any ConnectionPasswordStoring
    private let sqliteBookmarkAccess: any SQLiteBookmarkAccessing
    private let driverProvider: any DatabaseDriverProviding
    let preferences: AppPreferences
    let windowState: WindowState
    private let queryTimeoutOverride: Int?

    init(
        profileStore: (any ConnectionProfilePersisting)? = nil,
        passwordStore: any ConnectionPasswordStoring = KeychainPasswordStore(),
        sqliteBookmarkAccess: any SQLiteBookmarkAccessing = SQLiteBookmark(),
        driverProvider: any DatabaseDriverProviding = DefaultDatabaseDriverProvider(),
        queryTimeoutSeconds: Int? = nil,
        preferences: AppPreferences? = nil,
        windowState: WindowState? = nil
    ) {
        self.passwordStore = passwordStore
        self.sqliteBookmarkAccess = sqliteBookmarkAccess
        self.driverProvider = driverProvider
        self.preferences = preferences ?? AppPreferences()
        self.windowState = windowState ?? WindowState(windowID: UUID().uuidString)
        self.queryTimeoutOverride = queryTimeoutSeconds
        if let profileStore {
            self.profileStore = profileStore
        } else {
            do {
                self.profileStore = try ConnectionProfileStore()
            } catch {
                self.profileStore = InMemoryConnectionProfileStore()
                self.errorMessage = error.localizedDescription
                return
            }
        }
        do {
            connectionProfiles = try self.profileStore.load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = "Saved connections could not be loaded: \(error.localizedDescription)"
        }
    }

    var filteredTables: [TableInfo] {
        guard !filterText.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var canGoBack: Bool {
        page > 0
    }

    var canGoForward: Bool {
        guard let totalRows else { return resultSet.rows.count == pageSize }
        return (page + 1) * pageSize < totalRows
    }

    var isTableMode: Bool {
        workspaceMode == .table
    }

    var tableReadOnlyReason: String? {
        guard let table = selectedTable else { return nil }
        if table.kind == .view { return "Views are read-only." }
        if !tableColumns.contains(where: \.isPrimaryKey) { return "Tables without a primary key are read-only." }
        return nil
    }

    var canEditTable: Bool { selectedTable != nil && tableReadOnlyReason == nil }

    var activeFilter: FilterState? {
        guard !filterColumn.isEmpty else { return nil }
        if filterOperator.needsValue && filterValue.isEmpty {
            return nil
        }
        return FilterState(column: filterColumn, op: filterOperator, value: filterValue)
    }

    var canConnectMySQL: Bool {
        !mysqlHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int(mysqlPort) != nil
            && !mysqlDatabase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !mysqlUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canConnectPostgreSQL: Bool {
        !postgresqlHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int(postgresqlPort) != nil
            && !postgresqlDatabase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !postgresqlUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canConnectServer: Bool {
        serverKind == .mysql ? canConnectMySQL : canConnectPostgreSQL
    }

    var canOpenSQLWorkspace: Bool { screen == .database }
    var canRefresh: Bool {
        session != nil && queryExecutionState == .idle && !isApplyingMutations && pendingChanges.isEmpty
    }
    var canApplyPendingChanges: Bool {
        session != nil && workspaceMode == .table && selectedTable != nil
            && !pendingChanges.isEmpty && !isApplyingMutations && queryExecutionState == .idle
    }
    var canFocusTableFilter: Bool { screen == .database && workspaceMode == .table && selectedTable != nil }

    func requestTableFilterFocus() {
        guard canFocusTableFilter else { return }
        filterFocusRequest += 1
    }

    func openSQLite(path: String) async {
        isLoading = true
        errorMessage = nil
        await disconnectCurrentSession()
        resetWorkspace()
        databasePath = path
        connectionName = URL(fileURLWithPath: path).lastPathComponent
        sqlText = "SELECT name, type FROM sqlite_master ORDER BY type, name"

        let config = ConnectionConfig(name: connectionName, kind: .sqlite, filePath: path)
        let session = ConnectionSession(driver: driver(for: .sqlite))
        do {
            try await session.connect(config: config)
            let loadedSchemas = try await session.schemas()
            let loadedSchema = loadedSchemas.first
            let loadedTables = try await session.tables(in: loadedSchema?.name ?? "main")
            self.session = session
            activeConnectionKind = .sqlite
            activeProfile = nil
            activeConnectionConfig = config
            schemas = loadedSchemas
            selectedSchema = loadedSchema
            tables = loadedTables
            screen = .database
            await restoreWorkspaceSelection()
        } catch {
            await session.disconnect()
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func openSQLite(url: URL) async {
        do {
            let existingProfile = connectionProfiles.first { $0.kind == .sqlite && $0.filePath == url.path }
            let profile = try preparedSQLiteProfile(
                existingProfile ?? ConnectionProfile(name: "", kind: .sqlite),
                selectedURL: url
            )
            try persistProfile(profile)
            await openSavedSQLite(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func preparedSQLiteProfile(_ profile: ConnectionProfile, selectedURL: URL) throws -> ConnectionProfile {
        var updated = profile
        updated.filePath = selectedURL.path
        updated.sqliteBookmark = try sqliteBookmarkAccess.make(for: selectedURL)
        if updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.name = selectedURL.deletingPathExtension().lastPathComponent
        }
        return updated
    }

    func openMySQL() async {
        isLoading = true
        errorMessage = nil
        await disconnectCurrentSession()
        resetWorkspace()

        let host = mysqlHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let database = mysqlDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = mysqlUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(mysqlPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 3306
        connectionName = "MySQL: \(database)"
        databasePath = "\(host):\(port)/\(database)"

        let config = ConnectionConfig(
            name: connectionName,
            kind: .mysql,
            host: host,
            port: port,
            database: database,
            user: user,
            password: mysqlPassword.isEmpty ? nil : mysqlPassword
        )
        let session = ConnectionSession(driver: driver(for: .mysql))
        do {
            try await session.connect(config: config)
            let loadedSchemas = try await session.schemas()
            let loadedSchema = loadedSchemas.first
            let loadedTables = try await session.tables(in: loadedSchema?.name ?? database)
            self.session = session
            activeConnectionKind = .mysql
            activeProfile = nil
            activeConnectionConfig = config
            schemas = loadedSchemas
            selectedSchema = loadedSchema
            tables = loadedTables
            sqlText = "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = \(quoteLiteral(database)) ORDER BY table_type, table_name"
            screen = .database
            await restoreWorkspaceSelection()
        } catch {
            await session.disconnect()
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func openPostgreSQL() async {
        isLoading = true
        errorMessage = nil
        await disconnectCurrentSession()
        resetWorkspace()

        let host = postgresqlHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let database = postgresqlDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = postgresqlUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(postgresqlPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5432
        connectionName = "PostgreSQL: \(database)"
        databasePath = "\(host):\(port)/\(database)"

        let config = ConnectionConfig(
            name: connectionName,
            kind: .postgresql,
            host: host,
            port: port,
            database: database,
            user: user,
            password: postgresqlPassword.isEmpty ? nil : postgresqlPassword
        )
        let session = ConnectionSession(driver: driver(for: .postgresql))
        do {
            try await session.connect(config: config)
            let loadedSchemas = try await session.schemas()
            let loadedSchema = loadedSchemas.first
            let loadedTables = try await session.tables(in: loadedSchema?.name ?? "public")
            self.session = session
            activeConnectionKind = .postgresql
            activeProfile = nil
            activeConnectionConfig = config
            schemas = loadedSchemas
            selectedSchema = loadedSchema
            tables = loadedTables
            sqlText = "SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_type, table_name"
            screen = .database
            await restoreWorkspaceSelection()
        } catch {
            await session.disconnect()
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func openSelectedServer() async {
        switch serverKind {
        case .mysql:
            await openMySQL()
        case .postgresql:
            await openPostgreSQL()
        case .sqlite:
            break
        }
    }

    func saveProfile(_ profile: ConnectionProfile, password: String?, replacePassword: Bool) {
        do {
            let previousPassword = replacePassword ? try passwordStore.password(for: profile.id) : nil
            if replacePassword {
                if let password, !password.isEmpty {
                    try passwordStore.save(password: password, for: profile.id)
                } else {
                    try passwordStore.deletePassword(for: profile.id)
                }
            }
            do {
                try persistProfile(profile)
            } catch {
                if replacePassword {
                    restorePassword(previousPassword, for: profile.id)
                }
                throw error
            }
            infoMessage = "Saved connection \(profile.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        do {
            let updated = connectionProfiles.filter { $0.id != profile.id }
            let previousPassword = try passwordStore.password(for: profile.id)
            try passwordStore.deletePassword(for: profile.id)
            do {
                try profileStore.save(updated)
            } catch {
                restorePassword(previousPassword, for: profile.id)
                throw error
            }
            connectionProfiles = updated
            infoMessage = "Deleted connection \(profile.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateProfile(_ profile: ConnectionProfile) {
        do {
            var copy = profile
            copy.id = UUID()
            copy.name = "\(profile.name) Copy"
            if let password = try passwordStore.password(for: profile.id) {
                try passwordStore.save(password: password, for: copy.id)
            }
            var updated = connectionProfiles
            updated.append(copy)
            do {
                try profileStore.save(updated)
            } catch {
                try? passwordStore.deletePassword(for: copy.id)
                throw error
            }
            connectionProfiles = updated.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            infoMessage = "Duplicated connection \(profile.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connectProfile(_ profile: ConnectionProfile) async {
        do {
            switch profile.kind {
            case .sqlite:
                await openSavedSQLite(profile)
            case .mysql:
                let password = try passwordStore.password(for: profile.id)
                serverKind = .mysql
                mysqlHost = profile.host ?? ""
                mysqlPort = String(profile.port ?? 3306)
                mysqlDatabase = profile.database ?? ""
                mysqlUser = profile.user ?? ""
                mysqlPassword = password ?? ""
                await openMySQL()
                if screen == .database { connectionName = profile.name }
            case .postgresql:
                let password = try passwordStore.password(for: profile.id)
                serverKind = .postgresql
                postgresqlHost = profile.host ?? ""
                postgresqlPort = String(profile.port ?? 5432)
                postgresqlDatabase = profile.database ?? ""
                postgresqlUser = profile.user ?? ""
                postgresqlPassword = password ?? ""
                await openPostgreSQL()
                if screen == .database { connectionName = profile.name }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if screen == .database { activeProfile = profile }
    }

    func testProfile(_ profile: ConnectionProfile) async {
        isLoading = true
        errorMessage = nil
        var sqliteAccess: SQLiteSecurityScopedResource?
        defer { sqliteAccess?.endAccess() }
        do {
            let sqlitePath: String?
            let password: String?
            if profile.kind == .sqlite {
                let access = try acquireSQLiteAccess(for: profile)
                sqliteAccess = access
                sqlitePath = access.url.path
                password = nil
            } else {
                sqlitePath = nil
                password = try passwordStore.password(for: profile.id)
            }
            let driver = driver(for: profile.kind)
            try await driver.connect(config: profile.connectionConfig(password: password, sqlitePath: sqlitePath))
            await driver.disconnect()
            infoMessage = "Connection test succeeded for \(profile.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func driver(for kind: DatabaseKind) -> any DatabaseDriver {
        driverProvider.makeDriver(for: kind)
    }

    private func acquireSQLiteAccess(for profile: ConnectionProfile) throws -> SQLiteSecurityScopedResource {
        guard let path = profile.filePath else { throw DatabaseError.missingSQLitePath }
        guard let bookmark = profile.sqliteBookmark else {
            return SQLiteSecurityScopedResource(url: URL(fileURLWithPath: path), bookmarkAccess: NoopSQLiteBookmarkAccess())
        }
        let resolution = try sqliteBookmarkAccess.resolve(bookmark)
        guard sqliteBookmarkAccess.startAccessingSecurityScopedResource(at: resolution.url) else {
            throw ConnectionProfileStoreError.sqliteAccessDenied(resolution.url.path)
        }
        let resource = SQLiteSecurityScopedResource(url: resolution.url, bookmarkAccess: sqliteBookmarkAccess)
        do {
            let refreshedBookmark = resolution.isStale ? try sqliteBookmarkAccess.make(for: resolution.url) : nil
            if refreshedBookmark != nil || profile.filePath != resolution.url.path {
                try refreshSQLiteProfile(
                    profileID: profile.id,
                    resolvedURL: resolution.url,
                    refreshedBookmark: refreshedBookmark
                )
            }
            return resource
        } catch {
            resource.endAccess()
            throw error
        }
    }

    private func openSavedSQLite(_ profile: ConnectionProfile) async {
        isLoading = true
        errorMessage = nil
        await disconnectCurrentSession()
        resetWorkspace()
        var resource: SQLiteSecurityScopedResource?
        var pendingSession: ConnectionSession?
        var didConnect = false
        do {
            let acquiredResource = try acquireSQLiteAccess(for: profile)
            resource = acquiredResource
            let session = ConnectionSession(driver: driver(for: .sqlite))
            pendingSession = session
            try await session.connect(config: profile.connectionConfig(sqlitePath: acquiredResource.url.path))
            didConnect = true
            let loadedSchemas = try await session.schemas()
            let loadedSchema = loadedSchemas.first
            let loadedTables = try await session.tables(in: loadedSchema?.name ?? "main")

            self.session = session
            activeConnectionKind = .sqlite
            activeProfile = profile
            activeConnectionConfig = profile.connectionConfig(sqlitePath: acquiredResource.url.path)
            activeSecurityScopedResource = acquiredResource
            resource = nil
            pendingSession = nil
            databasePath = acquiredResource.url.path
            connectionName = profile.name
            sqlText = "SELECT name, type FROM sqlite_master ORDER BY type, name"
            schemas = loadedSchemas
            selectedSchema = loadedSchema
            tables = loadedTables
            screen = .database
            await restoreWorkspaceSelection()
        } catch {
            if let pendingSession { await pendingSession.disconnect() }
            resource?.endAccess()
            if !didConnect, let url = resource?.url, profile.sqliteBookmark != nil {
                errorMessage = ConnectionProfileStoreError.sqliteAccessDenied(url.path).localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func endSQLiteAccess() {
        activeSecurityScopedResource?.endAccess()
        activeSecurityScopedResource = nil
    }

    private func disconnectCurrentSession() async {
        queryGeneration += 1
        queryTimeoutTask?.cancel()
        activeQueryTask?.cancel()
        if let queryTeardownTask { await queryTeardownTask.value }
        if let activeQueryTask { await activeQueryTask.value }
        self.queryTimeoutTask = nil
        self.activeQueryTask = nil
        queryTeardownTask = nil
        if let session { await session.disconnect() }
        self.session = nil
        endSQLiteAccess()
    }

    private func restorePassword(_ password: String?, for profileID: UUID) {
        if let password {
            try? passwordStore.save(password: password, for: profileID)
        } else {
            try? passwordStore.deletePassword(for: profileID)
        }
    }

    func createSampleDatabase() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "GlassDB-Sample.sqlite")
        let driver = SQLiteDriver()
        let config = ConnectionConfig(name: "Sample", kind: .sqlite, filePath: url.path)

        do {
            try await driver.connect(config: config)
            _ = try await driver.execute("""
            CREATE TABLE IF NOT EXISTS projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                status TEXT NOT NULL,
                owner TEXT,
                updated_at TEXT
            );
            """)
            _ = try await driver.execute("DELETE FROM projects;")
            _ = try await driver.execute("""
            INSERT INTO projects (name, status, owner, updated_at) VALUES
            ('GlassDB MVP', 'Active', 'Masaki', '2026-07-02'),
            ('Driver abstraction', 'Planned', NULL, '2026-07-03'),
            ('Read-only grid', 'Active', 'Codex', '2026-07-02');
            """)
            await driver.disconnect()
            await openSQLite(path: url.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ table: TableInfo) async {
        guard let session else { return }
        selectedTable = table
        selectedCell = nil
        workspaceMode = .table
        page = 0
        sortState = nil
        filterColumn = ""
        filterOperator = .equals
        filterValue = ""
        totalRows = nil
        discardPendingChanges()
        windowState.connectionKey = currentConnectionKey
        windowState.schemaName = table.schema
        windowState.tableName = table.name
        do {
            let tableColumns = try await session.columns(of: TableRef(schema: table.schema, name: table.name))
            self.tableColumns = tableColumns
            filterColumn = tableColumns.first?.name ?? ""
            await loadRows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stageEdit(row: ResultRow, column: ColumnInfo, text: String) {
        guard canEditTable else { return }
        do {
            let value = try parsedValue(text, for: column)
            let key = Dictionary(uniqueKeysWithValues: tableColumns.filter(\.isPrimaryKey).map { ($0.name, row.values[$0.name] ?? .null) })
            if let index = pendingChanges.firstIndex(where: { if case .update(_, let existing, _) = $0 { return existing == key }; return false }),
               case .update(let id, let existing, let values) = pendingChanges[index] {
                pendingChanges[index] = .update(id: id, originalKey: existing, values: values.merging([column.name: value]) { _, new in new })
            } else {
                pendingChanges.append(.update(id: UUID(), originalKey: key, values: [column.name: value]))
            }
            Task { await refreshMutationPreview() }
        } catch { errorMessage = error.localizedDescription }
    }

    func stageInsert(values: [String: String]) {
        guard canEditTable else { return }
        do {
            let parsed = try Dictionary(uniqueKeysWithValues: tableColumns.compactMap { column -> (String, DBValue)? in
                let text = values[column.name] ?? ""
                if text.isEmpty { return nil }
                return (column.name, try parsedValue(text, for: column))
            })
            pendingChanges.append(.insert(id: UUID(), values: parsed))
            Task { await refreshMutationPreview() }
        } catch { errorMessage = error.localizedDescription }
    }

    func stageDelete(row: ResultRow) {
        guard canEditTable else { return }
        let key = Dictionary(uniqueKeysWithValues: tableColumns.filter(\.isPrimaryKey).map { ($0.name, row.values[$0.name] ?? .null) })
        pendingChanges.append(.delete(id: UUID(), originalKey: key))
        Task { await refreshMutationPreview() }
    }

    func discardPendingChanges() { pendingChanges = []; mutationSQLPreview = "" }

    func applyPendingChanges() async {
        guard let session, let table = selectedTable, canApplyPendingChanges else { return }
        isApplyingMutations = true
        defer { isApplyingMutations = false }
        do {
            try await session.applyMutations(pendingChanges, table: TableRef(schema: table.schema, name: table.name), columns: tableColumns)
            discardPendingChanges(); await loadRows()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshMutationPreview() async {
        guard let session, let table = selectedTable else { return }
        let snapshot = pendingChanges
        do { let preview = try await session.previewMutations(snapshot, table: TableRef(schema: table.schema, name: table.name), columns: tableColumns).map(\.sql).joined(separator: ";\n"); if snapshot == pendingChanges { mutationSQLPreview = preview } }
        catch { errorMessage = error.localizedDescription }
    }

    private func parsedValue(_ text: String, for column: ColumnInfo) throws -> DBValue {
        if text.uppercased() == "NULL" { if column.isNullable { return .null }; throw DataEditingError.invalidValue(column: column.name, expectedType: column.type) }
        let type = column.type.lowercased()
        if type.contains("int") { guard let value = Int64(text) else { throw DataEditingError.invalidValue(column: column.name, expectedType: column.type) }; return .integer(value) }
        if type.contains("real") || type.contains("double") || type.contains("float") || type.contains("numeric") || type.contains("decimal") { guard let value = Double(text), value.isFinite else { throw DataEditingError.invalidValue(column: column.name, expectedType: column.type) }; return .double(value) }
        if type.contains("bool") { guard ["true", "false", "0", "1"].contains(text.lowercased()) else { throw DataEditingError.invalidValue(column: column.name, expectedType: column.type) } }
        if type.contains("blob") || type.contains("bytea") || type.contains("binary") { throw DataEditingError.invalidValue(column: column.name, expectedType: "hex blob") }
        return .text(text)
    }

    func refresh() async {
        guard let session, canRefresh else { return }
        do {
            tables = try await session.tables(in: selectedSchema?.name ?? schemas.first?.name ?? "main")
            if isTableMode {
                await loadRows()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSchema(_ schema: SchemaInfo) async {
        guard let session else { return }
        selectedSchema = schema
        windowState.schemaName = schema.name
        windowState.tableName = nil
        resetTableSelection()
        do {
            tables = try await session.tables(in: schema.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func nextPage() async {
        guard canGoForward else { return }
        page += 1
        await loadRows()
    }

    func previousPage() async {
        page = max(0, page - 1)
        await loadRows()
    }

    func toggleSort(column: String) async {
        guard isTableMode else { return }
        if sortState?.column == column {
            switch sortState?.direction {
            case .ascending:
                sortState = SortState(column: column, direction: .descending)
            case .descending:
                sortState = nil
            case nil:
                sortState = SortState(column: column, direction: .ascending)
            }
        } else {
            sortState = SortState(column: column, direction: .ascending)
        }
        page = 0
        await loadRows()
    }

    func applyFilter() async {
        guard isTableMode else { return }
        page = 0
        await loadRows()
    }

    func clearFilter() async {
        guard isTableMode else { return }
        filterColumn = tableColumns.first?.name ?? ""
        filterOperator = .equals
        filterValue = ""
        page = 0
        await loadRows()
    }

    func countRows(_ table: TableInfo? = nil) async {
        guard let session else { return }
        let target = table ?? selectedTable
        guard let target else { return }
        do {
            let count = try await session.rowCount(
                in: TableRef(schema: target.schema, name: target.name),
                filter: target == selectedTable ? activeFilter : nil
            )
            infoMessage = "\(target.name): \(count) rows"
            if target == selectedTable {
                totalRows = count
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showSQLWorkspace() {
        workspaceMode = .sql
        selectedCell = nil
        sqlStatusMessage = ""
        resultSet = ResultSet(columns: [], rows: [])
    }

    func showTableWorkspace() async {
        workspaceMode = .table
        selectedCell = nil
        await loadRows()
    }

    func runSQL() async {
        guard let session else { return }
        let sql = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        guard !queryExecutionState.isRunning else { return }
        queryGeneration += 1
        let generation = queryGeneration
        queryExecutionState = .running
        isLoading = true
        errorMessage = nil
        selectedCell = nil
        workspaceMode = .sql
        let resultProducing = isResultProducingSQL(sql)
        let limit = autoLimitSelects ? 1000 : nil
        let timeoutSeconds = queryTimeoutSeconds
        let schema = selectedSchema?.name ?? schemas.first?.name ?? "main"
        activeQueryTask = Task { [weak self] in
            do {
                let outcome: SQLExecutionOutcome
                if resultProducing {
                    outcome = .result(try await session.query(sql, limit: limit))
                } else {
                    let changedRows = try await session.execute(sql)
                    outcome = .changed(changedRows, try await session.tables(in: schema))
                }
                self?.finishSQL(outcome, sql: sql, generation: generation)
            } catch {
                self?.finishSQL(error: error, generation: generation, session: session)
            }
        }
        queryTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
            catch { return }
            self?.timeoutSQL(generation: generation, session: session, timeoutSeconds: timeoutSeconds)
        }
    }

    func cancelQuery() async {
        guard queryExecutionState == .running, let session else { return }
        queryExecutionState = .cancelling
        queryGeneration += 1
        queryExecutionState = .disconnected
        isLoading = false
        errorMessage = DatabaseError.queryCancelled.localizedDescription
        beginQueryTeardown(session: session)
    }

    func reconnect() async {
        guard queryExecutionState == .disconnected else { return }
        if let queryTeardownTask { await queryTeardownTask.value }
        if let activeQueryTask { await activeQueryTask.value }
        self.queryTeardownTask = nil
        self.activeQueryTask = nil
        queryExecutionState = .idle
        if let activeProfile {
            await connectProfile(activeProfile)
        } else if let config = activeConnectionConfig {
            restoreConnectionFields(from: config)
            switch config.kind {
            case .sqlite: await openSQLite(path: config.filePath ?? databasePath)
            case .mysql: await openMySQL()
            case .postgresql: await openPostgreSQL()
            }
        } else {
            switch activeConnectionKind {
            case .sqlite: await openSQLite(path: databasePath)
            case .mysql: await openMySQL()
            case .postgresql: await openPostgreSQL()
            case nil: break
            }
        }
        if session == nil { queryExecutionState = .disconnected }
    }

    private func finishSQL(_ outcome: SQLExecutionOutcome, sql: String, generation: Int) {
        guard generation == queryGeneration else { return }
        queryTimeoutTask?.cancel()
        queryTimeoutTask = nil
        switch outcome {
        case .result(let result):
            resultSet = result
            sqlStatusMessage = "\(result.rows.count) rows"
        case .changed(let count, let refreshedTables):
            resultSet = ResultSet(columns: [], rows: [])
            sqlStatusMessage = "\(count) rows affected"
            tables = refreshedTables
        }
        recordSQLHistory(sql)
        queryExecutionState = .idle
        isLoading = false
        activeQueryTask = nil
    }

    private func finishSQL(error: Error, generation: Int, session: ConnectionSession) {
        guard generation == queryGeneration else { return }
        queryTimeoutTask?.cancel()
        queryTimeoutTask = nil
        let classified = classifyQueryError(error)
        errorMessage = classified.localizedDescription
        isLoading = false
        activeQueryTask = nil
        if case .connectionLost = classified {
            queryExecutionState = .disconnected
            beginQueryTeardown(session: session)
        } else if case .queryCancelled = classified {
            queryExecutionState = .disconnected
            beginQueryTeardown(session: session)
        } else {
            queryExecutionState = .idle
        }
    }

    private func timeoutSQL(generation: Int, session: ConnectionSession, timeoutSeconds: Int) {
        guard generation == queryGeneration, queryExecutionState == .running else { return }
        queryGeneration += 1
        errorMessage = DatabaseError.queryTimedOut(seconds: timeoutSeconds).localizedDescription
        queryExecutionState = .disconnected
        isLoading = false
        beginQueryTeardown(session: session)
    }

    private func beginQueryTeardown(session: ConnectionSession) {
        queryTimeoutTask?.cancel()
        queryTimeoutTask = nil
        activeQueryTask?.cancel()
        if queryTeardownTask == nil {
            queryTeardownTask = Task { await session.cancelCurrentQuery() }
        }
    }

    private func restoreConnectionFields(from config: ConnectionConfig) {
        switch config.kind {
        case .sqlite: break
        case .mysql:
            mysqlHost = config.host ?? ""
            mysqlPort = String(config.port ?? 3306)
            mysqlDatabase = config.database ?? ""
            mysqlUser = config.user ?? ""
            mysqlPassword = config.password ?? ""
        case .postgresql:
            postgresqlHost = config.host ?? ""
            postgresqlPort = String(config.port ?? 5432)
            postgresqlDatabase = config.database ?? ""
            postgresqlUser = config.user ?? ""
            postgresqlPassword = config.password ?? ""
        }
    }

    private func classifyQueryError(_ error: Error) -> DatabaseError {
        if let databaseError = error as? DatabaseError {
            switch databaseError {
            case .queryFailed(let detail), .connectionFailed(let detail):
                if isConnectionLoss(detail) { return .connectionLost(detail) }
            default: break
            }
            return databaseError
        }
        if error is CancellationError { return .queryCancelled }
        let detail = error.localizedDescription
        if isConnectionLoss(detail) {
            return .connectionLost(detail)
        }
        return .queryFailed(detail)
    }

    private func isConnectionLoss(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return ["connection reset", "broken pipe", "connection closed", "unexpected eof", "not connected", "connection refused", "server closed", "channel inactive", "io on closed channel", "ioonclosedchannel", "eof while reading"].contains(where: lower.contains)
    }

    func copyCell(_ value: DBValue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value.description, forType: .string)
    }

    func copyRow(_ row: ResultRow) {
        let text = resultSet.columns
            .map { row.values[$0.name]?.description ?? "NULL" }
            .joined(separator: "\t")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func loadRows() async {
        guard let session, let selectedTable else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await session.rows(
                in: TableRef(schema: selectedTable.schema, name: selectedTable.name),
                pageSize: pageSize,
                page: page,
                sort: sortState,
                filter: activeFilter
            )
            if tableColumns.isEmpty {
                resultSet = result
            } else {
                resultSet = ResultSet(columns: tableColumns, rows: result.rows)
            }
            totalRows = try await session.rowCount(
                in: TableRef(schema: selectedTable.schema, name: selectedTable.name),
                filter: activeFilter
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func isResultProducingSQL(_ sql: String) -> Bool {
        let uppercased = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return uppercased.hasPrefix("SELECT")
            || uppercased.hasPrefix("WITH")
            || uppercased.hasPrefix("PRAGMA")
            || uppercased.hasPrefix("EXPLAIN")
    }

    private func recordSQLHistory(_ sql: String) {
        sqlHistory.removeAll { $0 == sql }
        sqlHistory.insert(sql, at: 0)
        if sqlHistory.count > 10 {
            sqlHistory.removeLast(sqlHistory.count - 10)
        }
    }

    private func resetWorkspace() {
        selectedSchema = nil
        resetTableSelection()
        sqlStatusMessage = ""
    }

    private func restoreWorkspaceSelection() async {
        guard windowState.connectionKey == currentConnectionKey,
              let schemaName = windowState.schemaName,
              let schema = schemas.first(where: { $0.name == schemaName }) else { return }
        if selectedSchema != schema {
            selectedSchema = schema
            do { tables = try await session?.tables(in: schema.name) ?? [] }
            catch { errorMessage = error.localizedDescription; return }
        }
        guard let tableName = windowState.tableName,
              let table = tables.first(where: { $0.name == tableName && $0.schema == schema.name }) else { return }
        await select(table)
    }

    private var currentConnectionKey: String? {
        guard let config = activeConnectionConfig else { return nil }
        switch config.kind {
        case .sqlite: return "sqlite:\(config.filePath ?? databasePath)"
        case .mysql, .postgresql:
            return "\(config.kind.rawValue):\(config.host ?? ""):\(config.port ?? 0):\(config.database ?? "")"
        }
    }

    private func resetTableSelection() {
        selectedTable = nil
        tableColumns = []
        resultSet = ResultSet(columns: [], rows: [])
        selectedCell = nil
        totalRows = nil
        page = 0
        sortState = nil
        filterColumn = ""
        filterOperator = .equals
        filterValue = ""
        discardPendingChanges()
    }

    private func persistProfile(_ profile: ConnectionProfile) throws {
        var updated = connectionProfiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        try profileStore.save(updated)
        connectionProfiles = updated.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func refreshSQLiteProfile(
        profileID: UUID,
        resolvedURL: URL,
        refreshedBookmark: Data?
    ) throws {
        guard let profile = connectionProfiles.first(where: { $0.id == profileID }) else {
            throw ConnectionProfileStoreError.savedConnectionNotFound
        }
        var updated = profile
        updated.filePath = resolvedURL.path
        if let refreshedBookmark {
            updated.sqliteBookmark = refreshedBookmark
        }
        try persistProfile(updated)
    }
}

private struct NoopSQLiteBookmarkAccess: SQLiteBookmarkAccessing {
    func make(for url: URL) throws -> Data { Data() }
    func resolve(_ bookmark: Data) throws -> SQLiteBookmarkResolution {
        throw ConnectionProfileStoreError.invalidSQLiteBookmark
    }
    func startAccessingSecurityScopedResource(at url: URL) -> Bool { true }
    func stopAccessingSecurityScopedResource(at url: URL) {}
}

protocol DatabaseDriverProviding: Sendable {
    func makeDriver(for kind: DatabaseKind) -> any DatabaseDriver
}

struct DefaultDatabaseDriverProvider: DatabaseDriverProviding {
    func makeDriver(for kind: DatabaseKind) -> any DatabaseDriver {
        switch kind {
        case .sqlite: SQLiteDriver()
        case .mysql: MySQLDriver()
        case .postgresql: PostgreSQLDriver()
        }
    }
}

struct CellSelection: Sendable, Hashable {
    let column: String
    let value: DBValue
}
