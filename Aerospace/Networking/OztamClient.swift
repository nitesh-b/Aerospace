//
//  OztamClient.swift
//  Aerospace
//
//  Polls the OzTAM Collection Service tail API for one device, the same way
//  uap.oztail's BaseSearch does: GET the kind's endpoint with the identifier
//  and a `fromDate` cursor, under HTTP basic auth, retrying transport errors
//  and non-200 responses a few times before giving up.
//

import Foundation

nonisolated struct OztamCredentials: Sendable, Equatable {
    var userId: String
    var password: String

    var isComplete: Bool {
        !userId.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }
}

nonisolated struct OztamFetchResult: Sendable {
    let events: [OztamEvent]
    /// The newest `createdAt` seen in this batch, used to advance the cursor.
    let latestCreatedAt: Date?
    /// Meter events in the response before flattening. Zero means OzTAM had
    /// nothing for this device; non-zero with no `events` means the payload
    /// carried no nested event rows.
    let meterEventCount: Int
}

nonisolated enum OztamClientError: LocalizedError, Equatable {
    case invalidURL
    case unauthorized
    case http(Int)
    case transport(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not build a request URL for this device."
        case .unauthorized: return "Rejected by OzTAM (check the user ID and password)."
        case .http(let code): return "OzTAM returned HTTP \(code)."
        case .transport(let message): return message
        case .malformedResponse: return "OzTAM returned a response that could not be read."
        }
    }
}

nonisolated struct OztamClient: Sendable {

    /// Attempts per poll before the error surfaces to the UI.
    private static let maxAttempts = 3

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchEvents(
        host: URL,
        device: OztamDevice,
        fromDate: Date,
        credentials: OztamCredentials
    ) async throws -> OztamFetchResult {
        let request = try Self.makeRequest(host: host, device: device,
                                           fromDate: fromDate, credentials: credentials)

        var lastError: OztamClientError = .malformedResponse
        for attempt in 1...Self.maxAttempts {
            do {
                return try await perform(request, device: device)
            } catch let error as OztamClientError {
                // Bad credentials will not fix themselves; fail straight away.
                if case .unauthorized = error { throw error }
                lastError = error
                if attempt < Self.maxAttempts {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                }
            }
        }
        throw lastError
    }

    private func perform(_ request: URLRequest, device: OztamDevice) async throws -> OztamFetchResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OztamClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OztamClientError.malformedResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OztamClientError.unauthorized
        }
        guard http.statusCode == 200 else {
            throw OztamClientError.http(http.statusCode)
        }

        return Self.decode(data, device: device)
    }

    // MARK: - Request building

    /// The exact URL a poll will hit. Carries no credentials (auth travels as a
    /// header), so it is safe to display and to paste into curl.
    static func makeURL(host: URL, device: OztamDevice, fromDate: Date) throws -> URL {
        guard device.isUsable,
              var components = URLComponents(url: host.appendingPathComponent(device.kind.endpointPath),
                                             resolvingAgainstBaseURL: false)
        else { throw OztamClientError.invalidURL }

        // Encoded by hand rather than via `queryItems`: URLComponents leaves a
        // raw `+` in place (it is a legal query character), but server-side
        // query parsers decode `+` as a space, which corrupts the `+10:00`
        // timezone offset in `fromDate` and makes OzTAM return nothing.
        let pairs = [
            (device.kind.queryName, device.queryValue),
            ("fromDate", cursorFormatter.string(from: fromDate)),
        ]
        components.percentEncodedQuery = pairs
            .map { "\(encodeQueryComponent($0.0))=\(encodeQueryComponent($0.1))" }
            .joined(separator: "&")

        guard let url = components.url else { throw OztamClientError.invalidURL }
        return url
    }

    /// The characters JavaScript's `encodeURIComponent` leaves unescaped.
    /// Matching it keeps Aerospace's requests byte-identical to oztail's,
    /// which reaches OzTAM through superagent.
    private static let unreservedQueryCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    /// Percent-encodes one query name or value the way `encodeURIComponent`
    /// does, escaping `+` and `:` included.
    static func encodeQueryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedQueryCharacters) ?? value
    }

    static func makeRequest(
        host: URL,
        device: OztamDevice,
        fromDate: Date,
        credentials: OztamCredentials
    ) throws -> URLRequest {
        let url = try makeURL(host: host, device: device, fromDate: fromDate)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let pair = Data("\(credentials.userId):\(credentials.password)".utf8).base64EncodedString()
        request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// `moment().format()` — ISO-8601 in the local time zone, no fractional
    /// seconds — which is what the OCS expects for `fromDate`.
    static let cursorFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f
    }()

    // MARK: - Decoding

    static func decode(_ data: Data, device: OztamDevice) -> OztamFetchResult {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let meterEvents = root as? [[String: Any]]
        else { return OztamFetchResult(events: [], latestCreatedAt: nil, meterEventCount: 0) }

        var events: [OztamEvent] = []
        var latest: Date?
        for meterEvent in meterEvents {
            let rows = OztamEvent.rows(fromMeterEvent: meterEvent, device: device)
            events.append(contentsOf: rows)
            if let createdAt = rows.first?.createdAt, latest == nil || createdAt > latest! {
                latest = createdAt
            }
        }
        return OztamFetchResult(events: events, latestCreatedAt: latest,
                                meterEventCount: meterEvents.count)
    }
}
