import Foundation
import Network
import Testing

@MainActor
struct WorldSessionTests {
    @Test func connectsOnlyAfterSimulatorConfirmationAndExchangesChat() async throws {
        let server = try SimulatorFixture()
        defer { server.stop() }
        try await eventually { server.port != nil }
        let port = try #require(server.port)
        let ticket = GridSession(agentID: UUID(), sessionID: UUID(), circuitCode: 1234,
                                 host: "127.0.0.1", port: port,
                                 displayName: "Fixture Resident", message: "")
        server.ticket = ticket
        // Drop the first circuit packet to exercise reliable retransmission.
        server.dropFirstCircuit = true
        let world = WorldSession(loginService: FixtureLogin(ticket: ticket))
        world.signIn(credentials)
        try await eventually { server.movementRequested }
        #expect(server.circuitAttempts >= 2)
        #expect(world.phase == .connecting)
        #expect(world.regionName == "Fixture Region")

        server.confirmMovement()
        try await eventually { world.phase == .online }
        #expect(world.position == SIMD3(121, 122, 30))
        server.sendDuplicateChat(audible: 255)
        try await Task.sleep(for: .milliseconds(100))
        #expect(world.messages.isEmpty)
        server.sendDuplicateChat()
        try await eventually { world.messages.count == 1 }
        #expect(world.messages.first?.text == "Hello from the simulator")
        // A reliable packet sent twice must produce one visible chat message.
        try await Task.sleep(for: .milliseconds(100))
        #expect(world.messages.count == 1)

        world.sendChat("Hello nearby")
        try await eventually { server.receivedChat == "Hello nearby" }
        #expect(server.chatChannel == 0)
        world.turn(.pi * 3)
        #expect(world.heading >= -.pi && world.heading <= .pi)
        world.step(forward: true)
        try await eventually { server.controlFlags == 1 }
        try await eventually { server.controlFlags == 0 }
        await world.signOut()
        #expect(server.receivedLogout)
        #expect(world.phase == .offline)
        #expect(world.messages.isEmpty)
        #expect(world.objects.isEmpty)
    }

    @Test func loginFailureReturnsToForm() async throws {
        let world = WorldSession(loginService: RejectedLogin())
        world.signIn(credentials)
        try await eventually { world.phase == .offline }
        #expect(world.errorMessage == "Fixture login declined")
        #expect(world.accountName.isEmpty)
    }

    @Test func cancelledLoginCannotReplaceNewSessionState() async throws {
        let world = WorldSession(loginService: SlowLogin())
        world.signIn(credentials)
        #expect(world.phase == .authenticating)
        world.cancelSignIn()
        #expect(world.phase == .offline)
        try await Task.sleep(for: .milliseconds(150))
        #expect(world.phase == .offline)
        #expect(world.errorMessage == nil)
    }

    @Test(arguments: [Int64(-1), 2_147_483_649, 4_294_967_295])
    func acceptsUnsignedCircuitCodesInSignedXMLRPCIntegers(code: Int64) throws {
        let fields: [String: RPCValue] = [
            "agent_id": .string(UUID().uuidString),
            "session_id": .string(UUID().uuidString),
            "circuit_code": .integer(code),
            "sim_ip": .string("127.0.0.1"),
            "sim_port": .integer(13000)
        ]
        let ticket = try GridSession(response: fields, displayName: "Fixture")
        #expect(ticket.circuitCode == UInt32(truncatingIfNeeded: code))
    }

    private var credentials: LoginCredentials {
        LoginCredentials(username: "Fixture", password: "unused", token: "",
                         start: "last", grid: .secondLife, agreeToTerms: true)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Simulator fixture did not reach the expected state")
    }
}

private struct FixtureLogin: GridAuthenticating {
    let ticket: GridSession
    func login(_ credentials: LoginCredentials, deviceID: String) async throws -> GridSession { ticket }
}

private struct RejectedLogin: GridAuthenticating {
    func login(_ credentials: LoginCredentials, deviceID: String) async throws -> GridSession {
        throw WorldError.message("Fixture login declined")
    }
}

private struct SlowLogin: GridAuthenticating {
    func login(_ credentials: LoginCredentials, deviceID: String) async throws -> GridSession {
        try await Task.sleep(for: .seconds(10))
        throw WorldError.message("This cancelled request must not update the form")
    }
}

/// A local UDP simulator fixture. No account credentials or external grid are used.
@MainActor
private final class SimulatorFixture {
    private let listener: NWListener
    private var peer: NWConnection?
    private var sequence: UInt32 = 100
    var port: UInt16?
    var ticket: GridSession?
    var dropFirstCircuit = false
    var circuitAttempts = 0
    var movementRequested = false
    var receivedChat: String?
    var chatChannel: UInt32?
    var receivedLogout = false
    var controlFlags: UInt32?

    init() throws {
        listener = try NWListener(using: .udp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peer = connection
                connection.start(queue: .main)
                self.receive(connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        peer?.cancel()
        listener.cancel()
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, error == nil else { return }
                if let data { self.handle(data) }
                self.receive(connection)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let packet = try? SimulatorPacket(data: data) else { return }
        if packet.message == 0xffff0003 {
            circuitAttempts += 1
            if dropFirstCircuit, circuitAttempts == 1 { return }
        }
        if packet.reliable {
            var ack = PacketWriter()
            ack.u8(1)
            ack.u32(packet.sequence)
            send(0xfffffffb, ack.bytes)
        }
        var reader = PacketReader(packet.payload)
        do {
            switch packet.message {
            case 0xffff0003:
                var handshake = PacketWriter()
                handshake.u32(0)
                handshake.u8(13)
                let name = Array("Fixture Region".utf8) + [0]
                handshake.u8(UInt8(name.count))
                handshake.bytes += name
                send(0xffff0094, handshake.bytes, reliable: true)
            case 0xffff00f9: movementRequested = true
            case 0xffff0050:
                try reader.skip(32)
                receivedChat = try reader.string(2)
                try reader.skip(1)
                chatChannel = try reader.u32()
            case 4:
                try reader.skip(32 + 12 + 12 + 1 + 12 * 4 + 4)
                controlFlags = try reader.u32()
            case 0xffff00fc:
                receivedLogout = true
                var reply = agentData()
                reply.u8(0)
                send(0xffff00fd, reply.bytes, reliable: true)
            default: break
            }
        } catch {
            Issue.record("Invalid packet received by simulator fixture")
        }
    }

    func confirmMovement() {
        var writer = agentData()
        writer.vector([121, 122, 30])
        writer.vector([1, 0, 0])
        writer.bytes += Array(repeating: 0, count: 12)
        writer.string("Fixture simulator")
        send(0xffff00fa, writer.bytes, reliable: true)
    }

    func sendDuplicateChat(audible: UInt8 = 1) {
        var writer = PacketWriter()
        let name = Array("Fixture Resident".utf8) + [0]
        writer.u8(UInt8(name.count))
        writer.bytes += name
        writer.bytes += Array(repeating: 0, count: 32)
        writer.u8(1); writer.u8(1); writer.u8(audible)
        writer.vector([121, 122, 30])
        writer.string("Hello from the simulator")
        sequence += 1
        let packet = SimulatorPacket.encode(message: 0xffff008b, payload: writer.bytes,
                                            sequence: sequence, reliable: true)
        peer?.send(content: packet, completion: .idempotent)
        peer?.send(content: packet, completion: .idempotent)
    }

    private func agentData() -> PacketWriter {
        var writer = PacketWriter()
        if let ticket {
            writer.uuid(ticket.agentID)
            writer.uuid(ticket.sessionID)
        }
        return writer
    }

    private func send(_ message: UInt32, _ payload: [UInt8], reliable: Bool = false) {
        sequence += 1
        let data = SimulatorPacket.encode(message: message, payload: payload,
                                          sequence: sequence, reliable: reliable)
        peer?.send(content: data, completion: .idempotent)
    }
}
