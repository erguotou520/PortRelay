import Foundation
import Security

// Keep the legacy service so saved passwords remain available after the rename.
let service = "com.erguotou.PortForward.password"
guard let account = ProcessInfo.processInfo.environment["PORTFORWARD_KEYCHAIN_ACCOUNT"] else {
    exit(1)
}

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let password = String(data: data, encoding: .utf8) else {
    exit(1)
}
print(password)
