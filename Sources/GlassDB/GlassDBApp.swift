import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct GlassDBCommandActions {
    let canOpenSQL: Bool
    let canRefresh: Bool
    let canApply: Bool
    let canFocusFilter: Bool
    let openSQL: () -> Void
    let refresh: () -> Void
    let apply: () -> Void
    let focusFilter: () -> Void
}

private struct GlassDBCommandActionsKey: FocusedValueKey {
    typealias Value = GlassDBCommandActions
}

extension FocusedValues {
    var glassDBCommands: GlassDBCommandActions? {
        get { self[GlassDBCommandActionsKey.self] }
        set { self[GlassDBCommandActionsKey.self] = newValue }
    }
}

struct GlassDBCommands: Commands {
    @FocusedValue(\.glassDBCommands) private var actions

    var body: some Commands {
        CommandMenu("Database") {
            Button("Open SQL Editor", action: { actions?.openSQL() })
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions?.canOpenSQL != true)
            Button("Refresh", action: { actions?.refresh() })
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.canRefresh != true)
            Divider()
            Button("Apply Pending Changes", action: { actions?.apply() })
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions?.canApply != true)
            Button("Focus Table Filter", action: { actions?.focusFilter() })
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.canFocusFilter != true)
        }
    }
}

@main
struct GlassDBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var preferences = AppPreferences()
    @StateObject private var updaterModel = UpdaterModel()

    var body: some Scene {
        WindowGroup("GlassDB") {
            WindowIdentityRoot(preferences: preferences)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            GlassDBCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") { updaterModel.checkForUpdates() }
                    .disabled(!updaterModel.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environment(preferences)
        }
    }
}

private struct WindowIdentityRoot: View {
    private static let allocator = WindowIdentityAllocator()
    let preferences: AppPreferences
    private let claimedID: String
    @SceneStorage("windowIdentity") private var storedWindowID: String?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        let claimedID = Self.allocator.claim()
        self.claimedID = claimedID
    }

    var body: some View {
        let windowID = storedWindowID ?? claimedID
        WindowModelHost(preferences: preferences, windowID: windowID)
            .id(windowID)
            .onAppear {
                if storedWindowID == nil { storedWindowID = claimedID }
                Self.allocator.activate(windowID, replacing: claimedID)
            }
            .onDisappear { Self.allocator.release(windowID) }
    }
}

private struct WindowModelHost: View {
    @State private var model: AppModel

    init(preferences: AppPreferences, windowID: String) {
        _model = State(initialValue: AppModel(
            preferences: preferences,
            windowState: WindowState(windowID: windowID)
        ))
    }

    var body: some View {
        ContentView()
            .environment(model)
            .focusedSceneValue(\.glassDBCommands, GlassDBCommandActions(
                canOpenSQL: model.canOpenSQLWorkspace,
                canRefresh: model.canRefresh,
                canApply: model.canApplyPendingChanges,
                canFocusFilter: model.canFocusTableFilter,
                openSQL: { model.showSQLWorkspace() },
                refresh: { Task { await model.refresh() } },
                apply: { Task { await model.applyPendingChanges() } },
                focusFilter: { model.requestTableFilterFocus() }
            ))
    }
}

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Picker("Default page size", selection: $preferences.pageSize) {
                ForEach(AppPreferenceValues.allowedPageSizes, id: \.self) { size in
                    Text("\(size) rows").tag(size)
                }
            }
            Picker("Query timeout", selection: $preferences.queryTimeoutSeconds) {
                ForEach(AppPreferenceValues.allowedQueryTimeouts, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            Toggle("Add LIMIT 1000 to SELECT queries by default", isOn: $preferences.autoLimitSelects)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
