import Foundation
import Security

/// The Pass10x login, kept in the app's Keychain: building, suite and password
/// are each a generic password item under the service "pass10x".
struct Credentials: Equatable {
    var building = "Landmark 33"
    var suite = ""
    var password = ""

    var isComplete: Bool { !building.isEmpty && !suite.isEmpty && !password.isEmpty }

    static func load() -> Credentials {
        var c = Credentials()
        if let b = Keychain.read("building"), !b.isEmpty { c.building = b }
        c.suite = Keychain.read("suite") ?? ""
        c.password = Keychain.read("password") ?? ""
        return c
    }

    func save() throws {
        try Keychain.write(building, for: "building")
        try Keychain.write(suite, for: "suite")
        try Keychain.write(password, for: "password")
    }
}

enum Keychain {
    static let service = "pass10x"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
