//
//  N10Signer.swift
//  Aerospace
//
//  Reproduces the Network Ten signed-request scheme used by the 10play app.
//  Signing is method-dependent: GET requests get an HMAC-SHA256 signature
//  over "<unixSeconds>:<url>" (X-N10-SIG); POST requests get a base64-encoded
//  UTC timestamp token instead (X-Network-Ten-Auth), no HMAC; every other
//  method gets neither. X-Network-Ten-App is only sent when the device
//  identifies as tvOS. Pure and deterministic (the timestamp is injected) so
//  it can be unit-tested.
//

import Foundation
import CryptoKit

nonisolated struct N10Signer: Sendable {

    /// The device identity embedded in the User-Agent. On iOS these come from
    /// UIDevice; here they are user-supplied so a macOS client can mimic the app.
    nonisolated struct DeviceInfo: Sendable, Equatable {
        var appVersion: String
        var systemName: String
        var systemVersion: String
    }

    /// The headers the 10play app sends. Names match the iOS implementation.
    static let signatureHeader = "X-N10-SIG"
    static let authTokenHeader = "X-Network-Ten-Auth"
    static let userAgentHeader = "User-Agent"
    static let appHeader = "X-Network-Ten-App"

    /// "10play/<appVersion> <systemName> <systemVersion> UAP"
    func userAgent(_ device: DeviceInfo) -> String {
        "10play/\(device.appVersion) \(device.systemName) \(device.systemVersion) UAP"
    }

    /// True when the device identity indicates the 10play Apple TV app.
    static func isAppleTV(_ device: DeviceInfo) -> Bool {
        device.systemName.caseInsensitiveCompare("tvOS") == .orderedSame
    }

    /// The full set of headers to attach to a request, given the request's
    /// HTTP method, its FINAL URL (query params included), and the current
    /// timestamp in whole seconds. User-Agent is always included; the
    /// signature header is method-dependent (see type documentation above).
    func headers(method: HTTPMethod, finalURL: String, apiKeyHex: String, device: DeviceInfo,
                timestamp: Int) -> [String: String] {
        let ua = userAgent(device)
        var result: [String: String] = [Self.userAgentHeader: ua]

        if Self.isAppleTV(device) {
            result[Self.appHeader] = ua
        }

        switch method {
        case .get:
            result[Self.signatureHeader] = signatureHeaderValue(
                timestamp: timestamp, url: finalURL, apiKeyHex: apiKeyHex)
        case .post:
            result[Self.authTokenHeader] = authTokenHeaderValue(timestamp: timestamp)
        case .put, .patch, .delete:
            break
        }

        return result
    }

    /// The value of X-N10-SIG: "<timestamp>_<hmacHex>".
    func signatureHeaderValue(timestamp: Int, url: String, apiKeyHex: String) -> String {
        let message = "\(timestamp):\(url)"
        return "\(timestamp)_\(Self.hmacSHA256Hex(message: message, keyHex: apiKeyHex))"
    }

    /// The value of X-Network-Ten-Auth: base64("yyyyMMddHHmmss") in UTC.
    func authTokenHeaderValue(timestamp: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let raw = String(format: "%04d%02d%02d%02d%02d%02d",
                         c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return Data(raw.utf8).base64EncodedString()
    }

    // MARK: - Primitives (static, so they can be tested against known vectors)

    /// Lowercase-hex HMAC-SHA256 of `message` (UTF-8) keyed by the bytes decoded
    /// from `keyHex`.
    static func hmacSHA256Hex(message: String, keyHex: String) -> String {
        let key = SymmetricKey(data: hexDecode(keyHex))
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Decode a hex string into bytes. Whitespace and an optional "0x" prefix are
    /// ignored; a trailing half-byte is dropped.
    static func hexDecode(_ hex: String) -> Data {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        cleaned = cleaned.filter { !$0.isWhitespace }

        var data = Data()
        data.reserveCapacity(cleaned.count / 2)
        var iterator = cleaned.makeIterator()
        while let hi = iterator.next(), let lo = iterator.next() {
            guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { continue }
            data.append(UInt8(h << 4 | l))
        }
        return data
    }
}
