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

    @Test
    func profilesProduceConnectionConfigsForEachSupportedDatabase() {
        let sqlite = ConnectionProfile(name: "SQLite", kind: .sqlite, filePath: "/tmp/data.sqlite")
        let mysql = ConnectionProfile(name: "MySQL", kind: .mysql, host: "localhost", port: 3306, database: "app", user: "reader")
        let postgresql = ConnectionProfile(name: "PostgreSQL", kind: .postgresql, host: "localhost", port: 5432, database: "app", user: "reader")

        #expect(sqlite.connectionConfig().filePath == "/tmp/data.sqlite")
        #expect(mysql.connectionConfig(password: "secret").password == "secret")
        #expect(postgresql.connectionConfig().kind == .postgresql)
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
