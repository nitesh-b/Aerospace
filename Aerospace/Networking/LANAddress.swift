//
//  LANAddress.swift
//  Aerospace
//
//  This Mac's address as seen from other devices on the same network, for
//  URLs handed to TVs, phones and emulators.
//

import Foundation
import Darwin

nonisolated enum LANAddress {
    /// First non-loopback IPv4 address on an active interface (e.g. en0).
    static func current() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                      &host, socklen_t(host.count),
                                      nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }
}
