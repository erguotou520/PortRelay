import Foundation
import Security

enum KeychainStore {
    // Keep the legacy service so saved passwords remain available after the rename.
    static let service = "com.erguotou.PortForward.password"

    static func setPassword(_ password: String, for serverID: UUID) throws {
        try setPassword(password, account: serverID.uuidString)
    }

    static func hasPassword(for serverID: UUID) -> Bool {
        hasPassword(account: serverID.uuidString)
    }

    static func deletePassword(for serverID: UUID) {
        deletePassword(account: serverID.uuidString)
    }

    static func setTeleportPassword(_ password: String, for clusterID: UUID) throws {
        try setPassword(password, account: "teleport-\(clusterID.uuidString)")
    }

    static func teleportPassword(for clusterID: UUID) -> String? {
        password(account: "teleport-\(clusterID.uuidString)")
    }

    static func hasTeleportPassword(for clusterID: UUID) -> Bool {
        hasPassword(account: "teleport-\(clusterID.uuidString)")
    }

    static func deleteTeleportPassword(for clusterID: UUID) {
        deletePassword(account: "teleport-\(clusterID.uuidString)")
    }

    private static func setPassword(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ValidationError.message("无法保存密码到钥匙串（错误 \(status)）")
        }
    }

    private static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func hasPassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
