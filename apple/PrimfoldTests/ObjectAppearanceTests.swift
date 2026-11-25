import Foundation
import Testing

struct ObjectAppearanceTests {
    @Test func textureEntryKeepsPerFaceExceptionsAndInvertedColors() throws {
        var writer = PacketWriter()
        let baseTexture = UUID()
        let alternateTexture = UUID()
        writer.uuid(baseTexture)
        writer.u8(0x02) // Texture override for face 1.
        writer.uuid(alternateTexture)
        writer.u8(0)
        writer.bytes += [0, 255, 255, 0] // Red, fully opaque (inverted RGBA).
        writer.u8(0)
        writer.float(1); writer.u8(0) // Repeat S.
        writer.float(2); writer.u8(0) // Repeat T.
        for _ in 0..<3 { writer.u16(0); writer.u8(0) } // Offsets and rotation.
        for _ in 0..<3 { writer.u8(0); writer.u8(0) } // Bump, media, glow.
        let faces = try TextureEntryDecoder.decode(writer.bytes)
        #expect(faces.count == 64)
        #expect(faces[0].textureID == baseTexture)
        #expect(faces[1].textureID == alternateTexture)
        #expect(faces[2].textureID == baseTexture)
        #expect(faces[0].color == SIMD4<Float>(1, 0, 0, 1))
        #expect(faces[0].repeats == SIMD2<Float>(1, 2))
        for count in 1..<writer.bytes.count {
            #expect(throws: (any Error).self) {
                try TextureEntryDecoder.decode(Array(writer.bytes.prefix(count)))
            }
        }
    }

    @Test func unmodifiedPrimitivesAreRecognizedWithoutMisclassifyingMesh() {
        var shape = Array(repeating: UInt8(0), count: 23)
        shape[0] = 0x10
        shape[1] = 0x01
        shape[6] = 100
        shape[7] = 100
        let box = ObjectAppearance(shape: shape, textureEntry: [], extraParameters: [:])
        #expect(box.basicPrimitive == .box)
        shape[1] = 0x00
        #expect(ObjectAppearance(shape: shape, textureEntry: [], extraParameters: [:]).basicPrimitive == .cylinder)
        #expect(ObjectAppearance(shape: shape, textureEntry: [], extraParameters: [0x30: [5]]).basicPrimitive == nil)
        shape[10] = 20 // Twist.
        #expect(ObjectAppearance(shape: shape, textureEntry: [], extraParameters: [:]).basicPrimitive == nil)
    }

    @Test func sculptAndMaterialParametersSurviveParsing() throws {
        var writer = PacketWriter()
        writer.u8(2)
        writer.u16(0x30); writer.u32(17)
        writer.bytes += Array(repeating: 7, count: 17)
        writer.u16(0x80); writer.u32(3)
        writer.bytes += [1, 2, 3]
        let parameters = try ObjectAppearance.extraParameters(writer.bytes)
        #expect(parameters[0x30] == Array(repeating: 7, count: 17))
        #expect(parameters[0x80] == [1, 2, 3])
        #expect(throws: (any Error).self) {
            try ObjectAppearance.extraParameters(Array(writer.bytes.dropLast()))
        }
    }
}
