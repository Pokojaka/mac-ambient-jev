import Foundation

public enum CanonicalCAFFixtureError: Error, LocalizedError {
    case missingResource(String)
    case invalidExpectedSamples(Int)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): "CAF fixture resource is missing: \(name)"
        case .invalidExpectedSamples(let byteCount): "Expected-sample file has \(byteCount) bytes, not a multiple of 4"
        }
    }
}

/// A 4,800-frame canonical CAF written by the Mac `ProcessingTimelineAudioExporter`, and the
/// samples the Mac AVFoundation reader returns for it. Both files are shared by every platform.
public enum CanonicalCAFFixture {
    public static let frameCount = 4_800

    public static func cafURL() throws -> URL {
        try resource("canonical-mac-16k", "caf")
    }

    public static func expectedSamplesURL() throws -> URL {
        try resource("canonical-mac-16k.expected", "f32le")
    }

    public static func expectedSamples() throws -> [Float] {
        let data = try Data(contentsOf: expectedSamplesURL())
        guard data.count % 4 == 0 else { throw CanonicalCAFFixtureError.invalidExpectedSamples(data.count) }
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }

    private static func resource(_ name: String, _ fileExtension: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources") else {
            throw CanonicalCAFFixtureError.missingResource("\(name).\(fileExtension)")
        }
        return url
    }
}
