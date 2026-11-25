import Observation
import Security
import CryptoKit
import Foundation

enum Grid: String, CaseIterable, Identifiable {
    case secondLife
    case beta

    var id: Self { self }

    var title: String {
        self == .secondLife ? "Second Life" : "Second Life Beta"
    }

    var loginURL: URL? {
        URL(string: self == .secondLife
            ? "https://login.agni.lindenlab.com/cgi-bin/login.cgi"
            : "https://login.aditi.lindenlab.com/cgi-bin/login.cgi")
    }
}

struct LoginCredentials {
    let username: String
    let password: String
    let token: String
    let start: String
    let grid: Grid
    let agreeToTerms: Bool

    var avatarName: (first: String, last: String)? {
        let parts = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        guard !username.contains("@"), (1...2).contains(parts.count), let first = parts.first else { return nil }
        return (String(first), parts.count == 2 ? String(parts[1]) : "Resident")
    }
}

struct GridSession: Sendable {
    let agentID: UUID
    let sessionID: UUID
    let circuitCode: UInt32
    let host: String
    let port: UInt16
    let displayName: String
    let message: String
}

enum WorldError: LocalizedError {
    case message(String)
    case malformedResponse
    case malformedPacket

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .malformedResponse: String(localized: "The server returned an invalid login response.")
        case .malformedPacket: String(localized: "The simulator sent an invalid packet.")
        }
    }
}

/// XML-RPC values are typed so booleans and integers do not become string parameters.
indirect enum RPCValue {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case array([RPCValue])
    case structure([String: RPCValue])

    var text: String? {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .boolean(let value): value ? "true" : "false"
        default: nil
        }
    }

    var fields: [String: RPCValue]? {
        if case .structure(let fields) = self { return fields }
        return nil
    }

    var xml: String {
        let body: String
        switch self {
        case .string(let value):
            body = "<string>\(Self.escape(value))</string>"
        case .integer(let value):
            body = "<int>\(value)</int>"
        case .boolean(let value):
            body = "<boolean>\(value ? 1 : 0)</boolean>"
        case .array(let values):
            body = "<array><data>\(values.map(\.xml).joined())</data></array>"
        case .structure(let values):
            body = "<struct>" + values.keys.sorted().map { key in
                "<member><name>\(Self.escape(key))</name>\(values[key]?.xml ?? "")</member>"
            }.joined() + "</struct>"
        }
        return "<value>\(body)</value>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func response(_ data: Data) throws -> [String: RPCValue] {
        let tree = XMLTree()
        let root = try tree.parse(data)
        guard root.name == "methodResponse" else { throw WorldError.malformedResponse }
        if let fault = root.children.first(where: { $0.name == "fault" }),
           let value = fault.children.first {
            let fields = try decode(value).fields
            throw WorldError.message(fields?["faultString"]?.text ?? String(localized: "Login service error."))
        }
        guard let params = root.children.first(where: { $0.name == "params" }),
              let value = params.children.first?.children.first,
              let fields = try decode(value).fields else { throw WorldError.malformedResponse }
        return fields
    }

    private static func decode(_ node: XMLTree.Node) throws -> RPCValue {
        guard node.name == "value" else { throw WorldError.malformedResponse }
        guard let child = node.children.first else { return .string(node.text) }
        switch child.name {
        case "string", "uuid", "dateTime.iso8601": return .string(child.text)
        case "int", "i4", "i8":
            guard let number = Int64(child.text) else { throw WorldError.malformedResponse }
            return .integer(number)
        case "boolean": return .boolean(child.text == "1" || child.text == "true")
        case "array":
            return .array(try (child.children.first?.children ?? []).map(decode))
        case "struct":
            var result: [String: RPCValue] = [:]
            for member in child.children {
                guard let name = member.children.first(where: { $0.name == "name" }),
                      let value = member.children.first(where: { $0.name == "value" }) else {
                    throw WorldError.malformedResponse
                }
                result[name.text] = try decode(value)
            }
            return .structure(result)
        // Login responses also contain doubles (for example look-at coordinates).
        case "double": return .string(child.text)
        default: throw WorldError.malformedResponse
        }
    }
}

/// Bounded parsing without external entity resolution, shared by login response decoding.
final class XMLTree: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }
    }

    private var stack: [Node] = []
    private var root: Node?
    private var nodeCount = 0

    func parse(_ data: Data) throws -> Node {
        guard data.count <= 4_194_304 else { throw WorldError.malformedResponse }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), let root, stack.isEmpty else { throw WorldError.malformedResponse }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        nodeCount += 1
        guard stack.count < 64, nodeCount < 50_000 else {
            parser.abortParsing()
            return
        }
        let node = Node(elementName)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

protocol GridAuthenticating: Sendable {
    func login(_ credentials: LoginCredentials, deviceID: String) async throws -> GridSession
}

extension GridSession {
    init(response: [String: RPCValue], displayName: String) throws {
        guard let agent = response["agent_id"]?.text.flatMap(UUID.init(uuidString:)),
              let session = response["session_id"]?.text.flatMap(UUID.init(uuidString:)),
              let rawCode = response["circuit_code"]?.text.flatMap(Int64.init),
              rawCode >= Int64(Int32.min), rawCode <= Int64(UInt32.max),
              let host = response["sim_ip"]?.text, !host.isEmpty,
              let port = response["sim_port"]?.text.flatMap(UInt16.init), port > 0 else {
            throw WorldError.malformedResponse
        }
        self.init(agentID: agent, sessionID: session, circuitCode: UInt32(truncatingIfNeeded: rawCode),
                  host: host, port: port, displayName: displayName,
                  message: response["message"]?.text ?? "")
    }
}

actor GridLogin: GridAuthenticating {
    // This transport does not persist credentials; optional account storage uses Keychain.
    func login(_ credentials: LoginCredentials, deviceID: String) async throws -> GridSession {
        guard let name = credentials.avatarName, !credentials.password.isEmpty else {
            throw WorldError.message(String(localized: "Enter your account username and password."))
        }
        // MD5 is required by the legacy grid protocol, and is sent only over HTTPS.
        let digest = Insecure.MD5.hash(data: Data(credentials.password.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var fields: [String: RPCValue] = [
            "first": .string(name.first), "last": .string(name.last),
            "passwd": .string("$1$" + digest),
            "start": .string(credentials.start),
            "channel": .string("Primfold"),
            "version": .string("0.1.0.1"),
            "platform": .string("iOS"), "address_size": .integer(64),
            "mac": .string(deviceID), "id0": .string(deviceID),
            "agree_to_tos": .boolean(credentials.agreeToTerms),
            "read_critical": .boolean(false),
            "token": .string(credentials.token),
            "options": .array([.string("login-flags")])
        ]
        guard var endpoint = credentials.grid.loginURL else { throw WorldError.malformedResponse }
        var method = "login_to_simulator"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        let http = URLSession(configuration: config, delegate: LoginRedirectPolicy(), delegateQueue: nil)
        defer { http.invalidateAndCancel() }

        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(("""
                <?xml version="1.0"?><methodCall><methodName>\(RPCValue.escape(method))</methodName>
                <params><param>\(RPCValue.structure(fields).xml)</param></params></methodCall>
                """).utf8)
            let (data, response) = try await http.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw WorldError.message(String(localized: "The login service is unavailable. Please try again."))
            }
            let result = try RPCValue.response(data)
            if result["login"]?.text == "indeterminate" {
                guard let urlText = result["next_url"]?.text, let url = URL(string: urlText),
                      url.scheme == "https", let host = url.host,
                      host.hasSuffix(".lindenlab.com"),
                      let nextMethod = result["next_method"]?.text else {
                    throw WorldError.malformedResponse
                }
                endpoint = url
                method = nextMethod
                if let options = result["next_options"] { fields["options"] = options }
                continue
            }
            guard result["login"]?.text == "true" else {
                throw WorldError.message(result["message"]?.text ?? String(localized: "Login was declined."))
            }
            return try GridSession(response: result, displayName: "\(name.first) \(name.last)")
        }
        throw WorldError.message(String(localized: "The login service redirected too many times."))
    }
}

private final class LoginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // XML-RPC redirects are handled explicitly above; never forward a credential POST.
        completionHandler(nil)
    }
}


// MARK: - Saved accounts

struct SavedLoginAccount: Codable, Equatable, Sendable {
    let username: String
    let password: String
}

protocol LoginCredentialStoring: Sendable {
    func load(for grid: Grid) async throws -> SavedLoginAccount?
    func save(_ account: SavedLoginAccount, for grid: Grid) async throws
    func remove(for grid: Grid) async throws
}

/// Keychain operations run off the main actor. Each grid has its own account slot.
actor KeychainLoginCredentialStore: LoginCredentialStoring {
    private let service: String

    init(service: String = "org.primfold.viewer.saved-login") {
        self.service = service
    }

    func load(for grid: Grid) throws -> SavedLoginAccount? {
        var query = identity(for: grid)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
        guard let data = item as? Data else { throw CredentialStorageError(status: errSecDecode) }
        return try JSONDecoder().decode(SavedLoginAccount.self, from: data)
    }

    func save(_ account: SavedLoginAccount, for grid: Grid) throws {
        let identity = identity(for: grid)
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(account),
            // Accessible while unlocked, confined to this device, without iCloud sync.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = identity.merging(attributes) { _, new in new }
            let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else { throw CredentialStorageError(status: insertionStatus) }
        } else if status != errSecSuccess {
            throw CredentialStorageError(status: status)
        }
    }

    func remove(for grid: Grid) throws {
        let status = SecItemDelete(identity(for: grid) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStorageError(status: status)
        }
    }

    private func identity(for grid: Grid) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: grid.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }
}

struct CredentialStorageError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        String(localized: "Unable to access the saved account in Keychain. Unlock your device and try again.")
    }
}

@MainActor
@Observable
final class LoginAccountForm {
    var username = ""
    var password = ""
    var token = ""
    var grid = Grid.secondLife
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var hasSavedAccount = false
    private(set) var storageError: String?
    private var rememberPreference = false

    @ObservationIgnored private var credentialRevision = UUID()
    @ObservationIgnored private let store: any LoginCredentialStoring

    init(store: any LoginCredentialStoring = KeychainLoginCredentialStore()) {
        self.store = store
    }

    var rememberAccount: Bool {
        get { rememberPreference }
        set {
            rememberPreference = newValue
            let revision = UUID()
            credentialRevision = revision
            if !newValue {
                let selectedGrid = grid
                Task { await removeAccount(for: selectedGrid, revision: revision, clearForm: false) }
            }
        }
    }

    func loadSavedAccount(for selectedGrid: Grid) async {
        guard grid == selectedGrid else { return }
        isLoading = true
        username = ""
        password = ""
        token = ""
        rememberPreference = false
        hasSavedAccount = false
        storageError = nil
        do {
            let saved = try await store.load(for: selectedGrid)
            guard !Task.isCancelled, grid == selectedGrid else { return }
            if let saved {
                username = saved.username
                password = saved.password
                rememberPreference = true
                hasSavedAccount = true
            }
        } catch {
            guard !Task.isCancelled, grid == selectedGrid else { return }
            storageError = error.localizedDescription
        }
        if grid == selectedGrid { isLoading = false }
    }

    func prepareCredentials(start: String, agreeToTerms: Bool) async -> LoginCredentials? {
        guard !isLoading, !isSaving else { return nil }
        let credentials = LoginCredentials(username: username, password: password, token: token,
                                           start: start, grid: grid, agreeToTerms: agreeToTerms)
        guard credentials.avatarName != nil, !password.isEmpty else { return nil }
        isSaving = true
        storageError = nil
        defer { isSaving = false }
        do {
            if rememberPreference {
                try await store.save(SavedLoginAccount(username: username, password: password), for: grid)
                hasSavedAccount = true
            }
            // MFA codes and session tokens are never included in the saved account.
            return credentials
        } catch {
            storageError = error.localizedDescription
            return nil
        }
    }

    func forgetAccount(for selectedGrid: Grid, clearForm: Bool = false) async {
        let revision = UUID()
        credentialRevision = revision
        if grid == selectedGrid { rememberPreference = false }
        await removeAccount(for: selectedGrid, revision: revision, clearForm: clearForm)
    }

    private func removeAccount(for selectedGrid: Grid, revision: UUID, clearForm: Bool) async {
        do {
            try await store.remove(for: selectedGrid)
            guard grid == selectedGrid else { return }
            hasSavedAccount = false
            guard credentialRevision == revision else { return }
            storageError = nil
            if clearForm {
                username = ""
                clearSensitiveFields()
            }
        } catch {
            guard grid == selectedGrid, credentialRevision == revision else { return }
            rememberPreference = true
            storageError = error.localizedDescription
        }
    }

    func clearSensitiveFields() {
        password = ""
        token = ""
    }
}
