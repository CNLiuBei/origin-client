import Observation
import SwiftUI

enum PlayerEngine: String, CaseIterable, Identifiable {
    /// 能用系统播放器就用系统播放器，否则用 FFmpeg 直接播放
    case auto
    /// 始终使用系统播放器，不兼容时请服务器转封装为 HLS
    case systemOnly
    /// 始终使用 FFmpeg 内核
    case ffmpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "自动（系统优先）"
        case .systemOnly: "仅系统播放器"
        case .ffmpeg: "始终使用 FFmpeg"
        }
    }

    /// 分段控件上的短标题，完整说明见 footnote
    var shortTitle: String {
        switch self {
        case .auto: "自动"
        case .systemOnly: "仅系统"
        case .ffmpeg: "FFmpeg"
        }
    }

    var footnote: String {
        switch self {
        case .auto: "MP4/MOV 等系统支持的格式交给系统播放器；MKV、DTS、ASS 字幕等由 FFmpeg 直接解码。"
        case .systemOnly: "不兼容的文件交由服务器转封装为 HLS 后再用系统播放器播放，会占用服务器资源。"
        case .ffmpeg: "所有内容使用 FFmpeg 内核直接播放，提供手势、外挂字幕样式等完整控制。"
        }
    }
}

/// 遇到服务器标记的片头或片尾时怎么处理
enum SegmentSkip: String, CaseIterable, Identifiable {
    case ask
    case automatic
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "询问"
        case .automatic: "自动跳过"
        case .off: "关闭"
        }
    }
}

enum LanguagePreference: String, CaseIterable, Identifiable {
    case auto
    case chinese
    case english
    case japanese
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "自动"
        case .chinese: "中文"
        case .english: "英语"
        case .japanese: "日语"
        case .none: "关闭"
        }
    }

    /// ISO 639 代码（含 2 位与 3 位写法）
    var codes: [String] {
        switch self {
        case .auto: Locale.preferredLanguages.map { String($0.prefix(2)) }
        case .chinese: ["zh", "chi", "zho", "chs", "cht", "cmn", "yue"]
        case .english: ["en", "eng"]
        case .japanese: ["ja", "jpn"]
        case .none: []
        }
    }

    func matches(_ code: String?) -> Bool {
        guard let code = code?.lowercased() else { return false }
        return codes.contains { code.hasPrefix($0) }
    }
}

/// 所有用户偏好，基于 UserDefaults 持久化。改动先落在本机，再交给 CloudSync 上传。
@Observable
final class AppSettings {
    static let factory: [String: Any] = [
        "engine": PlayerEngine.auto.rawValue,
        "hardwareDecode": true,
        "defaultRate": 1.0,
        "skipForward": 15,
        "skipBackward": 10,
        "autoPlayNext": true,
        "autoResume": true,
        "skipIntro": SegmentSkip.ask.rawValue,
        "skipCredits": SegmentSkip.ask.rawValue,
        "audioLanguage": LanguagePreference.auto.rawValue,
        "subtitleLanguage": LanguagePreference.chinese.rawValue,
        "subtitleSize": 22.0,
        "subtitleBottomPadding": 24.0,
        "subtitleBackground": false,
        "subtitleColorHex": "#FFFFFF",
        "tmdbEnabled": true,
        "longPressRate": 2.0,
    ]

    private let defaults = UserDefaults.standard
    @ObservationIgnored weak var cloudSync: CloudSync?
    @ObservationIgnored private var isApplyingRemote = false

    var engine: PlayerEngine { didSet { save("engine", engine.rawValue) } }
    var hardwareDecode: Bool { didSet { save("hardwareDecode", hardwareDecode) } }
    var defaultRate: Double { didSet { save("defaultRate", defaultRate) } }
    var skipForward: Int { didSet { save("skipForward", skipForward) } }
    var skipBackward: Int { didSet { save("skipBackward", skipBackward) } }
    var autoPlayNext: Bool { didSet { save("autoPlayNext", autoPlayNext) } }
    var autoResume: Bool { didSet { save("autoResume", autoResume) } }
    var skipIntro: SegmentSkip { didSet { save("skipIntro", skipIntro.rawValue) } }
    var skipCredits: SegmentSkip { didSet { save("skipCredits", skipCredits.rawValue) } }
    var audioLanguage: LanguagePreference { didSet { save("audioLanguage", audioLanguage.rawValue) } }
    var subtitleLanguage: LanguagePreference { didSet { save("subtitleLanguage", subtitleLanguage.rawValue) } }
    var subtitleSize: Double { didSet { save("subtitleSize", subtitleSize) } }
    var subtitleBottomPadding: Double { didSet { save("subtitleBottomPadding", subtitleBottomPadding) } }
    var subtitleBackground: Bool { didSet { save("subtitleBackground", subtitleBackground) } }
    var subtitleColorHex: String { didSet { save("subtitleColorHex", subtitleColorHex) } }
    var tmdbEnabled: Bool { didSet { save("tmdbEnabled", tmdbEnabled) } }
    var customTMDBToken: String {
        didSet { Keychain.set(customTMDBToken.isEmpty ? nil : customTMDBToken, for: "tmdb-token", synchronizable: cloudSync?.enabled == true) }
    }
    var longPressRate: Double { didSet { save("longPressRate", longPressRate) } }

    init() {
        defaults.register(defaults: Self.factory)
        engine = PlayerEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .auto
        hardwareDecode = defaults.bool(forKey: "hardwareDecode")
        defaultRate = defaults.double(forKey: "defaultRate")
        skipForward = defaults.integer(forKey: "skipForward")
        skipBackward = defaults.integer(forKey: "skipBackward")
        autoPlayNext = defaults.bool(forKey: "autoPlayNext")
        autoResume = defaults.bool(forKey: "autoResume")
        skipIntro = SegmentSkip(rawValue: defaults.string(forKey: "skipIntro") ?? "") ?? .ask
        skipCredits = SegmentSkip(rawValue: defaults.string(forKey: "skipCredits") ?? "") ?? .ask
        audioLanguage = LanguagePreference(rawValue: defaults.string(forKey: "audioLanguage") ?? "") ?? .auto
        subtitleLanguage = LanguagePreference(rawValue: defaults.string(forKey: "subtitleLanguage") ?? "") ?? .chinese
        subtitleSize = defaults.double(forKey: "subtitleSize")
        subtitleBottomPadding = defaults.double(forKey: "subtitleBottomPadding")
        subtitleBackground = defaults.bool(forKey: "subtitleBackground")
        subtitleColorHex = defaults.string(forKey: "subtitleColorHex") ?? "#FFFFFF"
        tmdbEnabled = defaults.bool(forKey: "tmdbEnabled")
        customTMDBToken = Keychain.string(for: "tmdb-token") ?? ""
        longPressRate = defaults.double(forKey: "longPressRate")
    }

    func syncSnapshot() -> [String: Any] {
        [
            "engine": engine.rawValue,
            "hardwareDecode": hardwareDecode,
            "defaultRate": defaultRate,
            "skipForward": skipForward,
            "skipBackward": skipBackward,
            "autoPlayNext": autoPlayNext,
            "autoResume": autoResume,
            "skipIntro": skipIntro.rawValue,
            "skipCredits": skipCredits.rawValue,
            "audioLanguage": audioLanguage.rawValue,
            "subtitleLanguage": subtitleLanguage.rawValue,
            "subtitleSize": subtitleSize,
            "subtitleBottomPadding": subtitleBottomPadding,
            "subtitleBackground": subtitleBackground,
            "subtitleColorHex": subtitleColorHex,
            "tmdbEnabled": tmdbEnabled,
            "longPressRate": longPressRate,
        ]
    }

    func localStamp(for key: String) -> Date? {
        Self.date(defaults.object(forKey: Self.stampKey(key)))
    }

    func adoptStamp(_ key: String, _ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.stampKey(key))
    }

    /// 用另一台设备上更新的值覆盖本机。不会再次上传。
    func applyRemoteSetting(_ key: String, value: Any, updatedAt: Date) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let applied: Bool
        switch key {
        case "engine":
            applied = apply(value as? String, into: \.engine, as: PlayerEngine.self)
        case "hardwareDecode":
            applied = apply(Self.bool(value), into: \.hardwareDecode)
        case "defaultRate":
            applied = apply(Self.double(value), into: \.defaultRate)
        case "skipForward":
            applied = apply(Self.int(value), into: \.skipForward)
        case "skipBackward":
            applied = apply(Self.int(value), into: \.skipBackward)
        case "autoPlayNext":
            applied = apply(Self.bool(value), into: \.autoPlayNext)
        case "autoResume":
            applied = apply(Self.bool(value), into: \.autoResume)
        case "skipIntro":
            applied = apply(value as? String, into: \.skipIntro, as: SegmentSkip.self)
        case "skipCredits":
            applied = apply(value as? String, into: \.skipCredits, as: SegmentSkip.self)
        case "audioLanguage":
            guard let raw = value as? String, let parsed = LanguagePreference(rawValue: raw), parsed != .none else { return }
            audioLanguage = parsed
            applied = true
        case "subtitleLanguage":
            applied = apply(value as? String, into: \.subtitleLanguage, as: LanguagePreference.self)
        case "subtitleSize":
            applied = apply(Self.double(value), into: \.subtitleSize)
        case "subtitleBottomPadding":
            applied = apply(Self.double(value), into: \.subtitleBottomPadding)
        case "subtitleBackground":
            applied = apply(Self.bool(value), into: \.subtitleBackground)
        case "subtitleColorHex":
            guard let raw = value as? String else { return }
            subtitleColorHex = raw
            applied = true
        case "tmdbEnabled":
            applied = apply(Self.bool(value), into: \.tmdbEnabled)
        case "longPressRate":
            applied = apply(Self.double(value), into: \.longPressRate)
        default:
            return
        }
        if applied {
            defaults.set(updatedAt.timeIntervalSince1970, forKey: Self.stampKey(key))
        }
    }

    func applyRemoteTMDBToken(_ token: String) {
        guard token != customTMDBToken else { return }
        isApplyingRemote = true
        customTMDBToken = token
        isApplyingRemote = false
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        guard !isApplyingRemote else { return }
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: Self.stampKey(key))
        cloudSync?.pushSetting(key: key, value: value, updatedAt: now)
    }

    private func apply<Value: Equatable>(_ value: Value?, into keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Bool {
        guard let value else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    private func apply<Value: RawRepresentable>(_ raw: String?, into keyPath: ReferenceWritableKeyPath<AppSettings, Value>, as type: Value.Type) -> Bool where Value.RawValue == String {
        guard let raw, let value = type.init(rawValue: raw) else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    private static func stampKey(_ key: String) -> String { "sync.stamp.\(key)" }

    private static func bool(_ value: Any) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func int(_ value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func double(_ value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let value = value as? Double { return Date(timeIntervalSince1970: value) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        return nil
    }

    var subtitleColor: Color {
        get { Color(hex: subtitleColorHex) }
        set { subtitleColorHex = newValue.hexString }
    }

    var tmdbToken: String {
        customTMDBToken.isEmpty ? TMDBClient.bundledToken : customTMDBToken
    }
}

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let c = resolve(in: EnvironmentValues())
        func byte(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.red), byte(c.green), byte(c.blue))
    }
}
