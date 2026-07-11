import Foundation
import Observation

struct AppPreferenceValues: Equatable, Sendable {
    static let defaultPageSize = 200
    static let defaultQueryTimeout = 30
    static let allowedPageSizes = [50, 100, 200, 500, 1_000]
    static let allowedQueryTimeouts = [5, 10, 30, 60, 120]

    var pageSize: Int
    var queryTimeoutSeconds: Int
    var autoLimitSelects: Bool

    static let defaults = AppPreferenceValues(
        pageSize: defaultPageSize,
        queryTimeoutSeconds: defaultQueryTimeout,
        autoLimitSelects: true
    )

    static func sanitized(pageSize: Int, queryTimeoutSeconds: Int, autoLimitSelects: Bool) -> Self {
        Self(
            pageSize: allowedPageSizes.contains(pageSize) ? pageSize : defaultPageSize,
            queryTimeoutSeconds: allowedQueryTimeouts.contains(queryTimeoutSeconds) ? queryTimeoutSeconds : defaultQueryTimeout,
            autoLimitSelects: autoLimitSelects
        )
    }
}

protocol AppPreferencesPersisting: AnyObject {
    func load() -> AppPreferenceValues
    func save(_ values: AppPreferenceValues)
}

final class UserDefaultsAppPreferencesStore: AppPreferencesPersisting {
    private enum Key {
        static let pageSize = "preferences.pageSize"
        static let queryTimeout = "preferences.queryTimeoutSeconds"
        static let autoLimit = "preferences.autoLimitSelects"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> AppPreferenceValues {
        let pageSize = defaults.object(forKey: Key.pageSize) as? Int ?? AppPreferenceValues.defaultPageSize
        let timeout = defaults.object(forKey: Key.queryTimeout) as? Int ?? AppPreferenceValues.defaultQueryTimeout
        let autoLimit = defaults.object(forKey: Key.autoLimit) as? Bool ?? true
        let values = AppPreferenceValues.sanitized(pageSize: pageSize, queryTimeoutSeconds: timeout, autoLimitSelects: autoLimit)
        save(values) // Migrates missing or out-of-range legacy values to supported defaults.
        return values
    }

    func save(_ values: AppPreferenceValues) {
        let values = AppPreferenceValues.sanitized(
            pageSize: values.pageSize,
            queryTimeoutSeconds: values.queryTimeoutSeconds,
            autoLimitSelects: values.autoLimitSelects
        )
        defaults.set(values.pageSize, forKey: Key.pageSize)
        defaults.set(values.queryTimeoutSeconds, forKey: Key.queryTimeout)
        defaults.set(values.autoLimitSelects, forKey: Key.autoLimit)
    }
}

@MainActor @Observable
final class AppPreferences {
    private let store: any AppPreferencesPersisting
    private var storedPageSize: Int
    private var storedQueryTimeoutSeconds: Int
    var pageSize: Int {
        get { storedPageSize }
        set { storedPageSize = AppPreferenceValues.allowedPageSizes.contains(newValue) ? newValue : AppPreferenceValues.defaultPageSize; persist() }
    }
    var queryTimeoutSeconds: Int {
        get { storedQueryTimeoutSeconds }
        set { storedQueryTimeoutSeconds = AppPreferenceValues.allowedQueryTimeouts.contains(newValue) ? newValue : AppPreferenceValues.defaultQueryTimeout; persist() }
    }
    var autoLimitSelects: Bool { didSet { persist() } }

    init(store: any AppPreferencesPersisting = UserDefaultsAppPreferencesStore()) {
        self.store = store
        let values = store.load()
        storedPageSize = values.pageSize
        storedQueryTimeoutSeconds = values.queryTimeoutSeconds
        autoLimitSelects = values.autoLimitSelects
    }

    private func persist() {
        store.save(AppPreferenceValues(
            pageSize: pageSize,
            queryTimeoutSeconds: queryTimeoutSeconds,
            autoLimitSelects: autoLimitSelects
        ))
    }
}

struct WindowWorkspaceState: Codable, Equatable, Sendable {
    static let defaultSidebarWidth = 300.0
    static let defaultInspectorWidth = 320.0
    static let sidebarBounds = 260.0...380.0
    static let inspectorBounds = 260.0...480.0

    var sidebarWidth = defaultSidebarWidth
    var inspectorWidth = defaultInspectorWidth
    var connectionKey: String?
    var schemaName: String?
    var tableName: String?

    var sanitized: Self {
        var value = self
        value.sidebarWidth = min(max(sidebarWidth, Self.sidebarBounds.lowerBound), Self.sidebarBounds.upperBound)
        value.inspectorWidth = min(max(inspectorWidth, Self.inspectorBounds.lowerBound), Self.inspectorBounds.upperBound)
        return value
    }
}

protocol WindowStatePersisting: AnyObject {
    func load(windowID: String) -> WindowWorkspaceState
    func save(_ state: WindowWorkspaceState, windowID: String)
}

final class UserDefaultsWindowStateStore: WindowStatePersisting {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(windowID: String) -> WindowWorkspaceState {
        guard let data = defaults.data(forKey: key(windowID)),
              let value = try? decoder.decode(WindowWorkspaceState.self, from: data) else {
            return WindowWorkspaceState()
        }
        return value.sanitized
    }

    func save(_ state: WindowWorkspaceState, windowID: String) {
        defaults.set(try? encoder.encode(state.sanitized), forKey: key(windowID))
    }

    private func key(_ windowID: String) -> String { "windowState.\(windowID)" }
}

@MainActor @Observable
final class WindowState {
    let windowID: String
    private let store: any WindowStatePersisting
    var sidebarWidth: Double { didSet { persist() } }
    var inspectorWidth: Double { didSet { persist() } }
    var connectionKey: String? { didSet { persist() } }
    var schemaName: String? { didSet { persist() } }
    var tableName: String? { didSet { persist() } }

    init(windowID: String, store: any WindowStatePersisting = UserDefaultsWindowStateStore()) {
        self.windowID = windowID
        self.store = store
        let value = store.load(windowID: windowID)
        sidebarWidth = value.sidebarWidth
        inspectorWidth = value.inspectorWidth
        connectionKey = value.connectionKey
        schemaName = value.schemaName
        tableName = value.tableName
    }

    func updateSidebarWidth(_ width: Double) {
        guard width >= WindowWorkspaceState.sidebarBounds.lowerBound else { return }
        sidebarWidth = min(max(width, WindowWorkspaceState.sidebarBounds.lowerBound), WindowWorkspaceState.sidebarBounds.upperBound)
    }

    func updateInspectorWidth(_ width: Double) {
        guard width >= WindowWorkspaceState.inspectorBounds.lowerBound else { return }
        inspectorWidth = min(max(width, WindowWorkspaceState.inspectorBounds.lowerBound), WindowWorkspaceState.inspectorBounds.upperBound)
    }

    private func persist() {
        store.save(WindowWorkspaceState(
            sidebarWidth: sidebarWidth,
            inspectorWidth: inspectorWidth,
            connectionKey: connectionKey,
            schemaName: schemaName,
            tableName: tableName
        ), windowID: windowID)
    }
}

@MainActor
final class WindowIdentityAllocator {
    private let defaults: UserDefaults
    private let key: String
    private var activeIDs: Set<String> = []

    init(defaults: UserDefaults = .standard, key: String = "windowState.lastIdentity") {
        self.defaults = defaults
        self.key = key
    }

    func claim() -> String {
        let saved = defaults.string(forKey: key)
        let id = saved.flatMap { activeIDs.contains($0) ? nil : $0 } ?? UUID().uuidString
        activeIDs.insert(id)
        defaults.set(id, forKey: key)
        return id
    }

    func activate(_ id: String, replacing claimedID: String) {
        activeIDs.remove(claimedID)
        activeIDs.insert(id)
        defaults.set(id, forKey: key)
    }

    func release(_ id: String) { activeIDs.remove(id) }
}
