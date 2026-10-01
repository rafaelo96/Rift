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
    enum BitstreamFormat {
        case lengthPrefixed
        case annexB
    }

    /// SPS then PPS, in the order Core Video expects.
    let parameterSets: [AVCParameterSet]
    /// Length-field size of the NAL units in the packet bitstream
    /// (lengthSizeMinusOne + 1). MP4/MKV H.264 uses 4.
    let nalUnitHeaderLength: Int
    /// Packet representation supplied by the container.
    let bitstreamFormat: BitstreamFormat

    static func parse(_ extradata: [UInt8]) throws -> AVCConfiguration {
        if Self.startCodeLength(at: 0, in: extradata) != nil {
            return try parseAnnexB(extradata)
        }

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
        return AVCConfiguration(
            parameterSets: sets,
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
            throw AVCConfigurationError.malformed("Annex-B packet contains no NAL units")
        }

        var sample: [UInt8] = []
        sample.reserveCapacity(packet.count + nalUnits.count)
        for nal in nalUnits {
            guard nal.count <= Int(UInt32.max) else {
                throw AVCConfigurationError.malformed("NAL unit exceeds UInt32 length")
            }
            let length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: length) { sample.append(contentsOf: $0) }
            sample.append(contentsOf: nal)
        }
        return sample
    }

    private static func parseAnnexB(_ extradata: [UInt8]) throws -> AVCConfiguration {
        let nalUnits = annexBNALUnits(in: extradata)
        let sets = nalUnits.compactMap { bytes -> AVCParameterSet? in
            guard let first = bytes.first else { return nil }
            let type = first & 0x1f
            guard type == 7 || type == 8 else { return nil }
            return AVCParameterSet(type: type, bytes: bytes)
        }
        guard sets.contains(where: { $0.type == 7 }),
              sets.contains(where: { $0.type == 8 }) else {
            throw AVCConfigurationError.malformed("Annex-B extradata is missing SPS or PPS")
        }
        return AVCConfiguration(
            parameterSets: sets.sorted { $0.type < $1.type },
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
}
