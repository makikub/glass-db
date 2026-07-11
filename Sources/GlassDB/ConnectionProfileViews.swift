import SwiftUI
import UniformTypeIdentifiers

struct SavedConnectionsView: View {
    @Environment(AppModel.self) private var model
    @Binding var editorProfile: ConnectionProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved Connections")
                    .font(.headline)
                Spacer()
                Button {
                    editorProfile = ConnectionProfile(name: "", kind: .sqlite)
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
            }

            List(model.connectionProfiles) { profile in
                ConnectionProfileRow(profile: profile, editorProfile: $editorProfile)
            }
            .frame(minHeight: 150, maxHeight: 240)
            .overlay {
                if model.connectionProfiles.isEmpty {
                    ContentUnavailableView(
                        "No Saved Connections",
                        systemImage: "cylinder.split.1x2",
                        description: Text("Create a connection to reopen it later.")
                    )
                }
            }
        }
    }
}

private struct ConnectionProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: ConnectionProfile
    @Binding var editorProfile: ConnectionProfile?

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(profile.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Test") { Task { await model.testProfile(profile) } }
                .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.connectProfile(profile) } }
        .contextMenu {
            Button("Connect") { Task { await model.connectProfile(profile) } }
            Button("Edit") { editorProfile = profile }
            Button("Duplicate") { model.duplicateProfile(profile) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteProfile(profile) }
        }
    }

    private var iconName: String {
        switch profile.kind {
        case .sqlite: "doc.text"
        case .mysql: "cylinder"
        case .postgresql: "shippingbox"
        }
    }

    private var detail: String {
        switch profile.kind {
        case .sqlite: profile.filePath ?? "SQLite file not selected"
        case .mysql, .postgresql:
            "\(profile.kind.rawValue) · \(profile.host ?? ""):\(profile.port ?? 0)/\(profile.database ?? "")"
        }
    }
}

struct ConnectionProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile
    @State private var password = ""
    @State private var replacePassword = true
    @State private var isFileImporterPresented = false

    init(profile: ConnectionProfile) {
        _profile = State(initialValue: profile)
        _replacePassword = State(initialValue: profile.name.isEmpty)
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $profile.name)
                Picker("Database", selection: kindBinding) {
                    ForEach(DatabaseKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
            }
            if profile.kind == .sqlite {
                Section("SQLite File") {
                    Text(profile.filePath ?? "No file selected")
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Button("Choose File…") { isFileImporterPresented = true }
                }
            } else {
                Section("Server") {
                    TextField("Host", text: optionalBinding(\.host, default: "127.0.0.1"))
                    TextField("Port", value: optionalBinding(\.port, default: defaultPort), format: .number)
                    TextField("Database", text: optionalBinding(\.database, default: ""))
                    TextField("User", text: optionalBinding(\.user, default: ""))
                }
                Section("Password") {
                    Toggle("Replace saved password", isOn: $replacePassword)
                    if replacePassword {
                        SecureField("Password", text: $password)
                        Text("Leave blank to remove the saved password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveProfile(profile, password: password, replacePassword: replacePassword)
                    if model.errorMessage == nil { dismiss() }
                }
                .disabled(!isValid)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.database, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                profile.filePath = url.path
                profile.sqliteBookmark = try SQLiteBookmark.make(for: url)
                if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.name = url.deletingPathExtension().lastPathComponent
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var defaultPort: Int { profile.kind == .mysql ? 3306 : 5432 }

    private var kindBinding: Binding<DatabaseKind> {
        Binding(
            get: { profile.kind },
            set: { kind in
                profile.kind = kind
                guard kind != .sqlite else { return }
                profile.host = profile.host ?? "127.0.0.1"
                profile.port = kind == .mysql ? 3306 : 5432
            }
        )
    }

    private var isValid: Bool {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch profile.kind {
        case .sqlite: return profile.filePath != nil
        case .mysql, .postgresql:
            return !(profile.host ?? "").isEmpty && profile.port != nil && !(profile.database ?? "").isEmpty && !(profile.user ?? "").isEmpty
        }
    }

    private func optionalBinding<T>(_ keyPath: WritableKeyPath<ConnectionProfile, T?>, default value: T) -> Binding<T> {
        Binding(get: { profile[keyPath: keyPath] ?? value }, set: { profile[keyPath: keyPath] = $0 })
    }
}
