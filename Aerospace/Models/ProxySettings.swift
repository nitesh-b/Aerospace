//
//  ProxySettings.swift
//  Aerospace
//
//  App-wide HTTP/HTTPS proxy for the API tester (e.g. a corporate proxy that
//  GlobalProtect requires). When enabled and valid, every request is routed
//  through `host:port`; otherwise requests go direct / via the system proxy.
//

import Foundation

nonisolated struct ProxySettings: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var host: String
    /// Kept as text so the editor can hold partial / invalid input.
    var port: String

    init(isEnabled: Bool = false, host: String = "", port: String = "") {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
    }

    /// The host with surrounding whitespace and any pasted `http://` /
    /// `https://` scheme or trailing slash removed.
    var normalizedHost: String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where value.lowercased().hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(value) else { return nil }
        return value
    }

    var isValid: Bool { !normalizedHost.isEmpty && portNumber != nil }

    /// A `URLSessionConfiguration.connectionProxyDictionary` routing both HTTP
    /// and HTTPS through the proxy, or nil when disabled or invalid.
    var connectionProxyDictionary: [AnyHashable: Any]? {
        guard isEnabled, isValid, let portNumber else { return nil }
        return [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: normalizedHost,
            kCFNetworkProxiesHTTPPort as String: portNumber,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: normalizedHost,
            kCFNetworkProxiesHTTPSPort as String: portNumber,
        ]
    }
}
