import SwiftUI

struct ContentView: View {
    @State private var mode = WorkspaceMode.ssh
    @ObservedObject private var sessions = AppStore.shared.sessionManager

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 30) {
                    tabButton(.ssh)
                    tabButton(.kubernetes)
                }
                .frame(width: 240)
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()

            Group {
                switch mode {
                case .ssh:
                    SSHWorkspaceView()
                case .kubernetes:
                    KubernetesWorkspaceView()
                }
            }
            .frame(maxHeight: .infinity)

            if !sessions.sessions.isEmpty {
                Divider()
                SessionPanelView(
                    manager: sessions,
                    isCollapsed: $sessions.isPanelCollapsed
                )
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func tabButton(_ item: WorkspaceMode) -> some View {
        Button {
            mode = item
        } label: {
            VStack(spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: mode == item ? .semibold : .regular))
                Rectangle()
                    .fill(mode == item ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .foregroundStyle(mode == item ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum WorkspaceMode: String, CaseIterable, Identifiable {
    case ssh
    case kubernetes

    var id: String { rawValue }
    var title: String { self == .ssh ? "SSH 转发" : "Kubernetes" }
}

private struct SSHWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddServer = false
    @State private var showingSSHImport = false
    @State private var editingServer: ServerProfile?
    @State private var serverSelection = Set<UUID>()
    @State private var deletingServerIDs = Set<UUID>()
    @State private var importMessage: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("SSH 服务器")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingAddServer = true
                    } label: {
                        Label("添加服务器", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        Button("批量导入 ~/.ssh/config") {
                            store.reloadSSHConfig()
                            showingSSHImport = true
                        }
                        Button("重新读取 SSH 配置") { store.reloadSSHConfig() }
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("导入 SSH 配置")
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                Divider()

                List(selection: $serverSelection) {
                    ForEach(store.servers) { server in
                        ServerRow(server: server)
                            .tag(server.id)
                            .contextMenu {
                                Button("连接服务器", systemImage: "terminal") {
                                    store.sessionManager.openSSH(server: server)
                                }
                                Divider()
                                Button("修改") { editingServer = server }
                                Divider()
                                Button(deleteServerTitle(for: server), role: .destructive) {
                                    deletingServerIDs = deletionIDs(for: server)
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
                            description: Text("点击上方的加号添加，或导入 SSH 配置。")
                        )
                    }
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 360)

            Group {
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
            .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
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
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var manager = AppStore.shared.forwardManager
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
            Spacer()
            if hasRunningMapping {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 3)
    }

    private var hasRunningMapping: Bool {
        store.mappings(for: server.id).contains {
            manager.status(for: $0.id) == .running
        }
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
