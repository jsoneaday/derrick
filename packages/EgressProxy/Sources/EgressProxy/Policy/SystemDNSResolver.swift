import Foundation
import Structure

public struct SystemDNSResolver: DNSResolving {
    public init() {}

    public func resolveAddresses(for host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let first = result else {
                    continuation.resume(
                        throwing: EgressProxyError.upstreamConnectFailed("DNS failed for \(host) (status=\(status))")
                    )
                    return
                }
                defer { freeaddrinfo(first) }

                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    if let sockaddr = info.pointee.ai_addr {
                        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let nameStatus = getnameinfo(
                            sockaddr,
                            socklen_t(info.pointee.ai_addrlen),
                            &hostBuffer,
                            socklen_t(hostBuffer.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                        if nameStatus == 0 {
                            let end = hostBuffer.firstIndex(of: 0) ?? hostBuffer.endIndex
                            addresses.append(String(decoding: hostBuffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self))
                        }
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}
