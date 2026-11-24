import Foundation
import simd

/// LLUDP uses a network-order packet header and little-endian message fields.
/// Message numbers and layouts follow scripts/messages/message_template.msg.
struct PacketReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= bytes.count, count <= bytes.count - offset else {
            throw WorldError.malformedPacket
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    mutating func networkU32() throws -> UInt32 {
        try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func float() throws -> Float { Float(bitPattern: try u32()) }
    mutating func vector() throws -> SIMD3<Float> { try SIMD3(float(), float(), float()) }
    mutating func variable(_ width: Int) throws -> [UInt8] {
        let count = width == 1 ? Int(try u8()) : Int(try u16())
        return try take(count)
    }
    mutating func string(_ width: Int) throws -> String {
        String(decoding: try variable(width).prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

struct PacketWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) {
        bytes += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    mutating func u32(_ value: UInt32) {
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    mutating func networkU32(_ value: UInt32) {
        bytes += (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    mutating func float(_ value: Float) { u32(value.bitPattern) }
    mutating func vector(_ value: SIMD3<Float>) { float(value.x); float(value.y); float(value.z) }
    mutating func uuid(_ value: UUID) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
    }
    mutating func string(_ value: String) {
        let data = Array(value.utf8) + [0]
        u16(UInt16(data.count))
        bytes += data
    }
}

struct SimulatorPacket {
    let sequence: UInt32
    let reliable: Bool
    let message: UInt32
    let payload: [UInt8]
    let acknowledgements: [UInt32]

    init(data: Data) throws {
        var raw = Array(data)
        guard raw.count >= 7 else { throw WorldError.malformedPacket }
        let flags = raw[0]
        var header = PacketReader(Array(raw[1..<5]))
        sequence = try header.networkU32()
        reliable = flags & 0x40 != 0

        var acks: [UInt32] = []
        if flags & 0x10 != 0 {
            let count = Int(raw[raw.count - 1])
            let size = 1 + count * 4
            guard raw.count - size >= 7 else { throw WorldError.malformedPacket }
            var reader = PacketReader(Array(raw[(raw.count - size)..<(raw.count - 1)]))
            for _ in 0..<count { acks.append(try reader.networkU32()) }
            raw.removeLast(size)
        }
        acknowledgements = acks

        // Zerocoding starts after the first six header bytes; appended ACKs are unencoded.
        if flags & 0x80 != 0 {
            var expanded = Array(raw.prefix(6))
            var index = 6
            while index < raw.count {
                let byte = raw[index]
                index += 1
                if byte == 0 {
                    guard index < raw.count, raw[index] > 0 else { throw WorldError.malformedPacket }
                    expanded.append(contentsOf: repeatElement(0, count: Int(raw[index])))
                    index += 1
                } else {
                    expanded.append(byte)
                }
                guard expanded.count <= 65_536 else { throw WorldError.malformedPacket }
            }
            raw = expanded
        }

        var reader = PacketReader(raw)
        try reader.skip(6 + Int(raw[5]))
        let first = try reader.u8()
        if first != 0xff {
            message = UInt32(first)
        } else {
            let second = try reader.u8()
            if second != 0xff {
                message = 0xff00 | UInt32(second)
            } else {
                let high = try reader.u8()
                let low = try reader.u8()
                message = 0xffff0000 | UInt32(high) << 8 | UInt32(low)
            }
        }
        payload = try reader.take(raw.count - reader.offset)
    }

    static func encode(message: UInt32, payload: [UInt8], sequence: UInt32, reliable: Bool) -> Data {
        var writer = PacketWriter()
        writer.u8(reliable ? 0x40 : 0)
        writer.networkU32(sequence)
        writer.u8(0)
        if message < 0xff {
            writer.u8(UInt8(message))
        } else if message < 0xffff {
            writer.u8(0xff)
            writer.u8(UInt8(truncatingIfNeeded: message))
        } else {
            writer.u8(0xff); writer.u8(0xff)
            writer.u8(UInt8(truncatingIfNeeded: message >> 8))
            writer.u8(UInt8(truncatingIfNeeded: message))
        }
        writer.bytes += payload
        return Data(writer.bytes)
    }
}

struct WorldObject: Equatable {
    let id: UInt32
    var position: SIMD3<Float>
    var rotation: SIMD4<Float>
    let scale: SIMD3<Float>
    let parentID: UInt32
    let isAvatar: Bool
}

enum ObjectDecoder {
    static func full(_ reader: inout PacketReader) throws -> WorldObject? {
        let id = try reader.u32()
        try reader.skip(1 + 16 + 4)
        let pcode = try reader.u8()
        try reader.skip(2)
        let scale = try reader.vector()
        let data = try reader.variable(1)
        let parent = try reader.u32()
        try reader.skip(4 + 23) // UpdateFlags and the packed path/profile parameters.
        _ = try reader.variable(2) // TextureEntry
        _ = try reader.variable(1) // TextureAnim
        _ = try reader.variable(2) // NameValue
        _ = try reader.variable(2) // Data
        _ = try reader.variable(1) // Text
        try reader.skip(4)
        for _ in 0..<3 { _ = try reader.variable(1) } // MediaURL, particles, extra parameters
        try reader.skip(16 + 16 + 4 + 1 + 4 + 1 + 12 + 12)

        var packed = PacketReader(data)
        let position: SIMD3<Float>
        let rotation: SIMD4<Float>
        switch data.count {
        case 32, 48, 64, 80:
            if data.count == 48 || data.count == 80 { try packed.skip(16) }
            position = try SIMD3(
                unpack(packed.u16(), min: -128, max: 384),
                unpack(packed.u16(), min: -128, max: 384),
                unpack(packed.u16(), min: -256, max: 4096))
            try packed.skip(12)
            rotation = try SIMD4(
                unpack(packed.u16(), min: -1, max: 1),
                unpack(packed.u16(), min: -1, max: 1),
                unpack(packed.u16(), min: -1, max: 1),
                unpack(packed.u16(), min: -1, max: 1))
        case 60, 76, 124, 140:
            if data.count == 76 || data.count == 140 { try packed.skip(16) }
            position = try packed.vector()
            try packed.skip(24)
            rotation = quaternion(try packed.vector())
        default: return nil
        }
        return validated(id: id, position: position, rotation: rotation,
                         scale: scale, parent: parent, pcode: pcode)
    }

    static func compressed(_ data: [UInt8]) throws -> WorldObject? {
        var reader = PacketReader(data)
        try reader.skip(16)
        let id = try reader.u32()
        let pcode = try reader.u8()
        try reader.skip(1 + 4 + 1 + 1)
        let scale = try reader.vector()
        let position = try reader.vector()
        let rotation = quaternion(try reader.vector())
        let flags = try reader.u32()
        try reader.skip(16)
        if flags & 0x80 != 0 { try reader.skip(12) }
        let parent: UInt32 = flags & 0x20 != 0 ? try reader.u32() : 0
        return validated(id: id, position: position, rotation: rotation,
                         scale: scale, parent: parent, pcode: pcode)
    }

    static func terse(_ data: [UInt8]) throws -> (UInt32, SIMD3<Float>, SIMD4<Float>) {
        var reader = PacketReader(data)
        let id = try reader.u32()
        try reader.skip(1)
        let avatar = try reader.u8() != 0
        if avatar { try reader.skip(16) }
        let position = try reader.vector()
        try reader.skip(12) // quantized velocity and acceleration
        let rotation = try SIMD4(
            unpack(reader.u16(), min: -1, max: 1),
            unpack(reader.u16(), min: -1, max: 1),
            unpack(reader.u16(), min: -1, max: 1),
            unpack(reader.u16(), min: -1, max: 1))
        return (id, position, rotation)
    }

    private static func unpack(_ value: UInt16, min: Float, max: Float) -> Float {
        min + Float(value) / 65_535 * (max - min)
    }

    private static func quaternion(_ xyz: SIMD3<Float>) -> SIMD4<Float> {
        SIMD4(xyz.x, xyz.y, xyz.z, sqrt(max(0, 1 - simd_length_squared(xyz))))
    }

    private static func validated(id: UInt32, position: SIMD3<Float>, rotation: SIMD4<Float>,
                                  scale: SIMD3<Float>, parent: UInt32, pcode: UInt8) -> WorldObject? {
        guard [position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, rotation.w,
               scale.x, scale.y, scale.z].allSatisfy(\.isFinite),
              simd_length(position) < 100_000, scale.min() > 0, scale.max() < 4096,
              simd_length_squared(rotation) > 0.1 else { return nil }
        return WorldObject(id: id, position: position, rotation: rotation,
                           scale: scale, parentID: parent, isAvatar: pcode == 47)
    }
}
