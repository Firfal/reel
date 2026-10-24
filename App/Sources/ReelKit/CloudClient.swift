import Foundation
import Security

/// Where the user's sharing server lives and the key that proves the app owns it, kept in the Keychain.
public struct CloudAccount: Sendable, Hashable {
    public var serverURL: URL
    public var ownerToken: String

    public init(serverURL: URL, ownerToken: String) {
        self.serverURL = serverURL
        self.ownerToken = ownerToken
    }

    static let service = "app.reel.mac.cloud"

    /// The account saved on this Mac, if any.
    public static func load() -> CloudAccount? {
        guard let url = Keychain.read(service: service, account: "server-url").flatMap(URL.init(string:)),
              let token = Keychain.read(service: service, account: "owner-token")
        else { return nil }
        return CloudAccount(serverURL: url, ownerToken: token)
    }

    public func save() throws {
        try Keychain.write(serverURL.absoluteString, service: Self.service, account: "server-url")
        try Keychain.write(ownerToken, service: Self.service, account: "owner-token")
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

public enum CloudError: LocalizedError {
    case server(status: Int, message: String)
    case quota(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .server(let status, let message): "Le serveur de partage a répondu \(status) : \(message)"
        case .quota(let message): message
        case .keychain(let status): "Impossible d'enregistrer la clé dans le Trousseau (\(status))."
        }
    }
}

/// What a shared video carries besides the file.
public struct ShareMetadata: Codable, Sendable {
    public struct Chapter: Codable, Sendable, Hashable { public var time: Double; public var title: String
        public init(time: Double, title: String) { self.time = time; self.title = title } }
    public struct CallToAction: Codable, Sendable, Hashable { public var label: String; public var url: URL
        public init(label: String, url: URL) { self.label = label; self.url = url } }
    public struct Link: Codable, Sendable, Hashable { public var start: Double; public var end: Double; public var label: String; public var url: URL
        public init(start: Double, end: Double, label: String, url: URL) { self.start = start; self.end = end; self.label = label; self.url = url } }

    public var title: String
    public var description: String = ""
    public var duration: Double
    public var privacy: String = "unlisted"
    public var password: String?
    public var chapters: [Chapter] = []
    public var cta: CallToAction?
    public var links: [Link] = []
    public var captions: String?

    public init(title: String, duration: Double) {
        self.title = title
        self.duration = duration
    }
}

public struct ServerUsage: Codable, Sendable {
    public var storageBytes: Int64
    public var storageCapBytes: Int64
    public var writeOps: Int
    public var writeOpsCap: Int
    public var readOps: Int
    public var readOpsCap: Int
}

/// Talks to the user's own sharing server (cloud/ in this repo).
public struct CloudClient: Sendable {
    public let account: CloudAccount
    private let session: URLSession

    public init(account: CloudAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    /// Uploads `fileURL` in parts and returns the public link. `progress` receives 0...1.
    @concurrent
    public func upload(
        _ fileURL: URL,
        metadata: ShareMetadata,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> (id: String, url: URL) {
        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
        struct Created: Decodable { let id: String; let partSize: Int; let url: URL }
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any] ?? [:]
        body["sizeBytes"] = size
        let created: Created = try await send("POST", "api/videos", json: body)

        struct Part: Codable { let partNumber: Int; let etag: String }
        var parts: [Part] = []
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var sent: Int64 = 0
        var number = 1
        while let chunk = try handle.read(upToCount: created.partSize), !chunk.isEmpty {
            try Task.checkCancellation()
            let part: Part = try await send("PUT", "api/videos/\(created.id)/parts/\(number)", data: chunk)
            parts.append(part)
            sent += Int64(chunk.count)
            progress(size > 0 ? Double(sent) / Double(size) : 1)
            number += 1
        }
        let _: [String: AnyCodable] = try await send("POST", "api/videos/\(created.id)/complete", json: ["parts": parts.map { ["partNumber": $0.partNumber, "etag": $0.etag] }])
        return (created.id, created.url)
    }

    public func uploadThumbnail(_ jpeg: Data, videoID: String) async throws {
        let _: [String: AnyCodable] = try await send("PUT", "api/videos/\(videoID)/thumbnail", data: jpeg)
    }

    public struct Branding: Codable, Sendable, Hashable {
        public var companyName: String
        public var playerColor: String
        public var hasLogo: Bool
        public var defaultPrivacy: String
    }

    public func branding() async throws -> Branding {
        try await send("GET", "api/settings")
    }

    public func saveBranding(_ branding: Branding) async throws -> Branding {
        let body: [String: Any] = ["companyName": branding.companyName, "playerColor": branding.playerColor, "defaultPrivacy": branding.defaultPrivacy]
        return try await send("PUT", "api/settings", json: body)
    }

    public func uploadLogo(_ png: Data) async throws {
        let _: [String: AnyCodable] = try await send("PUT", "api/brand/logo", data: png)
    }

    public func usage() async throws -> ServerUsage {
        try await send("GET", "api/usage")
    }

    public func delete(videoID: String) async throws {
        let _: [String: AnyCodable] = try await send("DELETE", "api/videos/\(videoID)")
    }

    // MARK: Transport

    private func send<T: Decodable>(_ method: String, _ path: String, json: Any? = nil, data: Data? = nil) async throws -> T {
        var request = URLRequest(url: account.serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(account.ownerToken)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let data {
            request.httpBody = data
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"] ?? String(decoding: body, as: UTF8.self)
            throw status == 429 ? CloudError.quota(message) : CloudError.server(status: status, message: message)
        }
        return try JSONDecoder().decode(T.self, from: body)
    }
}

/// Lets responses we only acknowledge decode without a dedicated type.
public struct AnyCodable: Codable, Sendable {
    public init(from decoder: any Decoder) throws {}
    public func encode(to encoder: any Encoder) throws {}
}
