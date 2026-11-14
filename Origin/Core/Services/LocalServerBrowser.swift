import Foundation
import Network
import Observation

/// 局域网中通过 Bonjour 广播的媒体服务器
struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: ServerKind
    /// 解析出的 IPv4 地址与端口，如 10.10.10.10:8005
    let address: String
}

/// 用系统 NWBrowser 发现局域网里的飞牛影视（_trim_media._tcp）与 Plex（_plexmediasvr._tcp）。
/// Jellyfin / Emby 只提供 UDP 广播发现，需要额外申请组播权限，因此不在此列。
@Observable
final class LocalServerBrowser {
    private(set) var servers: [DiscoveredServer] = []
    private(set) var isSearching = false

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var resolving: [String: NWConnection] = [:]

    private static let serviceTypes: [(String, ServerKind)] = [
        ("_trim_media._tcp", .fnos),
        ("_plexmediasvr._tcp", .plex),
    ]

    func start() {
        guard browsers.isEmpty else { return }
        isSearching = true
        for (type, kind) in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.handle(results, kind: kind) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            isSearching = false
        }
    }

    func restart() {
        stop()
        servers.removeAll()
        start()
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
        isSearching = false
    }

    private func handle(_ results: Set<NWBrowser.Result>, kind: ServerKind) {
        let alive = Set(results.map { "\($0.endpoint)" })
        servers.removeAll { $0.kind == kind && !alive.contains($0.id) }
        for result in results {
            let id = "\(result.endpoint)"
            guard case let .service(name, _, _, _) = result.endpoint,
                  resolving[id] == nil, !servers.contains(where: { $0.id == id }) else { continue }
            resolve(result.endpoint, id: id, name: Self.displayName(name, kind: kind), kind: kind)
        }
    }

    /// Bonjour 只给出服务名，建立一次 IPv4 连接拿到实际地址
    private func resolve(_ endpoint: NWEndpoint, id: String, name: String, kind: ServerKind) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        let address = "\(Self.hostString(host)):\(port.rawValue)"
                        if !self.servers.contains(where: { $0.id == id }) {
                            self.servers.append(DiscoveredServer(id: id, name: name, kind: kind, address: address))
                        }
                    }
                    connection.cancel()
                    self.resolving[id] = nil
                case .failed, .cancelled:
                    self.resolving[id] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private nonisolated static func hostString(_ host: NWEndpoint.Host) -> String {
        func stripInterface(_ text: String) -> String {
            text.split(separator: "%").first.map(String.init) ?? text
        }
        return switch host {
        case let .ipv4(address): stripInterface("\(address)")
        case let .ipv6(address): "[\(stripInterface("\(address)"))]"
        case let .name(name, _): name
        @unknown default: "\(host)"
        }
    }

    /// 飞牛把服务器名做了 Base64 编码（如 SUZJTQ== → IFIM）
    private static func displayName(_ name: String, kind: ServerKind) -> String {
        if kind == .fnos, let data = Data(base64Encoded: name), let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
            return decoded
        }
        return name
    }
}
