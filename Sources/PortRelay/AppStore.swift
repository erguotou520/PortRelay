import Foundation

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var servers: [ServerProfile] = []
    @Published private(set) var mappings: [PortMapping] = []
    @Published var selectedServerID: UUID?
    @Published private(set) var kubernetesClusters: [KubernetesClusterProfile] = []
    @Published private(set) var kubernetesMappings: [KubernetesPortMapping] = []
    @Published var selectedKubernetesClusterID: UUID?
    @Published var selectedNamespace: String?
    @Published var alertMessage: String?
    @Published private(set) var sshConfigEntries: [SSHConfigEntry] = []

    let forwardManager = PortRelayManager()
    let kubernetesForwardManager = KubernetesPortForwardManager()
    let sessionManager = GlobalSessionManager()

    private init() {
        do {
            let configuration = try ConfigurationStore.load()
            servers = configuration.servers
            mappings = configuration.mappings
            kubernetesClusters = configuration.kubernetesClusters
            kubernetesMappings = configuration.kubernetesMappings
            selectedServerID = servers.first?.id
            selectedKubernetesClusterID = kubernetesClusters.first?.id
        } catch {
            alertMessage = "读取配置失败：\(error.localizedDescription)"
        }
        reloadSSHConfig()
        restoreEnabledMappings()
        restoreEnabledKubernetesMappings()
    }

    var selectedServer: ServerProfile? {
        servers.first { $0.id == selectedServerID }
    }

    var selectedKubernetesCluster: KubernetesClusterProfile? {
        kubernetesClusters.first { $0.id == selectedKubernetesClusterID }
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
        if mapping.isEnabled,
           let conflict = localPortConflict(for: mapping) {
            throw ValidationError.message(conflict.message)
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

        if let conflict = localPortConflict(for: mappings[index]) {
            alertMessage = conflict.message
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
        if let conflict = localPortConflict(for: mapping) {
            alertMessage = conflict.message
            return
        }
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

    func kubernetesMappings(
        clusterID: UUID,
        namespace: String? = nil
    ) -> [KubernetesPortMapping] {
        kubernetesMappings.filter {
            $0.clusterID == clusterID && (namespace == nil || $0.namespace == namespace)
        }
    }

    func kubernetesMapping(
        clusterID: UUID,
        namespace: String,
        port: KubernetesPort
    ) -> KubernetesPortMapping? {
        kubernetesMappings.first {
            $0.clusterID == clusterID
                && $0.namespace == namespace
                && $0.resourceKind == port.kind
                && $0.resourceName == port.resourceName
                && (port.remotePort == nil || (
                    $0.remotePort == port.remotePort
                        && $0.portName == port.portName
                ))
        }
    }

    func saveKubernetesCluster(
        _ cluster: KubernetesClusterProfile,
        kubeconfigContents: String
    ) throws {
        var cluster = cluster
        cluster.name = cluster.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cluster.contextName = cluster.contextName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cluster.name.isEmpty else { throw ValidationError.message("请输入集群名称") }
        guard !cluster.contextName.isEmpty else { throw ValidationError.message("请选择 Context") }

        let previous = kubernetesClusters.first { $0.id == cluster.id }
        if cluster.configSource == .embedded {
            if !kubeconfigContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cluster.kubeconfigPath = try ConfigurationStore.saveKubeconfig(
                    kubeconfigContents,
                    clusterID: cluster.id
                )
            } else if previous?.configSource != .embedded || cluster.kubeconfigPath.isEmpty {
                throw ValidationError.message("请粘贴 kubeconfig YAML")
            }
        } else {
            cluster.kubeconfigPath = (cluster.kubeconfigPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: cluster.kubeconfigPath) else {
                throw ValidationError.message("找不到 kubeconfig：\(cluster.kubeconfigPath)")
            }
            if previous?.configSource == .embedded {
                ConfigurationStore.deleteKubeconfig(for: cluster.id)
            }
        }

        if let index = kubernetesClusters.firstIndex(where: { $0.id == cluster.id }) {
            stopKubernetesMappings(for: cluster.id)
            kubernetesClusters[index] = cluster
        } else {
            kubernetesClusters.append(cluster)
            kubernetesClusters.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        selectedKubernetesClusterID = cluster.id
        selectedNamespace = nil
        try persistThrowing()
        restoreEnabledKubernetesMappings(for: cluster.id)
    }

    func deleteKubernetesClusters(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            stopKubernetesMappings(for: id)
            ConfigurationStore.deleteKubeconfig(for: id)
        }
        kubernetesMappings.removeAll { ids.contains($0.clusterID) }
        kubernetesClusters.removeAll { ids.contains($0.id) }
        if let selectedKubernetesClusterID, ids.contains(selectedKubernetesClusterID) {
            self.selectedKubernetesClusterID = kubernetesClusters.first?.id
            selectedNamespace = nil
        }
        persist()
    }

    func saveKubernetesMapping(_ mapping: KubernetesPortMapping) throws {
        guard !mapping.namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.message("Namespace 不能为空")
        }
        guard !mapping.resourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.message("资源名称不能为空")
        }
        guard (1...65535).contains(mapping.remotePort), (1...65535).contains(mapping.localPort) else {
            throw ValidationError.message("端口必须在 1 到 65535 之间")
        }
        if kubernetesMappings.contains(where: {
            $0.id != mapping.id
                && $0.clusterID == mapping.clusterID
                && $0.namespace == mapping.namespace
                && $0.resourceKind == mapping.resourceKind
                && $0.resourceName == mapping.resourceName
                && $0.remotePort == mapping.remotePort
                && $0.portName == mapping.portName
        }) {
            throw ValidationError.message("这个集群端口已经配置了本地映射")
        }
        if mapping.isEnabled,
           let conflict = localPortConflict(for: mapping) {
            throw ValidationError.message(conflict.message)
        }

        if let index = kubernetesMappings.firstIndex(where: { $0.id == mapping.id }) {
            kubernetesForwardManager.stop(mappingID: mapping.id)
            kubernetesMappings[index] = mapping
        } else {
            kubernetesMappings.append(mapping)
        }
        try persistThrowing()
        if mapping.isEnabled { startKubernetesMapping(mapping) }
    }

    func deleteKubernetesMappings(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { kubernetesForwardManager.stop(mappingID: id) }
        kubernetesMappings.removeAll { ids.contains($0.id) }
        persist()
    }

    func toggleKubernetesMapping(_ mapping: KubernetesPortMapping) {
        guard let index = kubernetesMappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        if kubernetesMappings[index].isEnabled {
            kubernetesMappings[index].isEnabled = false
            kubernetesForwardManager.stop(mappingID: mapping.id)
            persist()
            return
        }
        if let conflict = localPortConflict(for: kubernetesMappings[index]) {
            alertMessage = conflict.message
            return
        }
        kubernetesMappings[index].isEnabled = true
        persist()
        startKubernetesMapping(kubernetesMappings[index])
    }

    func retryKubernetesMapping(_ mapping: KubernetesPortMapping) {
        guard let current = kubernetesMappings.first(where: { $0.id == mapping.id }),
              current.isEnabled else { return }
        kubernetesForwardManager.stop(mappingID: current.id)
        startKubernetesMapping(current)
    }

    func stopKubernetesMappings(for clusterID: UUID) {
        for mapping in kubernetesMappings where mapping.clusterID == clusterID {
            kubernetesForwardManager.stop(mappingID: mapping.id)
        }
    }

    private func startKubernetesMapping(_ mapping: KubernetesPortMapping) {
        guard let cluster = kubernetesClusters.first(where: { $0.id == mapping.clusterID }) else { return }
        if let conflict = localPortConflict(for: mapping) {
            alertMessage = conflict.message
            return
        }
        do {
            try kubernetesForwardManager.start(mapping: mapping, cluster: cluster)
        } catch {
            alertMessage = "启动 Kubernetes 映射失败：\(error.localizedDescription)"
        }
    }

    private func restoreEnabledKubernetesMappings(for clusterID: UUID? = nil) {
        for mapping in kubernetesMappings where mapping.isEnabled
            && (clusterID == nil || mapping.clusterID == clusterID) {
            guard !kubernetesForwardManager.status(for: mapping.id).isActive else { continue }
            startKubernetesMapping(mapping)
        }
    }

    private func localPortConflict(for mapping: PortMapping) -> LocalPortConflict? {
        LocalPortAvailability.conflict(
            host: mapping.localHost,
            port: mapping.localPort,
            excludingSSHID: mapping.id,
            sshMappings: mappings,
            kubernetesMappings: kubernetesMappings
        )
    }

    private func localPortConflict(for mapping: KubernetesPortMapping) -> LocalPortConflict? {
        LocalPortAvailability.conflict(
            host: mapping.localHost,
            port: mapping.localPort,
            excludingKubernetesID: mapping.id,
            sshMappings: mappings,
            kubernetesMappings: kubernetesMappings
        )
    }

    private func persist() {
        do { try persistThrowing() }
        catch { alertMessage = "保存配置失败：\(error.localizedDescription)" }
    }

    private func persistThrowing() throws {
        try ConfigurationStore.save(StoredConfiguration(
            servers: servers,
            mappings: mappings,
            kubernetesClusters: kubernetesClusters,
            kubernetesMappings: kubernetesMappings
        ))
    }
}
