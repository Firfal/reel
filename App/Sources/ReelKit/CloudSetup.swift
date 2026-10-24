import Foundation

/// Installs the sharing server on the user's own Cloudflare account from an API token, without a terminal:
/// R2 bucket, D1 database and schema, the Worker with its bindings and secrets, and its workers.dev address.
/// Running it again updates the Worker and issues a new owner key.
public struct CloudSetup: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case account, storage, database, server, address, waiting, finishing

        public var label: String {
            switch self {
            case .account: "Vérification du jeton"
            case .storage: "Création du stockage des vidéos"
            case .database: "Création de la base de données"
            case .server: "Installation du serveur de partage"
            case .address: "Publication de l'adresse"
            case .waiting: "Attente du certificat HTTPS (jusqu'à 2 min)"
            case .finishing: "Derniers réglages"
            }
        }
    }

    public enum SetupError: LocalizedError {
        case invalidToken
        case noAccount
        case r2NotEnabled
        case cloudflare(String)
        case notReachable

        public var errorDescription: String? {
            switch self {
            case .invalidToken: "Ce jeton Cloudflare n'est pas valide ou n'a pas les bonnes permissions."
            case .noAccount: "Aucun compte Cloudflare n'est associé à ce jeton."
            case .r2NotEnabled: "Active d'abord R2 dans ton tableau de bord Cloudflare (menu R2 Object Storage, offre gratuite), puis réessaie."
            case .cloudflare(let message): "Cloudflare a répondu : \(message)"
            case .notReachable: "Le serveur est installé mais pas encore joignable. Réessaie dans quelques minutes."
            }
        }
    }

    public let token: String
    public var scriptName = "reel"
    public var bucketName = "reel-videos"
    public var databaseName = "reel"
    private let session = URLSession.shared
    private let api = URL(string: "https://api.cloudflare.com/client/v4/")!

    public init(token: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The permissions to tick when creating the token, shown to the user.
    public static let tokenPermissions = [
        "Compte › Workers Scripts › Modifier",
        "Compte › Workers R2 Storage › Modifier",
        "Compte › D1 › Modifier",
        "Compte › Paramètres du compte › Lire",
    ]

    /// Creates or updates everything, then returns the account to save. `progress` is called before each step.
    public func run(workerScript: Data, schema: String, font: Data?, progress: @Sendable (Step) -> Void) async throws -> CloudAccount {
        progress(.account)
        let accountID = try await accountID()

        progress(.storage)
        try await createBucket(accountID: accountID)

        progress(.database)
        let databaseID = try await database(accountID: accountID)
        let idempotent = schema
            .replacingOccurrences(of: "CREATE TABLE ", with: "CREATE TABLE IF NOT EXISTS ")
            .replacingOccurrences(of: "CREATE INDEX ", with: "CREATE INDEX IF NOT EXISTS ")
        _ = try await call("POST", "accounts/\(accountID)/d1/database/\(databaseID)/query", json: ["sql": idempotent])

        progress(.server)
        let ownerToken = Self.randomHex()
        try await uploadWorker(accountID: accountID, databaseID: databaseID, script: workerScript, ownerToken: ownerToken)

        progress(.address)
        let subdomain = try await workersSubdomain(accountID: accountID)
        _ = try await call("POST", "accounts/\(accountID)/workers/scripts/\(scriptName)/subdomain", json: ["enabled": true, "previews_enabled": false])
        let serverURL = URL(string: "https://\(scriptName).\(subdomain).workers.dev")!

        progress(.waiting)
        try await waitUntilReachable(serverURL)

        progress(.finishing)
        let account = CloudAccount(serverURL: serverURL, ownerToken: ownerToken)
        if let font {
            var request = URLRequest(url: serverURL.appendingPathComponent("api/fonts/InstrumentSans.ttf"))
            request.httpMethod = "PUT"
            request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = font
            _ = try? await session.data(for: request)
        }
        return account
    }

    // MARK: Steps

    private func accountID() async throws -> String {
        let result: Any
        do {
            result = try await call("GET", "accounts")
        } catch SetupError.cloudflare {
            throw SetupError.invalidToken
        }
        guard let accounts = result as? [[String: Any]], let id = accounts.first?["id"] as? String else { throw SetupError.noAccount }
        return id
    }

    private func createBucket(accountID: String) async throws {
        do {
            _ = try await call("POST", "accounts/\(accountID)/r2/buckets", json: ["name": bucketName])
        } catch SetupError.cloudflare(let message) where message.localizedCaseInsensitiveContains("already exists") || message.contains("10004") {
            return
        } catch SetupError.cloudflare(let message) where message.localizedCaseInsensitiveContains("enable R2") || message.contains("10042") {
            throw SetupError.r2NotEnabled
        }
    }

    private func database(accountID: String) async throws -> String {
        if let existing = try await call("GET", "accounts/\(accountID)/d1/database?name=\(databaseName)") as? [[String: Any]],
           let id = existing.first(where: { $0["name"] as? String == databaseName })?["uuid"] as? String {
            return id
        }
        guard let created = try await call("POST", "accounts/\(accountID)/d1/database", json: ["name": databaseName]) as? [String: Any],
              let id = created["uuid"] as? String else { throw SetupError.cloudflare("no database id") }
        return id
    }

    private func uploadWorker(accountID: String, databaseID: String, script: Data, ownerToken: String) async throws {
        let metadata: [String: Any] = [
            "main_module": "index.js",
            "compatibility_date": "2026-10-24",
            "compatibility_flags": ["nodejs_compat"],
            "observability": ["enabled": true],
            "bindings": [
                ["type": "r2_bucket", "name": "VIDEOS", "bucket_name": bucketName],
                ["type": "d1", "name": "DB", "database_id": databaseID],
                ["type": "plain_text", "name": "STORAGE_CAP_BYTES", "text": "9000000000"],
                ["type": "plain_text", "name": "WRITE_OPS_CAP_MONTH", "text": "900000"],
                ["type": "plain_text", "name": "READ_OPS_CAP_MONTH", "text": "9000000"],
                ["type": "secret_text", "name": "OWNER_TOKEN", "text": ownerToken],
                ["type": "secret_text", "name": "SIGNING_KEY", "text": Self.randomHex()],
            ],
        ]
        let boundary = "reel-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, filename: String? = nil, type: String, _ content: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"".utf8))
            if let filename { body.append(Data("; filename=\"\(filename)\"".utf8)) }
            body.append(Data("\r\nContent-Type: \(type)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part("metadata", type: "application/json", try JSONSerialization.data(withJSONObject: metadata))
        part("index.js", filename: "index.js", type: "application/javascript+module", script)
        body.append(Data("--\(boundary)--\r\n".utf8))
        _ = try await call("PUT", "accounts/\(accountID)/workers/scripts/\(scriptName)", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// The account's workers.dev subdomain, created on first use.
    private func workersSubdomain(accountID: String) async throws -> String {
        if let existing = try? await call("GET", "accounts/\(accountID)/workers/subdomain") as? [String: Any],
           let name = existing["subdomain"] as? String, !name.isEmpty {
            return name
        }
        let name = "reel-" + String(Self.randomHex().prefix(6))
        _ = try await call("PUT", "accounts/\(accountID)/workers/subdomain", json: ["subdomain": name])
        return name
    }

    private func waitUntilReachable(_ url: URL) async throws {
        for _ in 0..<40 {
            if let (_, response) = try? await session.data(from: url.appendingPathComponent("api/health")),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .seconds(3))
        }
        throw SetupError.notReachable
    }

    // MARK: Transport

    /// Calls the Cloudflare API and returns its `result`, or throws its first error message.
    private func call(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil, contentType: String? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: path, relativeTo: api)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await session.data(for: request)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SetupError.cloudflare("réponse illisible") }
        guard response["success"] as? Bool == true else {
            let errors = response["errors"] as? [[String: Any]] ?? []
            let message = errors.map { "\($0["message"] as? String ?? "?") (\($0["code"] ?? ""))" }.joined(separator: "; ")
            throw SetupError.cloudflare(message.isEmpty ? "erreur inconnue" : message)
        }
        return response["result"] ?? [:]
    }

    static func randomHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
