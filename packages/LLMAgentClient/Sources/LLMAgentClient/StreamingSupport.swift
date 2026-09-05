import Foundation
import Structure

struct SSEDecoder {
    let bytes: URLSession.AsyncBytes

    var events: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard let payload = dataPayload(from: line) else { continue }
                        continuation.yield(payload)
                    }
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

    private func dataPayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":"), trimmed.hasPrefix("data:") else {
            return nil
        }

        return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
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
