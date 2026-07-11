import Foundation
import Security

protocol ConnectionPasswordStoring: Sendable {
    func password(for profileID: UUID) throws -> String?
    func save(password: String, for profileID: UUID) throws
    func deletePassword(for profileID: UUID) throws
}

enum KeychainPasswordStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidPasswordData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "GlassDB could not access the Keychain (\(message)). Your connection was not opened; try again after unlocking Keychain."
        case .invalidPasswordData:
            return "GlassDB found an unreadable password in Keychain. Edit the connection and save its password again."
        }
    }
}

struct KeychainPasswordStore: ConnectionPasswordStoring {
    private let service = "com.makikub.GlassDB.connection-password"

    func password(for profileID: UUID) throws -> String? {
        let query = baseQuery(profileID: profileID).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainPasswordStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainPasswordStoreError.invalidPasswordData
        }
        return password
    }

    func save(password: String, for profileID: UUID) throws {
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let updateStatus = SecItemUpdate(baseQuery(profileID: profileID) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainPasswordStoreError.unexpectedStatus(updateStatus)
        }
        var query = baseQuery(profileID: profileID)
        query[kSecValueData as String] = Data(password.utf8)
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainPasswordStoreError.unexpectedStatus(addStatus) }
    }

    func deletePassword(for profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPasswordStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }
}
