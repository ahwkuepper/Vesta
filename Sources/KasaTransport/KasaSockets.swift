// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import KasaKit

/// Blocking BSD work is confined to detached utility tasks with a single deadline.
/// No socket or response can outlive a read indefinitely.
enum KasaSockets {
    static func discovery() async throws -> [KasaDevice] {
        try await Task.detached(priority: .utility) { try scan() }.value
    }

    private static func scan() throws -> [KasaDevice] {
        let subnets = LocalNetwork.subnets()
        guard !subnets.isEmpty else { throw KasaError.localNetwork }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw KasaError.localNetwork }
        defer { close(fd) }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw KasaError.localNetwork }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var local = LocalNetwork.endpoint(0, port: 0)
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw KasaError.localNetwork }
        let legacy = KasaCrypto.xorEncode(Data(#"{"system":{"get_sysinfo":{}}}"#.utf8))
        let modern = Data([2,0,0,1,0,0,0,0,0,0,0,0,0x46,0x3c,0xb5,0xd3])
        let current = try KasaCrypto.discoveryProbe()
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + 4_000_000_000
        var lastRound = -1
        var sent = false
        var found: [String: KasaDevice] = [:]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let round = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
            if round != lastRound && round < 3 {
                lastRound = round
                for subnet in subnets {
                    for (port, payload) in [(UInt16(9999), legacy), (UInt16(20002), modern), (UInt16(20002), current)] {
                        var target = LocalNetwork.endpoint(subnet.broadcast, port: port)
                        let count = payload.withUnsafeBytes { bytes in
                            withUnsafePointer(to: &target) { pointer in
                                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                        if count == payload.count { sent = true }
                    }
                }
            }
            var pollfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollfd, 1, 150) > 0 else { continue }
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0, count < buffer.count, found.count < 256 else { continue }
            let address = UInt32(bigEndian: sender.sin_addr.s_addr)
            guard LocalNetwork.privateAddress(address), subnets.contains(where: { $0.contains(address) }) else { continue }
            let port = UInt16(bigEndian: sender.sin_port)
            guard port == 9999 || port == 20002 else { continue }
            let host = LocalNetwork.string(address)
            // Broadcast domains contain unrelated and occasionally malformed datagrams.
            guard let device = try? KasaCoding.discovery(Data(buffer.prefix(count)), host: host, port: port) else { continue }
            if found[host]?.transport == .klap && device.transport == .xor { continue }
            found[host] = device
        }
        guard sent else { throw KasaError.localNetwork }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func exchange(host: String, payload: Data) async throws -> Data {
        try await Task.detached(priority: .utility) { try tcp(host: host, payload: payload) }.value
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw KasaError.unavailable }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let remaining = Int32(min((deadline - now) / 1_000_000 + 1, 5000))
            let result = poll(&descriptor, 1, remaining)
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & events != 0 else { throw KasaError.unavailable }
            return
        }
    }

    private static func tcp(host: String, payload: Data) throws -> Data {
        try LocalNetwork.requireLocal(host)
        guard let address = LocalNetwork.parse(host), payload.count <= KasaCoding.limit else { throw KasaError.localNetwork }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw KasaError.unavailable }
        defer { close(fd) }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var target = LocalNetwork.endpoint(address, port: 9999)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 || errno == EINPROGRESS else { throw KasaError.unavailable }
        try wait(fd, events: Int16(POLLOUT), until: deadline)
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw KasaError.unavailable }
        let bytes = KasaCrypto.bigEndian(UInt32(payload.count)) + KasaCrypto.xorEncode(payload)
        var written = 0
        while written < bytes.count {
            try wait(fd, events: Int16(POLLOUT), until: deadline)
            let count = bytes.withUnsafeBytes { send(fd, $0.baseAddress?.advanced(by: written), bytes.count - written, 0) }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw KasaError.unavailable }
            written += count
        }
        func read(_ count: Int) throws -> Data {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: min(count, 8192))
            while data.count < count {
                try wait(fd, events: Int16(POLLIN), until: deadline)
                let received = recv(fd, &chunk, min(chunk.count, count - data.count), 0)
                if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard received > 0 else { throw KasaError.unavailable }
                data.append(contentsOf: chunk.prefix(received))
            }
            return data
        }
        let length = Int(try KasaCrypto.number(read(4)))
        guard length > 0, length <= KasaCoding.limit else { throw KasaError.invalidResponse }
        return KasaCrypto.xorDecode(try read(length))
    }
}
