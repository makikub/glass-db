import Foundation
import Security
import Testing
@testable import GlassDB

@Suite
struct ConnectionProfileTests {
    @Test
    func persistsProfilesWithoutPasswordsAndRestoresThem() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "GlassDBProfileTests-\(UUID().uuidString)/connections.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try ConnectionProfileStore(fileURL: url)
        let profile = ConnectionProfile(
            name: "Local MySQL",
            kind: .mysql,
            host: "127.0.0.1",
            port: 3306,
            database: "glassdb",
            user: "glassdb"
        )
        try store.save([profile])

        #expect(try store.load() == [profile])
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.localizedCaseInsensitiveContains("password"))
        #expect(!json.contains("secret-value"))
    }

    @Test @MainActor
    func appModelKeepsPasswordsInKeychainStoreAcrossProfileOperations() throws {
        let profiles = TestProfileStore()
        let passwords = TestPasswordStore()
        let model = AppModel(profileStore: profiles, passwordStore: passwords)
        let profile = ConnectionProfile(
            name: "Production PostgreSQL",
            kind: .postgresql,
            host: "db.example.test",
            port: 5432,
            database: "app",
            user: "reader"
        )

        model.saveProfile(profile, password: "secret-value", replacePassword: true)
        #expect(model.connectionProfiles == [profile])
        #expect(try passwords.password(for: profile.id) == "secret-value")
        #expect(profiles.savedProfiles.first?.connectionConfig().password == nil)

        let restored = AppModel(profileStore: profiles, passwordStore: passwords)
        #expect(restored.connectionProfiles == [profile])

        restored.duplicateProfile(profile)
        #expect(restored.connectionProfiles.count == 2)
        let copy = try #require(restored.connectionProfiles.first(where: { $0.id != profile.id }))
        #expect(try passwords.password(for: copy.id) == "secret-value")

        restored.deleteProfile(profile)
        #expect(restored.connectionProfiles.map(\.id) == [copy.id])
        #expect(try passwords.password(for: profile.id) == nil)
    }

    @Test @MainActor
    func keychainFailureIsPresentedAsRecoverableError() {
        let profile = ConnectionProfile(name: "DB", kind: .mysql, host: "localhost", port: 3306, database: "db", user: "me")
        let model = AppModel(profileStore: TestProfileStore(), passwordStore: FailingPasswordStore())

        model.saveProfile(profile, password: "secret", replacePassword: true)

        #expect(model.errorMessage?.contains("Keychain") == true)
    }

    @Test @MainActor
    func keychainDeleteFailureKeepsProfileAvailableForRecovery() {
        let profile = ConnectionProfile(name: "DB", kind: .mysql, host: "localhost", port: 3306, database: "db", user: "me")
        let model = AppModel(profileStore: TestProfileStore(profiles: [profile]), passwordStore: FailingPasswordStore())

        model.deleteProfile(profile)

        #expect(model.connectionProfiles == [profile])
        #expect(model.errorMessage?.contains("Keychain") == true)
    }

    @Test @MainActor
    func connectionTestPreservesDatabaseFailureMessage() async {
        let profile = ConnectionProfile(
            name: "Unreadable SQLite",
            kind: .sqlite,
            filePath: FileManager.default.temporaryDirectory.path
        )
        let model = AppModel(profileStore: TestProfileStore(), passwordStore: TestPasswordStore())

        await model.testProfile(profile)

        #expect(model.errorMessage?.localizedCaseInsensitiveContains("SQLite connection failed") == true)
    }

    @Test @MainActor
    func selectedSQLiteFileCreatesBookmarkAndPersistsProfileWithoutCredentials() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Selected.sqlite")
        let profiles = TestProfileStore()
        let bookmarkAccess = TestSQLiteBookmarkAccess(url: url, createdBookmark: Data("bookmark".utf8))
        let model = AppModel(
            profileStore: profiles,
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: bookmarkAccess
        )

        let profile = try model.preparedSQLiteProfile(ConnectionProfile(name: "", kind: .sqlite), selectedURL: url)
        model.saveProfile(profile, password: nil, replacePassword: false)

        #expect(profile.name == "Selected")
        #expect(profile.filePath == url.path)
        #expect(profile.sqliteBookmark == Data("bookmark".utf8))
        #expect(bookmarkAccess.createdURLs == [url])
        #expect(profiles.savedProfiles == [profile])
        #expect(profile.connectionConfig().password == nil)
    }

    @Test @MainActor
    func savedSQLiteProfileRestoresAccessAndEndsItWhenReplacingTheSession() async throws {
        let url = try makeSQLiteDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = ConnectionProfile(
            name: "Restored SQLite",
            kind: .sqlite,
            filePath: url.path,
            sqliteBookmark: Data("bookmark".utf8)
        )
        let profiles = TestProfileStore(profiles: [profile])
        let bookmarkAccess = TestSQLiteBookmarkAccess(url: url)
        let restoredModel = AppModel(
            profileStore: profiles,
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: bookmarkAccess
        )

        await restoredModel.connectProfile(profile)
        #expect(restoredModel.errorMessage == nil)
        #expect(restoredModel.databasePath == url.path)
        #expect(bookmarkAccess.startedURLs == [url])

        await restoredModel.openSQLite(path: url.path)
        #expect(bookmarkAccess.stoppedURLs == [url])
    }

    @Test @MainActor
    func staleSQLiteBookmarkIsRegeneratedAndPersisted() async throws {
        let originalURL = FileManager.default.temporaryDirectory.appending(path: "Moved-\(UUID().uuidString).sqlite")
        let resolvedURL = try makeSQLiteDatabase()
        defer { try? FileManager.default.removeItem(at: resolvedURL) }
        let oldBookmark = Data("old-bookmark".utf8)
        let refreshedBookmark = Data("refreshed-bookmark".utf8)
        let events = LockedEvents()
        let profile = ConnectionProfile(name: "Stale SQLite", kind: .sqlite, filePath: originalURL.path, sqliteBookmark: oldBookmark)
        let profiles = TestProfileStore(profiles: [profile])
        let bookmarkAccess = TestSQLiteBookmarkAccess(
            url: resolvedURL,
            createdBookmark: refreshedBookmark,
            isStale: true,
            events: events
        )
        let model = AppModel(
            profileStore: profiles,
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: bookmarkAccess
        )

        await model.testProfile(profile)

        #expect(model.errorMessage == nil)
        #expect(profiles.savedProfiles == [ConnectionProfile(id: profile.id, name: "Stale SQLite", kind: .sqlite, filePath: resolvedURL.path, sqliteBookmark: refreshedBookmark)])
        #expect(bookmarkAccess.createdURLs == [resolvedURL])
        #expect(bookmarkAccess.startedURLs == [resolvedURL])
        #expect(bookmarkAccess.stoppedURLs == [resolvedURL])
        #expect(events.values == ["resolve", "start", "make", "stop"])
    }

    @Test @MainActor
    func inaccessibleOrUnresolvableSQLiteBookmarkShowsRecoverableErrorWithoutLeakingAccess() async throws {
        let url = try makeSQLiteDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = ConnectionProfile(name: "Unavailable SQLite", kind: .sqlite, filePath: url.path, sqliteBookmark: Data("bookmark".utf8))

        let deniedAccess = TestSQLiteBookmarkAccess(url: url, allowsAccess: false)
        let deniedModel = AppModel(
            profileStore: TestProfileStore(profiles: [profile]),
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: deniedAccess
        )
        await deniedModel.testProfile(profile)
        #expect(deniedModel.errorMessage?.contains("could not access") == true)
        #expect(deniedAccess.stoppedURLs.isEmpty)

        let unresolvedAccess = TestSQLiteBookmarkAccess(url: url, resolveError: ConnectionProfileStoreError.invalidSQLiteBookmark)
        let unresolvedModel = AppModel(
            profileStore: TestProfileStore(profiles: [profile]),
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: unresolvedAccess
        )
        await unresolvedModel.testProfile(profile)
        #expect(unresolvedModel.errorMessage?.contains("permission is no longer valid") == true)
        #expect(unresolvedAccess.startedURLs.isEmpty)
        #expect(unresolvedAccess.stoppedURLs.isEmpty)
    }

    @Test @MainActor
    func metadataFailureDisconnectsBeforeEndingSecurityScope() async throws {
        let url = try makeSQLiteDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let events = LockedEvents()
        let profile = ConnectionProfile(name: "Metadata failure", kind: .sqlite, filePath: url.path, sqliteBookmark: Data("bookmark".utf8))
        let bookmarkAccess = TestSQLiteBookmarkAccess(url: url, events: events)
        let driver = LifecycleTestDriver(events: events, failSchemas: true)
        let model = AppModel(
            profileStore: TestProfileStore(profiles: [profile]),
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: bookmarkAccess,
            driverProvider: TestDriverProvider(driver: driver)
        )

        await model.connectProfile(profile)

        #expect(model.errorMessage?.contains("Metadata failed") == true)
        #expect(events.values == ["resolve", "start", "connect", "schemas", "disconnect", "stop"])
        #expect(bookmarkAccess.stoppedURLs == [url])
    }

    @Test @MainActor
    func bookmarkResolvedButDatabaseOpenFailsWithReselectionGuidance() async {
        let url = URL(fileURLWithPath: "/tmp/Unavailable.sqlite")
        let events = LockedEvents()
        let profile = ConnectionProfile(name: "Unavailable", kind: .sqlite, filePath: url.path, sqliteBookmark: Data("bookmark".utf8))
        let bookmarkAccess = TestSQLiteBookmarkAccess(url: url, events: events)
        let driver = LifecycleTestDriver(events: events, failConnect: true)
        let model = AppModel(
            profileStore: TestProfileStore(profiles: [profile]),
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: bookmarkAccess,
            driverProvider: TestDriverProvider(driver: driver)
        )

        await model.connectProfile(profile)

        #expect(model.errorMessage?.contains("Edit this connection and choose the file again") == true)
        #expect(events.values == ["resolve", "start", "connect", "disconnect", "stop"])
    }

    @Test @MainActor
    func staleBookmarkRefreshFailuresEndAccessAndKeepThePreviousProfile() async throws {
        let url = try makeSQLiteDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = ConnectionProfile(name: "Refresh failure", kind: .sqlite, filePath: url.path, sqliteBookmark: Data("old".utf8))

        let makeFailure = TestSQLiteBookmarkAccess(
            url: url,
            isStale: true,
            makeError: ConnectionProfileStoreError.sqliteBookmarkCreationFailed
        )
        let makeFailureModel = AppModel(
            profileStore: TestProfileStore(profiles: [profile]),
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: makeFailure
        )
        await makeFailureModel.testProfile(profile)
        #expect(makeFailureModel.connectionProfiles == [profile])
        #expect(makeFailureModel.errorMessage?.contains("could not save permission") == true)
        #expect(makeFailure.startedURLs == [url])
        #expect(makeFailure.stoppedURLs == [url])

        let saveFailure = TestSQLiteBookmarkAccess(url: url, createdBookmark: Data("new".utf8), isStale: true)
        let saveFailureModel = AppModel(
            profileStore: FailingProfileStore(profiles: [profile]),
            passwordStore: TestPasswordStore(),
            sqliteBookmarkAccess: saveFailure
        )
        await saveFailureModel.testProfile(profile)
        #expect(saveFailureModel.connectionProfiles == [profile])
        #expect(saveFailureModel.errorMessage != nil)
        #expect(saveFailure.startedURLs == [url])
        #expect(saveFailure.stoppedURLs == [url])
    }

    @Test
    func profilesProduceConnectionConfigsForEachSupportedDatabase() {
        let sqlite = ConnectionProfile(name: "SQLite", kind: .sqlite, filePath: "/tmp/data.sqlite")
        let mysql = ConnectionProfile(name: "MySQL", kind: .mysql, host: "localhost", port: 3306, database: "app", user: "reader")
        let postgresql = ConnectionProfile(name: "PostgreSQL", kind: .postgresql, host: "localhost", port: 5432, database: "app", user: "reader")

        #expect(sqlite.connectionConfig().filePath == "/tmp/data.sqlite")
        #expect(mysql.connectionConfig(password: "secret").password == "secret")
        #expect(postgresql.connectionConfig().kind == .postgresql)
    }

    @Test
    func legacySQLiteProfileWithoutBookmarkStillDecodes() throws {
        let id = UUID()
        let json = """
        [{
          "id": "\(id.uuidString)",
          "name": "Legacy SQLite",
          "kind": "SQLite",
          "filePath": "/tmp/legacy.sqlite"
        }]
        """

        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))

        #expect(profiles.count == 1)
        #expect(profiles[0].id == id)
        #expect(profiles[0].sqliteBookmark == nil)
    }

    @Test
    func securityScopedBookmarkRoundTripsSelectedSQLiteURL() throws {
        let url = try makeSQLiteDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmarkAccess = SQLiteBookmark()

        let bookmark = try bookmarkAccess.make(for: url)
        let resolution = try bookmarkAccess.resolve(bookmark)

        #expect(!bookmark.isEmpty)
        #expect(resolution.url.standardizedFileURL == url.standardizedFileURL)
        #expect(!resolution.isStale)
    }

    @Test @MainActor
    func profileSaveFailureRestoresExistingPassword() throws {
        let profile = ConnectionProfile(name: "DB", kind: .mysql, host: "localhost", port: 3306, database: "db", user: "me")
        let passwords = TestPasswordStore()
        try passwords.save(password: "previous", for: profile.id)
        let model = AppModel(profileStore: FailingProfileStore(), passwordStore: passwords)

        model.saveProfile(profile, password: "replacement", replacePassword: true)

        #expect(try passwords.password(for: profile.id) == "previous")
        #expect(model.connectionProfiles.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test @MainActor
    func failedDeleteAndDuplicateLeaveKeychainConsistent() throws {
        let profile = ConnectionProfile(name: "DB", kind: .postgresql, host: "localhost", port: 5432, database: "db", user: "me")
        let passwords = TestPasswordStore()
        try passwords.save(password: "secret", for: profile.id)
        let model = AppModel(profileStore: FailingProfileStore(profiles: [profile]), passwordStore: passwords)

        model.deleteProfile(profile)
        #expect(try passwords.password(for: profile.id) == "secret")

        model.duplicateProfile(profile)
        #expect(model.connectionProfiles == [profile])
        #expect(try passwords.password(for: profile.id) == "secret")
    }
}

private final class TestProfileStore: ConnectionProfilePersisting, @unchecked Sendable {
    var savedProfiles: [ConnectionProfile]

    init(profiles: [ConnectionProfile] = []) {
        self.savedProfiles = profiles
    }

    func load() throws -> [ConnectionProfile] { savedProfiles }

    func save(_ profiles: [ConnectionProfile]) throws { savedProfiles = profiles }
}

private final class TestPasswordStore: ConnectionPasswordStoring, @unchecked Sendable {
    private var passwords: [UUID: String] = [:]

    func password(for profileID: UUID) throws -> String? { passwords[profileID] }

    func save(password: String, for profileID: UUID) throws { passwords[profileID] = password }

    func deletePassword(for profileID: UUID) throws { passwords.removeValue(forKey: profileID) }
}

private final class FailingProfileStore: ConnectionProfilePersisting, @unchecked Sendable {
    private let profiles: [ConnectionProfile]

    init(profiles: [ConnectionProfile] = []) {
        self.profiles = profiles
    }

    func load() throws -> [ConnectionProfile] { profiles }

    func save(_ profiles: [ConnectionProfile]) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct FailingPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: UUID) throws -> String? { nil }

    func save(password: String, for profileID: UUID) throws {
        throw KeychainPasswordStoreError.unexpectedStatus(errSecAuthFailed)
    }

    func deletePassword(for profileID: UUID) throws {
        throw KeychainPasswordStoreError.unexpectedStatus(errSecAuthFailed)
    }
}

private func makeSQLiteDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "GlassDBBookmarkTests-\(UUID().uuidString).sqlite")
    FileManager.default.createFile(atPath: url.path, contents: Data())
    return url
}

private final class TestSQLiteBookmarkAccess: SQLiteBookmarkAccessing, @unchecked Sendable {
    let url: URL
    let createdBookmark: Data
    let isStale: Bool
    let allowsAccess: Bool
    let resolveError: Error?
    let makeError: Error?
    let events: LockedEvents?
    private(set) var createdURLs: [URL] = []
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    init(
        url: URL,
        createdBookmark: Data = Data("bookmark".utf8),
        isStale: Bool = false,
        allowsAccess: Bool = true,
        resolveError: Error? = nil,
        makeError: Error? = nil,
        events: LockedEvents? = nil
    ) {
        self.url = url
        self.createdBookmark = createdBookmark
        self.isStale = isStale
        self.allowsAccess = allowsAccess
        self.resolveError = resolveError
        self.makeError = makeError
        self.events = events
    }

    func make(for url: URL) throws -> Data {
        events?.record("make")
        createdURLs.append(url)
        if let makeError { throw makeError }
        return createdBookmark
    }

    func resolve(_ bookmark: Data) throws -> SQLiteBookmarkResolution {
        events?.record("resolve")
        if let resolveError { throw resolveError }
        return SQLiteBookmarkResolution(url: url, isStale: isStale)
    }

    func startAccessingSecurityScopedResource(at url: URL) -> Bool {
        events?.record("start")
        startedURLs.append(url)
        return allowsAccess
    }

    func stopAccessingSecurityScopedResource(at url: URL) {
        events?.record("stop")
        stoppedURLs.append(url)
    }
}

private struct TestDriverProvider: DatabaseDriverProviding {
    let driver: any DatabaseDriver

    func makeDriver(for kind: DatabaseKind) -> any DatabaseDriver { driver }
}

private actor LifecycleTestDriver: DatabaseDriver {
    let events: LockedEvents
    let failConnect: Bool
    let failSchemas: Bool

    init(events: LockedEvents, failConnect: Bool = false, failSchemas: Bool = false) {
        self.events = events
        self.failConnect = failConnect
        self.failSchemas = failSchemas
    }

    func connect(config: ConnectionConfig) async throws {
        events.record("connect")
        if failConnect { throw DatabaseError.connectionFailed("Open failed") }
    }

    func schemas() async throws -> [SchemaInfo] {
        events.record("schemas")
        if failSchemas { throw DatabaseError.connectionFailed("Metadata failed") }
        return [SchemaInfo(name: "main")]
    }

    func tables(in schema: String) async throws -> [TableInfo] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { [] }
    func query(_ sql: String, limit: Int?) async throws -> ResultSet { ResultSet(columns: [], rows: []) }
    func execute(_ sql: String) async throws -> Int { 0 }

    func disconnect() async {
        events.record("disconnect")
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}
