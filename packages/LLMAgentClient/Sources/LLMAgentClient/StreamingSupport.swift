import Foundation

struct SSEDecoder {
    let bytes: URLSession.AsyncBytes

    var events: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer: [String] = []

                    for try await line in bytes.lines {
                        if line.isEmpty {
                            emit(buffer: buffer, to: continuation)
                            buffer.removeAll(keepingCapacity: true)
                            continue
                        }

                        buffer.append(line)
                    }

                    emit(buffer: buffer, to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func emit(buffer: [String], to continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let event = buffer.compactMap { line -> String? in
            line.hasPrefix("data:") ? line.dropFirst(5).trimmingCharacters(in: .whitespaces) : nil
        }.joined(separator: "\n")

        if !event.isEmpty {
            continuation.yield(event)
        }
    }
}

func encode<T: Encodable>(_ value: T) throws -> Data {
    do {
        return try JSONEncoder().encode(value)
    } catch {
        throw AgentError.requestEncodingFailed(String(describing: error))
    }
}

func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw AgentError.responseDecodingFailed(String(describing: error))
    }
}

func validate(response: URLResponse) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
        throw AgentError.invalidHTTPResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
        throw AgentError.httpStatus(httpResponse.statusCode, "")
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
