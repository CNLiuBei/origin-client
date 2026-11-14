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
    /// 剧集中当前单集之后的下一集
    func nextEpisode(after episode: MediaItem) async -> MediaItem? {
        guard episode.kind == .episode, let seriesID = episode.seriesID,
              let all = try? await episodes(seriesID: seriesID),
              let index = all.firstIndex(where: { $0.id == episode.id }),
              index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
