import Foundation
import AppKit
import Observation

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
    var pageSize = 200
    var totalRows: Int?
    var workspaceMode: WorkspaceMode = .table
    var sortState: SortState?
    var filterColumn = ""
    var filterOperator: FilterOperator = .equals
    var filterValue = ""
    var sqlText = "SELECT name, type FROM sqlite_master ORDER BY type, name"
    var sqlStatusMessage = ""
    var sqlHistory: [String] = []
    var autoLimitSelects = true
    var connectionProfiles: [ConnectionProfile] = []

    private var session: ConnectionSession?
    private var activeSecurityScopedURL: URL?
    private let profileStore: any ConnectionProfilePersisting
    private let passwordStore: any ConnectionPasswordStoring

    init(
        profileStore: (any ConnectionProfilePersisting)? = nil,
        passwordStore: any ConnectionPasswordStoring = KeychainPasswordStore()
    ) {
        self.passwordStore = passwordStore
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

    func openSQLite(path: String) async {
        isLoading = true
        errorMessage = nil
        await disconnectCurrentSession()
        resetWorkspace()
        databasePath = path
        connectionName = URL(fileURLWithPath: path).lastPathComponent
        sqlText = "SELECT name, type FROM sqlite_master ORDER BY type, name"

        let config = ConnectionConfig(name: connectionName, kind: .sqlite, filePath: path)
        let session = ConnectionSession(driver: SQLiteDriver())
        do {
            try await session.connect(config: config)
            self.session = session
            schemas = try await session.schemas()
            selectedSchema = schemas.first
            tables = try await session.tables(in: selectedSchema?.name ?? "main")
            screen = .database
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
        let session = ConnectionSession(driver: MySQLDriver())
        do {
            try await session.connect(config: config)
            self.session = session
            schemas = try await session.schemas()
            selectedSchema = schemas.first
            tables = try await session.tables(in: selectedSchema?.name ?? database)
            sqlText = "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = \(quoteLiteral(database)) ORDER BY table_type, table_name"
            screen = .database
        } catch {
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
        let session = ConnectionSession(driver: PostgreSQLDriver())
        do {
            try await session.connect(config: config)
            self.session = session
            schemas = try await session.schemas()
            selectedSchema = schemas.first
            tables = try await session.tables(in: selectedSchema?.name ?? "public")
            sqlText = "SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_type, table_name"
            screen = .database
        } catch {
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
            var updated = connectionProfiles
            if let index = updated.firstIndex(where: { $0.id == profile.id }) {
                updated[index] = profile
            } else {
                updated.append(profile)
            }
            let previousPassword = replacePassword ? try passwordStore.password(for: profile.id) : nil
            if replacePassword {
                if let password, !password.isEmpty {
                    try passwordStore.save(password: password, for: profile.id)
                } else {
                    try passwordStore.deletePassword(for: profile.id)
                }
            }
            do {
                try profileStore.save(updated)
            } catch {
                if replacePassword {
                    restorePassword(previousPassword, for: profile.id)
                }
                throw error
            }
            connectionProfiles = updated.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    }

    func testProfile(_ profile: ConnectionProfile) async {
        isLoading = true
        errorMessage = nil
        do {
            let sqlitePath: String?
            let password: String?
            if profile.kind == .sqlite {
                sqlitePath = try beginSQLiteAccess(for: profile)
                password = nil
            } else {
                sqlitePath = nil
                password = try passwordStore.password(for: profile.id)
            }
            let driver = driver(for: profile.kind)
            try await driver.connect(config: profile.connectionConfig(password: password, sqlitePath: sqlitePath))
            await driver.disconnect()
            endSQLiteAccess()
            infoMessage = "Connection test succeeded for \(profile.name)."
        } catch {
            endSQLiteAccess()
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func driver(for kind: DatabaseKind) -> any DatabaseDriver {
        switch kind {
        case .sqlite: SQLiteDriver()
        case .mysql: MySQLDriver()
        case .postgresql: PostgreSQLDriver()
        }
    }

    private func beginSQLiteAccess(for profile: ConnectionProfile) throws -> String {
        guard let path = profile.filePath else { throw DatabaseError.missingSQLitePath }
        guard let bookmark = profile.sqliteBookmark else { return path }
        let url = try SQLiteBookmark.resolve(bookmark)
        guard url.startAccessingSecurityScopedResource() else {
            throw ConnectionProfileStoreError.sqliteAccessDenied(url.path)
        }
        activeSecurityScopedURL = url
        return url.path
    }

    private func openSavedSQLite(_ profile: ConnectionProfile) async {
        isLoading = true
        errorMessage = nil
        await disconnectCurrentSession()
        resetWorkspace()
        do {
            let path = try beginSQLiteAccess(for: profile)
            databasePath = path
            connectionName = profile.name
            sqlText = "SELECT name, type FROM sqlite_master ORDER BY type, name"
            let session = ConnectionSession(driver: SQLiteDriver())
            try await session.connect(config: profile.connectionConfig(sqlitePath: path))
            self.session = session
            schemas = try await session.schemas()
            selectedSchema = schemas.first
            tables = try await session.tables(in: selectedSchema?.name ?? "main")
            screen = .database
        } catch {
            endSQLiteAccess()
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func endSQLiteAccess() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }

    private func disconnectCurrentSession() async {
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
        do {
            let tableColumns = try await session.columns(of: TableRef(schema: table.schema, name: table.name))
            self.tableColumns = tableColumns
            filterColumn = tableColumns.first?.name ?? ""
            await loadRows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard let session else { return }
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

        isLoading = true
        errorMessage = nil
        selectedCell = nil
        workspaceMode = .sql
        do {
            if isResultProducingSQL(sql) {
                let limit = autoLimitSelects ? 1000 : nil
                resultSet = try await session.query(sql, limit: limit)
                sqlStatusMessage = "\(resultSet.rows.count) rows"
            } else {
                let changedRows = try await session.execute(sql)
                resultSet = ResultSet(columns: [], rows: [])
                sqlStatusMessage = "\(changedRows) rows affected"
                tables = try await session.tables(in: selectedSchema?.name ?? schemas.first?.name ?? "main")
            }
            recordSQLHistory(sql)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
    }
}

struct CellSelection: Sendable, Hashable {
    let column: String
    let value: DBValue
}
