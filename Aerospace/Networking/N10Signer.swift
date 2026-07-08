//
//  N10Signer.swift
//  Aerospace
//
//  Reproduces the Network Ten signed-request scheme used by the 10play iOS app:
//  an HMAC-SHA256 signature over "<unixSeconds>:<url>" (keyed by the hex-decoded
//  API key) plus the identifying User-Agent / X-Network-Ten-App headers. Pure
//  and deterministic (the timestamp is injected) so it can be unit-tested.
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
    static let userAgentHeader = "User-Agent"
    static let appHeader = "X-Network-Ten-App"

    /// "10play/<appVersion> <systemName> <systemVersion> UAP"
    func userAgent(_ device: DeviceInfo) -> String {
        "10play/\(device.appVersion) \(device.systemName) \(device.systemVersion) UAP"
    }

    /// The full set of headers to attach to a request, given the FINAL request
    /// URL (query params included) and the current timestamp in whole seconds.
    func headers(finalURL: String, apiKeyHex: String, device: DeviceInfo, timestamp: Int)
        -> [String: String] {
        let ua = userAgent(device)
        return [
            Self.signatureHeader: signatureHeaderValue(timestamp: timestamp,
                                                        url: finalURL, apiKeyHex: apiKeyHex),
            Self.userAgentHeader: ua,
            Self.appHeader: ua,
        ]
    }

    /// The value of X-N10-SIG: "<timestamp>_<hmacHex>".
    func signatureHeaderValue(timestamp: Int, url: String, apiKeyHex: String) -> String {
        let message = "\(timestamp):\(url)"
        return "\(timestamp)_\(Self.hmacSHA256Hex(message: message, keyHex: apiKeyHex))"
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
