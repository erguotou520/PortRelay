import Foundation

enum ConfigurationStore {
    private static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Keep the legacy directory so existing installations retain their configuration.
            .appendingPathComponent("PortForward", isDirectory: true)
    }

    private static var configurationURL: URL {
        applicationDirectory.appendingPathComponent("configuration.json")
    }

    static func load() throws -> StoredConfiguration {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return StoredConfiguration()
        }
        return try JSONDecoder().decode(
            StoredConfiguration.self,
            from: Data(contentsOf: configurationURL)
        )
    }

    static func save(_ configuration: StoredConfiguration) throws {
        try FileManager.default.createDirectory(
            at: applicationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.pretty.encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
    }

    static func savePrivateKey(_ contents: String, serverID: UUID) throws -> String {
        let directory = applicationDirectory.appendingPathComponent("Keys", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(serverID.uuidString)
        guard contents.contains("PRIVATE KEY") else {
            throw ValidationError.message("粘贴的内容看起来不是有效的私钥")
        }
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    static func deletePrivateKey(for serverID: UUID) {
        let url = applicationDirectory
            .appendingPathComponent("Keys", isDirectory: true)
            .appendingPathComponent(serverID.uuidString)
        try? FileManager.default.removeItem(at: url)
    }

    static func saveKubeconfig(_ contents: String, clusterID: UUID) throws -> String {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("apiVersion:"), trimmed.contains("clusters:") else {
            throw ValidationError.message("粘贴的内容看起来不是有效的 kubeconfig YAML")
        }
        let directory = applicationDirectory.appendingPathComponent("Kubeconfigs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("\(clusterID.uuidString).yaml")
        try Data(trimmed.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    static func prepareTeleportKubeconfig(clusterID: UUID) throws -> String {
        let directory = applicationDirectory.appendingPathComponent("Kubeconfigs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("\(clusterID.uuidString).yaml")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url.path
    }

    static func loadKubeconfig(for cluster: KubernetesClusterProfile) -> String {
        guard cluster.configSource == .embedded,
              let data = FileManager.default.contents(atPath: cluster.kubeconfigPath) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func deleteKubeconfig(for clusterID: UUID) {
        let url = applicationDirectory
            .appendingPathComponent("Kubeconfigs", isDirectory: true)
            .appendingPathComponent("\(clusterID.uuidString).yaml")
        try? FileManager.default.removeItem(at: url)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
