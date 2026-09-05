import Foundation
import Network
import Structure

/// Handles one client connection (HTTP CONNECT or absolute-form HTTP).
struct ProxyConnectionHandler: Sendable {
    private let connection: NWConnection
    private let policy: any DestinationPolicy
    private let logger: any EgressProxyLogging
    private let requiredClientToken: String?

    init(
        connection: NWConnection,
        policy: any DestinationPolicy,
        logger: any EgressProxyLogging,
        requiredClientToken: String? = nil
    ) {
        self.connection = connection
        self.policy = policy
        self.logger = logger
        self.requiredClientToken = requiredClientToken
    }

    func run() async {
        do {
            let headerData = try await readHTTPHeaders(from: connection)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                try await sendClient(connection, statusLine: "HTTP/1.1 400 Bad Request", body: "invalid encoding")
                connection.cancel()
                return
            }

            let request = try parseProxyRequest(headerText)
            let destination = request.destination
            let clientDescription = connection.currentPath?.remoteEndpoint.map { "\($0)" }

            if let requiredClientToken,
               request.clientToken != requiredClientToken {
                logger.logError("rejecting proxy client with invalid crawler token")
                try await sendClient(
                    connection,
                    statusLine: "HTTP/1.1 407 Proxy Authentication Required",
                    body: "crawler authentication required"
                )
                connection.cancel()
                return
            }

            let decision = await policy.evaluate(destination: destination)
            switch decision {
            case .deny(let reason):
                logger.logUnauthorizedAccess(
                    destination: destination,
                    reason: reason,
                    clientDescription: clientDescription
                )
                try await sendClient(
                    connection,
                    statusLine: "HTTP/1.1 403 Forbidden",
                    body: "egress denied: \(reason)"
                )
                connection.cancel()
                return
            case .allow:
                logger.logAllowedAccess(destination: destination, clientDescription: clientDescription)
            }

            switch request.kind {
            case .connect:
                try await handleConnect(destination: destination)
            case .httpAbsolute(let method, let pathAndQuery, let restHeaders):
                try await handleHTTPAbsolute(
                    destination: destination,
                    method: method,
                    pathAndQuery: pathAndQuery,
                    restHeaders: restHeaders,
                    preamble: headerData
                )
            }
        } catch {
            logger.logError("connection handler error: \(error.localizedDescription)")
            connection.cancel()
        }
    }

    private func handleConnect(destination: ProxyDestination) async throws {
        let upstream = NWConnection(
            host: NWEndpoint.Host(destination.host),
            port: NWEndpoint.Port(rawValue: destination.port) ?? .https,
            using: .tcp
        )
        try await startConnection(upstream)

        try await sendRaw(connection, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        await pipeBidirectional(client: connection, upstream: upstream)
    }

    private func handleHTTPAbsolute(
        destination: ProxyDestination,
        method: String,
        pathAndQuery: String,
        restHeaders: String,
        preamble: Data
    ) async throws {
        let upstream = NWConnection(
            host: NWEndpoint.Host(destination.host),
            port: NWEndpoint.Port(rawValue: destination.port) ?? .http,
            using: .tcp
        )
        try await startConnection(upstream)

        var originRequest = "\(method) \(pathAndQuery) HTTP/1.1\r\n"
        originRequest += "Host: \(destination.host)\r\n"
        originRequest += restHeaders
        if !restHeaders.hasSuffix("\r\n") {
            originRequest += "\r\n"
        }
        if !originRequest.hasSuffix("\r\n\r\n") {
            originRequest += "\r\n"
        }
        try await sendRaw(upstream, Data(originRequest.utf8))

        // If client sent body after headers in the same buffer, we only had headers.
        // Remaining body (if any) is streamed via bidirectional pipe.
        _ = preamble
        await pipeBidirectional(client: connection, upstream: upstream)
    }

    private func startConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeOnce {
                        continuation.resume()
                    }
                case .failed(let error):
                    gate.resumeOnce {
                        continuation.resume(throwing: EgressProxyError.upstreamConnectFailed(error.localizedDescription))
                    }
                case .cancelled:
                    gate.resumeOnce {
                        continuation.resume(throwing: EgressProxyError.upstreamConnectFailed("cancelled"))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
}

// MARK: - Request parsing

private enum ProxyRequestKind: Sendable {
    case connect
    case httpAbsolute(method: String, pathAndQuery: String, restHeaders: String)
}

private struct ParsedProxyRequest: Sendable {
    let kind: ProxyRequestKind
    let destination: ProxyDestination
    let clientToken: String?
}

private func parseProxyRequest(_ text: String) throws -> ParsedProxyRequest {
    let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
    guard let requestLine = lines.first else {
        throw EgressProxyError.invalidRequest("missing request line")
    }
    let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 2 else {
        throw EgressProxyError.invalidRequest("malformed request line")
    }
    let method = parts[0].uppercased()
    let target = parts[1]

    if method == "CONNECT" {
        let hostPort = target.split(separator: ":", maxSplits: 1).map(String.init)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]) else {
            throw EgressProxyError.invalidRequest("malformed CONNECT target")
        }
        return ParsedProxyRequest(
            kind: .connect,
            destination: ProxyDestination(host: hostPort[0], port: port),
            clientToken: proxyClientToken(from: lines)
        )
    }

    guard let url = URL(string: target), let host = url.host else {
        throw EgressProxyError.invalidRequest("expected absolute-form HTTP URL for non-CONNECT")
    }
    let port = UInt16(url.port ?? ((url.scheme?.lowercased() == "https") ? 443 : 80))
    let path = url.path.isEmpty ? "/" : url.path
    let pathAndQuery = path + (url.query.map { "?\($0)" } ?? "")
    let rest = lines.dropFirst().filter { line in
        let lower = line.lowercased()
        return !lower.hasPrefix("proxy-connection:") && !lower.hasPrefix("host:")
    }.joined(separator: "\r\n")

    return ParsedProxyRequest(
        kind: .httpAbsolute(method: method, pathAndQuery: pathAndQuery, restHeaders: rest),
        destination: ProxyDestination(host: host, port: port),
        clientToken: proxyClientToken(from: lines)
    )
}

private func proxyClientToken(from lines: [String]) -> String? {
    guard let header = lines.dropFirst().first(where: {
        $0.lowercased().hasPrefix("x-derrick-crawler-token:")
    }) else {
        return nil
    }
    let parts = header.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - NWConnection helpers

private func readHTTPHeaders(from connection: NWConnection) async throws -> Data {
    var buffer = Data()
    while true {
        let chunk = try await receive(from: connection, maximum: 64 * 1024)
        if chunk.isEmpty {
            throw EgressProxyError.invalidRequest("client closed before headers completed")
        }
        buffer.append(chunk)
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            return buffer.subdata(in: buffer.startIndex..<range.upperBound)
        }
        if buffer.count > 64 * 1024 {
            throw EgressProxyError.invalidRequest("headers too large")
        }
    }
}

private func receive(from connection: NWConnection, maximum: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { content, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            if let content {
                continuation.resume(returning: content)
            } else if isComplete {
                continuation.resume(returning: Data())
            } else {
                continuation.resume(returning: Data())
            }
        }
    }
}

private func sendRaw(_ connection: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }
}

private func sendClient(_ connection: NWConnection, statusLine: String, body: String) async throws {
    let payload = "\(statusLine)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    try await sendRaw(connection, Data(payload.utf8))
}

private func pipeBidirectional(client: NWConnection, upstream: NWConnection) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            await pipe(from: client, to: upstream)
        }
        group.addTask {
            await pipe(from: upstream, to: client)
        }
        _ = await group.next()
        group.cancelAll()
        client.cancel()
        upstream.cancel()
    }
}

private func pipe(from source: NWConnection, to destination: NWConnection) async {
    while true {
        do {
            let data = try await receive(from: source, maximum: 64 * 1024)
            if data.isEmpty {
                destination.cancel()
                return
            }
            try await sendRaw(destination, data)
        } catch {
            source.cancel()
            destination.cancel()
            return
        }
    }
}
