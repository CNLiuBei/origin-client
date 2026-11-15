import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 备用线路：主地址连不上时按顺序尝试
struct ServerLine: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var url: URL
}

/// 单台服务器的连接参数
struct ServerAdvanced: Hashable, Codable, Sendable {
    var timeout: Double = 20
    /// 允许自签名或主机名不匹配的 HTTPS 证书
    var allowsInsecureTLS: Bool = false
}

/// 已保存的媒体服务器账号。访问令牌单独存放在 Keychain。
struct ServerAccount: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: ServerKind
    var name: String
    var baseURL: URL
    var userID: String
    var username: String
    /// Plex 服务器的 machineIdentifier
    var machineID: String?
    var note: String = ""
    var backupLines: [ServerLine] = []
    /// 当前线路；nil 表示主线路
    var activeLineID: UUID?
    /// 为 true 时，这台服务器不出现在首页、媒体库和搜索里
    var aggregationDisabled = false
    /// 自定义符号；nil 使用服务器类型的默认图标
    var customSymbol: String?
    /// 打开前需要本机认证
    var isEncrypted = false
    var advanced = ServerAdvanced()

    init(id: UUID, kind: ServerKind, name: String, baseURL: URL, userID: String, username: String, machineID: String? = nil,
         note: String = "", backupLines: [ServerLine] = [], activeLineID: UUID? = nil, aggregationDisabled: Bool = false,
         customSymbol: String? = nil, isEncrypted: Bool = false, advanced: ServerAdvanced = ServerAdvanced()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.userID = userID
        self.username = username
        self.machineID = machineID
        self.note = note
        self.backupLines = backupLines
        self.activeLineID = activeLineID
        self.aggregationDisabled = aggregationDisabled
        self.customSymbol = customSymbol
        self.isEncrypted = isEncrypted
        self.advanced = advanced
    }

    var token: String? {
        Keychain.string(for: id.uuidString)
    }

    /// 当前真正用来连接的地址
    var connectionURL: URL {
        if let activeLineID, let line = backupLines.first(where: { $0.id == activeLineID }) {
            return line.url
        }
        return baseURL
    }

    var activeLineName: String {
        if let activeLineID, let line = backupLines.first(where: { $0.id == activeLineID }) {
            return line.name.isEmpty ? "备用线路" : line.name
        }
        return "主线路"
    }

    /// 先试当前线路，再试主线路和其余备用线路
    var lineCandidates: [(id: UUID?, url: URL)] {
        var result: [(UUID?, URL)] = []
        if let activeLineID, backupLines.contains(where: { $0.id == activeLineID }) {
            result.append((activeLineID, connectionURL))
        }
        result.append((nil, baseURL))
        for line in backupLines {
            result.append((line.id, line.url))
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, baseURL, userID, username, machineID
        case note, backupLines, activeLineID, aggregationDisabled, customSymbol, isEncrypted, advanced
        /// 只读：早先单独的“在媒体库显示”开关，已并入 aggregationDisabled
        case hiddenFromLibraries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ServerKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        userID = try container.decode(String.self, forKey: .userID)
        username = try container.decode(String.self, forKey: .username)
        machineID = try container.decodeIfPresent(String.self, forKey: .machineID)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        backupLines = try container.decodeIfPresent([ServerLine].self, forKey: .backupLines) ?? []
        activeLineID = try container.decodeIfPresent(UUID.self, forKey: .activeLineID)
        aggregationDisabled = try container.decodeIfPresent(Bool.self, forKey: .aggregationDisabled) ?? false
        if try container.decodeIfPresent(Bool.self, forKey: .hiddenFromLibraries) == true {
            aggregationDisabled = true
        }
        customSymbol = try container.decodeIfPresent(String.self, forKey: .customSymbol)
        isEncrypted = try container.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        advanced = try container.decodeIfPresent(ServerAdvanced.self, forKey: .advanced) ?? ServerAdvanced()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(userID, forKey: .userID)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(machineID, forKey: .machineID)
        try container.encode(note, forKey: .note)
        try container.encode(backupLines, forKey: .backupLines)
        try container.encodeIfPresent(activeLineID, forKey: .activeLineID)
        try container.encode(aggregationDisabled, forKey: .aggregationDisabled)
        try container.encodeIfPresent(customSymbol, forKey: .customSymbol)
        try container.encode(isEncrypted, forKey: .isEncrypted)
        try container.encode(advanced, forKey: .advanced)
    }
}

/// 手动填写地址时的协议。自动会在连接时按端口和主机决定试 HTTP、HTTPS，或两种都试。
enum ServerScheme: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case http
    case https

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .http: "HTTP"
        case .https: "HTTPS"
        }
    }
}

enum ServerAddress {
    /// 拼出首选地址。自动时取 `probeURLs` 的第一个，不附带额外端口。
    static func compose(host: String, path: String, port: String, scheme: ServerScheme) -> URL? {
        probeURLs(host: host, path: path, port: port, scheme: scheme, alternatePorts: []).first
    }

    /// 连接时按顺序尝试的地址。指定 HTTP 或 HTTPS 时只生成该协议。
    /// 自动且写了端口：443、8443、8920 只用 HTTPS，80 只用 HTTP，其余先 HTTP 再 HTTPS。
    /// 自动且没写端口：域名先试 HTTPS，IP、localhost 和局域网主机名先试 HTTP 与默认端口。
    static func probeURLs(host: String, path: String, port: String, scheme: ServerScheme, alternatePorts: [Int]) -> [URL] {
        switch scheme {
        case .http:
            guard let primary = makeURL(host: host, path: path, port: port, https: false) else { return [] }
            guard portNumber(port) == nil, normalizedPath(path).isEmpty else { return [primary] }
            let extras = alternatePorts.compactMap { makeURL(host: host, path: path, port: String($0), https: false) }
            return unique([primary] + extras)
        case .https:
            return makeURL(host: host, path: path, port: port, https: true).map { [$0] } ?? []
        case .automatic:
            return automaticURLs(host: host, path: path, port: port, alternatePorts: alternatePorts)
        }
    }

    /// 把粘进「主机」的完整地址拆开。普通主机名原样保留。
    /// 只有原文带 `http://` 或 `https://` 时才改协议，否则保持「自动」。
    static func absorb(host: inout String, path: inout String, port: inout String, scheme: inout ServerScheme) {
        guard let parsed = parse(pasted: host) else { return }
        let hadScheme = host.contains("://")
        let hadSlash = host.contains("/")
        host = parsed.host
        if !parsed.path.isEmpty { path = parsed.path }
        if hadScheme {
            port = parsed.port
            scheme = parsed.scheme
        } else if hadSlash {
            if !parsed.port.isEmpty { port = parsed.port }
        } else if !parsed.port.isEmpty {
            port = parsed.port
        }
    }

    static func parts(of url: URL) -> (host: String, path: String, port: String, scheme: ServerScheme) {
        let stored = url.path()
        let path = (stored.isEmpty || stored == "/") ? "" : String(stored.drop(while: { $0 == "/" }))
        let scheme: ServerScheme = url.scheme?.lowercased() == "https" ? .https : .http
        return (url.host() ?? "", path, url.port.map(String.init) ?? "", scheme)
    }

    private static func automaticURLs(host: String, path: String, port: String, alternatePorts: [Int]) -> [URL] {
        if let number = portNumber(port) {
            let text = String(number)
            switch number {
            case 443, 8443, 8920:
                return makeURL(host: host, path: path, port: text, https: true).map { [$0] } ?? []
            case 80:
                return makeURL(host: host, path: path, port: text, https: false).map { [$0] } ?? []
            default:
                return unique([false, true].compactMap { makeURL(host: host, path: path, port: text, https: $0) })
            }
        }
        let secure = makeURL(host: host, path: path, port: "", https: true)
        let plain = makeURL(host: host, path: path, port: "", https: false)
        let defaults = normalizedPath(path).isEmpty
            ? alternatePorts.compactMap { makeURL(host: host, path: path, port: String($0), https: false) }
            : []
        if prefersSecureFirst(host) {
            return unique([secure].compactMap { $0 } + defaults + [plain].compactMap { $0 })
        }
        return unique(defaults + [plain, secure].compactMap { $0 })
    }

    private static func makeURL(host: String, path: String, port: String, https: Bool) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedHost.contains("/") else { return nil }
        var components = URLComponents()
        components.scheme = https ? "https" : "http"
        components.host = trimmedHost
        if let port = portNumber(port) { components.port = port }
        let pathText = normalizedPath(path)
        if !pathText.isEmpty { components.path = "/" + pathText }
        return components.url
    }

    private static func normalizedPath(_ path: String) -> String {
        var pathText = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while pathText.hasPrefix("/") { pathText.removeFirst() }
        while pathText.hasSuffix("/") { pathText.removeLast() }
        return pathText
    }

    private static func portNumber(_ port: String) -> Int? {
        let text = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let value = Int(text), (1 ... 65535).contains(value) else { return nil }
        return value
    }

    /// 域名先试 443。IP、无点主机名和 `.local` 多半在局域网，先试明文端口。
    private static func prefersSecureFirst(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.isEmpty || name == "localhost" || name.hasSuffix(".local") || !name.contains(".") { return false }
        return !isAddressLiteral(name)
    }

    private static func isAddressLiteral(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") { return true }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { (0 ... 255).contains($0) } ?? false }
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls where !result.contains(url) {
            result.append(url)
        }
        return result
    }

    private static func parse(pasted raw: String) -> (host: String, path: String, port: String, scheme: ServerScheme)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.contains("/") {
            let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
            guard let url = URL(string: candidate), let host = url.host(), !host.isEmpty else { return nil }
            return parts(of: url)
        }
        if trimmed.hasPrefix("[") {
            guard let end = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.startIndex...end])
            let rest = trimmed[trimmed.index(after: end)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1 ... 65535).contains(port) else { return nil }
            return (host, "", String(port), .http)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let portText = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, !host.contains(":"), let port = Int(portText), (1 ... 65535).contains(port) else { return nil }
        return (host, "", portText, .http)
    }

    static func same(_ url: URL, as other: URL) -> Bool {
        let left = parts(of: url)
        let right = parts(of: other)
        return left.host == right.host && left.path == right.path && left.port == right.port && left.scheme == right.scheme
    }
}

enum DeviceInfo {
    static let clientName = "Origin"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    #if os(macOS)
    static var deviceName: String { Host.current().localizedName ?? "Mac" }
    static var model: String { "Mac" }
    static var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    #else
    static var deviceName: String { UIDevice.current.name }
    static var model: String { UIDevice.current.model }
    static var systemVersion: String { UIDevice.current.systemVersion }
    #endif

    /// 每台设备唯一的客户端 ID，存放在 Keychain 中以便重装后保持不变
    static let deviceID: String = {
        let key = "origin.device-id"
        if let existing = Keychain.string(for: key) { return existing }
        let new = UUID().uuidString
        Keychain.set(new, for: key)
        return new
    }()
}
