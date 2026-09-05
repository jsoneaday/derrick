import Foundation
import Structure
#if canImport(zlib)
import zlib
#endif

enum ZipInflate {
    static func inflate(_ data: Data) -> Data? {
        #if canImport(zlib)
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                return nil
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            guard inflateInit2_(
                &stream,
                -MAX_WBITS,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else {
                return nil
            }
            defer { inflateEnd(&stream) }
            var output = Data()
            var buffer = [Bytef](repeating: 0, count: 16_384)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
                    stream.next_out = pointer.baseAddress
                    stream.avail_out = uInt(pointer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = 16_384 - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END {
                    return output
                }
                if status != Z_OK {
                    return nil
                }
            }
        }
        #else
        return nil
        #endif
    }
}
