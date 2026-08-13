import SwiftUI

struct PortMappingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var manager: PortRelayManager
    let server: ServerProfile

    @State private var showingAddMapping = false
    @State private var editingMapping: PortMapping?
    @State private var mappingSelection = Set<UUID>()
    @State private var deletingMappingIDs = Set<UUID>()

    init(server: ServerProfile) {
        self.server = server
        _manager = ObservedObject(wrappedValue: AppStore.shared.forwardManager)
    }

    private var filteredMappings: [PortMapping] {
        store.mappings(for: server.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnHeader
            Divider()

            if filteredMappings.isEmpty {
                ContentUnavailableView {
                    Label("还没有端口映射", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("添加一个映射，例如将远程 127.0.0.1:80 映射到本机 127.0.0.1:8082。")
                } actions: {
                    Button("添加端口映射") { showingAddMapping = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mappingList
            }
        }
        .sheet(isPresented: $showingAddMapping) {
            MappingEditorView(serverID: server.id, existing: nil)
                .environmentObject(store)
        }
        .sheet(item: $editingMapping) { mapping in
            MappingEditorView(serverID: server.id, existing: mapping)
                .environmentObject(store)
        }
        .confirmationDialog(
            deletingMappingIDs.count > 1
                ? "删除所选的 \(deletingMappingIDs.count) 个映射？"
                : "删除映射“\(singleDeletingMappingName)”？",
            isPresented: Binding(
                get: { !deletingMappingIDs.isEmpty },
                set: { if !$0 { deletingMappingIDs = [] } }
            )
        ) {
            Button("删除", role: .destructive) {
                store.deleteMappings(ids: deletingMappingIDs)
                mappingSelection.subtract(deletingMappingIDs)
                deletingMappingIDs = []
            }
            Button("取消", role: .cancel) { deletingMappingIDs = [] }
        } message: {
            Text("如果映射正在运行，它会立即停止。")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "server.rack")
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.headline)
                Text(server.source == .sshConfig
                     ? "SSH 配置：\(server.sshAlias ?? server.host)"
                     : "\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let runningCount = store.mappings(for: server.id).filter {
                manager.status(for: $0.id) == .running
            }.count
            Text("\(runningCount) 个运行中")
                .font(.caption.weight(.medium))
                .foregroundStyle(runningCount > 0 ? .green : .secondary)
            Button {
                showingAddMapping = true
            } label: {
                Label("添加映射", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
    }

    private var columnHeader: some View {
        HStack(spacing: 16) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("远程目标").frame(width: 170, alignment: .leading)
            Text("本地监听").frame(width: 170, alignment: .leading)
            Text("状态").frame(width: 90, alignment: .leading)
            Color.clear.frame(width: 28)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .frame(height: 30)
        .background(.quaternary.opacity(0.35))
    }

    private var mappingList: some View {
        List(selection: $mappingSelection) {
            ForEach(filteredMappings) { mapping in
                MappingRow(mapping: mapping, manager: manager) {
                    if mapping.isEnabled,
                       case .failed = manager.status(for: mapping.id) {
                        store.retry(mapping)
                    } else {
                        store.toggle(mapping)
                    }
                }
                .tag(mapping.id)
                .contextMenu {
                    if mapping.isEnabled {
                        if case .failed = manager.status(for: mapping.id) {
                            Button("重新连接", systemImage: "arrow.clockwise") { store.retry(mapping) }
                            Button("取消自动映射", systemImage: "stop.fill") { store.toggle(mapping) }
                        } else {
                            Button("停止映射", systemImage: "stop.fill") { store.toggle(mapping) }
                        }
                    } else {
                        Button("启动映射", systemImage: "play.fill") { store.toggle(mapping) }
                    }
                    Divider()
                    Button("修改", systemImage: "pencil") { editingMapping = mapping }
                    Button(deleteMappingTitle(for: mapping), systemImage: "trash", role: .destructive) {
                        deletingMappingIDs = deletionIDs(for: mapping)
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            if !mappingSelection.isEmpty {
                deletingMappingIDs = mappingSelection
            }
        }
    }

    private var singleDeletingMappingName: String {
        guard let id = deletingMappingIDs.first else { return "" }
        return store.mappings.first(where: { $0.id == id })?.name ?? ""
    }

    private func deletionIDs(for mapping: PortMapping) -> Set<UUID> {
        mappingSelection.contains(mapping.id) ? mappingSelection : [mapping.id]
    }

    private func deleteMappingTitle(for mapping: PortMapping) -> String {
        let count = deletionIDs(for: mapping).count
        return count > 1 ? "删除所选的 \(count) 个映射" : "删除"
    }
}

private struct MappingRow: View {
    let mapping: PortMapping
    @ObservedObject var manager: PortRelayManager
    let toggle: () -> Void

    private var status: MappingStatus { manager.status(for: mapping.id) }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(mapping.name).fontWeight(.medium).lineLimit(1)
                if case .failed(let message) = status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(mapping.remoteAddress)
                .font(.system(.body, design: .monospaced))
                .frame(width: 170, alignment: .leading)
            Text(mapping.localAddress)
                .font(.system(.body, design: .monospaced))
                .frame(width: 170, alignment: .leading)
            StatusBadge(status: status)
                .frame(width: 90, alignment: .leading)
            Button(action: toggle) {
                Image(systemName: actionIcon)
            }
            .buttonStyle(.borderless)
            .help(actionTitle)
            .frame(width: 28)
        }
        .padding(.vertical, 7)
    }

    private var actionIcon: String {
        if mapping.isEnabled, case .failed = status { return "arrow.clockwise" }
        return mapping.isEnabled ? "stop.fill" : "play.fill"
    }

    private var actionTitle: String {
        if mapping.isEnabled, case .failed = status { return "重新连接" }
        return mapping.isEnabled ? "停止映射" : "启动映射"
    }
}

private struct StatusBadge: View {
    let status: MappingStatus

    private var color: Color {
        switch status {
        case .stopped: .secondary
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.title).font(.caption)
        }
        .foregroundStyle(color)
    }
}
