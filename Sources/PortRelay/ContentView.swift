import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddServer = false
    @State private var showingSSHImport = false
    @State private var editingServer: ServerProfile?
    @State private var serverSelection = Set<UUID>()
    @State private var deletingServerIDs = Set<UUID>()
    @State private var importMessage: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $serverSelection) {
                Section("服务器") {
                    ForEach(store.servers) { server in
                        ServerRow(server: server)
                            .tag(server.id)
                            .contextMenu {
                                Button("修改") { editingServer = server }
                                Divider()
                                Button(deleteServerTitle(for: server), role: .destructive) {
                                    deletingServerIDs = deletionIDs(for: server)
                                }
                            }
                    }
                }
            }
            .onDeleteCommand {
                if !serverSelection.isEmpty {
                    deletingServerIDs = serverSelection
                }
            }
            .overlay {
                if store.servers.isEmpty {
                    ContentUnavailableView(
                        "还没有服务器",
                        systemImage: "server.rack",
                        description: Text("点击下方的加号添加，或从 SSH 配置批量导入。")
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showingAddServer = true
                    } label: {
                        Label("添加服务器", systemImage: "plus")
                    }

                    Menu {
                        Button("批量导入 ~/.ssh/config") {
                            store.reloadSSHConfig()
                            showingSSHImport = true
                        }
                        Button("重新读取 SSH 配置") { store.reloadSSHConfig() }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }

                    if !serverSelection.isEmpty {
                        Button(role: .destructive) {
                            deletingServerIDs = serverSelection
                        } label: {
                            Label("删除所选服务器", systemImage: "trash")
                        }
                        .help("删除所选的 \(serverSelection.count) 台服务器")
                    }
                }
            }
        } detail: {
            if let server = store.selectedServer {
                PortMappingsView(server: server)
                    .id(server.id)
            } else {
                ContentUnavailableView(
                    "选择一台服务器",
                    systemImage: "arrow.left",
                    description: Text("右侧将显示该服务器的端口映射。")
                )
            }
        }
        .sheet(isPresented: $showingAddServer) {
            ServerEditorView(existing: nil)
                .environmentObject(store)
        }
        .sheet(item: $editingServer) { server in
            ServerEditorView(existing: server)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingSSHImport) {
            SSHImportView(
                entries: store.sshConfigEntries,
                existingAliases: Set(store.servers.compactMap(\.sshAlias))
            ) { aliases in
                let count = store.importSSHServers(aliases: aliases)
                importMessage = count == 0 ? "没有导入新的服务器。" : "已导入 \(count) 台服务器。"
            }
        }
        .confirmationDialog(
            deletingServerIDs.count > 1
                ? "删除所选的 \(deletingServerIDs.count) 台服务器？"
                : "删除服务器“\(singleDeletingServerName)”？",
            isPresented: Binding(
                get: { !deletingServerIDs.isEmpty },
                set: { if !$0 { deletingServerIDs = [] } }
            )
        ) {
            Button("删除服务器及其全部映射", role: .destructive) {
                store.deleteServers(ids: deletingServerIDs)
                serverSelection.subtract(deletingServerIDs)
                if let selectedServerID = store.selectedServerID {
                    serverSelection = [selectedServerID]
                }
                deletingServerIDs = []
            }
            Button("取消", role: .cancel) { deletingServerIDs = [] }
        } message: {
            Text("正在运行的映射也会停止，此操作无法撤销。")
        }
        .alert("导入结果", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("确定") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .onAppear {
            if let selectedServerID = store.selectedServerID {
                serverSelection = [selectedServerID]
            }
        }
        .onChange(of: serverSelection) { _, selection in
            guard !selection.isEmpty else {
                store.selectedServerID = nil
                return
            }
            if let selectedServerID = store.selectedServerID,
               selection.contains(selectedServerID) {
                return
            }
            store.selectedServerID = selection.first
        }
        .onChange(of: store.selectedServerID) { _, selectedServerID in
            guard let selectedServerID else { return }
            if !serverSelection.contains(selectedServerID) {
                serverSelection = [selectedServerID]
            }
        }
    }

    private var singleDeletingServerName: String {
        guard let id = deletingServerIDs.first else { return "" }
        return store.servers.first(where: { $0.id == id })?.name ?? ""
    }

    private func deletionIDs(for server: ServerProfile) -> Set<UUID> {
        serverSelection.contains(server.id) ? serverSelection : [server.id]
    }

    private func deleteServerTitle(for server: ServerProfile) -> String {
        let count = deletionIDs(for: server).count
        return count > 1 ? "删除所选的 \(count) 台服务器" : "删除"
    }
}

private struct ServerRow: View {
    let server: ServerProfile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).fontWeight(.medium).lineLimit(1)
                Text(server.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SSHImportView: View {
    @Environment(\.dismiss) private var dismiss

    let entries: [SSHConfigEntry]
    let existingAliases: Set<String>
    let onImport: (Set<String>) -> Void

    @State private var selection: Set<String>

    init(
        entries: [SSHConfigEntry],
        existingAliases: Set<String>,
        onImport: @escaping (Set<String>) -> Void
    ) {
        self.entries = entries
        self.existingAliases = existingAliases
        self.onImport = onImport
        _selection = State(initialValue: Set(entries.map(\.alias)).subtracting(existingAliases))
    }

    private var availableEntries: [SSHConfigEntry] {
        entries.filter { !existingAliases.contains($0.alias) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("导入 SSH 服务器").font(.title2.weight(.semibold))
                    Text("选择要从 ~/.ssh/config 导入的服务器")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !availableEntries.isEmpty {
                    Button(selection.count == availableEntries.count ? "取消全选" : "全选") {
                        if selection.count == availableEntries.count {
                            selection = []
                        } else {
                            selection = Set(availableEntries.map(\.alias))
                        }
                    }
                }
            }
            .padding(22)
            Divider()

            if availableEntries.isEmpty {
                ContentUnavailableView(
                    "没有可导入的新服务器",
                    systemImage: "checkmark.circle",
                    description: Text("SSH 配置中的服务器都已经导入。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(availableEntries) { entry in
                    Toggle(isOn: Binding(
                        get: { selection.contains(entry.alias) },
                        set: { selected in
                            if selected { selection.insert(entry.alias) }
                            else { selection.remove(entry.alias) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.alias).fontWeight(.medium)
                            Text("\(entry.user)@\(entry.hostName):\(entry.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
            }

            Divider()
            HStack {
                Text("已选择 \(selection.count) 台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入") {
                    onImport(selection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
            .padding(18)
        }
        .frame(width: 580, height: 520)
    }
}
