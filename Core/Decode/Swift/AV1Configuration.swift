import Foundation

// MARK: - AV1CodecConfigurationRecord (av1C) parser
//
// Matroska and MP4 expose AV1 decoder configuration as an av1C payload. Unlike
// AVC/HEVC, Core Media consumes the complete record as a sample-description
// extension atom; parsing here validates the container data and selects the
// output pixel depth before creating the VideoToolbox session.

enum AV1ConfigurationError: Error, CustomStringConvertible {
    case notAv1C(String)
    case malformed(String)

    var description: String {
        switch self {
        case .notAv1C(let detail): return "extradata is not av1C — \(detail)"
        case .malformed(let detail): return "malformed av1C — \(detail)"
        }
    }
}

struct AV1Configuration {
    /// Complete AV1CodecConfigurationRecord payload, without an atom header.
    let record: [UInt8]
    let profile: UInt8
    let level: UInt8
    let highBitDepth: Bool
    let twelveBit: Bool

    var usesHighBitDepth: Bool { highBitDepth || twelveBit }

    static func parse(_ extradata: [UInt8]) throws -> AV1Configuration {
        guard extradata.count >= 4 else {
            throw AV1ConfigurationError.malformed("record shorter than 4 bytes")
        }

        let marker = extradata[0] >> 7
        let version = extradata[0] & 0x7f
        guard marker == 1, version == 1 else {
            throw AV1ConfigurationError.notAv1C(
                "marker/version byte is 0x\(String(format: "%02x", extradata[0])) (expected 0x81)"
            )
        }

        let profile = extradata[1] >> 5
        let level = extradata[1] & 0x1f
        guard profile <= 2 else {
            throw AV1ConfigurationError.malformed("unsupported seq_profile \(profile)")
        }

        let highBitDepth = (extradata[2] & 0x40) != 0
        let twelveBit = (extradata[2] & 0x20) != 0
        guard !twelveBit || highBitDepth else {
            throw AV1ConfigurationError.malformed("twelve_bit requires high_bitdepth")
        }

        return AV1Configuration(
            record: extradata,
            profile: profile,
            level: level,
            highBitDepth: highBitDepth,
            twelveBit: twelveBit
        )
    }
}
