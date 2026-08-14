import Foundation

/// On-disk identity of the JobKeepAlive executable this process launched from.
/// Same path after an Xcode rebuild is a different identity (inode / size / mtime).
public struct DerrickDaemonBinaryIdentity: Hashable, Sendable, Codable, Equatable {
    public let inode: UInt64
    public let size: UInt64
    public let modificationTime: TimeInterval

    public init(inode: UInt64, size: UInt64, modificationTime: TimeInterval) {
        self.inode = inode
        self.size = size
        self.modificationTime = modificationTime
    }

    public var fingerprint: String {
        "\(inode)-\(size)-\(String(format: "%.3f", modificationTime))"
    }

    public static func snapshot(atPath path: String) -> DerrickDaemonBinaryIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        guard size > 0 else { return nil }
        return DerrickDaemonBinaryIdentity(inode: inode, size: size, modificationTime: mtime)
    }
}
