// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import KasaKit

/// No DNS, redirects, proxy routing, or public destinations. Every connection is
/// rechecked against a private IPv4 subnet attached to an active local interface.
enum LocalNetwork {
    struct Subnet: Sendable {
        let address: UInt32
        let mask: UInt32
        var broadcast: UInt32 { address | ~mask }
        func contains(_ value: UInt32) -> Bool {
            (value & mask) == (address & mask) && value != broadcast && value != (address & mask)
        }
    }

    static func parse(_ host: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func privateAddress(_ address: UInt32) -> Bool {
        address >> 24 == 10 || address >> 20 == 0xac1 || address >> 16 == 0xc0a8 || address >> 16 == 0xa9fe
    }

    static func string(_ address: UInt32) -> String {
        [24,16,8,0].map { String((address >> $0) & 255) }.joined(separator: ".")
    }

    static func subnets() -> [Subnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }
        var result: [Subnet] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let entry = item.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if privateAddress(ip) { result.append(Subnet(address: ip, mask: bits)) }
        }
        return result
    }

    static func requireLocal(_ host: String) throws {
        guard let address = parse(host), privateAddress(address), subnets().contains(where: { $0.contains(address) }) else {
            throw KasaError.localNetwork
        }
    }

    static func endpoint(_ address: UInt32, port: UInt16) -> sockaddr_in {
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = port.bigEndian
        endpoint.sin_addr.s_addr = address.bigEndian
        return endpoint
    }
}
