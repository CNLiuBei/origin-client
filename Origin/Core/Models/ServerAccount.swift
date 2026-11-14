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
    /// 为 true 时，这台服务器不并入首页和其他服务器的媒体库
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

enum ServerAddress {
    /// 把主机、路径、端口和 https 拼成地址
    static func compose(host: String, path: String, port: String, https: Bool) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedHost.contains("/") else { return nil }
        var components = URLComponents()
        components.scheme = https ? "https" : "http"
        components.host = trimmedHost
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !portText.isEmpty {
            guard let value = Int(portText), (1 ... 65535).contains(value) else { return nil }
            components.port = value
        }
        var pathText = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while pathText.hasPrefix("/") { pathText.removeFirst() }
        while pathText.hasSuffix("/") { pathText.removeLast() }
        if !pathText.isEmpty { components.path = "/" + pathText }
        return components.url
    }

    static func parts(of url: URL) -> (host: String, path: String, port: String, https: Bool) {
        let stored = url.path()
        let path = (stored.isEmpty || stored == "/") ? "" : String(stored.drop(while: { $0 == "/" }))
        return (url.host() ?? "", path, url.port.map(String.init) ?? "", url.scheme?.lowercased() == "https")
    }

    static func same(_ url: URL, as other: URL) -> Bool {
        let left = parts(of: url)
        let right = parts(of: other)
        return left.host == right.host && left.path == right.path && left.port == right.port && left.https == right.https
    }
}

enum DeviceInfo {
    static let clientName = "Origin"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
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
