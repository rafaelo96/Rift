import Foundation

// MARK: - AVCDecoderConfigurationRecord (avcC) parser
//
// Core/Demux exposes the MP4/MKV CodecPrivate as raw bytes. For H.264 that
// record is an AVCDecoderConfigurationRecord (ISO/IEC 14496-15), the container
// format used by MP4 (avcC) as opposed to Annex-B byte-stream. It holds the
// SPS and PPS needed to build the CMVideoFormatDescription.
//
// Record layout (same family as hvcC, but SPS/PPS in sequential sections):
//   [0]        configurationVersion (== 1)
//   [1..3]     profile/level (ignored here)
//   [4]        lengthSizeMinusOne (lower 2 bits) → NAL length prefix size
//   [5]        numOfSPS (lower 3 bits)
//   then for each SPS: 2-byte length + SPS bytes
//   [..]       numOfPPS
//   then for each PPS: 2-byte length + PPS bytes

struct AVCParameterSet: Equatable {
    /// NAL unit type (7 = SPS, 8 = PPS).
    let type: UInt8
    /// Raw NAL bytes WITHOUT the avcC record's 2-byte length prefix.
    let bytes: [UInt8]
}

enum AVCConfigurationError: Error, CustomStringConvertible {
    case notAvcC(String)
    case malformed(String)

    var description: String {
        switch self {
        case .notAvcC(let detail): return "extradata is not avcC — \(detail)"
        case .malformed(let detail): return "malformed avcC — \(detail)"
        }
    }
}

struct AVCConfiguration {
    /// SPS then PPS, in the order Core Video expects.
    let parameterSets: [AVCParameterSet]
    /// Length-field size of the NAL units in the packet bitstream
    /// (lengthSizeMinusOne + 1). MP4/MKV H.264 uses 4.
    let nalUnitHeaderLength: Int

    static func parse(_ extradata: [UInt8]) throws -> AVCConfiguration {
        guard let first = extradata.first, first == 1 else {
            throw AVCConfigurationError.notAvcC(
                "first byte is 0x\(String(format: "%02x", extradata.first ?? 0)) (expected 0x01 configurationVersion)"
            )
        }
        guard extradata.count >= 7 else {
            throw AVCConfigurationError.malformed("record shorter than 7 bytes")
        }

        let nalUnitHeaderLength = Int(extradata[4] & 0x03) + 1

        var sets: [AVCParameterSet] = []
        var offset = 5

        // SPS section
        let numSPS = Int(extradata[offset] & 0x1f)
        offset += 1
        for _ in 0..<numSPS {
            guard offset + 2 <= extradata.count else {
                throw AVCConfigurationError.malformed("SPS length field past end of record")
            }
            let length = (Int(extradata[offset]) << 8) | Int(extradata[offset + 1])
            offset += 2
            guard offset + length <= extradata.count else {
                throw AVCConfigurationError.malformed("SPS body past end of record")
            }
            sets.append(AVCParameterSet(type: 7, bytes: Array(extradata[offset..<(offset + length)])))
            offset += length
        }

        // PPS section
        guard offset < extradata.count else {
            throw AVCConfigurationError.malformed("missing PPS count")
        }
        let numPPS = Int(extradata[offset])
        offset += 1
        for _ in 0..<numPPS {
            guard offset + 2 <= extradata.count else {
                throw AVCConfigurationError.malformed("PPS length field past end of record")
            }
            let length = (Int(extradata[offset]) << 8) | Int(extradata[offset + 1])
            offset += 2
            guard offset + length <= extradata.count else {
                throw AVCConfigurationError.malformed("PPS body past end of record")
            }
            sets.append(AVCParameterSet(type: 8, bytes: Array(extradata[offset..<(offset + length)])))
            offset += length
        }

        guard !sets.isEmpty else {
            throw AVCConfigurationError.malformed("no SPS/PPS found in avcC extradata")
        }
        return AVCConfiguration(parameterSets: sets, nalUnitHeaderLength: nalUnitHeaderLength)
    }
}