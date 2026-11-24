import Foundation
import Network
import Observation
import simd

enum ConnectionPhase: Equatable {
    case offline, authenticating, connecting, online, disconnecting

    var title: LocalizedStringResource {
        switch self {
        case .offline: "Offline"
        case .authenticating: "Signing in…"
        case .connecting: "Connecting to region…"
        case .online: "Connected"
        case .disconnecting: "Signing out…"
        }
    }

    var isBusy: Bool { self == .authenticating || self == .connecting || self == .disconnecting }
}

struct NearbyMessage: Identifiable, Equatable {
    let id = UUID()
    let sender: String
    let text: String
}

@MainActor
@Observable
final class WorldSession {
    private(set) var phase = ConnectionPhase.offline
    private(set) var errorMessage: String?
    private(set) var regionName = ""
    private(set) var accountName = ""
    private(set) var position = SIMD3<Float>(128, 128, 25)
    private(set) var heading: Float = 0
    private(set) var messages: [NearbyMessage] = []
    private(set) var objectCount = 0
    private(set) var worldRevision = 0
    private(set) var welcomeMessage = ""

    @ObservationIgnored private(set) var objects: [UInt32: WorldObject] = [:]
    @ObservationIgnored private let loginService: any GridAuthenticating
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var session: GridSession?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sequence: UInt32 = 0
    @ObservationIgnored private var circuitSequence: UInt32?
    @ObservationIgnored private var movementRequested = false
    @ObservationIgnored private var ownLocalID: UInt32?
    @ObservationIgnored private var pending: [UInt32: PendingPacket] = [:]
    @ObservationIgnored private var received = Set<UInt32>()
    @ObservationIgnored private var receivedOrder: [UInt32] = []
    @ObservationIgnored private var lastReceived = Date()
    @ObservationIgnored private var connectedAt = Date()
    @ObservationIgnored private var lastAgentUpdate = Date.distantPast
    @ObservationIgnored private var movementUntil = Date.distantPast
    @ObservationIgnored private var movementFlags: UInt32 = 0
    @ObservationIgnored private var dirtyWorld = false
    @ObservationIgnored private var generation = UUID()

    private struct PendingPacket {
        var data: Data
        var lastSent: Date
        var retries: Int
    }

    init(loginService: any GridAuthenticating = GridLogin()) {
        self.loginService = loginService
    }

    func signIn(_ credentials: LoginCredentials) {
        guard phase == .offline else { return }
        clearWorld()
        errorMessage = nil
        phase = .authenticating
        let attempt = UUID()
        generation = attempt
        var deviceID = UserDefaults.standard.string(forKey: "loginDeviceID")
        if deviceID == nil {
            deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(deviceID, forKey: "loginDeviceID")
        }
        let identifier = deviceID ?? ""
        let service = loginService
        loginTask = Task { [weak self] in
            do {
                let result = try await service.login(credentials, deviceID: identifier)
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                self.open(result)
            } catch {
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        guard phase == .authenticating || phase == .connecting else { return }
        if session != nil {
            Task { await signOut() }
        } else {
            close()
        }
    }

    private func open(_ session: GridSession) {
        self.session = session
        accountName = session.displayName
        welcomeMessage = session.message
        phase = .connecting
        connectedAt = Date()
        lastReceived = Date()
        guard let port = NWEndpoint.Port(rawValue: session.port) else {
            fail(String(localized: "Invalid simulator port."))
            return
        }
        let attempt = generation
        let connection = NWConnection(host: NWEndpoint.Host(session.host), port: port, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                switch state {
                case .ready:
                    self.beginCircuit()
                case .failed:
                    self.fail(String(localized: "The simulator connection failed. Check your network and try again."))
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(connection, attempt: attempt)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func beginCircuit() {
        guard let session else { return }
        var writer = PacketWriter()
        writer.u32(session.circuitCode)
        writer.uuid(session.sessionID)
        writer.uuid(session.agentID)
        circuitSequence = send(0xffff0003, writer.bytes, reliable: true)
    }

    private func completeMovement() {
        guard !movementRequested, let session else { return }
        movementRequested = true
        var writer = agentData()
        writer.u32(session.circuitCode)
        send(0xffff00f9, writer.bytes, reliable: true)

        var throttle = agentData()
        throttle.u32(session.circuitCode)
        throttle.u32(1)
        throttle.u8(28)
        // Resend, land, wind, cloud, task, texture and asset bits per second.
        for rate: Float in [100_000, 100_000, 0, 0, 600_000, 0, 0] { throttle.float(rate) }
        send(0xffff0051, throttle.bytes, reliable: true)
    }

    private func receive(_ connection: NWConnection, attempt: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, self.connection === connection else { return }
                if error != nil {
                    self.fail(String(localized: "The simulator connection was interrupted."))
                    return
                }
                if let data { self.handle(data) }
                if self.connection === connection { self.receive(connection, attempt: attempt) }
            }
        }
    }

    private func handle(_ data: Data) {
        do {
            let packet = try SimulatorPacket(data: data)
            lastReceived = Date()
            for ack in packet.acknowledgements { acknowledge(ack) }
            if packet.reliable {
                var ack = PacketWriter()
                ack.u8(1)
                ack.u32(packet.sequence)
                send(0xfffffffb, ack.bytes)
                guard received.insert(packet.sequence).inserted else { return }
                receivedOrder.append(packet.sequence)
                if receivedOrder.count > 4096 { received.remove(receivedOrder.removeFirst()) }
            }
            var reader = PacketReader(packet.payload)
            switch packet.message {
            case 0xfffffffb:
                let count = try reader.u8()
                for _ in 0..<count { acknowledge(try reader.u32()) }
            case 1:
                send(2, [try reader.u8()])
            case 0xffff0094: // RegionHandshake
                try reader.skip(5)
                regionName = try reader.string(1)
                var reply = agentData()
                reply.u32(0) // No object cache or mesh capability claims.
                send(0xffff0095, reply.bytes, reliable: true)
                completeMovement()
            case 0xffff00fa: // AgentMovementComplete
                guard try reader.take(32) == agentData().bytes else { return }
                let location = try reader.vector()
                guard location.x.isFinite, location.y.isFinite, location.z.isFinite else { return }
                position = location
                let look = try reader.vector()
                if look.x.isFinite, look.y.isFinite { heading = atan2(look.y, look.x) }
                phase = .online
                sendAgentUpdate()
            case 12, 13, 14, 15:
                try readObjects(packet.message, reader: &reader)
            case 16:
                let count = try reader.u8()
                for _ in 0..<count { objects.removeValue(forKey: try reader.u32()) }
                dirtyWorld = true
            case 0xffff008b: // ChatFromSimulator
                let name = try reader.string(1)
                try reader.skip(16 + 16 + 1 + 1)
                let audible = try reader.u8()
                try reader.skip(12)
                let text = try reader.string(2)
                if audible == 1, !text.isEmpty {
                    messages.append(NearbyMessage(sender: name, text: text))
                    if messages.count > 200 { messages.removeFirst(messages.count - 200) }
                }
            case 0xffff00a3: // KickUser
                try reader.skip(6)
                guard try reader.take(32) == agentData().bytes else { return }
                fail(try reader.string(2))
            case 0xffff00fd: // LogoutReply
                guard try reader.take(32) == agentData().bytes else { return }
                close()
            default: break
            }
        } catch {
            // Drop malformed datagrams; a peer cannot cause an out-of-bounds read.
        }
    }

    private func acknowledge(_ id: UInt32) {
        pending.removeValue(forKey: id)
        if id == circuitSequence { completeMovement() }
    }

    private func readObjects(_ type: UInt32, reader: inout PacketReader) throws {
        try reader.skip(10)
        let count = try reader.u8()
        var missing: [UInt32] = []
        var ownUUID = PacketWriter()
        if let session { ownUUID.uuid(session.agentID) }
        for _ in 0..<count {
            switch type {
            case 12:
                let start = reader.offset
                if let object = try ObjectDecoder.full(&reader) {
                    if Array(reader.bytes[(start + 5)..<(start + 21)]) == ownUUID.bytes {
                        ownLocalID = object.id
                    }
                    store(object)
                }
            case 13:
                try reader.skip(4)
                let data = try reader.variable(2)
                if let object = try ObjectDecoder.compressed(data) {
                    if Array(data.prefix(16)) == ownUUID.bytes { ownLocalID = object.id }
                    store(object)
                }
            case 14:
                let id = try reader.u32()
                try reader.skip(8)
                // This client has no disk object cache, so request every cached update.
                missing.append(id)
            case 15:
                let (id, location, rotation) = try ObjectDecoder.terse(reader.variable(1))
                _ = try reader.variable(2)
                guard location.x.isFinite, location.y.isFinite, location.z.isFinite,
                      rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite, rotation.w.isFinite,
                      simd_length_squared(rotation) > 0.1, simd_length(location) < 100_000 else { continue }
                if var object = objects[id] {
                    object.position = location
                    object.rotation = rotation
                    store(object)
                }
            default: break
            }
        }
        if !missing.isEmpty {
            var request = agentData()
            request.u8(UInt8(missing.count))
            for id in missing { request.u8(0); request.u32(id) }
            send(0xff03, request.bytes, reliable: true)
        }
    }

    private func store(_ object: WorldObject) {
        if object.id == ownLocalID { position = object.position }
        guard objects.count < 10_000 || objects[object.id] != nil else { return }
        objects[object.id] = object
        dirtyWorld = true
    }

    private func tick() {
        let now = Date()
        if phase == .connecting, now.timeIntervalSince(connectedAt) > 30 {
            fail(String(localized: "The region did not finish connecting. Please try again."))
            return
        }
        if phase == .online, now.timeIntervalSince(lastReceived) > 45 {
            fail(String(localized: "The region stopped responding. Please sign in again."))
            return
        }
        for (id, var packet) in pending where now.timeIntervalSince(packet.lastSent) > 1.5 {
            if packet.retries >= 5 {
                pending.removeValue(forKey: id)
                if phase == .connecting {
                    fail(String(localized: "The simulator did not acknowledge the connection."))
                    return
                }
                continue
            }
            packet.data[0] |= 0x20
            packet.lastSent = now
            packet.retries += 1
            pending[id] = packet
            transmit(packet.data)
        }
        if phase == .online, now.timeIntervalSince(lastAgentUpdate) >= 0.1 { sendAgentUpdate() }
        if dirtyWorld {
            dirtyWorld = false
            objectCount = objects.count
            worldRevision &+= 1
        }
    }

    func turn(_ radians: Float) {
        guard phase == .online else { return }
        heading = atan2(sin(heading + radians), cos(heading + radians))
        sendAgentUpdate()
    }

    /// A short server-controlled step avoids stuck movement after a lost touch or suspension.
    func step(forward: Bool) {
        guard phase == .online else { return }
        movementFlags = forward ? 1 : 2
        movementUntil = Date().addingTimeInterval(0.4)
        sendAgentUpdate()
    }

    private func sendAgentUpdate() {
        guard phase == .online else { return }
        var writer = agentData()
        let rotation = SIMD3<Float>(0, 0, sin(heading / 2))
        writer.vector(rotation)
        writer.vector(rotation)
        writer.u8(0)
        writer.vector(position + SIMD3(0, 0, 1.5))
        writer.vector(SIMD3(cos(heading), sin(heading), 0))
        writer.vector(SIMD3(-sin(heading), cos(heading), 0))
        writer.vector(SIMD3(0, 0, 1))
        writer.float(64)
        writer.u32(Date() < movementUntil ? movementFlags : 0)
        writer.u8(0)
        send(4, writer.bytes)
        lastAgentUpdate = Date()
    }

    func sendChat(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .online, !trimmed.isEmpty, trimmed.utf8.count <= 1023 else { return }
        var writer = agentData()
        writer.string(trimmed)
        writer.u8(1) // Normal chat.
        writer.u32(0)
        send(0xffff0050, writer.bytes, reliable: true)
    }

    func signOut() async {
        guard phase != .offline, phase != .disconnecting else { return }
        loginTask?.cancel()
        if session == nil { close(); return }
        phase = .disconnecting
        let attempt = generation
        send(0xffff00fc, agentData().bytes, reliable: true)
        // Give the server a chance to acknowledge logout before closing the socket.
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if generation != attempt || phase == .offline { return }
        }
        if generation == attempt { close() }
    }

    private func agentData() -> PacketWriter {
        var writer = PacketWriter()
        if let session {
            writer.uuid(session.agentID)
            writer.uuid(session.sessionID)
        }
        return writer
    }

    @discardableResult
    private func send(_ message: UInt32, _ payload: [UInt8], reliable: Bool = false) -> UInt32 {
        sequence &+= 1
        let data = SimulatorPacket.encode(message: message, payload: payload, sequence: sequence, reliable: reliable)
        if reliable { pending[sequence] = PendingPacket(data: data, lastSent: Date(), retries: 0) }
        transmit(data)
        return sequence
    }

    private func transmit(_ data: Data) {
        let attempt = generation
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                self.fail(String(localized: "Unable to send data to the simulator."))
            }
        })
    }

    private func fail(_ message: String) {
        // Best effort cleanup also covers an authenticated session whose handshake failed.
        if session != nil { send(0xffff00fc, agentData().bytes) }
        close()
        errorMessage = message
    }

    private func close() {
        generation = UUID()
        loginTask?.cancel()
        loginTask = nil
        ticker?.cancel()
        ticker = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        session = nil
        pending.removeAll()
        received.removeAll()
        receivedOrder.removeAll()
        circuitSequence = nil
        movementRequested = false
        ownLocalID = nil
        phase = .offline
        clearWorld()
    }

    private func clearWorld() {
        objects.removeAll()
        messages.removeAll()
        objectCount = 0
        worldRevision &+= 1
        dirtyWorld = false
        regionName = ""
        accountName = ""
        welcomeMessage = ""
        position = SIMD3(128, 128, 25)
        heading = 0
        movementUntil = .distantPast
    }
}
