import Foundation

enum ConnectionProfileStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidSQLiteBookmark
    case sqliteAccessDenied(String)
    case sqliteBookmarkCreationFailed
    case savedConnectionNotFound

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "GlassDB could not access its Application Support folder. Choose another connection or try again."
        case .invalidSQLiteBookmark:
            return "The saved SQLite file permission is no longer valid. Edit this connection and choose the file again."
        case .sqliteAccessDenied(let path):
            return "GlassDB could not access \(path). Edit this connection and choose the file again."
        case .sqliteBookmarkCreationFailed:
            return "GlassDB could not save permission for the selected SQLite file. Choose the file again."
        case .savedConnectionNotFound:
            return "The saved connection was changed or deleted. Reopen the connection list and try again."
        }
    }
}

protocol ConnectionProfilePersisting: Sendable {
    func load() throws -> [ConnectionProfile]
    func save(_ profiles: [ConnectionProfile]) throws
}

struct ConnectionProfileStore: ConnectionProfilePersisting {
    let fileURL: URL

    init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ConnectionProfileStoreError.applicationSupportUnavailable
        }
        self.fileURL = directory
            .appending(path: "GlassDB", directoryHint: .isDirectory)
            .appending(path: "connections.json")
    }

    func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}

final class InMemoryConnectionProfileStore: ConnectionProfilePersisting, @unchecked Sendable {
    private var profiles: [ConnectionProfile] = []

    func load() throws -> [ConnectionProfile] { profiles }

    func save(_ profiles: [ConnectionProfile]) throws {
        self.profiles = profiles
    }
}

struct SQLiteBookmarkResolution: Sendable {
    let url: URL
    let isStale: Bool
}

protocol SQLiteBookmarkAccessing: Sendable {
    func make(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> SQLiteBookmarkResolution
    func startAccessingSecurityScopedResource(at url: URL) -> Bool
    func stopAccessingSecurityScopedResource(at url: URL)
}

struct SQLiteBookmark: SQLiteBookmarkAccessing {
    func make(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw ConnectionProfileStoreError.sqliteBookmarkCreationFailed
        }
    }

    func resolve(_ bookmark: Data) throws -> SQLiteBookmarkResolution {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return SQLiteBookmarkResolution(url: url, isStale: isStale)
        } catch {
            throw ConnectionProfileStoreError.invalidSQLiteBookmark
        }
    }

    func startAccessingSecurityScopedResource(at url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScopedResource(at url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

struct SQLiteSecurityScopedResource: Sendable {
    let url: URL
    private let bookmarkAccess: any SQLiteBookmarkAccessing

    init(url: URL, bookmarkAccess: any SQLiteBookmarkAccessing) {
        self.url = url
        self.bookmarkAccess = bookmarkAccess
    }

    func endAccess() {
        bookmarkAccess.stopAccessingSecurityScopedResource(at: url)
    }
}
