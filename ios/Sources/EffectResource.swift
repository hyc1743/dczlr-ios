import Foundation

struct EffectResource {
    let id: ResourceId
    let bytes: Data

    // Original D3DX9 effect blobs must be converted before Metal upload.
    init(id: ResourceId, bytes: Data) throws {
        guard bytes.count >= 4 else { throw EffectResourceError.truncated }
        let magic = bytes.prefix(4).enumerated().reduce(UInt32(0)) { partial, item in
            partial | (UInt32(item.element) << UInt32(item.offset * 8))
        }
        guard magic != 0xFEFF0901 else {
            throw EffectResourceError.requiresConversion
        }
        self.id = id
        self.bytes = bytes
    }
}

struct ConvertedEffectMetadata: Codable {
    let id: String
    let sourceSha256: String
    let metalLibrary: String
    let techniqueCount: Int
    let passCount: Int
    let constantBindings: [ConstantBinding]
    let textureBindings: [TextureBinding]

    struct ConstantBinding: Codable {
        let name: String
        let buffer: Int
        let offset: Int
        let type: String
        enum CodingKeys: String, CodingKey { case name, buffer, offset, type }
    }
    struct TextureBinding: Codable {
        let name: String
        let index: Int
        let pixelFormat: String
        enum CodingKeys: String, CodingKey { case name, index; case pixelFormat = "pixel_format" }
    }
    enum CodingKeys: String, CodingKey {
        case id
        case sourceSha256 = "source_sha256"
        case metalLibrary = "metal_library"
        case techniqueCount = "technique_count"
        case passCount = "pass_count"
        case constantBindings = "constant_bindings"
        case textureBindings = "texture_bindings"
    }
}

struct ConvertedEffectManifest: Codable {
    let schema: Int
    let format: String
    let sourceArtifact: SourceArtifact
    let effects: [ConvertedEffectMetadata]

    struct SourceArtifact: Codable { let sha256: String }

    enum CodingKeys: String, CodingKey {
        case schema, format, effects
        case sourceArtifact = "source_artifact"
    }

    func validate() throws {
        guard schema == 1, format == "dczlr-ios-converted-effects-v1",
              sourceArtifact.sha256.count == 64, !effects.isEmpty else {
            throw EffectResourceError.invalidManifest
        }
    }
}

enum EffectResourceError: Error {
    case truncated
    case requiresConversion
    case unsupportedFormat
    case invalidManifest
}
