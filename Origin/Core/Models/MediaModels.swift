import Foundation

enum ServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case jellyfin
    case emby
    case plex
    case fnos

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .plex: "Plex"
        case .fnos: "飞牛影视"
        }
    }

    /// 未填写端口时使用的默认端口。
    var defaultPort: Int {
        switch self {
        case .jellyfin, .emby: 8096
        case .plex: 32400
        case .fnos: 8005
        }
    }

    /// 各服务官方应用图标，资源名与 Assets 中的 imageset 一致。
    var iconAsset: String {
        switch self {
        case .jellyfin: "ServerJellyfin"
        case .emby: "ServerEmby"
        case .plex: "ServerPlex"
        case .fnos: "ServerFnos"
        }
    }
}

enum MediaKind: String, Codable, Hashable, Sendable {
    case movie
    case series
    case season
    case episode
    case collection
    case folder
    case video
    case other

    var isPlayable: Bool {
        switch self {
        case .movie, .episode, .video: true
        default: false
        }
    }

    var isBrowsable: Bool {
        self == .collection || self == .folder
    }
}

enum LibraryKind: String, Codable, Hashable, Sendable {
    case movies
    case tvShows
    case collections
    case mixed

    var symbol: String {
        switch self {
        case .movies: "film"
        case .tvShows: "tv"
        case .collections: "square.stack"
        case .mixed: "folder"
        }
    }
}

struct MediaLibrary: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let kind: LibraryKind
    let imageURL: URL?
    var serverID: UUID?
    var serverName: String?

    var displayName: String {
        guard let serverName, !serverName.isEmpty else { return name }
        return "\(serverName) · \(name)"
    }

    init(id: String, name: String, kind: LibraryKind, imageURL: URL?, serverID: UUID? = nil, serverName: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.imageURL = imageURL
        self.serverID = serverID
        self.serverName = serverName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, imageURL, serverID, serverName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(LibraryKind.self, forKey: .kind)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        serverID = try container.decodeIfPresent(UUID.self, forKey: .serverID)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(serverID, forKey: .serverID)
        try container.encodeIfPresent(serverName, forKey: .serverName)
    }
}

struct MediaPerson: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
}

struct MediaStreamInfo: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case video
        case audio
        case subtitle
    }

    var id: String { "\(kind.rawValue)-\(index)" }
    let index: Int
    let kind: Kind
    let codec: String?
    let language: String?
    let title: String?
    let isDefault: Bool
    let isForced: Bool
    let isExternal: Bool
    /// 外挂字幕的下载地址（已带鉴权参数）
    let deliveryURL: URL?
    let channels: Int?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    /// SDR / HDR10 / HLG / DOVI 等
    let videoRange: String?
    var profile: String? = nil
    var level: Int? = nil
    var aspectRatio: String? = nil
    var isInterlaced: Bool? = nil
    var frameRate: Double? = nil
    var bitDepth: Int? = nil
    var pixelFormat: String? = nil
    var refFrames: Int? = nil
    var sampleRate: Int? = nil
    var channelLayout: String? = nil

    var displayName: String {
        if let title, !title.isEmpty { return title }
        var parts: [String] = []
        if let language { parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language) }
        if let codec { parts.append(codec.uppercased()) }
        if let channels { parts.append(Self.channelLayout(channels)) }
        if isForced { parts.append("强制") }
        if isExternal { parts.append("外挂") }
        return parts.isEmpty ? "轨道 \(index)" : parts.joined(separator: " · ")
    }

    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: "单声道"
        case 2: "立体声"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) 声道"
        }
    }

    var isTextSubtitle: Bool {
        guard kind == .subtitle, let codec = codec?.lowercased() else { return false }
        return ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "tx3g", "text", "ttml"].contains(codec)
    }
}

struct MediaSourceInfo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let path: String?
    let streams: [MediaStreamInfo]
    /// 直连播放地址（已带鉴权参数）
    let directURL: URL?

    var videoStream: MediaStreamInfo? { streams.first { $0.kind == .video } }
    var audioStreams: [MediaStreamInfo] { streams.filter { $0.kind == .audio } }
    var subtitleStreams: [MediaStreamInfo] { streams.filter { $0.kind == .subtitle } }
    var externalSubtitles: [MediaStreamInfo] { subtitleStreams.filter { $0.isExternal && $0.deliveryURL != nil } }

    var fileName: String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
}

struct UserState: Hashable, Codable, Sendable {
    var isPlayed = false
    var isFavorite = false
    var playbackPosition: TimeInterval = 0
    var playCount = 0
    var unplayedCount: Int?
}

struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let serverID: UUID
    let kind: MediaKind
    let name: String
    var originalTitle: String?
    var overview: String?
    var tagline: String?
    var year: Int?
    var premiereDate: Date?
    var runtime: TimeInterval?
    var communityRating: Double?
    var criticRating: Double?
    var officialRating: String?
    var genres: [String] = []
    var studios: [String] = []
    var people: [MediaPerson] = []
    var posterURL: URL?
    var backdropURL: URL?
    var thumbURL: URL?
    var logoURL: URL?
    var seriesID: String?
    var seriesName: String?
    var seasonID: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var childCount: Int?
    var userState = UserState()
    var mediaSources: [MediaSourceInfo] = []
    var providerIDs: [String: String] = [:]
    var dateAdded: Date?
    var endDate: Date? = nil
    /// 剧集连载状态，服务器原值（Continuing / Ended）
    var seriesStatus: String? = nil

    /// 剧集年份区间：2026 - 现在 / 2008 - 2013
    var yearRange: String? {
        guard let year else { return nil }
        guard kind == .series else { return "\(year)" }
        if seriesStatus?.lowercased() == "continuing" { return "\(year) - 现在" }
        if let end = endDate.map({ Calendar.current.component(.year, from: $0) }), end != year { return "\(year) - \(end)" }
        return "\(year)"
    }

    var progress: Double {
        guard let runtime, runtime > 0 else { return 0 }
        return min(1, userState.playbackPosition / runtime)
    }

    var isResumable: Bool {
        userState.playbackPosition > 30 && progress < 0.95
    }

    var episodeLabel: String? {
        guard kind == .episode else { return nil }
        switch (seasonNumber, episodeNumber) {
        case let (s?, e?): return "S\(s) E\(e)"
        case let (nil, e?): return "第 \(e) 集"
        default: return nil
        }
    }

    /// 卡片上的主标题：单集显示剧名
    var cardTitle: String {
        kind == .episode ? (seriesName ?? name) : name
    }

    var cardSubtitle: String? {
        switch kind {
        case .episode:
            [shortEpisodeLabel, name].compactMap(\.self).joined(separator: " - ")
        default:
            yearRange
        }
    }

    /// S1:E45
    var shortEpisodeLabel: String? {
        guard kind == .episode, let e = episodeNumber else { return nil }
        return seasonNumber.map { "S\($0):E\(e)" } ?? "E\(e)"
    }

    var tmdbID: String? { providerIDs["tmdb"] }
    var imdbID: String? { providerIDs["imdb"] }
}

struct PagedResult: Sendable {
    let items: [MediaItem]
    let total: Int
}

enum SortOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case dateAdded
    case premiereDate
    case rating
    case runtime
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "名称"
        case .dateAdded: "添加日期"
        case .premiereDate: "上映日期"
        case .rating: "评分"
        case .runtime: "时长"
        case .random: "随机"
        }
    }
}

enum FilterOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case unplayed
    case played
    case resumable
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .unplayed: "未观看"
        case .played: "已观看"
        case .resumable: "观看中"
        case .favorites: "收藏"
        }
    }
}

struct LibraryQuery: Hashable, Sendable {
    var sort: SortOption = .name
    var ascending = true
    var filter: FilterOption = .all
    var genre: String?
}

extension TimeInterval {
    /// 1:02:03 / 12:34
    var clockString: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(self)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 2小时5分钟
    var durationString: String {
        let f = DateComponentsFormatter()
        f.allowedUnits = self >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .short
        return f.string(from: self) ?? ""
    }
}
