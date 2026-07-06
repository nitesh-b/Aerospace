//
//  LogRequest.swift
//  Aerospace
//
//  Decodes an incoming POST body into a LogEvent.
//
//  Expected shape:
//    {
//      "arg1": "Category",
//      "arg2": "SubCategory",
//      "arg3": { ...arbitrary JSON payload... }
//    }
//
//  arg3 may be a JSON object, array, string, number, or bool. Objects are
//  inspected for optional `level`, `sessionId`, and `application` fields,
//  which may also appear at the top level as a fallback.
//

import Foundation

nonisolated enum LogRequestError: Error, LocalizedError, Equatable {
    case emptyBody
    case notJSONObject
    case missingCategory
    case missingSubCategory

    var errorDescription: String? {
        switch self {
        case .emptyBody: return "Request body was empty."
        case .notJSONObject: return "Request body was not a JSON object."
        case .missingCategory: return "Missing required field 'arg1' (category)."
        case .missingSubCategory: return "Missing required field 'arg2' (subCategory)."
        }
    }
}

nonisolated enum LogRequest {
    /// Parse a raw request body into a LogEvent, applying `timestamp` as the
    /// receive time. Throws `LogRequestError` on malformed input.
    static func makeEvent(from body: Data, receivedAt timestamp: Date = Date()) throws -> LogEvent {
        guard !body.isEmpty else { throw LogRequestError.emptyBody }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            throw LogRequestError.notJSONObject
        }

        guard let dict = root as? [String: Any] else {
            throw LogRequestError.notJSONObject
        }

        guard let category = string(dict["arg1"]), !category.isEmpty else {
            throw LogRequestError.missingCategory
        }
        guard let subCategory = string(dict["arg2"]), !subCategory.isEmpty else {
            throw LogRequestError.missingSubCategory
        }

        let rawPayload = dict["arg3"]
        let payloadString = serialize(rawPayload)
        let payloadObject = rawPayload as? [String: Any]

        let level = LogLevel(parsing:
            string(payloadObject?["level"]) ?? string(dict["level"])
        )
        let sessionId =
            string(payloadObject?["sessionId"]) ??
            string(payloadObject?["session_id"]) ??
            string(dict["sessionId"]) ??
            string(dict["session_id"])
        let application =
            string(payloadObject?["application"]) ??
            string(payloadObject?["app"]) ??
            string(dict["application"]) ??
            string(dict["app"])
        let component =
            string(payloadObject?["component"]) ??
            string(payloadObject?["comp"]) ??
            string(dict["component"]) ??
            string(dict["comp"])

        return LogEvent(
            timestamp: timestamp,
            category: category,
            subCategory: subCategory,
            payload: payloadString,
            level: level,
            sessionId: sessionId,
            application: application,
            component: component
        )
    }

    /// Coerce a JSON scalar into a String, ignoring containers and null.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Turn an arbitrary arg3 value into a compact JSON string. Objects and
    /// arrays are re-serialized with sorted keys; scalars are stringified;
    /// a missing value becomes an empty object.
    private static func serialize(_ rawValue: Any?) -> String {
        guard let value = rawValue, !(value is NSNull) else { return "{}" }
        switch value {
        case let s as String:
            return s
        case let container where JSONSerialization.isValidJSONObject(container):
            if let data = try? JSONSerialization.data(
                withJSONObject: container,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ), let string = String(data: data, encoding: .utf8) {
                return string
            }
            return "{}"
        case let n as NSNumber:
            return n.stringValue
        case let b as Bool:
            return b ? "true" : "false"
        default:
            return String(describing: value)
        }
    }
}
