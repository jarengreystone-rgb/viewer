import Foundation
import Testing
import simd

struct LoginProtocolTests {
    @Test(arguments: [
        ("Example", "Example", "Resident"),
        ("Example.Resident", "Example", "Resident"),
        ("  Example Legacy  ", "Example", "Legacy")
    ])
    func accountNames(input: String, first: String, last: String) {
        let credentials = LoginCredentials(username: input, password: "unused", token: "",
                                           start: "last", grid: .secondLife, agreeToTerms: false)
        #expect(credentials.avatarName?.first == first)
        #expect(credentials.avatarName?.last == last)
    }

    @Test(arguments: ["", "   ", "one two three", "name@example.com"])
    func invalidNames(input: String) {
        let credentials = LoginCredentials(username: input, password: "", token: "",
                                           start: "last", grid: .secondLife, agreeToTerms: false)
        #expect(credentials.avatarName == nil)
    }

    @Test func xmlEscaping() {
        #expect(RPCValue.string("<a&\"'>").xml == "<value><string>&lt;a&amp;&quot;&apos;&gt;</string></value>")
        #expect(RPCValue.boolean(false).xml == "<value><boolean>0</boolean></value>")
    }

    @Test func decodesLoginResponse() throws {
        let xml = """
        <?xml version="1.0"?>
        <methodResponse><params><param><value><struct>
        <member><name>login</name><value><boolean>1</boolean></value></member>
        <member><name>circuit_code</name><value><int>2147483649</int></value></member>
        <member><name>message</name><value><string>Hello &amp; welcome</string></value></member>
        <member><name>options</name><value><array><data>
        <value><struct><member><name>login-flags</name><value><string>yes</string></value></member></struct></value>
        </data></array></value></member>
        </struct></value></param></params></methodResponse>
        """
        let result = try RPCValue.response(Data(xml.utf8))
        #expect(result["login"]?.text == "true")
        #expect(result["circuit_code"]?.text == "2147483649")
        #expect(result["message"]?.text == "Hello & welcome")
    }

    @Test func xmlFaultIsAnError() {
        let xml = """
        <methodResponse><fault><value><struct>
        <member><name>faultString</name><value><string>Service unavailable</string></value></member>
        </struct></value></fault></methodResponse>
        """
        #expect(throws: (any Error).self) { try RPCValue.response(Data(xml.utf8)) }
    }

    @Test func rejectsDeepOrTruncatedXML() {
        let deep = String(repeating: "<value>", count: 65) + String(repeating: "</value>", count: 65)
        #expect(throws: (any Error).self) { try RPCValue.response(Data(deep.utf8)) }
        #expect(throws: (any Error).self) { try RPCValue.response(Data("<methodResponse>".utf8)) }
    }
}

struct SimulatorProtocolTests {
    @Test func circuitPacketMatchesWireFormat() throws {
        let packet = SimulatorPacket.encode(message: 0xffff0003, payload: [0x78, 0x56, 0x34, 0x12],
                                            sequence: 0x01020304, reliable: true)
        #expect(Array(packet) == [0x40, 1, 2, 3, 4, 0, 0xff, 0xff, 0, 3, 0x78, 0x56, 0x34, 0x12])
    }

    @Test func decodesZeroRunsAndAppendedAcks() throws {
        // Reliable + zerocoded + appended ACK. ACK sequence bytes are big-endian,
        // and must be removed before expanding zero runs in the message.
        let raw: [UInt8] = [
            0xd0, 0, 0, 0, 9, 0,
            0xff, 0xff, 0, 1, 0x94, 7, 0, 3, 8,
            0, 0, 0, 42, 1
        ]
        let packet = try SimulatorPacket(data: Data(raw))
        #expect(packet.message == 0xffff0094)
        #expect(packet.sequence == 9)
        #expect(packet.reliable)
        #expect(packet.payload == [7, 0, 0, 0, 8])
        #expect(packet.acknowledgements == [42])
    }

    @Test func decodesMediumAndFixedMessages() throws {
        let medium = try SimulatorPacket(data: Data([0, 0, 0, 0, 1, 0, 0xff, 3, 7]))
        #expect(medium.message == 0xff03)
        #expect(medium.payload == [7])
        let fixed = try SimulatorPacket(data: Data([0, 0, 0, 0, 1, 0, 0xff, 0xff, 0xff, 0xfb, 1, 9, 0, 0, 0]))
        #expect(fixed.message == 0xfffffffb)
        var reader = PacketReader(fixed.payload)
        #expect(try reader.u8() == 1)
        #expect(try reader.u32() == 9)
    }

    @Test(arguments: [
        [UInt8](),
        [0, 0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1, 0, 0xff],
        [0x80, 0, 0, 0, 1, 0, 0],
        [0x80, 0, 0, 0, 1, 0, 0, 0],
        [0x10, 0, 0, 0, 1, 0, 1, 99],
        [0, 0, 0, 0, 1, 240, 1]
    ])
    func malformedPacketsAreRejected(bytes: [UInt8]) {
        #expect(throws: (any Error).self) { try SimulatorPacket(data: Data(bytes)) }
    }

    @Test func rejectsZeroExpansionOverflow() {
        var bytes: [UInt8] = [0x80, 0, 0, 0, 1, 0]
        for _ in 0..<258 { bytes += [0, 255] }
        #expect(throws: (any Error).self) { try SimulatorPacket(data: Data(bytes)) }
    }

    @Test func readsUnalignedLittleEndianFields() throws {
        var reader = PacketReader([99, 0x78, 0x56, 0x34, 0x12, 0, 0, 0x80, 0x3f])
        try reader.skip(1)
        #expect(try reader.u32() == 0x12345678)
        #expect(try reader.float() == 1)
        #expect(throws: (any Error).self) { try reader.u8() }
    }

    @Test func decodesCompressedObjectWithParentAndAngularVelocity() throws {
        let data = compressedObject()
        let object = try #require(try ObjectDecoder.compressed(data))
        #expect(object.id == 42)
        #expect(object.position == SIMD3(128, 64, 30))
        #expect(object.scale == SIMD3(2, 3, 4))
        #expect(object.rotation == SIMD4(0, 0, 0, 1))
        #expect(object.parentID == 7)
        #expect(object.appearance?.basicPrimitive == .cylinder)
        #expect(object.appearance?.shape[6] == 100)
        #expect(!object.isAvatar)
        for count in 0..<data.count {
            #expect(throws: (any Error).self) {
                try ObjectDecoder.compressed(Array(data.prefix(count)))
            }
        }
    }

    @Test func rejectsNonFiniteObjectPosition() throws {
        let result = try ObjectDecoder.compressed(compressedObject(position: [.nan, 64, 30]))
        #expect(result == nil)
    }

    @Test func decodesAvatarTerseUpdate() throws {
        var writer = PacketWriter()
        writer.u32(73)
        writer.u8(0) // state
        writer.u8(1) // avatar
        writer.bytes += Array(repeating: 0, count: 16) // collision plane
        writer.vector(SIMD3(121, 122, 40))
        writer.bytes += Array(repeating: 0, count: 12)
        for value: UInt16 in [32768, 32768, 32768, 65535] { writer.u16(value) }
        writer.bytes += Array(repeating: 0, count: 6)
        let (id, position, rotation) = try ObjectDecoder.terse(writer.bytes)
        #expect(id == 73)
        #expect(position == SIMD3(121, 122, 40))
        #expect(abs(rotation.x) < 0.0001)
        #expect(rotation.w == 1)
    }

    @Test func decodesFullObjectAndConsumesEntireBlock() throws {
        var writer = PacketWriter()
        writer.u32(23)
        writer.u8(0)
        writer.bytes += Array(repeating: 0, count: 16)
        writer.u32(0)
        writer.u8(47)
        writer.u8(0); writer.u8(0)
        writer.vector(SIMD3(1, 1, 2))
        // Full-precision object data: position, velocity, acceleration,
        // packed quaternion XYZ and angular velocity.
        writer.u8(60)
        writer.vector(SIMD3(100, 101, 30))
        writer.bytes += Array(repeating: 0, count: 48)
        writer.u32(0)
        writer.u32(0)
        writer.bytes += Array(repeating: 0, count: 23)
        writer.u16(0); writer.u8(0); writer.u16(0); writer.u16(0); writer.u8(0)
        writer.bytes += Array(repeating: 0, count: 4)
        writer.u8(0); writer.u8(0); writer.u8(0)
        writer.bytes += Array(repeating: 0, count: 66)
        var reader = PacketReader(writer.bytes)
        let object = try #require(try ObjectDecoder.full(&reader))
        #expect(object.id == 23)
        #expect(object.isAvatar)
        #expect(object.position == SIMD3(100, 101, 30))
        #expect(reader.offset == writer.bytes.count)
    }

    private func compressedObject(position: SIMD3<Float> = [128, 64, 30]) -> [UInt8] {
        var writer = PacketWriter()
        writer.bytes += Array(repeating: 0, count: 16) // full UUID
        writer.u32(42)
        writer.u8(9) // primitive
        writer.u8(0) // state
        writer.u32(0) // CRC
        writer.u8(0); writer.u8(0)
        writer.vector([2, 3, 4])
        writer.vector(position)
        writer.vector(.zero)
        writer.u32(0xa0) // angular velocity and parent present
        writer.bytes += Array(repeating: 0, count: 16) // owner
        writer.vector(.zero)
        writer.u32(7)
        writer.u8(0) // Extra parameter count.
        var shape = Array(repeating: UInt8(0), count: 23)
        shape[0] = 0x10
        shape[6] = 100
        shape[7] = 100
        writer.bytes += [shape[0]] + Array(shape[2..<17]) // Path.
        writer.bytes += [shape[1]] + Array(shape[17..<23]) // Profile.
        writer.u32(0) // Texture entry length.
        return writer.bytes
    }
}
