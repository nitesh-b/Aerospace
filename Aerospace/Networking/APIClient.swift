//
//  APIClient.swift
//  Aerospace
//
//  Executes a URLRequest off the main actor and maps the result into an
//  APIResponse. Never throws to the caller — transport problems become
//  `.failure`, cancellation becomes `.cancelled`.
//

import Foundation

nonisolated struct APIClient: Sendable {

    /// Bodies larger than this are truncated for display (the full byte count is
    /// still reported). Keeps the syntax highlighter and text view responsive.
    private static let maxDisplayBytes = 2 * 1024 * 1024

    /// Injectable for tests (default is the shared session).
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async -> APIResponse {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = clock.now - start

            guard let http = response as? HTTPURLResponse else {
                return APIResponse(outcome: .failure("Non-HTTP response."), duration: elapsed)
            }

            let headers = http.allHeaderFields
                .compactMap { key, value -> HeaderPair? in
                    guard let name = key as? String else { return nil }
                    return HeaderPair(name: name, value: String(describing: value))
                }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let (bodyText, isJSON) = Self.decodeBody(data, contentType: contentType)

            return APIResponse(
                outcome: .success,
                statusCode: http.statusCode,
                headers: headers,
                bodyText: bodyText,
                bodyByteCount: data.count,
                duration: elapsed,
                isBodyJSON: isJSON,
                finalURL: http.url?.absoluteString
            )
        } catch let error as URLError where error.code == .cancelled {
            return APIResponse(outcome: .cancelled, duration: clock.now - start)
        } catch {
            return APIResponse(outcome: .failure(error.localizedDescription),
                               duration: clock.now - start)
        }
    }

    /// Decode a response body to text, tolerating non-UTF8 and binary data, and
    /// report whether it should be treated as JSON.
    private static func decodeBody(_ data: Data, contentType: String) -> (text: String, isJSON: Bool) {
        let declaresJSON = contentType.contains("application/json") || contentType.contains("+json")

        if data.isEmpty { return ("", declaresJSON) }

        let display = data.count > maxDisplayBytes ? data.prefix(maxDisplayBytes) : data[...]

        if let text = String(data: display, encoding: .utf8) {
            let isJSON = declaresJSON || looksLikeJSON(data)
            let suffix = data.count > maxDisplayBytes
                ? "\n\n… truncated (\(data.count) bytes total)" : ""
            return (text + suffix, isJSON)
        }

        // Non-UTF8: Latin-1 never fails, but if the payload is clearly binary
        // (contains NUL bytes) show a placeholder instead of garbage.
        if display.contains(0) {
            return ("<binary response, \(data.count) bytes>", false)
        }
        let latin = String(decoding: display, as: UTF8.self)
        return (latin.isEmpty ? "<\(data.count) bytes>" : latin, false)
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d) })
        else { return false }
        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
