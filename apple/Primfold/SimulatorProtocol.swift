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
    var appearance: ObjectAppearance? = nil
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
        try reader.skip(4) // UpdateFlags
        let shape = try reader.take(23)
        let textures = try reader.variable(2)
        _ = try reader.variable(1) // TextureAnim
        _ = try reader.variable(2) // NameValue
        _ = try reader.variable(2) // Data
        _ = try reader.variable(1) // Text
        try reader.skip(4)
        _ = try reader.variable(1) // MediaURL
        _ = try reader.variable(1) // Particle system
        let extras = try ObjectAppearance.extraParameters(reader.variable(1))
        let appearance = ObjectAppearance(shape: shape, textureEntry: textures, extraParameters: extras)
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
                         scale: scale, parent: parent, pcode: pcode, appearance: appearance)
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
        if flags & 0x02 != 0 {
            try reader.skip(1)
        } else if flags & 0x01 != 0 {
            try reader.skip(Int(reader.u32()))
        }
        if flags & 0x04 != 0 { _ = try reader.terminatedString(); try reader.skip(4) }
        if flags & 0x200 != 0 { _ = try reader.terminatedString() }
        if flags & 0x08 != 0 { try reader.skip(86) } // Legacy particle system.
        let extras = try ObjectAppearance.readExtraParameters(&reader)
        if flags & 0x10 != 0 { try reader.skip(25) }
        if flags & 0x100 != 0 { _ = try reader.terminatedString() }
        // Compressed updates put ProfileCurve after all 16 path bytes.
        let path = try reader.take(16)
        let profile = try reader.take(7)
        let shape = [path[0], profile[0]] + Array(path.dropFirst()) + Array(profile.dropFirst())
        let textures = try reader.take(Int(reader.u32()))
        let appearance = ObjectAppearance(shape: shape, textureEntry: textures, extraParameters: extras)
        return validated(id: id, position: position, rotation: rotation,
                         scale: scale, parent: parent, pcode: pcode, appearance: appearance)
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
                                  scale: SIMD3<Float>, parent: UInt32, pcode: UInt8,
                                  appearance: ObjectAppearance? = nil) -> WorldObject? {
        guard [position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, rotation.w,
               scale.x, scale.y, scale.z].allSatisfy(\.isFinite),
              simd_length(position) < 100_000, scale.min() > 0, scale.max() < 4096,
              simd_length_squared(rotation) > 0.1 else { return nil }
        return WorldObject(id: id, position: position, rotation: rotation,
                           scale: scale, parentID: parent, isAvatar: pcode == 47, appearance: appearance)
    }
}


// MARK: - Object appearance

/// The simulator's original shape and appearance data is retained for asset rendering.
struct ObjectAppearance: Equatable {
    enum BasicPrimitive {
        case box, cylinder
    }

    let shape: [UInt8]
    let textureEntry: [UInt8]
    let extraParameters: [UInt16: [UInt8]]

    var faces: [FaceAppearance] {
        (try? TextureEntryDecoder.decode(textureEntry)) ?? []
    }

    /// Only recognize undeformed, uncut linear primitives. Meshes/sculpts need their assets.
    var basicPrimitive: BasicPrimitive? {
        guard shape.count == 23, extraParameters[0x30] == nil,
              shape[0] == 0x10, shape[6] == 100, shape[7] == 100,
              shape[2..<6].allSatisfy({ $0 == 0 }),
              shape[8..<23].allSatisfy({ $0 == 0 }) else { return nil }
        switch shape[1] {
        case 0x01: return .box
        case 0x00: return .cylinder
        default: return nil
        }
    }

    static func extraParameters(_ data: [UInt8]) throws -> [UInt16: [UInt8]] {
        guard !data.isEmpty else { return [:] }
        var reader = PacketReader(data)
        return try readExtraParameters(&reader)
    }

    static func readExtraParameters(_ reader: inout PacketReader) throws -> [UInt16: [UInt8]] {
        let count = try reader.u8()
        var result: [UInt16: [UInt8]] = [:]
        for _ in 0..<count {
            let type = try reader.u16()
            let size = try reader.u32()
            result[type] = try reader.take(Int(size))
        }
        return result
    }
}

struct FaceAppearance: Equatable {
    var textureID: UUID
    var color: SIMD4<Float>
    var repeats: SIMD2<Float>
    var offsets: SIMD2<Float>
    var rotation: Float
    var bumpAndShininess: UInt8
    var mediaAndTexgen: UInt8
    var glow: Float
    var materialID: UUID?

    var isFullbright: Bool { bumpAndShininess & 0x20 != 0 }
}

enum TextureEntryDecoder {
    /// LL texture entries contain a default followed by face-mask exceptions for each field.
    /// Preserve 64 faces so mesh material indices are not collapsed to one material.
    static func decode(_ data: [UInt8]) throws -> [FaceAppearance] {
        guard !data.isEmpty else { return [] }
        var reader = PacketReader(data)
        let textures = try readField(&reader, width: 16)
        let colors = try readField(&reader, width: 4)
        let repeatS = try readField(&reader, width: 4)
        let repeatT = try readField(&reader, width: 4)
        let offsetS = try readField(&reader, width: 2)
        let offsetT = try readField(&reader, width: 2)
        let rotation = try readField(&reader, width: 2)
        let bump = try readField(&reader, width: 1)
        let media = try readField(&reader, width: 1)
        let glow = try readField(&reader, width: 1)
        let materials = reader.offset < data.count ? try readField(&reader, width: 16, allowEnd: true) : nil
        return try (0..<64).map { face in
            var texture = PacketReader(textures[face])
            var s = PacketReader(repeatS[face])
            var t = PacketReader(repeatT[face])
            var os = PacketReader(offsetS[face])
            var ot = PacketReader(offsetT[face])
            var angle = PacketReader(rotation[face])
            let color = colors[face].map { Float(255 - $0) / 255 }
            let material = try materials.map { values -> UUID in
                var bytes = PacketReader(values[face])
                return try bytes.uuid()
            }
            let result = try FaceAppearance(
                textureID: texture.uuid(), color: SIMD4(color[0], color[1], color[2], color[3]),
                repeats: SIMD2(s.float(), t.float()),
                offsets: SIMD2(Float(Int16(bitPattern: os.u16())) / 32767,
                               Float(Int16(bitPattern: ot.u16())) / 32767),
                rotation: Float(Int16(bitPattern: angle.u16())) / 32768 * 2 * .pi,
                bumpAndShininess: bump[face][0], mediaAndTexgen: media[face][0],
                glow: Float(glow[face][0]) / 255, materialID: material)
            guard result.repeats.x.isFinite, result.repeats.y.isFinite else { throw WorldError.malformedPacket }
            return result
        }
    }

    private static func readField(_ reader: inout PacketReader, width: Int,
                                  allowEnd: Bool = false) throws -> [[UInt8]] {
        let initial = try reader.take(width)
        var faces = Array(repeating: initial, count: 64)
        while reader.offset < reader.bytes.count {
            var mask: UInt64 = 0
            var more = true
            var groups = 0
            while more {
                let byte = try reader.u8()
                guard groups < 10, mask <= UInt64.max >> 7 else { throw WorldError.malformedPacket }
                mask = mask << 7 | UInt64(byte & 0x7f)
                more = byte & 0x80 != 0
                groups += 1
            }
            if mask == 0 { return faces }
            let value = try reader.take(width)
            for face in 0..<64 where mask & (UInt64(1) << face) != 0 { faces[face] = value }
        }
        guard allowEnd else { throw WorldError.malformedPacket }
        return faces
    }
}

extension PacketReader {
    mutating func uuid() throws -> UUID {
        let b = try take(16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    mutating func terminatedString() throws -> [UInt8] {
        let start = offset
        while try u8() != 0 {}
        return Array(bytes[start..<(offset - 1)])
    }
}
