import SwiftUI

struct KubernetesClusterEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let existing: KubernetesClusterProfile?
    private let id: UUID

    @State private var name: String
    @State private var configSource: KubeConfigSource
    @State private var kubeconfigPath: String
    @State private var kubeconfigContents: String
    @State private var contextName: String
    @State private var contexts: [String] = []
    @State private var showingFileImporter = false
    @State private var isInspecting = false
    @State private var errorMessage: String?

    init(existing: KubernetesClusterProfile?) {
        self.existing = existing
        let id = existing?.id ?? UUID()
        self.id = id
        _name = State(initialValue: existing?.name ?? "")
        _configSource = State(initialValue: existing?.configSource ?? .localFile)
        _kubeconfigPath = State(initialValue: existing?.kubeconfigPath ?? "~/.kube/config")
        _kubeconfigContents = State(initialValue: existing.map(ConfigurationStore.loadKubeconfig) ?? "")
        _contextName = State(initialValue: existing?.contextName ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing == nil ? "添加 Kubernetes 集群" : "修改 Kubernetes 集群")
                        .font(.title2.weight(.semibold))
                    Text("每个集群绑定一个 kubeconfig Context")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()

            Form {
                TextField("显示名称", text: $name, prompt: Text("例如：生产集群"))

                Picker("kubeconfig", selection: $configSource) {
                    ForEach(KubeConfigSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: configSource) { _, _ in
                    contexts = []
                    errorMessage = nil
                }

                Section("配置") {
                    if configSource == .localFile {
                        HStack {
                            TextField("文件路径", text: $kubeconfigPath, prompt: Text("~/.kube/config"))
                            Button("选择…") { showingFileImporter = true }
                        }
                    } else {
                        Text("内容会以 0600 权限保存在这台 Mac 的应用私有目录中。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $kubeconfigContents)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 180)
                            .overlay {
                                if kubeconfigContents.isEmpty {
                                    Text("粘贴完整的 kubeconfig YAML")
                                        .foregroundStyle(.tertiary)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    HStack {
                        Button("读取 Context") {
                            Task { await inspectContexts() }
                        }
                        .disabled(isInspecting)
                        if isInspecting {
                            ProgressView().controlSize(.small)
                            Text("正在读取…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Context") {
                    if contexts.isEmpty {
                        Text(contextName.isEmpty ? "请先读取 kubeconfig" : contextName)
                            .foregroundStyle(contextName.isEmpty ? .secondary : .primary)
                    } else {
                        Picker("使用", selection: $contextName) {
                            ForEach(contexts, id: \.self) { context in
                                Text(context).tag(context)
                            }
                        }
                        Text("同一份 kubeconfig 中的其他 Context 可以另行添加为独立集群。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isInspecting)
            }
            .padding(18)
        }
        .frame(width: 620, height: configSource == .embedded ? 650 : 500)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                kubeconfigPath = url.path
                Task { await inspectContexts() }
            }
        }
    }

    @MainActor
    private func inspectContexts() async {
        isInspecting = true
        errorMessage = nil
        var temporaryURL: URL?
        defer {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            isInspecting = false
        }

        do {
            let path: String
            if configSource == .localFile {
                path = (kubeconfigPath as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else {
                    throw ValidationError.message("找不到 kubeconfig：\(kubeconfigPath)")
                }
            } else {
                guard !kubeconfigContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.message("请粘贴 kubeconfig YAML")
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PortRelay-kubeconfig-\(UUID().uuidString).yaml")
                try Data(kubeconfigContents.utf8).write(to: url, options: .atomic)
                temporaryURL = url
                path = url.path
            }

            contexts = try await KubernetesClient.contexts(kubeconfigPath: path)
            guard !contexts.isEmpty else {
                throw ValidationError.message("kubeconfig 中没有可用的 Context")
            }
            if !contexts.contains(contextName) { contextName = contexts[0] }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = contextName
            }
        } catch {
            contexts = []
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            try store.saveKubernetesCluster(
                KubernetesClusterProfile(
                    id: id,
                    name: name,
                    configSource: configSource,
                    kubeconfigPath: kubeconfigPath,
                    contextName: contextName
                ),
                kubeconfigContents: kubeconfigContents
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
