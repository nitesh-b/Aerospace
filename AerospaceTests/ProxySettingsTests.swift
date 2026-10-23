//
//  ProxySettingsTests.swift
//  AerospaceTests
//
//  Covers proxy validation, the URLSession proxy dictionary, and persistence
//  of the app-wide proxy through APITesterStore.
//

import XCTest
@testable import Aerospace

final class ProxySettingsTests: XCTestCase {

    func testDisabledHasNoDictionary() {
        let settings = ProxySettings(isEnabled: false, host: "10.0.0.1", port: "8080")
        XCTAssertNil(settings.connectionProxyDictionary)
    }

    func testInvalidPortHasNoDictionary() {
        for port in ["", "abc", "0", "70000"] {
            let settings = ProxySettings(isEnabled: true, host: "10.0.0.1", port: port)
            XCTAssertFalse(settings.isValid, port)
            XCTAssertNil(settings.connectionProxyDictionary, port)
        }
    }

    func testBlankHostIsInvalid() {
        XCTAssertFalse(ProxySettings(isEnabled: true, host: "  ", port: "8080").isValid)
    }

    func testDictionaryRoutesHTTPAndHTTPS() throws {
        let settings = ProxySettings(isEnabled: true, host: " 10.0.0.1 ", port: "8080")
        let dict = try XCTUnwrap(settings.connectionProxyDictionary)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPEnable as String] as? Bool, true)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPProxy as String] as? String, "10.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPPort as String] as? Int, 8080)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSEnable as String] as? Bool, true)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSProxy as String] as? String, "10.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSPort as String] as? Int, 8080)
    }

    func testHostStripsPastedSchemeAndSlash() {
        let settings = ProxySettings(isEnabled: true, host: "http://proxy.corp/", port: "3128")
        XCTAssertEqual(settings.normalizedHost, "proxy.corp")
    }

    func testMakeSessionUsesSharedWhenDisabled() {
        XCTAssertTrue(APIClient.makeSession(proxy: ProxySettings()) === URLSession.shared)
    }

    func testMakeSessionAppliesProxy() {
        let settings = ProxySettings(isEnabled: true, host: "10.0.0.1", port: "8080")
        let session = APIClient.makeSession(proxy: settings)
        XCTAssertFalse(session === URLSession.shared)
        let dict = session.configuration.connectionProxyDictionary
        XCTAssertEqual(dict?[kCFNetworkProxiesHTTPSProxy as String] as? String, "10.0.0.1")
        session.invalidateAndCancel()
    }

    @MainActor
    func testStorePersistsProxy() throws {
        let suite = "test-\(UUID().uuidString)"
        let path = NSTemporaryDirectory() + "aerospace-proxy-\(UUID().uuidString).sqlite"
        let defaults = UserDefaults(suiteName: suite)!

        let store = APITesterStore(store: try SQLiteRequestStore(path: path), defaults: defaults)
        store.proxy = ProxySettings(isEnabled: true, host: "10.0.0.1", port: "8080")

        let reloaded = APITesterStore(store: try SQLiteRequestStore(path: path), defaults: defaults)
        XCTAssertEqual(reloaded.proxy, ProxySettings(isEnabled: true, host: "10.0.0.1", port: "8080"))
    }

    @MainActor
    func testSendFailsWhenProxyEnabledButInvalid() throws {
        let path = NSTemporaryDirectory() + "aerospace-proxy-\(UUID().uuidString).sqlite"
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let store = APITesterStore(store: try SQLiteRequestStore(path: path), defaults: defaults)
        store.newRequest()
        store.editing.urlString = "https://example.com"
        store.proxy = ProxySettings(isEnabled: true, host: "10.0.0.1", port: "")

        store.send()

        guard case .failure(let message)? = store.lastResponse?.outcome else {
            return XCTFail("expected a failure response")
        }
        XCTAssertTrue(message.contains("Proxy"))
        XCTAssertFalse(store.isSending)
    }
}
