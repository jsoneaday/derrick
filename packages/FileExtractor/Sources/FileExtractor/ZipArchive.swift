import Foundation
import Structure

enum ZipArchiveError: Error, Sendable {
    case invalidArchive
    case missingEntry(String)
}

enum ZipArchive {
    static func write(_ entries: [String: Data]) throws -> Data {
        var local = Data()
        var central = Data()
        var offsets: [UInt32] = []
        let sorted = entries.keys.sorted()
        for name in sorted {
            let data = entries[name] ?? Data()
            let nameData = Data(name.utf8)
            let crc = CRC32.hash(data)
            let offset = UInt32(local.count)
            offsets.append(offset)
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            appendUInt16(&local, 20)
            appendUInt16(&local, 0)
            appendUInt16(&local, 0)
            appendUInt16(&local, 0)
            appendUInt16(&local, 0)
            appendUInt32(&local, crc)
            appendUInt32(&local, UInt32(data.count))
            appendUInt32(&local, UInt32(data.count))
            appendUInt16(&local, UInt16(nameData.count))
            appendUInt16(&local, 0)
            local.append(nameData)
            local.append(data)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            appendUInt16(&central, 20)
            appendUInt16(&central, 20)
            appendUInt16(&central, 0)
            appendUInt16(&central, 0)
            appendUInt16(&central, 0)
            appendUInt16(&central, 0)
            appendUInt32(&central, crc)
            appendUInt32(&central, UInt32(data.count))
            appendUInt32(&central, UInt32(data.count))
            appendUInt16(&central, UInt16(nameData.count))
            appendUInt16(&central, 0)
            appendUInt16(&central, 0)
            appendUInt16(&central, 0)
            appendUInt16(&central, 0)
            appendUInt32(&central, 0)
            appendUInt32(&central, offset)
            central.append(nameData)
        }
        var result = local
        result.append(central)
        result.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        appendUInt16(&result, 0)
        appendUInt16(&result, 0)
        appendUInt16(&result, UInt16(sorted.count))
        appendUInt16(&result, UInt16(sorted.count))
        appendUInt32(&result, UInt32(central.count))
        appendUInt32(&result, UInt32(local.count))
        appendUInt16(&result, 0)
        return result
    }

    static func read(_ data: Data) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        var offset = 0
        while offset + 30 <= data.count {
            let signature = readUInt32(data, offset)
            if signature == 0x02014B50 || signature == 0x06054B50 {
                break
            }
            guard signature == 0x04034B50 else {
                throw ZipArchiveError.invalidArchive
            }
            let method = readUInt16(data, offset + 8)
            let compressedSize = Int(readUInt32(data, offset + 18))
            let nameLength = Int(readUInt16(data, offset + 26))
            let extraLength = Int(readUInt16(data, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard nameEnd <= data.count, dataEnd <= data.count else {
                throw ZipArchiveError.invalidArchive
            }
            let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
            let payload = Data(data[dataStart..<dataEnd])
            if method == 0 {
                entries[name] = payload
            } else if method == 8, let inflated = ZipInflate.inflate(payload) {
                entries[name] = inflated
            } else if !name.hasSuffix("/") {
                throw ZipArchiveError.invalidArchive
            }
            offset = dataEnd
        }
        return entries
    }

    static func readEntry(_ data: Data, named name: String) throws -> Data {
        let entries = try read(data)
        if let match = entries[name] {
            return match
        }
        if let match = entries.first(where: { $0.key == name || $0.key.hasSuffix("/" + name) })?.value {
            return match
        }
        throw ZipArchiveError.missingEntry(name)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
