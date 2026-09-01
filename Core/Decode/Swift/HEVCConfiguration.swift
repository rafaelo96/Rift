import Foundation

// MARK: - HEVCDecoderConfigurationRecord (hvcC) parser
//
// Core/Demux exposes the MKV CodecPrivate as raw bytes. For HEVC that record
// is a HEVCDecoderConfigurationRecord (ISO/IEC 14496-15), verified on the
// real test file: configVersion=1, high tier Main profile, level 6, 4:2:0
// 10-bit, lengthSizeMinusOne=3 (4-byte NAL length prefixes), and 3 arrays:
// NAL unit type 32 (VPS), 33 (SPS), 34 (PPS).
//
// VideoToolbox has no API that takes a whole hvcC blob, so we split the VPS/
// SPS/PPS out of the record arrays here.

struct HEVCParameterSet: Equatable {
    /// NAL unit type (32 = VPS, 33 = SPS, 34 = PPS).
    let type: UInt8
    /// Raw NAL bytes WITHOUT the hvcC record's 2-byte length prefix.
    let bytes: [UInt8]
}

enum HEVCConfigurationError: Error, CustomStringConvertible {
    case notHvcC(String)
    case malformed(String)

    var description: String {
        switch self {
        case .notHvcC(let detail): return "extradata is not hvcC — \(detail)"
        case .malformed(let detail): return "malformed hvcC — \(detail)"
        }
    }
}

struct HEVCConfiguration {
    /// VPS, SPS, PPS in the order Core Video expects (VPS first, then SPS, then PPS).
    let parameterSets: [HEVCParameterSet]
    /// Length-field size of the NAL units in the packet bitstream
    /// (lengthSizeMinusOne + 1). MKV HEVC uses 4.
    let nalUnitHeaderLength: Int

    static func parse(_ extradata: [UInt8]) throws -> HEVCConfiguration {
        guard let first = extradata.first, first == 1 else {
            throw HEVCConfigurationError.notHvcC(
                "first byte is 0x\(String(format: "%02x", extradata.first ?? 0)) (expected 0x01 configurationVersion) "
                    + "(Annex-B start codes and avcC are not handled here)"
            )
        }
        guard extradata.count >= 23 else {
            throw HEVCConfigurationError.malformed("record shorter than 23 bytes")
        }

        let nalUnitHeaderLength = Int(extradata[21] & 0x03) + 1
        let numOfArrays = Int(extradata[22])

        var sets: [HEVCParameterSet] = []
        var offset = 23
        for _ in 0..<numOfArrays {
            guard offset + 3 <= extradata.count else {
                throw HEVCConfigurationError.malformed(
                    "array header past end of record (offset \(offset))"
                )
            }
            let nalType = extradata[offset] & 0x3f
            let numNalus = (Int(extradata[offset + 1]) << 8) | Int(extradata[offset + 2])
            offset += 3

            for _ in 0..<numNalus {
                guard offset + 2 <= extradata.count else {
                    throw HEVCConfigurationError.malformed("NAL length field past end of record")
                }
                let length = (Int(extradata[offset]) << 8) | Int(extradata[offset + 1])
                offset += 2
                guard offset + length <= extradata.count else {
                    throw HEVCConfigurationError.malformed("NAL body past end of record")
                }
                sets.append(HEVCParameterSet(
                    type: nalType,
                    bytes: Array(extradata[offset..<(offset + length)])
                ))
                offset += length
            }
        }

        let ordered = sets.sorted { Self.order(of: $0.type) < Self.order(of: $1.type) }
        return HEVCConfiguration(parameterSets: ordered, nalUnitHeaderLength: nalUnitHeaderLength)
    }

    private static func order(of type: UInt8) -> Int {
        switch type {
        case 32: return 0 // VPS
        case 33: return 1 // SPS
        case 34: return 2 // PPS
        default: return 3
        }
    }
}