import Foundation

enum ServerSource: String, Codable, CaseIterable, Identifiable {
    case sshConfig
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sshConfig: "SSH 配置"
        case .manual: "手动添加"
        }
    }
}

enum AuthenticationKind: String, Codable, CaseIterable, Identifiable {
    case sshConfig
    case systemDefault
    case password
    case privateKeyFile
    case embeddedPrivateKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sshConfig: "使用 SSH 配置"
        case .systemDefault: "SSH Agent / 默认密钥"
        case .password: "密码"
        case .privateKeyFile: "私钥文件"
        case .embeddedPrivateKey: "粘贴私钥内容"
        }
    }
}

struct ServerProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var source: ServerSource
    var sshAlias: String?
    var host: String
    var port: Int
    var username: String
    var authentication: AuthenticationKind
    var privateKeyPath: String?

    var subtitle: String {
        if source == .sshConfig, let sshAlias {
            return sshAlias
        }
        return "\(username)@\(host):\(port)"
    }
}

struct PortMapping: Codable, Identifiable, Hashable {
    var id: UUID
    var serverID: UUID
    var name: String
    var remoteHost: String
    var remotePort: Int
    var localHost: String
    var localPort: Int
    var isEnabled: Bool

    init(
        id: UUID,
        serverID: UUID,
        name: String,
        remoteHost: String,
        remotePort: Int,
        localHost: String,
        localPort: Int,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.localHost = localHost
        self.localPort = localPort
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, serverID, name, remoteHost, remotePort, localHost, localPort, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serverID = try container.decode(UUID.self, forKey: .serverID)
        name = try container.decode(String.self, forKey: .name)
        remoteHost = try container.decode(String.self, forKey: .remoteHost)
        remotePort = try container.decode(Int.self, forKey: .remotePort)
        localHost = try container.decode(String.self, forKey: .localHost)
        localPort = try container.decode(Int.self, forKey: .localPort)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    }

    var remoteAddress: String { "\(remoteHost):\(remotePort)" }
    var localAddress: String { "\(localHost):\(localPort)" }
}

enum KubeConfigSource: String, Codable, CaseIterable, Identifiable {
    case localFile
    case embedded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localFile: "本地文件"
        case .embedded: "粘贴 YAML"
        }
    }
}

struct KubernetesClusterProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var configSource: KubeConfigSource
    var kubeconfigPath: String
    var contextName: String

    var subtitle: String { contextName }
}

enum KubernetesResourceKind: String, Codable, CaseIterable, Identifiable {
    case service
    case deployment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .service: "Service"
        case .deployment: "Deployment"
        }
    }

    var kubectlName: String {
        switch self {
        case .service: "service"
        case .deployment: "deployment"
        }
    }
}

struct KubernetesPort: Identifiable, Hashable {
    var kind: KubernetesResourceKind
    var resourceName: String
    var portName: String?
    var remotePort: Int

    var id: String { "\(kind.rawValue)/\(resourceName)/\(remotePort)/\(portName ?? "")" }
    var resourceDisplayName: String { "\(kind.title)/\(resourceName)" }
}

struct KubernetesPod: Identifiable, Hashable {
    var name: String
    var phase: String

    var id: String { name }
    var isRunning: Bool { phase == "Running" }
}

struct KubernetesPortMapping: Codable, Identifiable, Hashable {
    var id: UUID
    var clusterID: UUID
    var namespace: String
    var resourceKind: KubernetesResourceKind
    var resourceName: String
    var portName: String?
    var remotePort: Int
    var localHost: String
    var localPort: Int
    var isEnabled: Bool

    init(
        id: UUID,
        clusterID: UUID,
        namespace: String,
        resourceKind: KubernetesResourceKind,
        resourceName: String,
        portName: String?,
        remotePort: Int,
        localHost: String,
        localPort: Int,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.clusterID = clusterID
        self.namespace = namespace
        self.resourceKind = resourceKind
        self.resourceName = resourceName
        self.portName = portName
        self.remotePort = remotePort
        self.localHost = localHost
        self.localPort = localPort
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, clusterID, namespace, resourceKind, resourceName, portName
        case remotePort, localHost, localPort, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        clusterID = try container.decode(UUID.self, forKey: .clusterID)
        namespace = try container.decode(String.self, forKey: .namespace)
        resourceKind = try container.decode(KubernetesResourceKind.self, forKey: .resourceKind)
        resourceName = try container.decode(String.self, forKey: .resourceName)
        portName = try container.decodeIfPresent(String.self, forKey: .portName)
        remotePort = try container.decode(Int.self, forKey: .remotePort)
        localHost = try container.decode(String.self, forKey: .localHost)
        localPort = try container.decode(Int.self, forKey: .localPort)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    }

    var resourceAddress: String { "\(resourceKind.title)/\(resourceName):\(remotePort)" }
    var localAddress: String { "\(localHost):\(localPort)" }
}

enum LocalPortConflict: Equatable {
    case ssh(String)
    case kubernetes(String)

    var message: String {
        switch self {
        case .ssh(let name):
            "本地地址已被 SSH 映射“\(name)”使用"
        case .kubernetes(let address):
            "本地地址已被 Kubernetes 映射“\(address)”使用"
        }
    }
}

enum LocalPortAvailability {
    static func conflict(
        host: String,
        port: Int,
        excludingSSHID: UUID? = nil,
        excludingKubernetesID: UUID? = nil,
        sshMappings: [PortMapping],
        kubernetesMappings: [KubernetesPortMapping]
    ) -> LocalPortConflict? {
        if let mapping = sshMappings.first(where: {
            $0.id != excludingSSHID
                && $0.isEnabled
                && $0.localHost == host
                && $0.localPort == port
        }) {
            return .ssh(mapping.name)
        }
        if let mapping = kubernetesMappings.first(where: {
            $0.id != excludingKubernetesID
                && $0.isEnabled
                && $0.localHost == host
                && $0.localPort == port
        }) {
            return .kubernetes(mapping.resourceAddress)
        }
        return nil
    }
}

struct StoredConfiguration: Codable {
    var servers: [ServerProfile] = []
    var mappings: [PortMapping] = []
    var kubernetesClusters: [KubernetesClusterProfile] = []
    var kubernetesMappings: [KubernetesPortMapping] = []

    private enum CodingKeys: String, CodingKey {
        case servers, mappings, kubernetesClusters, kubernetesMappings
    }

    init(
        servers: [ServerProfile] = [],
        mappings: [PortMapping] = [],
        kubernetesClusters: [KubernetesClusterProfile] = [],
        kubernetesMappings: [KubernetesPortMapping] = []
    ) {
        self.servers = servers
        self.mappings = mappings
        self.kubernetesClusters = kubernetesClusters
        self.kubernetesMappings = kubernetesMappings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decodeIfPresent([ServerProfile].self, forKey: .servers) ?? []
        mappings = try container.decodeIfPresent([PortMapping].self, forKey: .mappings) ?? []
        kubernetesClusters = try container.decodeIfPresent(
            [KubernetesClusterProfile].self,
            forKey: .kubernetesClusters
        ) ?? []
        kubernetesMappings = try container.decodeIfPresent(
            [KubernetesPortMapping].self,
            forKey: .kubernetesMappings
        ) ?? []
    }
}

struct SSHConfigEntry: Identifiable, Hashable {
    var id: String { alias }
    var alias: String
    var hostName: String
    var port: Int
    var user: String
    var identityFile: String?
}

enum MappingStatus: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "未启动"
        case .starting: "连接中"
        case .running: "已映射"
        case .failed: "失败"
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }
}

enum ValidationError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
