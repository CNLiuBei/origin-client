import Darwin
import Foundation
import Network

/// 保存用户填写的域名。连接时用系统解析出的全部地址一起试，谁先返回 HTTP 就用谁。
/// 这样蜂窝网上连不上的私网 IPv4 不会挡住已经能通的 IPv6。备用线路仍按填写顺序尝试。
nonisolated enum ServerEndpoint {
    /// 保留用户填写的地址。未写端口时再补上常见媒体服务器端口。
    static func candidates(for url: URL, alternatePorts: [Int] = [8096, 8005]) async -> [URL] {
        var result: [URL] = []
        for base in await bases(for: url) {
            for candidate in portVariants(of: base, alternatePorts: alternatePorts) where !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result.isEmpty ? [url] : result
    }

    /// 备用地址按顺序试。同一个域名解析出的 IPv4 和 IPv6 同时试，先连上的胜出。
    static func firstReachable<T: Sendable>(
        _ urls: [URL],
        isMiss: @escaping @Sendable (Error) -> Bool = { isUnreachable($0) },
        attempt: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        guard !urls.isEmpty else { throw URLError(.cannotConnectToHost) }
        var lastError: Error = URLError(.cannotConnectToHost)
        for url in urls {
            let targets = await connectionTargets(for: url)
            do {
                return try await race(targets, isMiss: isMiss, attempt: attempt)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                if isMiss(error) {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    /// 同一个服务器地址的几种写法（HTTP、HTTPS、默认端口）同时试，先通的胜出。
    /// 不像备用线路那样按顺序等：家宽常封 80、443，逐个等超时会拖很久。
    /// 都没通时，优先抛出服务器明确给出的错误（如密码错误、类型不对），其次才是连不上。
    static func firstReachableAmong<T: Sendable>(
        _ urls: [URL],
        isMiss: @escaping @Sendable (Error) -> Bool = { isUnreachable($0) },
        attempt: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        guard urls.count > 1 else { return try await firstReachable(urls, isMiss: isMiss, attempt: attempt) }
        return try await withThrowingTaskGroup(of: Result<T, Error>.self) { group in
            for url in urls {
                group.addTask {
                    do {
                        return .success(try await firstReachable([url], isMiss: isMiss, attempt: attempt))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var definitive: Error?
            var miss: Error?
            for try await outcome in group {
                switch outcome {
                case let .success(value):
                    group.cancelAll()
                    return value
                case let .failure(error):
                    if error is CancellationError { continue }
                    if isMiss(error) {
                        miss = miss ?? error
                    } else {
                        definitive = definitive ?? error
                    }
                }
            }
            try Task.checkCancellation()
            throw definitive ?? miss ?? URLError(.cannotConnectToHost)
        }
    }

    /// 主地址在前，备用地址在后。每个域名下的地址同时探测。
    static func reachable(
        for url: URL,
        alternates: [URL] = [],
        timeout: TimeInterval = 4,
        allowsInsecureTLS: Bool = false,
        excluding: Set<String> = []
    ) async -> URL {
        var ordered: [URL] = []
        for seed in [url] + alternates {
            let options = await candidates(for: seed, alternatePorts: [])
            for option in options where !ordered.contains(option) && !excluding.contains(option.absoluteString) {
                ordered.append(option)
            }
        }
        let budget = min(max(timeout, 4), 8)
        if let winner = try? await firstReachable(ordered, attempt: { endpoint in
            guard await OriginTrust.responds(endpoint, timeout: budget, allowsInsecure: allowsInsecureTLS, direct: bypassesProxy(endpoint)) else {
                throw URLError(.cannotConnectToHost)
            }
            return endpoint
        }) {
            return winner
        }
        return url
    }

    /// 用户直接填写的 IP 不走系统代理。从域名解析出来的地址仍走普通连接，和浏览器一致。
    static func bypassesProxy(_ url: URL) -> Bool {
        let host = url.host() ?? ""
        guard isLiteralIP(host) else { return false }
        return ServerRoute.shared.certificateHost(for: host) == nil
    }

    /// 给解析出来的 IP 记一下原来的域名，请求时放进 Host。
    static func authority(for url: URL) -> String? {
        let host = url.host() ?? ""
        guard isLiteralIP(host), let domain = ServerRoute.shared.certificateHost(for: host) else { return nil }
        if let port = url.port, port != 80, port != 443 { return "\(domain):\(port)" }
        return domain
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if isIPv4(host) { return isPrivateIPv4(host) }
        if isIPv6(host) { return isNonGlobalIPv6(host) }
        return false
    }

    /// 保存用户填写的域名。只有对方本来就是 IP 时，才记下实际连上的地址。
    static func addressToStore(entered: URL, reached: URL) -> URL {
        guard let host = entered.host(), !isLiteralIP(host) else { return reached }
        return replacingHost(of: reached, with: host) ?? entered
    }

    /// 把已经生成的播放地址改到当前选中的连接上。
    static func redirect(_ url: URL, through route: URL) -> URL {
        guard let host = route.host() else { return url }
        if url.host()?.caseInsensitiveCompare(host) == .orderedSame, url.port == route.port, url.scheme == route.scheme {
            return url
        }
        return replacingHost(of: url, with: host, port: route.port, scheme: route.scheme, replacePort: true) ?? url
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

    private static func bases(for url: URL) async -> [URL] {
        [url]
    }

    /// 系统解析器给出的地址。代理 fake-ip 丢掉，私网地址保留。
    private static func connectionTargets(for url: URL) async -> [URL] {
        guard let host = url.host(), !host.isEmpty, !isLiteralIP(host) else { return [url] }
        let addresses = await Task.detached(priority: .userInitiated) {
            systemAddresses(host).filter { !isSynthetic($0) }
        }.value
        var result: [URL] = []
        for address in addresses {
            guard let rewritten = replacingHost(of: url, with: address), !result.contains(rewritten) else { continue }
            ServerRoute.shared.useCertificateHost(host, for: address)
            if let normalized = rewritten.host() {
                ServerRoute.shared.useCertificateHost(host, for: normalized)
            }
            result.append(rewritten)
        }
        return result.isEmpty ? [url] : result
    }

    private static func systemAddresses(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var info: UnsafeMutablePointer<addrinfo>?
        guard host.withCString({ getaddrinfo($0, nil, &hints, &info) }) == 0, let info else { return [] }
        defer { freeaddrinfo(info) }
        var results: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = current.pointee.ai_addr,
               getnameinfo(address, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                var text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
                if !text.isEmpty, !results.contains(text) { results.append(text) }
            }
            cursor = current.pointee.ai_next
        }
        return results
    }

    private static func race<T: Sendable>(
        _ urls: [URL],
        isMiss: @escaping @Sendable (Error) -> Bool,
        attempt: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        guard !urls.isEmpty else { throw URLError(.cannotConnectToHost) }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            for url in urls {
                group.addTask {
                    do {
                        return try await attempt(url)
                    } catch is CancellationError {
                        return nil
                    } catch let error as URLError where error.code == .cancelled {
                        return nil
                    } catch {
                        if isMiss(error) { return nil }
                        throw error
                    }
                }
            }
            while let value = try await group.next() {
                if let value {
                    group.cancelAll()
                    return value
                }
            }
            throw URLError(.cannotConnectToHost)
        }
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

    private static func replacingHost(of url: URL, with address: String, port: Int? = nil, scheme overrideScheme: String? = nil, replacePort: Bool = false) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = overrideScheme ?? components.scheme else { return nil }
        var userinfo = ""
        if let user = components.percentEncodedUser {
            userinfo = user
            if let password = components.percentEncodedPassword { userinfo += ":\(password)" }
            userinfo += "@"
        }
        let host = address.contains(":") ? "[\(address)]" : address
        let portValue = replacePort ? port : (port ?? components.port)
        let portText = portValue.map { ":\($0)" } ?? ""
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""
        return URL(string: "\(scheme)://\(userinfo)\(host)\(portText)\(path)\(query)\(fragment)")
    }

    static func isLiteralIP(_ host: String) -> Bool {
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

    /// 198.18.0.0/15 和 fdfe:dcba:9876::/48 是代理 fake-ip，连过去到不了服务器。
    private static func isSynthetic(_ address: String) -> Bool {
        if isIPv6(address) {
            var bytes = [UInt8](repeating: 0, count: 16)
            let parsed = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return address.withCString { inet_pton(AF_INET6, $0, base) == 1 }
            }
            guard parsed else { return false }
            return bytes[0] == 0xfd && bytes[1] == 0xfe && bytes[2] == 0xdc && bytes[3] == 0xba && bytes[4] == 0x98 && bytes[5] == 0x76
        }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 0 { return true }
        return parts[0] == 198 && (parts[1] == 18 || parts[1] == 19)
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16 ... 31).contains(parts[1]) { return true }
        return false
    }

    /// 链路本地、唯一本地和环回地址出了局域网就不可达。
    private static func isNonGlobalIPv6(_ host: String) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16)
        let parsed = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return host.withCString { inet_pton(AF_INET6, $0, base) == 1 }
        }
        guard parsed else { return false }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        if bytes[0] & 0xfe == 0xfc { return true }
        return bytes.allSatisfy { $0 == 0 } || bytes == [UInt8](repeating: 0, count: 15) + [1]
    }
}

/// 记住当前选用的线路。换网卡或蜂窝网络后重新按顺序探测。
nonisolated final class ServerRoute: @unchecked Sendable {
    static let shared = ServerRoute()

    private struct Entry {
        var generation: Int
        var url: URL
    }

    private let lock = NSLock()
    private var routes: [String: Entry] = [:]
    private var excluded: [String: Set<String>] = [:]
    private var certificateHosts: [String: String] = [:]
    private var generation = 0
    private var pathSignature: String?
    private let rememberedKey = "origin.remoteEndpoints"
    private let monitor: NWPathMonitor

    private init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.note(path)
        }
        monitor.start(queue: DispatchQueue(label: "origin.server-route"))
    }

    func cached(_ url: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = routes[url.absoluteString], entry.generation == generation else { return nil }
        return entry.url
    }

    func resolve(
        _ url: URL,
        timeout: TimeInterval = 4,
        allowsInsecureTLS: Bool = false,
        alternates: [URL] = []
    ) async -> URL {
        let seen = currentGeneration()
        if let cached = cached(url) { return cached }
        let chosen = await ServerEndpoint.reachable(
            for: url,
            alternates: alternates + remembered(for: url),
            timeout: timeout,
            allowsInsecureTLS: allowsInsecureTLS,
            excluding: excludedAddresses(for: url)
        )
        store(chosen, for: url, generation: seen)
        return cached(url) ?? chosen
    }

    func invalidate(_ url: URL, excluding chosen: URL? = nil) {
        lock.lock()
        routes[url.absoluteString] = nil
        if let chosen {
            var set = excluded[url.absoluteString] ?? []
            set.insert(chosen.absoluteString)
            excluded[url.absoluteString] = set
        }
        lock.unlock()
    }

    /// 在局域网连上后记下公网地址，换到蜂窝网络时还能再试。
    func remember(_ remote: URL, for stored: URL) {
        guard let host = remote.host(), !host.isEmpty, !ServerEndpoint.isPrivateHost(host) else { return }
        if remote.host()?.caseInsensitiveCompare(stored.host() ?? "") == .orderedSame,
           remote.port == stored.port, remote.scheme == stored.scheme { return }
        var map = UserDefaults.standard.dictionary(forKey: rememberedKey) as? [String: [String]] ?? [:]
        var list = map[stored.absoluteString] ?? []
        let text = remote.absoluteString
        guard !list.contains(text) else { return }
        list.append(text)
        map[stored.absoluteString] = list
        UserDefaults.standard.set(map, forKey: rememberedKey)
    }

    func remembered(for stored: URL) -> [URL] {
        let map = UserDefaults.standard.dictionary(forKey: rememberedKey) as? [String: [String]] ?? [:]
        return (map[stored.absoluteString] ?? []).compactMap(URL.init(string:))
    }

    func useCertificateHost(_ domain: String, for address: String) {
        lock.lock()
        certificateHosts[address.lowercased()] = domain
        lock.unlock()
    }

    func certificateHost(for address: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return certificateHosts[address.lowercased()]
    }

    /// 选一个当前能连上的地址，请求失败且像是网络不通时再选一次。
    func perform<T>(
        stored: URL,
        timeout: TimeInterval,
        allowsInsecureTLS: Bool = false,
        alternates: [URL] = [],
        register: (URL) -> Void,
        _ body: () async throws -> T
    ) async throws -> T {
        let first = await resolve(stored, timeout: timeout, allowsInsecureTLS: allowsInsecureTLS, alternates: alternates)
        register(first)
        do {
            return try await body()
        } catch {
            guard ServerEndpoint.isUnreachable(error) else { throw error }
            invalidate(stored, excluding: first)
            let second = await resolve(stored, timeout: timeout, allowsInsecureTLS: allowsInsecureTLS, alternates: alternates)
            register(second)
            guard second != first else { throw error }
            return try await body()
        }
    }

    private func excludedAddresses(for url: URL) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return excluded[url.absoluteString] ?? []
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func store(_ chosen: URL, for url: URL, generation seen: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard seen == generation else { return }
        routes[url.absoluteString] = Entry(generation: seen, url: chosen)
    }

    private func note(_ path: NWPath) {
        let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        let next = "\(path.status)|\(path.supportsIPv4)|\(path.supportsIPv6)|\(path.isExpensive)|\(path.isConstrained)|\(interfaces)"
        lock.lock()
        let previous = pathSignature
        pathSignature = next
        if previous != nil, previous != next {
            generation += 1
            routes.removeAll()
            excluded.removeAll()
        }
        lock.unlock()
    }
}

