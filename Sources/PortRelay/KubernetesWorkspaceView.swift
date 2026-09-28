import AppKit
import SwiftUI

struct KubernetesWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    @State private var clusterSelection = Set<UUID>()
    @State private var namespaceSelection: String?
    @State private var namespaces: [String] = []
    @State private var namespacesClusterID: UUID?
    @State private var namespaceError: String?
    @State private var isLoadingNamespaces = false
    @State private var showingAddCluster = false
    @State private var editingCluster: KubernetesClusterProfile?
    @State private var reauthenticatingCluster: KubernetesClusterProfile?
    @State private var deletingClusterIDs = Set<UUID>()

    var body: some View {
        HStack(spacing: 0) {
            Divider()
            clusterSidebar
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 330)
            Divider()
            namespaceSidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            Divider()
            Group {
                if let cluster = store.selectedKubernetesCluster,
                   let namespace = store.selectedNamespace {
                    KubernetesPortsView(cluster: cluster, namespace: namespace)
                        .id("\(cluster.id)-\(namespace)")
                } else if store.selectedKubernetesCluster == nil {
                    ContentUnavailableView(
                        "选择一个集群",
                        systemImage: "arrow.left",
                        description: Text("添加 kubeconfig 后即可浏览 Namespace 和可转发端口。")
                    )
                } else {
                    ContentUnavailableView(
                        "选择 Namespace",
                        systemImage: "arrow.left",
                        description: Text("右侧将显示 Service、Deployment 和 Pod 声明的端口。")
                    )
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAddCluster) {
            KubernetesClusterEditorView(existing: nil).environmentObject(store)
        }
        .sheet(item: $editingCluster) { cluster in
            KubernetesClusterEditorView(existing: cluster).environmentObject(store)
        }
        .sheet(item: $reauthenticatingCluster) { cluster in
            TeleportLoginView(cluster: cluster)
        }
        .confirmationDialog(
            deletingClusterIDs.count > 1
                ? "删除所选的 \(deletingClusterIDs.count) 个集群？"
                : "删除集群“\(singleDeletingClusterName)”？",
            isPresented: Binding(
                get: { !deletingClusterIDs.isEmpty },
                set: { if !$0 { deletingClusterIDs = [] } }
            )
        ) {
            Button("删除集群及其全部映射", role: .destructive) {
                store.deleteKubernetesClusters(ids: deletingClusterIDs)
                clusterSelection.subtract(deletingClusterIDs)
                deletingClusterIDs = []
            }
            Button("取消", role: .cancel) { deletingClusterIDs = [] }
        } message: {
            Text("正在运行的端口映射也会停止，此操作无法撤销。")
        }
        .onAppear { synchronizeClusterSelection() }
        .onChange(of: clusterSelection) { _, selection in
            guard !selection.isEmpty else {
                store.selectedKubernetesClusterID = nil
                return
            }
            if let selectedID = store.selectedKubernetesClusterID, selection.contains(selectedID) { return }
            store.selectedKubernetesClusterID = selection.first
        }
        .onChange(of: store.selectedKubernetesClusterID) { _, _ in
            synchronizeClusterSelection()
        }
        .task(id: store.selectedKubernetesClusterID) {
            await loadNamespaces()
        }
    }

    private var clusterSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("K8S 集群")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingAddCluster = true
                } label: {
                    Label("添加集群", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            Divider()

            List(selection: $clusterSelection) {
                ForEach(store.kubernetesClusters) { cluster in
                    KubernetesClusterRow(cluster: cluster)
                        .tag(cluster.id)
                        .contextMenu {
                            Button("修改") { editingCluster = cluster }
                            if cluster.configSource == .teleport {
                                Button("重新登录") { reauthenticatingCluster = cluster }
                            }
                            Divider()
                            Button(deleteClusterTitle(for: cluster), role: .destructive) {
                                deletingClusterIDs = deletionIDs(for: cluster)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.kubernetesClusters.isEmpty {
                    ContentUnavailableView(
                        "还没有集群",
                        systemImage: "shippingbox",
                        description: Text("点击上方加号添加 kubeconfig。")
                    )
                }
            }
            .onDeleteCommand {
                if !clusterSelection.isEmpty {
                    deletingClusterIDs = clusterSelection
                }
            }
        }
    }

    private var namespaceSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NAMESPACE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await loadNamespaces() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新 Namespace")
                .disabled(store.selectedKubernetesCluster == nil || isLoadingNamespaces)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            Divider()

            if isLoadingNamespaces {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取 Namespace…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let namespaceError, namespaces.isEmpty {
                ContentUnavailableView {
                    Label("无法读取 Namespace", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(namespaceError)
                        .textSelection(.enabled)
                } actions: {
                    HStack {
                        Button("重试") { Task { await loadNamespaces() } }
                        Button("复制错误") { copyError(namespaceError) }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if let namespaceError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(namespaceError)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Button { copyError(namespaceError) } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("复制完整错误信息")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    List(selection: $namespaceSelection) {
                        ForEach(namespaces, id: \.self) { namespace in
                            HStack(spacing: 8) {
                                Image(systemName: "square.stack.3d.up")
                                    .foregroundStyle(.purple)
                                Text(namespace).lineLimit(1)
                                Spacer()
                                let activeCount = namespaceMappingCount(namespace)
                                if activeCount > 0 {
                                    Text(String(activeCount))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .tag(namespace)
                        }
                    }
                    .listStyle(.plain)
                    .overlay {
                        if namespaces.isEmpty, store.selectedKubernetesCluster != nil {
                            ContentUnavailableView("没有 Namespace", systemImage: "square.stack.3d.up.slash")
                        }
                    }
                }
            }
        }
        .onChange(of: namespaceSelection) { _, namespace in
            store.selectedNamespace = namespace
        }
    }

    @MainActor
    private func loadNamespaces() async {
        guard let cluster = store.selectedKubernetesCluster else {
            namespaces = []
            namespacesClusterID = nil
            namespaceSelection = nil
            store.selectedNamespace = nil
            return
        }
        if namespacesClusterID != cluster.id {
            namespaces = []
            namespaceSelection = nil
            namespacesClusterID = cluster.id
        }
        isLoadingNamespaces = true
        namespaceError = nil
        do {
            let loaded = try await KubernetesClient.namespaces(cluster: cluster)
            guard store.selectedKubernetesClusterID == cluster.id else { return }
            let saved = store.kubernetesMappings(clusterID: cluster.id).map(\.namespace)
            namespaces = Array(Set(loaded + saved)).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            let preferred = store.selectedNamespace.flatMap { namespaces.contains($0) ? $0 : nil }
                ?? (namespaces.contains("default") ? "default" : namespaces.first)
            namespaceSelection = preferred
            store.selectedNamespace = preferred
        } catch {
            guard store.selectedKubernetesClusterID == cluster.id else { return }
            let saved = store.kubernetesMappings(clusterID: cluster.id).map(\.namespace)
            namespaces = Array(Set(namespaces + saved)).sorted()
            namespaceSelection = store.selectedNamespace.flatMap { namespaces.contains($0) ? $0 : nil }
                ?? namespaces.first
            store.selectedNamespace = namespaceSelection
            namespaceError = error.localizedDescription
        }
        isLoadingNamespaces = false
    }

    private func copyError(_ message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
    }

    private var singleDeletingClusterName: String {
        guard let id = deletingClusterIDs.first else { return "" }
        return store.kubernetesClusters.first(where: { $0.id == id })?.name ?? ""
    }

    private func synchronizeClusterSelection() {
        if let id = store.selectedKubernetesClusterID { clusterSelection = [id] }
        else { clusterSelection = [] }
    }

    private func deletionIDs(for cluster: KubernetesClusterProfile) -> Set<UUID> {
        clusterSelection.contains(cluster.id) ? clusterSelection : [cluster.id]
    }

    private func namespaceMappingCount(_ namespace: String) -> Int {
        guard let clusterID = store.selectedKubernetesClusterID else { return 0 }
        return store.kubernetesMappings(clusterID: clusterID, namespace: namespace)
            .filter(\.isEnabled).count
    }

    private func deleteClusterTitle(for cluster: KubernetesClusterProfile) -> String {
        let count = deletionIDs(for: cluster).count
        return count > 1 ? "删除所选的 \(count) 个集群" : "删除"
    }
}

private struct KubernetesClusterRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var manager = AppStore.shared.kubernetesForwardManager
    let cluster: KubernetesClusterProfile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cluster.configSource == .teleport ? "network.badge.shield.half.filled" : "shippingbox")
                .foregroundStyle(.purple)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.name).fontWeight(.medium).lineLimit(1)
                Text(cluster.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if runningCount > 0 {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 3)
    }

    private var runningCount: Int {
        store.kubernetesMappings(clusterID: cluster.id).filter {
            manager.status(for: $0.id) == .running
        }.count
    }
}

private struct KubernetesPortsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var manager = AppStore.shared.kubernetesForwardManager

    let cluster: KubernetesClusterProfile
    let namespace: String

    @State private var ports: [KubernetesPort] = []
    @State private var filter = KubernetesPortFilter.all
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var editingItem: KubernetesPortListItem?
    @State private var selection = Set<String>()
    @State private var deletingMappingIDs = Set<UUID>()
    @State private var podRequest: KubernetesPodRequest?
    @State private var loadingDeploymentName: String?

    private var items: [KubernetesPortListItem] {
        var values = ports.map { port in
            KubernetesPortListItem(
                port: port,
                mapping: store.kubernetesMapping(clusterID: cluster.id, namespace: namespace, port: port)
            )
        }
        for mapping in store.kubernetesMappings(clusterID: cluster.id, namespace: namespace) {
            guard !values.contains(where: { $0.mapping?.id == mapping.id }) else { continue }
            values.append(KubernetesPortListItem(
                port: KubernetesPort(
                    kind: mapping.resourceKind,
                    resourceName: mapping.resourceName,
                    portName: mapping.portName,
                    remotePort: mapping.remotePort
                ),
                mapping: mapping
            ))
        }
        return values.filter { item in
            let matchesKind = filter.kind == nil || item.port.kind == filter.kind
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || item.port.resourceName.localizedCaseInsensitiveContains(query)
                || item.port.kind.title.localizedCaseInsensitiveContains(query)
                || (item.port.remotePort.map { String($0).contains(query) } == true)
                || (item.port.portName?.localizedCaseInsensitiveContains(query) == true)
                || (item.mapping?.localHost.localizedCaseInsensitiveContains(query) == true)
                || (item.mapping.map { String($0.localPort).contains(query) } == true)
            return matchesKind && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnHeader
            Divider()

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取 Service、Deployment 和 Pod…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, items.isEmpty {
                ContentUnavailableView {
                    Label("无法读取端口", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") { Task { await loadPorts() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView(
                    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? emptyTitle
                        : "没有匹配的端口",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? emptyDescription
                            : "尝试搜索其他资源名称、Host 或端口。"
                    )
                )
            } else {
                VStack(spacing: 0) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(.orange.opacity(0.07))
                        Divider()
                    }
                    portList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editingItem) { item in
            KubernetesMappingEditorView(
                clusterID: cluster.id,
                namespace: namespace,
                port: item.port,
                existing: item.mapping
            )
            .environmentObject(store)
        }
        .sheet(item: $podRequest) { request in
            KubernetesPodChooser(
                request: request,
                onSelect: { pod in
                    startSession(request.action, session: request.session, pod: pod)
                },
                onCancel: {
                    store.sessionManager.close(request.session)
                }
            )
        }
        .confirmationDialog(
            deletingMappingIDs.count > 1
                ? "删除所选的 \(deletingMappingIDs.count) 个映射？"
                : "删除此端口映射？",
            isPresented: Binding(
                get: { !deletingMappingIDs.isEmpty },
                set: { if !$0 { deletingMappingIDs = [] } }
            )
        ) {
            Button("删除", role: .destructive) {
                store.deleteKubernetesMappings(ids: deletingMappingIDs)
                selection = []
                deletingMappingIDs = []
            }
            Button("取消", role: .cancel) { deletingMappingIDs = [] }
        } message: {
            Text("如果映射正在运行，它会立即停止。")
        }
        .task(id: "\(cluster.id)-\(namespace)") { await loadPorts() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("资源类型", selection: $filter) {
                ForEach(KubernetesPortFilter.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            TextField("搜索资源或端口", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
            Button {
                Task { await loadPorts() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
            Spacer()
            Text("\(runningCount) 个运行中")
                .font(.caption.weight(.medium))
                .foregroundStyle(runningCount > 0 ? .green : .secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var columnHeader: some View {
        HStack(spacing: 14) {
            Text("资源").frame(maxWidth: .infinity, alignment: .leading)
            Text("集群端口").frame(width: 96, alignment: .leading)
            Text("本地监听").frame(width: 110, alignment: .leading)
            Text("状态").frame(width: 78, alignment: .leading)
            Color.clear.frame(width: 24)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(.quaternary.opacity(0.35))
    }

    private var portList: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                KubernetesPortRow(
                    item: item,
                    manager: manager,
                    action: { performPrimaryAction(item) },
                    viewLogs: item.port.kind == .deployment
                        ? { prepareDeploymentSession(.logs, deployment: item.port.resourceName) }
                        : item.port.kind == .pod
                            ? { openPodSession(.logs, port: item.port) }
                            : nil
                )
                .tag(item.id)
                .contextMenu {
                    contextMenu(for: item)
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            if !selectedMappingIDs.isEmpty { deletingMappingIDs = selectedMappingIDs }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: KubernetesPortListItem) -> some View {
        if item.port.kind == .deployment {
            Button("查看日志", systemImage: "doc.text.magnifyingglass") {
                prepareDeploymentSession(.logs, deployment: item.port.resourceName)
            }
            Button("Shell 连接", systemImage: "terminal") {
                prepareDeploymentSession(.shell, deployment: item.port.resourceName)
            }
            .disabled(loadingDeploymentName != nil)
            Divider()
        } else if item.port.kind == .pod {
            Button("查看日志", systemImage: "doc.text.magnifyingglass") {
                openPodSession(.logs, port: item.port)
            }
            Button("Shell 连接", systemImage: "terminal") {
                openPodSession(.shell, port: item.port)
            }
            Divider()
        }
        if let mapping = item.mapping {
            if mapping.isEnabled {
                if case .failed = manager.status(for: mapping.id) {
                    Button("重新连接", systemImage: "arrow.clockwise") {
                        store.retryKubernetesMapping(mapping)
                    }
                    Button("取消自动映射", systemImage: "stop.fill") {
                        store.toggleKubernetesMapping(mapping)
                    }
                } else {
                    Button("停止映射", systemImage: "stop.fill") {
                        store.toggleKubernetesMapping(mapping)
                    }
                }
            } else {
                Button("启动映射", systemImage: "play.fill") {
                    store.toggleKubernetesMapping(mapping)
                }
            }
            Divider()
            Button("修改本地端口", systemImage: "pencil") { editingItem = item }
            Button("删除映射", systemImage: "trash", role: .destructive) {
                deletingMappingIDs = [mapping.id]
            }
        } else {
            Button("设置本地端口", systemImage: "plus") { editingItem = item }
        }
    }

    private var selectedMappingIDs: Set<UUID> {
        Set(items.filter { selection.contains($0.id) }.compactMap { $0.mapping?.id })
    }

    private var runningCount: Int {
        store.kubernetesMappings(clusterID: cluster.id, namespace: namespace).filter {
            manager.status(for: $0.id) == .running
        }.count
    }

    private var emptyTitle: String {
        switch filter {
        case .all: "没有资源"
        case .services: "没有 Service"
        case .deployments: "没有 Deployment"
        case .pods: "没有 Pod"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .all: "此 Namespace 没有 Service、Deployment 或 Pod。"
        case .services: "此 Namespace 没有 Service。"
        case .deployments: "此 Namespace 没有 Deployment。"
        case .pods: "此 Namespace 没有 Pod。"
        }
    }

    private func performPrimaryAction(_ item: KubernetesPortListItem) {
        guard let mapping = item.mapping else {
            editingItem = item
            return
        }
        if mapping.isEnabled, case .failed = manager.status(for: mapping.id) {
            store.retryKubernetesMapping(mapping)
        } else {
            store.toggleKubernetesMapping(mapping)
        }
    }

    private func prepareDeploymentSession(_ action: KubernetesSessionAction, deployment: String) {
        let session = store.sessionManager.prepareKubernetesSession(
            kind: action.sessionKind,
            namespace: namespace,
            sourceName: deployment
        )
        loadingDeploymentName = deployment
        Task {
            defer { loadingDeploymentName = nil }
            do {
                let pods = try await KubernetesClient.pods(
                    cluster: cluster,
                    namespace: namespace,
                    deployment: deployment
                )
                let runningPods = pods.filter(\.isRunning)
                guard !runningPods.isEmpty else {
                    session.fail(pods.isEmpty
                        ? "Deployment“\(deployment)”当前没有 Pod"
                        : "Deployment“\(deployment)”当前没有运行中的 Pod")
                    return
                }
                if runningPods.count == 1, let pod = runningPods.first {
                    startSession(action, session: session, pod: pod)
                } else {
                    podRequest = KubernetesPodRequest(
                        deployment: deployment,
                        pods: runningPods,
                        action: action,
                        session: session
                    )
                }
            } catch {
                session.fail("读取 Deployment Pod 失败：\(error.localizedDescription)")
            }
        }
    }

    private func openPodSession(_ action: KubernetesSessionAction, port: KubernetesPort) {
        let pod = KubernetesPod(name: port.resourceName, phase: port.podPhase ?? "Unknown")
        openSession(action, sourceName: port.resourceName, pod: pod)
    }

    private func openSession(
        _ action: KubernetesSessionAction,
        sourceName: String,
        pod: KubernetesPod
    ) {
        switch action {
        case .logs:
            store.sessionManager.openKubernetesLogs(
                cluster: cluster,
                namespace: namespace,
                sourceName: sourceName,
                pod: pod
            )
        case .shell:
            store.sessionManager.openKubernetesShell(
                cluster: cluster,
                namespace: namespace,
                sourceName: sourceName,
                pod: pod
            )
        }
    }

    private func startSession(
        _ action: KubernetesSessionAction,
        session: CommandSession,
        pod: KubernetesPod
    ) {
        switch action {
        case .logs:
            store.sessionManager.startKubernetesLogs(
                session,
                cluster: cluster,
                namespace: namespace,
                pod: pod
            )
        case .shell:
            store.sessionManager.startKubernetesShell(
                session,
                cluster: cluster,
                namespace: namespace,
                pod: pod
            )
        }
    }

    @MainActor
    private func loadPorts() async {
        isLoading = true
        loadError = nil
        do {
            ports = try await KubernetesClient.ports(cluster: cluster, namespace: namespace)
        } catch {
            ports = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

private enum KubernetesSessionAction {
    case logs
    case shell

    var title: String { self == .logs ? "查看日志" : "Shell 连接" }
    var sessionKind: SessionKind { self == .logs ? .kubernetesLogs : .kubernetesShell }
}

private struct KubernetesPodRequest: Identifiable {
    let id = UUID()
    let deployment: String
    let pods: [KubernetesPod]
    let action: KubernetesSessionAction
    let session: CommandSession
}

private struct KubernetesPodChooser: View {
    @Environment(\.dismiss) private var dismiss
    let request: KubernetesPodRequest
    let onSelect: (KubernetesPod) -> Void
    let onCancel: () -> Void
    @State private var selectedPodName: String?
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择 Pod").font(.title2.weight(.semibold))
                Text("\(request.deployment) 有多个运行中的副本，请选择用于\(request.action.title)的 Pod。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()

            List(request.pods, selection: $selectedPodName) { pod in
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.purple)
                    Text(pod.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text(pod.phase).font(.caption).foregroundStyle(.green)
                }
                .tag(pod.name)
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Spacer()
                Button("取消") {
                    didComplete = true
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(request.action.title) {
                    guard let pod = request.pods.first(where: { $0.name == selectedPodName }) else { return }
                    didComplete = true
                    onSelect(pod)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPodName == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 380)
        .onAppear { selectedPodName = request.pods.first?.name }
        .onDisappear {
            if !didComplete { onCancel() }
        }
    }
}

private struct KubernetesPortListItem: Identifiable {
    let port: KubernetesPort
    let mapping: KubernetesPortMapping?
    var id: String { port.id }
}

private enum KubernetesPortFilter: String, CaseIterable, Identifiable {
    case all
    case services
    case deployments
    case pods

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .services: "Service"
        case .deployments: "Deployment"
        case .pods: "Pod"
        }
    }
    var kind: KubernetesResourceKind? {
        switch self {
        case .all: nil
        case .services: .service
        case .deployments: .deployment
        case .pods: .pod
        }
    }
}

private struct KubernetesPortRow: View {
    let item: KubernetesPortListItem
    @ObservedObject var manager: KubernetesPortForwardManager
    let action: () -> Void
    let viewLogs: (() -> Void)?

    private var status: MappingStatus {
        item.mapping.map { manager.status(for: $0.id) } ?? .stopped
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.port.resourceName).fontWeight(.medium).lineLimit(1)
                    if let viewLogs {
                        Button(action: viewLogs) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("查看 \(item.port.kind.title) 日志")
                    }
                }
                HStack(spacing: 6) {
                    Text(item.port.kind.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(item.port.kind == .service ? .blue.opacity(0.12) : .purple.opacity(0.12), in: Capsule())
                    if item.port.kind == .pod, let phase = item.port.podPhase {
                        Text(phase)
                            .font(.caption2)
                            .foregroundStyle(phase == "Running" ? .green : .secondary)
                    }
                }
                if case .failed(let message) = status {
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(1).help(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.port.remotePort.map(String.init) ?? "未声明")
                    .font(item.port.remotePort == nil ? .caption : .system(.body, design: .monospaced))
                    .foregroundStyle(item.port.remotePort == nil ? .secondary : .primary)
                if let name = item.port.portName, !name.isEmpty {
                    Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 96, alignment: .leading)

            if let mapping = item.mapping {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(mapping.localPort))
                        .font(.system(.body, design: .monospaced))
                    Text(mapping.localHost)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 110, alignment: .leading)
            } else {
                Text("未设置")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
            }

            if item.mapping == nil {
                Text("未配置").foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
            } else {
                KubernetesStatusBadge(status: status).frame(width: 78, alignment: .leading)
            }

            Button(action: action) {
                Image(systemName: actionIcon)
            }
            .buttonStyle(.borderless)
            .help(actionTitle)
            .frame(width: 24)
        }
        .padding(.vertical, 7)
    }

    private var actionIcon: String {
        guard let mapping = item.mapping else { return "plus.circle" }
        if mapping.isEnabled, case .failed = status { return "arrow.clockwise" }
        return mapping.isEnabled ? "stop.fill" : "play.fill"
    }

    private var actionTitle: String {
        guard let mapping = item.mapping else { return "设置本地端口" }
        if mapping.isEnabled, case .failed = status { return "重新连接" }
        return mapping.isEnabled ? "停止映射" : "启动映射"
    }
}

private struct KubernetesStatusBadge: View {
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
            Text(status.title)
        }
        .foregroundStyle(color)
    }
}
