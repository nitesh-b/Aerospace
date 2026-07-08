//
//  SavedRequest.swift
//  Aerospace
//
//  The persisted, editable definition of an HTTP request in the API tester.
//

import Foundation

nonisolated struct SavedRequest: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var method: HTTPMethod
    var urlString: String
    var queryParams: [KeyValueItem]
    var headers: [KeyValueItem]
    var authKind: AuthKind
    var bearerToken: String
    var bodyKind: BodyKind
    var bodyText: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "New Request",
        method: HTTPMethod = .get,
        urlString: String = "",
        queryParams: [KeyValueItem] = [],
        headers: [KeyValueItem] = [],
        authKind: AuthKind = .none,
        bearerToken: String = "",
        bodyKind: BodyKind = .none,
        bodyText: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.urlString = urlString
        self.queryParams = queryParams
        self.headers = headers
        self.authKind = authKind
        self.bearerToken = bearerToken
        self.bodyKind = bodyKind
        self.bodyText = bodyText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when the request is an untouched blank template. Used to avoid
    /// persisting empty "New Request" rows until the user has entered something.
    var isEffectivelyEmpty: Bool {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        bearerToken.isEmpty &&
        bodyText.isEmpty &&
        queryParams.allSatisfy { $0.key.isEmpty && $0.value.isEmpty } &&
        headers.allSatisfy { $0.key.isEmpty && $0.value.isEmpty }
    }

    /// A duplicate with a fresh identity for the request and every row, a
    /// "copy" name, and reset timestamps.
    func duplicated(now: Date = Date()) -> SavedRequest {
        SavedRequest(
            id: UUID(),
            name: name + " copy",
            method: method,
            urlString: urlString,
            queryParams: queryParams.map { $0.copyWithNewID() },
            headers: headers.map { $0.copyWithNewID() },
            authKind: authKind,
            bearerToken: bearerToken,
            bodyKind: bodyKind,
            bodyText: bodyText,
            createdAt: now,
            updatedAt: now
        )
    }
}
