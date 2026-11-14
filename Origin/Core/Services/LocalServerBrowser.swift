import Darwin
import Foundation
import Network
import Observation

/// 局域网中通过 Bonjour 广播的媒体服务器
struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: ServerKind
    /// 解析出的地址与端口，如 10.10.10.10:8005。IPv6 带方括号。解析完成前为空。
    var address: String
    /// Bonjour 实例名，用来判断服务是否还在。
    var instanceKey: String
}

/// 飞牛影视与 Plex 用 Bonjour，Jellyfin 与 Emby 用 7359 端口的 UDP 广播。
/// 浏览放在后台执行，避免结果卡在主线程的界面动画后面。
/// Bonjour 地址用 NWConnection 在服务所在的网卡上同时问 IPv4 和 IPv6，不等待收到数据。
@Observable
final class LocalServerBrowser {
    private(set) var servers: [DiscoveredServer] = []
    private(set) var isSearching = false

    @ObservationIgnored private var browseTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lookups: [String: AddressLookup] = [:]
    @ObservationIgnored private var searchingTask: Task<Void, Never>?
    @ObservationIgnored private var broadcast: BroadcastFinder?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var pending: [String: PendingServer] = [:]
    @ObservationIgnored private var probing: Set<String> = []
    /// 只撤销 Bonjour 发现的条目。UDP 广播用另一套标识，不能被 Bonjour 的刷新删掉。
    @ObservationIgnored private var bonjourIDs: Set<String> = []

    private static let serviceTypes: [(String, ServerKind)] = [
        ("_trim_media._tcp", .fnos),
        ("_plexmediasvr._tcp", .plex),
    ]

    func start() {
        guard browseTasks.isEmpty else { return }
        isSearching = true
        session = UUID()
        if servers.isEmpty { servers = Self.cachedServers() }
        for (type, kind) in Self.serviceTypes {
            browseTasks.append(Task(priority: .userInitiated) { [weak self] in
                await self?.browse(type: type, kind: kind)
            })
        }
        let finder = BroadcastFinder()
        broadcast = finder
        let token = session
        finder.start { [weak self] announcement in
            Task { @MainActor in
                guard let self, self.session == token else { return }
                self.adopt(announcement)
            }
        }
        searchingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.isSearching = false
        }
    }

    func restart() {
        stop()
        servers.removeAll()
        start()
    }

    func stop() {
        session = UUID()
        searchingTask?.cancel()
        searchingTask = nil
        browseTasks.forEach { $0.cancel() }
        browseTasks.removeAll()
        lookups.values.forEach { $0.cancel() }
        lookups.removeAll()
        broadcast?.cancel()
        broadcast = nil
        pending.removeAll()
        probing.removeAll()
        bonjourIDs.removeAll()
        isSearching = false
    }

    /// 必须离开主线程。nonisolated async 会沿用调用方的 MainActor，结果就会排在界面动画后面。
    @concurrent
    private func browse(type: String, kind: ServerKind) async {
        let browser = NetworkBrowser(for: .bonjour(type, domain: "local."))
        do {
            try await browser.run { endpoints in
                if Task.isCancelled { throw CancellationError() }
                await self.handle(Self.candidates(in: endpoints), kind: kind)
            }
        } catch is CancellationError {
            return
        } catch {
            await self.noteSearchFailed()
        }
    }

    private func noteSearchFailed() {
        isSearching = false
    }

    private func handle(_ found: [ServiceCandidate], kind: ServerKind) {
        if !found.isEmpty {
            isSearching = false
            let alive = Set(found.map(\.instanceName))
            let gone = Set(servers.compactMap { server -> String? in
                guard bonjourIDs.contains(server.id), server.kind == kind, !alive.contains(server.instanceKey) else { return nil }
                return server.id
            })
            for id in gone {
                lookups[id]?.cancel()
                lookups[id] = nil
                bonjourIDs.remove(id)
            }
            servers.removeAll { gone.contains($0.id) }
            for (id, server) in pending where server.kind == kind && !alive.contains(server.instanceKey) {
                lookups[id]?.cancel()
                lookups[id] = nil
                pending[id] = nil
                bonjourIDs.remove(id)
            }
        }

        for candidate in found.sorted(by: { $0.rank < $1.rank }) {
            let id = "\(kind.rawValue)|\(candidate.instanceName)"
            let cached = AddressCache.address(for: id)
            if let cached, DiscoveryAddress.same(cached, in: servers, except: id) { continue }
            bonjourIDs.insert(id)
            if !servers.contains(where: { $0.id == id }), pending[id] == nil {
                if let cached, !cached.isEmpty {
                    servers.append(DiscoveredServer(
                        id: id,
                        name: Self.displayName(candidate.instanceName, kind: kind),
                        kind: kind,
                        address: cached,
                        instanceKey: candidate.instanceName
                    ))
                } else {
                    pending[id] = PendingServer(
                        name: Self.displayName(candidate.instanceName, kind: kind),
                        kind: kind,
                        instanceKey: candidate.instanceName
                    )
                }
            }
            guard lookups[id] == nil else { continue }
            let lookup = AddressLookup()
            lookups[id] = lookup
            lookup.start(endpoint: candidate.endpoint, interface: candidate.interface) { [weak self] address in
                Task { @MainActor in
                    if self?.pending[id] != nil {
                        self?.reveal(id, address: address)
                    } else {
                        self?.store(address, for: id)
                    }
                }
            }
        }
    }

    /// UDP 广播的应答里已经带了地址。先确认它是 Jellyfin、Emby 还是飞牛，再放进列表。
    private func adopt(_ announcement: BroadcastAnnouncement) {
        guard !DiscoveryAddress.same(announcement.address, in: servers, except: nil) else { return }
        guard probing.insert(announcement.id).inserted else { return }
        let token = session
        Task { [weak self] in
            let result = try? await JellyfinClient.probe(baseURL: announcement.url, timeout: 2)
            await MainActor.run {
                guard let self else { return }
                self.probing.remove(announcement.id)
                guard self.session == token, let (kind, info) = result else { return }
                guard !DiscoveryAddress.same(announcement.address, in: self.servers, except: nil) else { return }
                let id = "\(kind.rawValue)|\(announcement.id)"
                guard !self.servers.contains(where: { $0.id == id }) else { return }
                let trimmed = announcement.name.trimmingCharacters(in: .whitespacesAndNewlines)
                self.servers.append(DiscoveredServer(
                    id: id,
                    name: trimmed.isEmpty ? (info.serverName ?? kind.displayName) : trimmed,
                    kind: kind,
                    address: announcement.address,
                    instanceKey: announcement.id
                ))
                AddressCache.store(announcement.address, for: id)
                self.isSearching = false
            }
        }
    }

    private func reveal(_ id: String, address: String) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        lookups[id]?.cancel()
        lookups[id] = nil
        guard !DiscoveryAddress.same(address, in: servers, except: id) else { return }
        servers.append(DiscoveredServer(
            id: id,
            name: pending.name,
            kind: pending.kind,
            address: address,
            instanceKey: pending.instanceKey
        ))
        AddressCache.store(address, for: id)
        isSearching = false
    }

    /// 上次见过的服务器。打开页面时先显示，这一轮浏览用来确认它还在。
    private static func cachedServers() -> [DiscoveredServer] {
        var seen: [DiscoveredServer] = []
        for (id, address) in AddressCache.saved() {
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = ServerKind(rawValue: parts[0]), !address.isEmpty else { continue }
            guard !DiscoveryAddress.same(address, in: seen, except: nil) else { continue }
            seen.append(DiscoveredServer(
                id: id,
                name: displayName(parts[1], kind: kind),
                kind: kind,
                address: address,
                instanceKey: parts[1]
            ))
        }
        return seen
    }

    /// 飞牛把服务器名做了 Base64 编码（如 SUZJTQ== → IFIM）
    private static func displayName(_ name: String, kind: ServerKind) -> String {
        if kind == .fnos, let data = Data(base64Encoded: name), let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
            return decoded
        }
        return name
    }

    /// 先到的地址先显示。IPv4 后到时替换 IPv6，因为登录地址用 IPv4 更直接。
    private func store(_ address: String, for id: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        let current = servers[index].address
        if Self.isIPv4(current), !Self.isIPv4(address) { return }
        if DiscoveryAddress.same(address, in: servers, except: id) {
            lookups[id]?.cancel()
            lookups[id] = nil
            bonjourIDs.remove(id)
            servers.removeAll { $0.id == id }
            return
        }
        servers[index].address = address
        AddressCache.store(address, for: id)
        if Self.isIPv4(address) {
            lookups[id]?.cancel()
            lookups[id] = nil
        }
    }

    private static func isIPv4(_ address: String) -> Bool {
        !address.isEmpty && !address.hasPrefix("[")
    }

    private nonisolated static func candidates(in endpoints: [Bonjour.Endpoint]) -> [ServiceCandidate] {
        var best: [String: ServiceCandidate] = [:]
        for endpoint in endpoints {
            let usable = endpoint.result.interfaces.filter { !BonjourInterface.shouldSkip($0) }
            if !endpoint.result.interfaces.isEmpty, usable.isEmpty { continue }
            let interface = usable.min { BonjourInterface.rank($0) < BonjourInterface.rank($1) }
            let candidate = ServiceCandidate(
                instanceName: endpoint.name,
                endpoint: endpoint.nwEndpoint,
                interface: interface,
                rank: BonjourInterface.rank(interface)
            )
            if let existing = best[endpoint.name], existing.rank <= candidate.rank { continue }
            best[endpoint.name] = candidate
        }
        return Array(best.values)
    }
}

private struct ServiceCandidate: Sendable {
    var instanceName: String
    var endpoint: NWEndpoint
    var interface: NWInterface?
    var rank: Int
}

private nonisolated enum BonjourInterface {
    static func shouldSkip(_ interface: NWInterface?) -> Bool {
        guard let name = interface?.name.lowercased() else { return false }
        return name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun") || name.hasPrefix("ipsec")
    }

    static func rank(_ interface: NWInterface?) -> Int {
        guard let interface else { return 1 }
        if shouldSkip(interface) { return 9 }
        switch interface.type {
        case .wiredEthernet: return 0
        case .wifi: return 1
        case .loopback: return 5
        default: return 2
        }
    }
}

/// 上次解析出的地址。服务名一到就先显示，不必再等这一轮的地址查询。
private nonisolated enum AddressCache {
    private static let key = "origin.discoveredAddresses"

    static func saved() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func address(for id: String) -> String? {
        saved()[id]
    }

    static func store(_ address: String, for id: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard map[id] != address else { return }
        map[id] = address
        UserDefaults.standard.set(map, forKey: key)
    }
}

/// 在发现服务的同时连上它，从连接路径读取 IP。不等待收到任何数据。
/// IPv4 和 IPv6 一起问，谁先给出地址就先用谁。
private nonisolated final class AddressLookup: @unchecked Sendable {
    private let queue = DispatchQueue(label: "origin.bonjour.resolve", qos: .userInteractive)
    private var connections: [NWConnection] = []
    private var onAddress: (@Sendable (String) -> Void)?
    private var cancelled = false

    func start(endpoint: NWEndpoint, interface: NWInterface?, onAddress: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onAddress = onAddress
            for version: NWProtocolIP.Options.Version in [.v4, .v6] {
                let parameters = NWParameters.tcp
                parameters.includePeerToPeer = false
                parameters.preferNoProxies = true
                parameters.serviceClass = .responsiveData
                // 过期的解析结果先用，避免重新查询把地址拖到数秒之后
                parameters.expiredDNSBehavior = .allow
                parameters.requiredInterface = interface
                if let options = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    options.version = version
                }
                let connection = NWConnection(to: endpoint, using: parameters)
                connection.stateUpdateHandler = { [weak self] state in
                    guard case .ready = state else { return }
                    self?.consider(connection.currentPath?.remoteEndpoint)
                }
                connection.pathUpdateHandler = { [weak self] path in
                    self?.consider(path.remoteEndpoint)
                }
                self.connections.append(connection)
                connection.start(queue: self.queue)
            }
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.teardown()
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.teardown() }
    }

    private func consider(_ endpoint: NWEndpoint?) {
        guard !cancelled, let address = Self.address(from: endpoint) else { return }
        let callback = onAddress
        callback?(address)
        if !address.hasPrefix("[") {
            teardown()
        }
    }

    private func teardown() {
        guard !cancelled else { return }
        cancelled = true
        onAddress = nil
        for connection in connections {
            connection.stateUpdateHandler = nil
            connection.pathUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
    }

    /// 去掉网卡后缀。IPv6 要加方括号，否则 `http://` 地址无法解析。
    private static func address(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        var hostText = "\(host)"
        var zone: String?
        if let marker = hostText.firstIndex(of: "%") {
            zone = String(hostText[hostText.index(after: marker)...])
            hostText = String(hostText[..<marker])
        }
        guard !hostText.isEmpty else { return nil }
        if hostText.contains(":") {
            if hostText.lowercased().hasPrefix("fe80:"), let zone, !zone.isEmpty {
                return "[\(hostText)%25\(zone)]:\(port)"
            }
            return "[\(hostText)]:\(port)"
        }
        return "\(hostText):\(port)"
    }
}

private struct PendingServer {
    var name: String
    var kind: ServerKind
    var instanceKey: String
}

private struct BroadcastAnnouncement: Sendable {
    var id: String
    var name: String
    var address: String
    var url: URL
}

private nonisolated enum DiscoveryAddress {
    static func same(_ address: String, in servers: [DiscoveredServer], except id: String? = nil) -> Bool {
        let key = Self.key(address)
        guard !key.isEmpty else { return false }
        return servers.contains { $0.id != id && Self.key($0.address) == key }
    }

    private static func key(_ address: String) -> String {
        var text = address.lowercased()
        guard !text.isEmpty else { return "" }
        if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
            let host = text[text.index(after: text.startIndex)..<end]
            let port = text[text.index(after: end)...].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return "\(host)|\(port)"
        }
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return text }
        return "\(parts[0])|\(parts[1])"
    }

    static func hostPort(from url: URL) -> String? {
        guard var host = url.host()?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        if host.contains(":") { host = "[\(host)]" }
        return "\(host):\(port)"
    }
}

/// Jellyfin 与 Emby 在 7359 端口回答 UDP 广播。应答是单播，所以用未连接的数据报套接字，
/// 而不是连到广播地址的 NWConnection（那条连接收不到别人回过来的包）。
private nonisolated final class BroadcastFinder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "origin.discovery.udp", qos: .userInteractive)
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var fd: Int32 = -1
    private var onFound: (@Sendable (BroadcastAnnouncement) -> Void)?

    func start(onFound: @escaping @Sendable (BroadcastAnnouncement) -> Void) {
        queue.async { [weak self] in self?.open(onFound) }
    }

    func cancel() {
        queue.async { [weak self] in self?.teardown() }
    }

    private func open(_ onFound: @escaping @Sendable (BroadcastAnnouncement) -> Void) {
        guard source == nil else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        let optionLength = socklen_t(MemoryLayout.size(ofValue: yes))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, optionLength)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, optionLength)
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        self.fd = fd
        self.onFound = onFound
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.announce() }
        timer.resume()
        self.timer = timer
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        source?.cancel()
        source = nil
        onFound = nil
        fd = -1
    }

    private func announce() {
        guard fd >= 0 else { return }
        let payloads = ["Who is JellyfinServer?", "who is EmbyServer?"].compactMap { $0.data(using: .utf8) }
        for var target in Self.targets() {
            target.sin_port = UInt16(7359).bigEndian
            for payload in payloads {
                payload.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                            sendto(fd, base, raw.count, 0, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while fd >= 0 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 { return }
            guard count > 0,
                  let reply = try? JSONDecoder().decode(Reply.self, from: Data(buffer.prefix(count))),
                  let url = URL(string: reply.address),
                  let address = DiscoveryAddress.hostPort(from: url) else { continue }
            onFound?(BroadcastAnnouncement(id: reply.id.isEmpty ? address : reply.id, name: reply.name, address: address, url: url))
        }
    }

    private static func targets() -> [sockaddr_in] {
        var targets: [sockaddr_in] = []
        var global = sockaddr_in()
        global.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        global.sin_family = sa_family_t(AF_INET)
        global.sin_addr.s_addr = INADDR_BROADCAST
        targets.append(global)
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let pointer else { return targets }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = pointer
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let flags = Int32(current.pointee.ifa_flags)
            let name = current.pointee.ifa_name.map { String(cString: $0).lowercased() } ?? ""
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("utun"), !name.hasPrefix("ipsec"),
                  let destination = current.pointee.ifa_dstaddr, destination.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let copy = destination.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            targets.append(copy)
        }
        return targets
    }

    private struct Reply: Decodable {
        var address: String
        var id: String
        var name: String

        enum CodingKeys: String, CodingKey {
            case address = "Address"
            case id = "Id"
            case name = "Name"
        }
    }
}
