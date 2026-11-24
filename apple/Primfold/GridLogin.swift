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
    // Never persist passwords, password hashes, MFA codes, or session credentials.
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
