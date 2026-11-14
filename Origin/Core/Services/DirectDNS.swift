import Darwin
import Foundation

/// 把用户填写的服务器地址展开成实际要尝试的连接。
/// 域名不走系统解析器：代理的 fake-ip 会把域名答成 198.18.0.0/15，连接进虚拟网卡后到不了局域网里的服务器。
/// 这里直接问公共 DNS，拿到真实地址后再连。解析失败时仍回退到用户原来填写的地址。
nonisolated enum ServerEndpoint {
    /// 真实 IP 在前，用户填写的原地址在最后。未写端口时再补上常见媒体服务器端口。
    static func candidates(for url: URL, alternatePorts: [Int] = [8096, 8005]) async -> [URL] {
        var result: [URL] = []
        for base in await bases(for: url) {
            for candidate in portVariants(of: base, alternatePorts: alternatePorts) where !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result.isEmpty ? [url] : result
    }

    /// 这个地址没有连上，可以换下一个候选。服务器已经有响应时返回 false，避免把密码错误当成换地址。
    static func isUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return true
        default:
            return false
        }
    }

    private static let resolvers = ["223.5.5.5", "119.29.29.29", "180.76.76.76"]

    private static func bases(for url: URL) async -> [URL] {
        guard let host = url.host(), !host.isEmpty else { return [url] }
        if isLiteralIP(host) || !host.contains(".") || host.lowercased().hasSuffix(".local") {
            return [url]
        }
        let addresses = await lookup(host)
        let rewritten = addresses.compactMap { replacingHost(of: url, with: $0) }
        guard !rewritten.isEmpty else { return [url] }
        return rewritten.contains(url) ? rewritten : rewritten + [url]
    }

    private static func portVariants(of url: URL, alternatePorts: [Int]) -> [URL] {
        guard !alternatePorts.isEmpty, url.port == nil,
              url.path().isEmpty || url.path() == "/",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        return [url] + alternatePorts.compactMap { port in
            components.port = port
            return components.url
        }
    }

    private static func replacingHost(of url: URL, with address: String) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else { return nil }
        var userinfo = ""
        if let user = components.percentEncodedUser {
            userinfo = user
            if let password = components.percentEncodedPassword { userinfo += ":\(password)" }
            userinfo += "@"
        }
        let host = address.contains(":") ? "[\(address)]" : address
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""
        return URL(string: "\(scheme)://\(userinfo)\(host)\(port)\(path)\(query)\(fragment)")
    }

    private static func lookup(_ name: String) async -> [String] {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            for server in resolvers {
                let found = resolve(trimmed, server: server)
                if !found.isEmpty { return found }
            }
            return []
        }.value
    }

    /// 向一台公共 DNS 查 A 和 AAAA。假 IP 和空地址丢掉，局域网 IPv4 排在前面。
    private static func resolve(_ name: String, server: String) -> [String] {
        let addresses = query(name, type: 1, server: server) + query(name, type: 28, server: server)
        var seen = Set<String>()
        let usable = addresses.filter { address in
            guard !isSynthetic(address), seen.insert(address).inserted else { return false }
            return true
        }
        return usable.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element)
            let right = rank(rhs.element)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func rank(_ address: String) -> Int {
        if isPrivateIPv4(address) { return 0 }
        if isIPv4(address) { return 1 }
        return 2
    }

    private static func isLiteralIP(_ host: String) -> Bool {
        isIPv4(host) || isIPv6(host)
    }

    private static func isIPv4(_ address: String) -> Bool {
        var addr = in_addr()
        return address.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    private static func isIPv6(_ address: String) -> Bool {
        var addr = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    /// 198.18.0.0/15 是网络基准测试地址，也被代理用来做 fake-ip。
    private static func isSynthetic(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0 ... 255).contains($0) }) else { return false }
        if parts[0] == 0 { return true }
        return parts[0] == 198 && (parts[1] == 18 || parts[1] == 19)
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16 ... 31).contains(parts[1]) { return true }
        return false
    }

    private static func query(_ name: String, type: UInt16, server: String) -> [String] {
        let id = UInt16.random(in: 0 ... UInt16.max)
        guard let packet = message(id: id, name: name, type: type),
              let response = exchange(packet, server: server) else { return [] }
        return parse(response, id: id)
    }

    private static func message(id: UInt16, name: String, type: UInt16) -> Data? {
        var data = Data()
        data.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xff)])
        data.append(contentsOf: [0x01, 0x00]) // 递归查询
        data.append(contentsOf: [0x00, 0x01]) // 一个问题
        data.append(contentsOf: [0, 0, 0, 0, 0, 0])
        for label in name.split(separator: ".") where !label.isEmpty {
            let bytes = Array(label.utf8)
            guard bytes.count <= 63 else { return nil }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
        data.append(contentsOf: [UInt8(type >> 8), UInt8(type & 0xff), 0x00, 0x01])
        return data
    }

    private static func exchange(_ packet: Data, server: String) -> Data? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(53).bigEndian)
        guard inet_pton(AF_INET, server, &address.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { endpoint in
                Darwin.connect(fd, endpoint, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let sent = packet.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.send(fd, base, raw.count, 0)
        }
        guard sent == packet.count else { return nil }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 1200) > 0, descriptor.revents & Int16(POLLIN) != 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let received = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard received >= 12 else { return nil }
        return Data(buffer.prefix(received))
    }

    private static func parse(_ data: Data, id: UInt16) -> [String] {
        guard data.count >= 12, read16(data, 0) == id else { return [] }
        let flags = read16(data, 2)
        guard flags & 0x000F == 0 else { return [] }
        let questions = Int(read16(data, 4))
        let answers = Int(read16(data, 6))
        var offset = 12
        for _ in 0 ..< questions {
            guard skipName(data, &offset), offset + 4 <= data.count else { return [] }
            offset += 4
        }
        var addresses: [String] = []
        for _ in 0 ..< answers {
            guard skipName(data, &offset), offset + 10 <= data.count else { break }
            let type = read16(data, offset)
            let length = Int(read16(data, offset + 8))
            offset += 10
            guard offset + length <= data.count else { break }
            if type == 1, length == 4 {
                addresses.append(data[offset ..< offset + 4].map(String.init).joined(separator: "."))
            } else if type == 28, length == 16, let text = formatIPv6(data[offset ..< offset + 16]) {
                addresses.append(text)
            }
            offset += length
        }
        return addresses
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func skipName(_ data: Data, _ offset: inout Int) -> Bool {
        var cursor = offset
        var end = offset
        var jumped = false
        var jumps = 0
        while cursor < data.count {
            let length = Int(data[cursor])
            if length == 0 {
                if !jumped { end = cursor + 1 }
                offset = end
                return true
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < data.count else { return false }
                if !jumped { end = cursor + 2 }
                let pointer = ((length & 0x3F) << 8) | Int(data[cursor + 1])
                guard pointer < data.count, jumps < 8 else { return false }
                cursor = pointer
                jumped = true
                jumps += 1
                continue
            }
            guard length & 0xC0 == 0 else { return false }
            cursor += 1 + length
            if !jumped { end = cursor }
        }
        return false
    }

    private static func formatIPv6(_ bytes: Data.SubSequence) -> String? {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { destination in
            for (index, byte) in bytes.enumerated() where index < destination.count {
                destination[index] = byte
            }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
