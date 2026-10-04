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
    enum BitstreamFormat {
        case lengthPrefixed
        case annexB
    }

    /// VPS, SPS, PPS in the order Core Video expects (VPS first, then SPS, then PPS).
    let parameterSets: [HEVCParameterSet]
    /// Length-field size of the NAL units in the packet bitstream
    /// (lengthSizeMinusOne + 1). MKV HEVC uses 4.
    let nalUnitHeaderLength: Int
    /// Packet representation supplied by the container.
    let bitstreamFormat: BitstreamFormat

    static func parse(_ extradata: [UInt8]) throws -> HEVCConfiguration {
        if Self.startCodeLength(at: 0, in: extradata) != nil {
            return try parseAnnexB(extradata)
        }

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
        return HEVCConfiguration(
            parameterSets: ordered,
            nalUnitHeaderLength: nalUnitHeaderLength,
            bitstreamFormat: .lengthPrefixed
        )
    }

    /// Converts one Annex-B access unit to the four-byte length-prefixed form
    /// consumed by VideoToolbox. Only the current compressed packet is copied.
    func videoToolboxSample(from packet: [UInt8]) throws -> [UInt8] {
        guard bitstreamFormat == .annexB else { return packet }
        let nalUnits = Self.annexBNALUnits(in: packet)
        guard !nalUnits.isEmpty else {
            throw HEVCConfigurationError.malformed("Annex-B packet contains no NAL units")
        }

        var sample: [UInt8] = []
        sample.reserveCapacity(packet.count + nalUnits.count)
        for nal in nalUnits {
            guard nal.count <= Int(UInt32.max) else {
                throw HEVCConfigurationError.malformed("NAL unit exceeds UInt32 length")
            }
            let length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: length) { sample.append(contentsOf: $0) }
            sample.append(contentsOf: nal)
        }
        return sample
    }

    private static func parseAnnexB(_ extradata: [UInt8]) throws -> HEVCConfiguration {
        let sets = annexBNALUnits(in: extradata).compactMap { bytes -> HEVCParameterSet? in
            guard let first = bytes.first else { return nil }
            let type = (first >> 1) & 0x3f
            guard type == 32 || type == 33 || type == 34 else { return nil }
            return HEVCParameterSet(type: type, bytes: bytes)
        }
        guard sets.contains(where: { $0.type == 32 }),
              sets.contains(where: { $0.type == 33 }),
              sets.contains(where: { $0.type == 34 }) else {
            throw HEVCConfigurationError.malformed(
                "Annex-B extradata is missing VPS, SPS, or PPS"
            )
        }
        return HEVCConfiguration(
            parameterSets: sets.sorted { order(of: $0.type) < order(of: $1.type) },
            nalUnitHeaderLength: 4,
            bitstreamFormat: .annexB
        )
    }

    private static func annexBNALUnits(in bytes: [UInt8]) -> [[UInt8]] {
        var starts: [(offset: Int, prefixLength: Int)] = []
        var index = 0
        while index < bytes.count {
            if let length = startCodeLength(at: index, in: bytes) {
                starts.append((index, length))
                index += length
            } else {
                index += 1
            }
        }

        return starts.enumerated().compactMap { position, start in
            let bodyStart = start.offset + start.prefixLength
            var bodyEnd = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            while bodyEnd > bodyStart, bytes[bodyEnd - 1] == 0 { bodyEnd -= 1 }
            guard bodyStart < bodyEnd else { return nil }
            return Array(bytes[bodyStart..<bodyEnd])
        }
    }

    private static func startCodeLength(at index: Int, in bytes: [UInt8]) -> Int? {
        guard index + 3 <= bytes.count,
              bytes[index] == 0, bytes[index + 1] == 0 else { return nil }
        if bytes[index + 2] == 1 { return 3 }
        if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
            return 4
        }
        return nil
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
