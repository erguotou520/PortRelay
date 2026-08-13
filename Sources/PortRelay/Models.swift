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

struct StoredConfiguration: Codable {
    var servers: [ServerProfile] = []
    var mappings: [PortMapping] = []
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
