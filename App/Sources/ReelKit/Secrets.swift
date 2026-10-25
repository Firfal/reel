import Foundation
import Security
import Synchronization

/// Where Reel keeps its secrets: the sharing server's owner key and the Claude key.
///
/// In the Keychain when the app is signed with an Apple Developer team. Without a team, macOS ties each Keychain
/// item to the exact hash of the build that last used it and asks for the password after every update, even
/// after « Always allow ». Such builds keep their secrets in a file only the user can read, like `gh` or
/// `wrangler` do, and move what the Keychain held there once.
enum Secrets {
    static func read(service: String, account: String) -> String? {
        if usesKeychain { return Keychain.read(service: service, account: account) }
        let name = "\(service)/\(account)"
        if let value = store.withLock({ $0.values[name] }) { return value }
        guard !store.withLock({ $0.migrated.contains(name) }) else { return nil }
        // One last Keychain read for values saved by earlier builds, without a password prompt:
        // a value macOS won't hand over silently is left behind, and the user enters it again.
        let legacy = Keychain.readSilently(service: service, account: account).0
        store.withLock { file in
            file.migrated.insert(name)
            if let legacy { file.values[name] = legacy }
            try? file.save()
        }
        return legacy
    }

    static func write(_ value: String, service: String, account: String) throws {
        if usesKeychain { return try Keychain.write(value, service: service, account: account) }
        try store.withLock { file in
            file.values["\(service)/\(account)"] = value
            try file.save()
        }
    }

    /// True when the running code is signed by an Apple Developer team.
    static let usesKeychain: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] != nil
    }()

    private static let store = Mutex(SecretFile.load())
}

/// `~/Library/Application Support/Reel/credentials.json`, readable by the user only (0600, folder 0700).
private struct SecretFile: Codable {
    var values: [String: String] = [:]
    /// Keychain entries already looked at, so a missing one is not read again on every launch.
    var migrated: Set<String> = []

    static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Reel", isDirectory: true).appendingPathComponent("credentials.json")
    }

    static func load() -> SecretFile {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(SecretFile.self, from: data) else { return SecretFile() }
        return file
    }

    func save() throws {
        let folder = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        let temporary = folder.appendingPathComponent(".credentials-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: Self.url.path) {
            _ = try FileManager.default.replaceItemAt(Self.url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: Self.url)
        }
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fails instead of asking for the login password when the item's access list doesn't include this build.
    static func readSilently(service: String, account: String) -> (String?, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    static func write(_ value: String, service: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudError.keychain(status) }
    }
}
