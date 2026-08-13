import SwiftUI

struct ServerEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let existing: ServerProfile?
    private let id: UUID

    @State private var source: ServerSource
    @State private var selectedAlias: String
    @State private var name: String
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var authentication: AuthenticationKind
    @State private var password = ""
    @State private var privateKeyPath: String
    @State private var privateKeyContents = ""
    @State private var showingFileImporter = false
    @State private var errorMessage: String?

    init(existing: ServerProfile?) {
        self.existing = existing
        let id = existing?.id ?? UUID()
        self.id = id
        _source = State(initialValue: existing?.source ?? .sshConfig)
        _selectedAlias = State(initialValue: existing?.sshAlias ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.host ?? "")
        _port = State(initialValue: existing?.port ?? 22)
        _username = State(initialValue: existing?.username ?? NSUserName())
        _authentication = State(initialValue: existing?.authentication ?? .sshConfig)
        _privateKeyPath = State(initialValue: existing?.privateKeyPath ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing == nil ? "添加服务器" : "修改服务器")
                        .font(.title2.weight(.semibold))
                    Text("配置用于建立 SSH 端口映射的连接信息")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            Form {
                Picker("来源", selection: $source) {
                    ForEach(ServerSource.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: source) { _, newValue in
                    if newValue == .sshConfig {
                        authentication = .sshConfig
                        selectFirstEntryIfNeeded()
                    } else if authentication == .sshConfig {
                        authentication = .systemDefault
                    }
                }

                if source == .sshConfig {
                    Section("SSH 配置") {
                        TextField("显示名称", text: $name, prompt: Text("例如：生产服务器"))
                        if store.sshConfigEntries.isEmpty {
                            ContentUnavailableView(
                                "没有可用的 SSH 主机",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("请检查 ~/.ssh/config 后重新读取。")
                            )
                            Button("重新读取") { store.reloadSSHConfig() }
                        } else {
                            Picker("主机", selection: $selectedAlias) {
                                Text("请选择").tag("")
                                ForEach(store.sshConfigEntries) { entry in
                                    Text("\(entry.alias)  —  \(entry.user)@\(entry.hostName):\(entry.port)")
                                        .tag(entry.alias)
                                }
                            }
                            .onChange(of: selectedAlias) { oldValue, newValue in
                                let shouldUseAliasAsName = name.isEmpty || name == oldValue
                                applySelectedEntry()
                                if shouldUseAliasAsName { name = newValue }
                            }
                        }
                    }
                } else {
                    Section("连接") {
                        TextField("名称", text: $name, prompt: Text("例如：生产服务器"))
                        TextField("服务器地址", text: $host, prompt: Text("IP 或域名"))
                        TextField("SSH 端口", value: $port, format: .number.grouping(.never))
                        TextField("用户名", text: $username)
                    }

                    Section("认证") {
                        Picker("认证方式", selection: $authentication) {
                            ForEach(AuthenticationKind.allCases.filter { $0 != .sshConfig }) { item in
                                Text(item.title).tag(item)
                            }
                        }

                        switch authentication {
                        case .password:
                            SecureField(
                                existing == nil ? "密码" : "密码（留空表示不修改）",
                                text: $password
                            )
                        case .privateKeyFile:
                            HStack {
                                TextField("私钥文件", text: $privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                                Button("选择…") { showingFileImporter = true }
                            }
                        case .embeddedPrivateKey:
                            Text("私钥内容只保存在这台 Mac 的应用私有目录中。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $privateKeyContents)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 110)
                                .overlay {
                                    if privateKeyContents.isEmpty {
                                        Text(existing == nil ? "粘贴 OpenSSH / PEM 私钥" : "留空表示不修改已有私钥")
                                            .foregroundStyle(.tertiary)
                                            .allowsHitTesting(false)
                                    }
                                }
                        default:
                            Text("将使用系统 SSH Agent 或 ~/.ssh 下的默认密钥。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            }
            .padding(18)
        }
        .frame(width: 560, height: source == .manual ? 600 : 430)
        .onAppear { selectFirstEntryIfNeeded() }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                privateKeyPath = url.path
            }
        }
    }

    private func selectFirstEntryIfNeeded() {
        guard source == .sshConfig, selectedAlias.isEmpty,
              let first = store.sshConfigEntries.first else { return }
        selectedAlias = first.alias
        applySelectedEntry()
        name = first.alias
    }

    private func applySelectedEntry() {
        guard let entry = store.sshConfigEntries.first(where: { $0.alias == selectedAlias }) else { return }
        host = entry.hostName
        port = entry.port
        username = entry.user
        privateKeyPath = entry.identityFile ?? ""
    }

    private func save() {
        let profile = ServerProfile(
            id: id,
            name: name,
            source: source,
            sshAlias: source == .sshConfig ? selectedAlias : nil,
            host: host,
            port: port,
            username: username,
            authentication: source == .sshConfig ? .sshConfig : authentication,
            privateKeyPath: privateKeyPath.isEmpty ? nil : privateKeyPath
        )
        do {
            try store.saveServer(profile, password: password, privateKeyContents: privateKeyContents)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
