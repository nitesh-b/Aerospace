//
//  RequestBuilder.swift
//  Aerospace
//
//  Turns a SavedRequest into a URLRequest. Pure and side-effect free so it can
//  be unit-tested without touching the network. The builder is faithful to the
//  user's input — it never silently strips a body or mangles the URL — except
//  for `{name}` variable substitution, which is applied to the URL, header
//  values, query-param values, the bearer token, and the body before the
//  request is otherwise built unchanged.
//

import Foundation

nonisolated struct RequestBuilder: Sendable {

    nonisolated enum BuildError: Error, LocalizedError, Equatable {
        case emptyURL
        case invalidURL
        case missingScheme

        var errorDescription: String? {
            switch self {
            case .emptyURL: return "The URL is empty."
            case .invalidURL: return "The URL could not be parsed."
            case .missingScheme: return "The URL needs a scheme, e.g. https://"
            }
        }
    }

    /// Replaces every `{name}` occurrence in `text` with the matching entry in
    /// `variables`. A token with no matching name is left untouched verbatim.
    static func substituting(_ text: String, with variables: [String: String]) -> String {
        guard !variables.isEmpty else { return text }
        var result = text
        for (name, value) in variables {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }

    func makeURLRequest(from request: SavedRequest, variables: [String: String] = [:]) throws -> URLRequest {
        func substituted(_ text: String) -> String { Self.substituting(text, with: variables) }

        let trimmed = substituted(request.urlString).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BuildError.emptyURL }
        guard var components = URLComponents(string: trimmed) else { throw BuildError.invalidURL }
        guard let scheme = components.scheme, !scheme.isEmpty else { throw BuildError.missingScheme }

        // Merge enabled query rows onto any query already present in the URL.
        // URLComponents handles percent-encoding; never encode manually.
        var items = components.queryItems ?? []
        for param in request.queryParams where param.isEnabled
            && !param.key.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: param.key, value: substituted(param.value)))
        }
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else { throw BuildError.invalidURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 30

        // Headers. addValue preserves duplicate keys (legal in HTTP). Track the
        // names the user set so we don't clobber their Content-Type below.
        var userHeaderNames: Set<String> = []
        for header in request.headers where header.isEnabled
            && !header.key.trimmingCharacters(in: .whitespaces).isEmpty {
            urlRequest.addValue(substituted(header.value), forHTTPHeaderField: header.key)
            userHeaderNames.insert(header.key.lowercased())
        }

        // Bearer token — only when selected and non-empty.
        if request.authKind == .bearer {
            let token = substituted(request.bearerToken).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        // Body — sent verbatim as UTF-8 (after substitution). Kept even for GET
        // (faithful to input).
        if request.bodyKind != .none {
            urlRequest.httpBody = Data(substituted(request.bodyText).utf8)
            if request.bodyKind == .json && !userHeaderNames.contains("content-type") {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        return urlRequest
    }
}
