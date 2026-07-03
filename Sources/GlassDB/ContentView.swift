import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isImporterPresented = false

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.screen {
            case .welcome:
                WelcomeView(isImporterPresented: $isImporterPresented)
            case .database:
                DatabaseView()
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.database, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.openSQLite(path: url.path) }
        }
        .alert("Database Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("GlassDB", isPresented: Binding(
            get: { model.infoMessage != nil },
            set: { if !$0 { model.infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.infoMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var isImporterPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("GlassDB")
                    .font(.system(size: 44, weight: .semibold))
                Text("Open a SQLite database and inspect tables in a read-only grid.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Open SQLite File", systemImage: "folder")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.createSampleDatabase() }
                } label: {
                    Label("Create Sample", systemImage: "sparkles")
                }
                .controlSize(.large)
            }

            Text("MySQL and PostgreSQL connection management are intentionally deferred beyond the MVP.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

struct DatabaseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                switch model.workspaceMode {
                case .table:
                    VStack(spacing: 0) {
                        TableControlsView()
                        DataGridView()
                    }
                    PagerBar()
                        .padding(.bottom, 16)
                case .sql:
                    SQLWorkspaceView()
                }
            }
        }
        .inspector(isPresented: .constant(true)) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 320)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.showTableWorkspace() }
                } label: {
                    Label("Table", systemImage: "tablecells")
                }
                .disabled(model.selectedTable == nil)
                .help("Show selected table")

                Button {
                    model.showSQLWorkspace()
                } label: {
                    Label("SQL", systemImage: "terminal")
                }
                .help("Open SQL editor")

                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh tables")

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.connectionName)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.databasePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            TextField("Filter tables", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .bottom])

            List(model.filteredTables, selection: $model.selectedTable) { table in
                Button {
                    Task { await model.select(table) }
                } label: {
                    Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open Data") {
                        Task { await model.select(table) }
                    }
                    Button("Count Rows") {
                        Task { await model.countRows(table) }
                    }
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(table.name, forType: .string)
                    }
                }
            }
        }
    }
}

struct DataGridView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedTable == nil {
            ContentUnavailableView("Select a table", systemImage: "tablecells", description: Text("Tables appear in the sidebar after connecting."))
        } else if model.resultSet.columns.isEmpty {
            ContentUnavailableView("No columns", systemImage: "rectangle.split.3x1")
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(model.resultSet.columns) { column in
                            HeaderCell(
                                title: column.name,
                                sortState: model.sortState,
                                isSortable: model.isTableMode
                            ) {
                                Task { await model.toggleSort(column: column.name) }
                            }
                        }
                    }

                    ForEach(model.resultSet.rows) { row in
                        GridRow {
                            ForEach(model.resultSet.columns) { column in
                                let value = row.values[column.name] ?? .null
                                ValueCell(value: value) {
                                    model.selectedCell = CellSelection(column: column.name, value: value)
                                } copyAction: {
                                    model.copyCell(value)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Copy Row") {
                                model.copyRow(row)
                            }
                        }
                    }
                }
                .padding(24)
                .padding(.bottom, 64)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct TableControlsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            Picker("Column", selection: $model.filterColumn) {
                ForEach(model.tableColumns) { column in
                    Text(column.name).tag(column.name)
                }
            }
            .frame(width: 180)

            Picker("Operator", selection: $model.filterOperator) {
                ForEach(FilterOperator.allCases) { op in
                    Text(op.rawValue).tag(op)
                }
            }
            .frame(width: 120)

            TextField("Filter value", text: $model.filterValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .disabled(!model.filterOperator.needsValue)

            Button {
                Task { await model.applyFilter() }
            } label: {
                Label("Apply Filter", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                Task { await model.clearFilter() }
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }

            Divider()
                .frame(height: 20)

            Button {
                Task { await model.countRows() }
            } label: {
                Label(model.totalRows.map { "\($0) rows" } ?? "Count Rows", systemImage: "number")
            }
            .disabled(model.selectedTable == nil)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

struct HeaderCell: View {
    let title: String
    let sortState: SortState?
    let isSortable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                if sortState?.column == title {
                    Image(systemName: sortState?.direction == .ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 160, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .border(Color(nsColor: .separatorColor), width: 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isSortable)
    }
}

struct ValueCell: View {
    let value: DBValue
    let action: () -> Void
    let copyAction: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if value.isNull {
                    Text("NULL")
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else {
                    Text(value.description)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(.body, design: .monospaced))
            .frame(width: 160, height: 34, alignment: .leading)
            .padding(.horizontal, 10)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor), width: 0.5)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Cell") {
                copyAction()
            }
        }
    }
}

struct SQLWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            VStack(spacing: 10) {
                TextEditor(text: $model.sqlText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }

                HStack(spacing: 12) {
                    Button {
                        Task { await model.runSQL() }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)

                    Toggle("Auto LIMIT 1000", isOn: $model.autoLimitSelects)
                        .toggleStyle(.checkbox)

                    Text(model.sqlStatusMessage)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !model.sqlHistory.isEmpty {
                        Menu {
                            ForEach(model.sqlHistory, id: \.self) { sql in
                                Button(sql) {
                                    model.sqlText = sql
                                }
                            }
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial)

            SQLResultGridView()
        }
    }
}

struct SQLResultGridView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.resultSet.columns.isEmpty {
            ContentUnavailableView("Run SQL", systemImage: "terminal", description: Text("SELECT results appear here."))
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(model.resultSet.columns) { column in
                            HeaderCell(title: column.name, sortState: nil, isSortable: false) {}
                        }
                    }

                    ForEach(model.resultSet.rows) { row in
                        GridRow {
                            ForEach(model.resultSet.columns) { column in
                                let value = row.values[column.name] ?? .null
                                ValueCell(value: value) {
                                    model.selectedCell = CellSelection(column: column.name, value: value)
                                } copyAction: {
                                    model.copyCell(value)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Copy Row") {
                                model.copyRow(row)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct PagerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.previousPage() }
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)

            Text("Page \(model.page + 1)")
                .font(.callout.monospacedDigit())

            Button {
                Task { await model.nextPage() }
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(!model.canGoForward)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 12, y: 4)
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inspector")
                .font(.headline)

            if let selection = model.selectedCell {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.column)
                        .font(.subheadline.weight(.semibold))
                    ScrollView {
                        Text(selection.value.description)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let table = model.selectedTable {
                Text(table.name)
                    .font(.subheadline.weight(.semibold))
                if let totalRows = model.totalRows {
                    Text("\(totalRows) rows")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.tableColumns) { column in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(column.name)
                                .font(.caption.weight(.semibold))
                            if column.isPrimaryKey {
                                Text("PK")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text("\(column.type.isEmpty ? "unknown" : column.type) · \(column.isNullable ? "nullable" : "not null")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Read-only grid")
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a cell to inspect its full value.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}

extension UTType {
    static let database = UTType(filenameExtension: "sqlite") ?? .data
}
