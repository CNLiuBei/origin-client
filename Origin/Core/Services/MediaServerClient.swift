import Foundation

/// 外挂字幕
struct ExternalSubtitle: Hashable, Sendable {
    let id: String
    let name: String
    let language: String?
    let url: URL
    let isDefault: Bool
    let isForced: Bool
}

/// 服务器标记的一段可跳过内容，时间单位为秒
struct MediaSegment: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case intro, recap, commercial, credits, preview

        var title: String {
            switch self {
            case .intro: "跳过片头"
            case .recap: "跳过前情"
            case .commercial: "跳过广告"
            case .credits: "跳过片尾"
            case .preview: "跳过预告"
            }
        }

        var doneTitle: String {
            switch self {
            case .intro: "已跳过片头"
            case .recap: "已跳过前情"
            case .commercial: "已跳过广告"
            case .credits: "已跳过片尾"
            case .preview: "已跳过预告"
            }
        }

        /// 片头、前情和广告用“片头”设置；片尾和预告用“片尾”设置
        var isOpening: Bool {
            switch self {
            case .intro, .recap, .commercial: true
            case .credits, .preview: false
            }
        }

        static func fromServer(_ raw: String) -> Kind? {
            switch raw.lowercased() {
            case "intro", "opening": .intro
            case "recap", "previously": .recap
            case "commercial", "advertisement", "ad": .commercial
            case "outro", "credits", "ending", "endcredits": .credits
            case "preview": .preview
            default: nil
            }
        }
    }

    let id: String
    let kind: Kind
    let start: TimeInterval
    let end: TimeInterval

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end - 0.6
    }

    /// 丢掉过短或长得不像标记的区间
    static func sanitized(_ segments: [MediaSegment]) -> [MediaSegment] {
        segments.filter { segment in
            let length = segment.end - segment.start
            return segment.start >= 0 && length >= 1 && length <= 20 * 60
        }
        .sorted { $0.start < $1.start }
    }
}

/// 播放进度上报所需的会话信息
struct PlaybackReport: Sendable {
    let item: MediaItem
    let mediaSourceID: String?
    let playSessionID: String
    let position: TimeInterval
    let duration: TimeInterval
    let isPaused: Bool
    let isTranscoding: Bool
}

/// Emby / Jellyfin / Plex 的统一抽象
protocol MediaServerClient: AnyObject, Sendable {
    var account: ServerAccount { get }
    var supportsFavorites: Bool { get }
    /// 服务器能否把不兼容的文件转封装/转码成 HLS，交给系统播放器
    var supportsHLS: Bool { get }
    /// 服务器是否支持媒体库的排序与筛选参数
    var supportsLibraryQuery: Bool { get }

    func libraries() async throws -> [MediaLibrary]
    func resumeItems(limit: Int) async throws -> [MediaItem]
    func nextUp(limit: Int) async throws -> [MediaItem]
    func latest(in library: MediaLibrary, limit: Int) async throws -> [MediaItem]
    func items(parentID: String, kind: LibraryKind, query: LibraryQuery, start: Int, limit: Int) async throws -> PagedResult
    func genres(parentID: String) async throws -> [String]
    /// 合集 / 文件夹作为 parentID 浏览时使用的标识
    func childrenParentID(of item: MediaItem) -> String
    func item(id: String) async throws -> MediaItem
    func seasons(seriesID: String) async throws -> [MediaItem]
    func episodes(seriesID: String) async throws -> [MediaItem]
    func similar(to item: MediaItem, limit: Int) async throws -> [MediaItem]
    func favorites() async throws -> [MediaItem]
    func search(_ term: String, limit: Int) async throws -> [MediaItem]
    /// 片头、片尾、前情、预告。服务器没有标记时返回空数组
    func segments(for item: MediaItem) async -> [MediaSegment]
    func setPlayed(_ played: Bool, item: MediaItem) async throws
    func setFavorite(_ favorite: Bool, item: MediaItem) async throws

    /// 请求播放器时附带的 HTTP 头
    var streamHeaders: [String: String] { get }
    /// 服务器端转封装 / 转码后的 HLS 地址
    func hlsURL(for item: MediaItem, source: MediaSourceInfo, playSessionID: String) -> URL?

    func reportStart(_ report: PlaybackReport) async
    func reportProgress(_ report: PlaybackReport) async
    func reportStop(_ report: PlaybackReport) async
}

extension MediaServerClient {
    func segments(for item: MediaItem) async -> [MediaSegment] { [] }

    /// 剧集中当前单集之后的下一集
    func nextEpisode(after episode: MediaItem) async -> MediaItem? {
        guard episode.kind == .episode, let seriesID = episode.seriesID,
              let all = try? await episodes(seriesID: seriesID),
              let index = all.firstIndex(where: { $0.id == episode.id }),
              index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
