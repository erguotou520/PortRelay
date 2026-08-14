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
    @State private var teleportProxy: String
    @State private var teleportUsername: String
    @State private var teleportPassword = ""
    @State private var teleportRequiresMFA: Bool
    @State private var teleportMFACode = ""
    @State private var teleportKubeCluster: String
    @State private var teleportClusters: [String] = []
    @State private var didAuthenticateTeleport = false
    @State private var showingFileImporter = false
    @State private var isInspecting = false
    @State private var isSaving = false
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
        _teleportProxy = State(initialValue: existing?.teleportProxy ?? "")
        _teleportUsername = State(initialValue: existing?.teleportUsername ?? "")
        _teleportRequiresMFA = State(initialValue: existing?.teleportRequiresMFA ?? false)
        _teleportKubeCluster = State(initialValue: existing?.teleportKubeCluster ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing == nil ? "添加 Kubernetes 集群" : "修改 Kubernetes 集群")
                        .font(.title2.weight(.semibold))
                    Text("支持 kubeconfig 或通过 Teleport 登录")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()

            Form {
                TextField("显示名称", text: $name, prompt: Text("例如：生产集群"))

                Picker("配置方式", selection: $configSource) {
                    ForEach(KubeConfigSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: configSource) { _, _ in
                    contexts = []
                    teleportClusters = []
                    didAuthenticateTeleport = false
                    errorMessage = nil
                }

                Section("配置") {
                    switch configSource {
                    case .localFile:
                        HStack {
                            TextField("文件路径", text: $kubeconfigPath, prompt: Text("~/.kube/config"))
                            Button("选择…") { showingFileImporter = true }
                        }
                    case .embedded:
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
                    case .teleport:
                        TextField("Teleport 地址", text: $teleportProxy, prompt: Text("teleport.example.com:443"))
                        TextField("账户", text: $teleportUsername)
                        SecureField(
                            existing == nil ? "密码" : "密码（留空表示不修改）",
                            text: $teleportPassword
                        )
                        Toggle("需要 MFA（OTP）", isOn: $teleportRequiresMFA)
                        if teleportRequiresMFA {
                            SecureField("当前 MFA 验证码", text: $teleportMFACode)
                            Text("验证码不会保存；凭证到期后需要输入新的验证码重新登录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button(configSource == .teleport ? "登录并读取集群" : "读取 Context") {
                            Task { await inspectContexts() }
                        }
                        .disabled(isInspecting)
                        if isInspecting {
                            ProgressView().controlSize(.small)
                            Text("正在读取…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section(configSource == .teleport ? "Kubernetes 集群" : "Context") {
                    if configSource == .teleport {
                        if teleportClusters.isEmpty {
                            Text(teleportKubeCluster.isEmpty ? "请先登录 Teleport" : teleportKubeCluster)
                                .foregroundStyle(teleportKubeCluster.isEmpty ? .secondary : .primary)
                        } else {
                            Picker("使用", selection: $teleportKubeCluster) {
                                ForEach(teleportClusters, id: \.self) { cluster in
                                    Text(cluster).tag(cluster)
                                }
                            }
                        }
                    } else if contexts.isEmpty {
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
                Button(existing == nil ? "添加" : "保存") {
                    Task { await save() }
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isInspecting || isSaving)
            }
            .padding(18)
        }
        .frame(width: 620, height: configSource == .embedded ? 650 : (configSource == .teleport ? 620 : 500))
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
            if configSource == .teleport {
                try await inspectTeleportClusters()
                return
            }
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

    @MainActor
    private func inspectTeleportClusters() async throws {
        let proxy = TeleportClient.normalizeProxy(teleportProxy)
        let username = teleportUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxy.isEmpty else { throw ValidationError.message("请输入 Teleport 地址") }
        guard !username.isEmpty else { throw ValidationError.message("请输入 Teleport 账户") }
        let password = teleportPassword.isEmpty
            ? KeychainStore.teleportPassword(for: id) ?? ""
            : teleportPassword
        guard !password.isEmpty else { throw ValidationError.message("请输入 Teleport 密码") }
        if teleportRequiresMFA && teleportMFACode.isEmpty {
            throw ValidationError.message("请输入当前 MFA 验证码")
        }
        teleportClusters = try await TeleportClient.loginAndListClusters(
            proxy: proxy,
            username: username,
            password: password,
            mfaCode: teleportRequiresMFA ? teleportMFACode : nil
        )
        guard !teleportClusters.isEmpty else {
            throw ValidationError.message("当前账户没有可访问的 Kubernetes 集群")
        }
        if !teleportClusters.contains(teleportKubeCluster) {
            teleportKubeCluster = teleportClusters[0]
        }
        teleportProxy = proxy
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = teleportKubeCluster
        }
        didAuthenticateTeleport = true
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            var profile = KubernetesClusterProfile(
                id: id,
                name: name,
                configSource: configSource,
                kubeconfigPath: kubeconfigPath,
                contextName: contextName,
                teleportProxy: TeleportClient.normalizeProxy(teleportProxy),
                teleportUsername: teleportUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                teleportKubeCluster: teleportKubeCluster,
                teleportRequiresMFA: teleportRequiresMFA
            )
            if configSource == .teleport {
                if !didAuthenticateTeleport && teleportConfigurationChanged {
                    try await inspectTeleportClusters()
                    profile.name = name
                    profile.teleportProxy = teleportProxy
                    profile.teleportUsername = teleportUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.teleportKubeCluster = teleportKubeCluster
                }
                profile.contextName = "portrelay-\(id.uuidString.lowercased())"
                profile.kubeconfigPath = try ConfigurationStore.prepareTeleportKubeconfig(clusterID: id)
                if didAuthenticateTeleport || teleportConfigurationChanged {
                    _ = try await TeleportClient.configureKubeconfig(for: profile)
                }
            }
            try store.saveKubernetesCluster(
                profile,
                kubeconfigContents: kubeconfigContents,
                teleportPassword: teleportPassword
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var teleportConfigurationChanged: Bool {
        guard let existing else { return true }
        return existing.configSource != .teleport
            || existing.teleportProxy != TeleportClient.normalizeProxy(teleportProxy)
            || existing.teleportUsername != teleportUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            || existing.teleportKubeCluster != teleportKubeCluster
            || existing.teleportRequiresMFA != teleportRequiresMFA
            || !teleportPassword.isEmpty
    }
}
