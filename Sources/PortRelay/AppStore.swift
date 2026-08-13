import Foundation

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var servers: [ServerProfile] = []
    @Published private(set) var mappings: [PortMapping] = []
    @Published var selectedServerID: UUID?
    @Published var alertMessage: String?
    @Published private(set) var sshConfigEntries: [SSHConfigEntry] = []

    let forwardManager = PortRelayManager()

    private init() {
        do {
            let configuration = try ConfigurationStore.load()
            servers = configuration.servers
            mappings = configuration.mappings
            selectedServerID = servers.first?.id
        } catch {
            alertMessage = "读取配置失败：\(error.localizedDescription)"
        }
        reloadSSHConfig()
        restoreEnabledMappings()
    }

    var selectedServer: ServerProfile? {
        servers.first { $0.id == selectedServerID }
    }

    func mappings(for serverID: UUID, matching query: String = "") -> [PortMapping] {
        let values = mappings.filter { $0.serverID == serverID }
        guard !query.isEmpty else { return values }
        return values.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.remoteAddress.localizedCaseInsensitiveContains(query)
                || $0.localAddress.localizedCaseInsensitiveContains(query)
        }
    }

    func reloadSSHConfig() {
        do {
            sshConfigEntries = try SSHConfigParser.loadDefault()
        } catch {
            alertMessage = "读取 ~/.ssh/config 失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func importSSHServers(aliases: Set<String>) -> Int {
        reloadSSHConfig()
        let existingAliases = Set(servers.compactMap(\.sshAlias))
        let additions = sshConfigEntries.filter {
            aliases.contains($0.alias) && !existingAliases.contains($0.alias)
        }.map {
            ServerProfile(
                id: UUID(),
                name: $0.alias,
                source: .sshConfig,
                sshAlias: $0.alias,
                host: $0.hostName,
                port: $0.port,
                username: $0.user,
                authentication: .sshConfig,
                privateKeyPath: $0.identityFile
            )
        }
        servers.append(contentsOf: additions)
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selectedServerID == nil { selectedServerID = servers.first?.id }
        persist()
        return additions.count
    }

    func saveServer(
        _ profile: ServerProfile,
        password: String,
        privateKeyContents: String
    ) throws {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !profile.name.isEmpty else { throw ValidationError.message("请输入服务器名称") }
        if profile.source == .manual {
            guard !profile.host.isEmpty else { throw ValidationError.message("请输入服务器地址") }
            guard !profile.username.isEmpty else { throw ValidationError.message("请输入用户名") }
            guard (1...65535).contains(profile.port) else {
                throw ValidationError.message("SSH 端口必须在 1 到 65535 之间")
            }
        } else {
            guard let alias = profile.sshAlias, !alias.isEmpty else {
                throw ValidationError.message("请选择 SSH 配置")
            }
        }

        if profile.authentication == .password {
            if !password.isEmpty {
                try KeychainStore.setPassword(password, for: profile.id)
            } else if !KeychainStore.hasPassword(for: profile.id) {
                throw ValidationError.message("请输入密码")
            }
        } else {
            KeychainStore.deletePassword(for: profile.id)
        }

        switch profile.authentication {
        case .privateKeyFile:
            guard let path = profile.privateKeyPath, !path.isEmpty else {
                throw ValidationError.message("请选择私钥文件")
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                throw ValidationError.message("找不到私钥文件：\(path)")
            }
        case .embeddedPrivateKey:
            if !privateKeyContents.isEmpty {
                profile.privateKeyPath = try ConfigurationStore.savePrivateKey(
                    privateKeyContents,
                    serverID: profile.id
                )
            } else if profile.privateKeyPath?.isEmpty != false {
                throw ValidationError.message("请粘贴私钥内容")
            }
        default:
            if servers.first(where: { $0.id == profile.id })?.authentication == .embeddedPrivateKey {
                ConfigurationStore.deletePrivateKey(for: profile.id)
            }
            if profile.authentication != .sshConfig {
                profile.privateKeyPath = nil
            }
        }

        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            stopMappings(for: profile.id)
            servers[index] = profile
        } else {
            servers.append(profile)
        }
        selectedServerID = profile.id
        try persistThrowing()
        restoreEnabledMappings(for: profile.id)
    }

    func deleteServer(_ server: ServerProfile) {
        deleteServers(ids: [server.id])
    }

    func deleteServers(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            stopMappings(for: id)
            KeychainStore.deletePassword(for: id)
            ConfigurationStore.deletePrivateKey(for: id)
        }
        mappings.removeAll { ids.contains($0.serverID) }
        servers.removeAll { ids.contains($0.id) }
        if let selectedServerID, ids.contains(selectedServerID) {
            self.selectedServerID = servers.first?.id
        }
        persist()
    }

    func saveMapping(_ mapping: PortMapping) throws {
        guard !mapping.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.message("请输入映射名称")
        }
        guard !mapping.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.message("请输入远程地址")
        }
        guard !mapping.localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.message("请输入本地监听地址")
        }
        guard (1...65535).contains(mapping.remotePort), (1...65535).contains(mapping.localPort) else {
            throw ValidationError.message("端口必须在 1 到 65535 之间")
        }
        if let conflict = mappings.first(where: {
            $0.id != mapping.id
                && $0.localHost == mapping.localHost
                && $0.localPort == mapping.localPort
        }) {
            throw ValidationError.message("本地地址已被“\(conflict.name)”配置使用")
        }

        var mapping = mapping
        mapping.name = mapping.name.trimmingCharacters(in: .whitespacesAndNewlines)
        mapping.remoteHost = mapping.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        mapping.localHost = mapping.localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = mappings.firstIndex(where: { $0.id == mapping.id }) {
            forwardManager.stop(mappingID: mapping.id)
            mappings[index] = mapping
        } else {
            mappings.append(mapping)
        }
        try persistThrowing()
        if mapping.isEnabled {
            start(mapping)
        }
    }

    func deleteMapping(_ mapping: PortMapping) {
        deleteMappings(ids: [mapping.id])
    }

    func deleteMappings(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            forwardManager.stop(mappingID: id)
        }
        mappings.removeAll { ids.contains($0.id) }
        persist()
    }

    func toggle(_ mapping: PortMapping) {
        guard let index = mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        if mappings[index].isEnabled {
            mappings[index].isEnabled = false
            forwardManager.stop(mappingID: mapping.id)
            persist()
            return
        }

        mappings[index].isEnabled = true
        persist()
        start(mappings[index])
    }

    func retry(_ mapping: PortMapping) {
        guard let current = mappings.first(where: { $0.id == mapping.id }), current.isEnabled else { return }
        forwardManager.stop(mappingID: current.id)
        start(current)
    }

    private func start(_ mapping: PortMapping) {
        guard let server = servers.first(where: { $0.id == mapping.serverID }) else { return }
        do {
            try forwardManager.start(mapping: mapping, server: server)
        } catch {
            alertMessage = "启动映射失败：\(error.localizedDescription)"
        }
    }

    private func restoreEnabledMappings(for serverID: UUID? = nil) {
        for mapping in mappings where mapping.isEnabled
            && (serverID == nil || mapping.serverID == serverID) {
            guard !forwardManager.status(for: mapping.id).isActive else { continue }
            start(mapping)
        }
    }

    func stopMappings(for serverID: UUID) {
        for mapping in mappings where mapping.serverID == serverID {
            forwardManager.stop(mappingID: mapping.id)
        }
    }

    private func persist() {
        do { try persistThrowing() }
        catch { alertMessage = "保存配置失败：\(error.localizedDescription)" }
    }

    private func persistThrowing() throws {
        try ConfigurationStore.save(StoredConfiguration(servers: servers, mappings: mappings))
    }
}
