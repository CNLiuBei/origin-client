import Foundation

final class PlexClient: MediaServerClient {
    let account: ServerAccount
    private let http: HTTPClient
    private let token: String?
    private var genreKeys: [String: [String: String]] = [:]

    var supportsFavorites: Bool { true }
    var supportsHLS: Bool { true }
    var supportsLibraryQuery: Bool { true }

    private var baseURL: URL { account.connectionURL }

    init(account: ServerAccount) {
        self.account = account
        token = account.token
        http = HTTPClient(timeout: account.advanced.timeout, allowsInsecureTLS: account.advanced.allowsInsecureTLS)
    }

    static var clientHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Product": DeviceInfo.clientName,
            "X-Plex-Version": DeviceInfo.version,
            "X-Plex-Client-Identifier": DeviceInfo.deviceID,
            "X-Plex-Device": DeviceInfo.model,
            "X-Plex-Device-Name": DeviceInfo.deviceName,
            "X-Plex-Platform": "iOS",
            "X-Plex-Platform-Version": DeviceInfo.systemVersion,
        ]
    }

    private var headers: [String: String] {
        var headers = Self.clientHeaders
        headers["X-Plex-Token"] = token
        return headers
    }

    var streamHeaders: [String: String] { headers }

    // MARK: - plex.tv 登录（PIN 流程）

    struct Pin: Decodable {
        let id: Int
        let code: String
        let authToken: String?
    }

    struct Resource: Decodable, Identifiable {
        struct Connection: Decodable, Hashable {
            let uri: String
            let local: Bool
            let relay: Bool
        }

        let name: String
        let provides: String
        let clientIdentifier: String
        let accessToken: String?
        let connections: [Connection]

        var id: String { clientIdentifier }
        var isServer: Bool { provides.contains("server") }
    }

    static func createPin() async throws -> Pin {
        try await HTTPClient().decode(Pin.self, from: URL(string: "https://plex.tv/api/v2/pins?strong=true")!, method: "POST", headers: clientHeaders)
    }

    static func checkPin(_ pin: Pin) async throws -> String? {
        try await HTTPClient().decode(Pin.self, from: URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!, headers: clientHeaders).authToken
    }

    static func authURL(for pin: Pin, forwardURL: String) -> URL {
        var components = URLComponents(string: "https://app.plex.tv/auth")!
        var fragment = URLComponents()
        fragment.queryItems = [
            URLQueryItem(name: "clientID", value: DeviceInfo.deviceID),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "forwardUrl", value: forwardURL),
            URLQueryItem(name: "context[device][product]", value: DeviceInfo.clientName),
        ]
        components.fragment = "?" + (fragment.percentEncodedQuery ?? "")
        return components.url!
    }

    static func username(token: String) async -> String? {
        struct User: Decodable { let username: String? }
        var headers = clientHeaders
        headers["X-Plex-Token"] = token
        return try? await HTTPClient().decode(User.self, from: URL(string: "https://plex.tv/api/v2/user")!, headers: headers).username
    }

    static func servers(token: String) async throws -> [Resource] {
        var headers = clientHeaders
        headers["X-Plex-Token"] = token
        let url = URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        return try await HTTPClient().decode([Resource].self, from: url, headers: headers).filter(\.isServer)
    }

    /// 依次测试服务器的连接地址，返回第一个可用的（优先局域网直连，最后才用中继）
    static func bestConnection(for resource: Resource) async -> URL? {
        let token = resource.accessToken
        let ordered = resource.connections.sorted { a, b in
            (a.relay ? 2 : a.local ? 0 : 1) < (b.relay ? 2 : b.local ? 0 : 1)
        }
        return await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, connection) in ordered.enumerated() {
                group.addTask {
                    guard let url = URL(string: connection.uri) else { return (index, nil) }
                    var headers = await clientHeaders
                    headers["X-Plex-Token"] = token
                    let ok = (try? await HTTPClient(timeout: 6).data(url.appending(path: "/identity", query: [:]), headers: headers)) != nil
                    return (index, ok ? url : nil)
                }
            }
            var results: [(Int, URL)] = []
            for await (index, url) in group {
                if let url { results.append((index, url)) }
            }
            return results.min { $0.0 < $1.0 }?.1
        }
    }

    // MARK: - 请求

    private func container(_ path: String, _ query: [String: String?] = [:]) async throws -> PlexContainer {
        let url = baseURL.appending(path: path, query: query)
        return try await http.decode(PlexResponse.self, from: url, headers: headers).mediaContainer
    }

    private func metadata(_ path: String, _ query: [String: String?] = [:]) async throws -> [MediaItem] {
        try await container(path, query.merging(["includeGuids": "1"]) { a, _ in a }).metadata?.map(map) ?? []
    }

    // MARK: - 浏览

    func libraries() async throws -> [MediaLibrary] {
        let result = try await container("/library/sections")
        return (result.directory ?? []).compactMap { dir in
            let kind: LibraryKind
            switch dir.type {
            case "movie": kind = .movies
            case "show": kind = .tvShows
            default: return nil
            }
            return MediaLibrary(id: dir.key, name: dir.title ?? "", kind: kind, imageURL: imageURL(dir.art ?? dir.thumb, width: 800, height: 450))
        }
    }

    func resumeItems(limit: Int) async throws -> [MediaItem] {
        let items = try await metadata("/hubs/continueWatching/items", ["X-Plex-Container-Size": "\(limit)"])
        return items.filter { $0.userState.playbackPosition > 0 }
    }

    func nextUp(limit: Int) async throws -> [MediaItem] {
        let items = try await metadata("/library/onDeck", ["X-Plex-Container-Size": "\(limit)"])
        return items.filter { $0.kind == .episode && $0.userState.playbackPosition == 0 }
    }

    func latest(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] {
        try await metadata("/library/sections/\(library.id)/recentlyAdded", ["X-Plex-Container-Size": "\(limit)"])
    }

    func items(parentID: String, kind: LibraryKind, query: LibraryQuery, start: Int, limit: Int) async throws -> PagedResult {
        let isSection = !parentID.hasPrefix("/")
        let direction = query.ascending ? "" : ":desc"
        var params: [String: String?] = [
            "X-Plex-Container-Start": "\(start)",
            "X-Plex-Container-Size": "\(limit)",
            "includeGuids": "1",
        ]
        params["sort"] = switch query.sort {
        case .name: "titleSort" + direction
        case .dateAdded: "addedAt" + direction
        case .premiereDate: "originallyAvailableAt" + direction
        case .rating: "audienceRating" + direction
        case .runtime: "duration" + direction
        case .random: "random"
        }
        if isSection {
            params["type"] = kind == .tvShows ? "2" : "1"
            switch query.filter {
            case .unplayed: params[kind == .tvShows ? "unwatchedLeaves" : "unwatched"] = "1"
            case .played: params[kind == .tvShows ? "unwatchedLeaves" : "unwatched"] = "0"
            case .resumable: params["inProgress"] = "1"
            case .all: break
            case .favorites: params["favorite"] = "1"
            }
            if let genre = query.genre {
                params["genre"] = genreKeys[parentID]?[genre] ?? genre
            }
        }
        let path = isSection ? "/library/sections/\(parentID)/all" : parentID
        let result = try await container(path, params)
        let items = result.metadata?.map(map) ?? []
        return PagedResult(items: items, total: result.totalSize ?? result.size ?? items.count)
    }

    func genres(parentID: String) async throws -> [String] {
        guard !parentID.hasPrefix("/") else { return [] }
        let result = try await container("/library/sections/\(parentID)/genre")
        var map: [String: String] = [:]
        let names = (result.directory ?? []).compactMap { dir -> String? in
            guard let title = dir.title else { return nil }
            map[title] = dir.key
            return title
        }
        genreKeys[parentID] = map
        return names
    }

    func childrenParentID(of item: MediaItem) -> String { "/library/metadata/\(item.id)/children" }

    func item(id: String) async throws -> MediaItem {
        guard let item = try await metadata("/library/metadata/\(id)").first else { throw APIError.notFound }
        return item
    }

    func seasons(seriesID: String) async throws -> [MediaItem] {
        try await metadata("/library/metadata/\(seriesID)/children").filter { $0.kind == .season }
    }

    func episodes(seriesID: String) async throws -> [MediaItem] {
        try await metadata("/library/metadata/\(seriesID)/allLeaves")
    }

    func similar(to item: MediaItem, limit: Int) async throws -> [MediaItem] {
        try await metadata("/library/metadata/\(item.seriesID ?? item.id)/similar", ["count": "\(limit)"])
    }

    func favorites() async throws -> [MediaItem] {
        var items: [MediaItem] = []
        for library in try await libraries() {
            let type = library.kind == .tvShows ? "2" : "1"
            let page = (try? await metadata("/library/sections/\(library.id)/all", ["favorite": "1", "type": type])) ?? []
            items.append(contentsOf: page)
        }
        return items
    }

    func segments(for item: MediaItem) async -> [MediaSegment] {
        guard let markers = try? await container("/library/metadata/\(item.id)", ["includeMarkers": "1"]).metadata?.first?.marker?.values else {
            return []
        }
        let mapped = markers.compactMap { marker -> MediaSegment? in
            guard let type = marker.type, let kind = MediaSegment.Kind.fromServer(type),
                  let start = marker.startTimeOffset, let end = marker.endTimeOffset else { return nil }
            return MediaSegment(id: marker.id.map(String.init) ?? "\(type)-\(start)", kind: kind,
                                start: TimeInterval(start) / 1000, end: TimeInterval(end) / 1000)
        }
        return MediaSegment.sanitized(mapped)
    }

    func search(_ term: String, limit: Int) async throws -> [MediaItem] {
        let result = try await container("/hubs/search", ["query": term, "limit": "\(limit)", "includeGuids": "1"])
        return (result.hub ?? [])
            .filter { ["movie", "show", "episode", "collection"].contains($0.type ?? "") }
            .flatMap { $0.metadata ?? [] }
            .map(map)
    }

    func setPlayed(_ played: Bool, item: MediaItem) async throws {
        let path = played ? "/:/scrobble" : "/:/unscrobble"
        _ = try await http.data(baseURL.appending(path: path, query: ["identifier": "com.plexapp.plugins.library", "key": item.id]), headers: headers)
    }

    func setFavorite(_ favorite: Bool, item: MediaItem) async throws {
        let url = baseURL.appending(path: "/library/metadata/\(item.id)", query: ["favorite": favorite ? "1" : "0"])
        _ = try await http.data(url, method: "PUT", headers: headers)
    }

    // MARK: - 播放

    func hlsURL(for item: MediaItem, source _: MediaSourceInfo, playSessionID: String) -> URL? {
        baseURL.appending(path: "/video/:/transcode/universal/start.m3u8", query: [
            "path": "/library/metadata/\(item.id)",
            "mediaIndex": "0",
            "partIndex": "0",
            "protocol": "hls",
            "fastSeek": "1",
            "directPlay": "0",
            "directStream": "1",
            "directStreamAudio": "1",
            "subtitles": "auto",
            "copyts": "1",
            "session": playSessionID,
            "X-Plex-Session-Identifier": playSessionID,
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": DeviceInfo.deviceID,
            "X-Plex-Product": DeviceInfo.clientName,
            "X-Plex-Platform": "iOS",
            "X-Plex-Client-Profile-Extra": "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3)",
        ])
    }

    private func timeline(_ report: PlaybackReport, state: String) async {
        let url = baseURL.appending(path: "/:/timeline", query: [
            "ratingKey": report.item.id,
            "key": "/library/metadata/\(report.item.id)",
            "state": state,
            "time": "\(Int(report.position * 1000))",
            "duration": "\(Int(report.duration * 1000))",
            "playbackTime": "\(Int(report.position * 1000))",
        ])
        var headers = headers
        headers["X-Plex-Session-Identifier"] = report.playSessionID
        _ = try? await http.data(url, headers: headers)
    }

    func reportStart(_ report: PlaybackReport) async {
        await timeline(report, state: "playing")
    }

    func reportProgress(_ report: PlaybackReport) async {
        await timeline(report, state: report.isPaused ? "paused" : "playing")
    }

    func reportStop(_ report: PlaybackReport) async {
        await timeline(report, state: "stopped")
    }

    // MARK: - 映射

    private func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return baseURL.appending(path: "/photo/:/transcode", query: [
            "url": path, "width": "\(width)", "height": "\(height)",
            "minSize": "1", "upscale": "1", "X-Plex-Token": token,
        ])
    }

    private func map(_ m: PlexMetadata) -> MediaItem {
        let kind: MediaKind = switch m.type {
        case "movie": .movie
        case "show": .series
        case "season": .season
        case "episode": .episode
        case "collection": .collection
        case "clip": .video
        default: .other
        }

        var providers: [String: String] = [:]
        for guid in m.guid ?? [] {
            let parts = guid.id.components(separatedBy: "://")
            if parts.count == 2 { providers[parts[0]] = parts[1] }
        }

        let poster: URL? = switch kind {
        case .episode: imageURL(m.grandparentThumb ?? m.parentThumb, width: 400, height: 600)
        case .season: imageURL(m.thumb ?? m.parentThumb, width: 400, height: 600)
        default: imageURL(m.thumb, width: 400, height: 600)
        }
        let backdrop = imageURL(m.art ?? m.grandparentArt, width: 1600, height: 900)
        let thumb = kind == .episode ? imageURL(m.thumb, width: 800, height: 450) ?? backdrop : backdrop
        let logo = imageURL(m.image?.first { $0.type == "clearLogo" }?.url, width: 800, height: 300)

        var user = UserState()
        user.playbackPosition = TimeInterval(m.viewOffset ?? 0) / 1000
        user.playCount = m.viewCount ?? 0
        if kind == .series || kind == .season, let leaves = m.leafCount {
            let viewed = m.viewedLeafCount ?? 0
            user.unplayedCount = max(0, leaves - viewed)
            user.isPlayed = leaves > 0 && viewed >= leaves
        } else {
            user.isPlayed = (m.viewCount ?? 0) > 0
        }
        user.isFavorite = m.userState?.favorite?.value ?? m.favorite?.value ?? false

        let sources = (m.media ?? []).enumerated().compactMap { index, media -> MediaSourceInfo? in
            guard let part = media.part?.first else { return nil }
            let streams = (part.stream ?? []).compactMap { s -> MediaStreamInfo? in
                let kind: MediaStreamInfo.Kind
                switch s.streamType {
                case 1: kind = .video
                case 2: kind = .audio
                case 3: kind = .subtitle
                default: return nil
                }
                let delivery = s.key.flatMap { key in
                    URL(string: baseURL.absoluteString + key + (key.contains("?") ? "&" : "?") + "X-Plex-Token=\(token ?? "")")
                }
                var range: String?
                if s.doviPresent == true { range = "DOVI" } else if s.colorTrc == "smpte2084" { range = "HDR10" } else if s.colorTrc == "arib-std-b67" { range = "HLG" }
                return MediaStreamInfo(
                    index: s.index ?? s.id, kind: kind, codec: s.codec, language: s.languageCode ?? s.language,
                    title: s.extendedDisplayTitle ?? s.displayTitle, isDefault: s.selected ?? s.default ?? false,
                    isForced: s.forced ?? false, isExternal: s.key != nil, deliveryURL: delivery,
                    channels: s.channels, width: s.width, height: s.height, bitRate: s.bitrate.map { $0 * 1000 },
                    videoRange: range, profile: s.profile, level: s.level,
                    isInterlaced: s.scanType.map { $0 == "interlaced" }, frameRate: s.frameRate, bitDepth: s.bitDepth,
                    pixelFormat: s.chromaSubsampling, refFrames: s.refFrames, sampleRate: s.samplingRate,
                    channelLayout: s.audioChannelLayout
                )
            }
            let direct = URL(string: baseURL.absoluteString + part.key + "?X-Plex-Token=\(token ?? "")")
            return MediaSourceInfo(
                id: "\(media.id)", name: media.videoResolution.map { $0.uppercased() + (index > 0 ? " #\(index + 1)" : "") } ?? "版本 \(index + 1)",
                container: part.container ?? media.container, size: part.size, bitrate: media.bitrate.map { $0 * 1000 },
                path: part.file, streams: streams, directURL: direct
            )
        }

        return MediaItem(
            id: m.ratingKey, serverID: account.id, kind: kind, name: m.title ?? "",
            originalTitle: m.originalTitle, overview: m.summary, tagline: m.tagline,
            year: m.year ?? m.parentYear, premiereDate: DateParsing.parse(m.originallyAvailableAt),
            runtime: m.duration.map { TimeInterval($0) / 1000 },
            communityRating: m.audienceRating ?? m.rating, criticRating: m.rating.map { $0 * 10 },
            officialRating: m.contentRating, genres: m.genre?.map(\.tag) ?? [],
            studios: m.studio.map { [$0] } ?? [],
            people: (m.role ?? []).map { MediaPerson(id: "\($0.id ?? 0)-\($0.tag)", name: $0.tag, role: $0.role, imageURL: $0.thumb.flatMap(URL.init(string:))) },
            posterURL: poster, backdropURL: backdrop, thumbURL: thumb, logoURL: logo,
            seriesID: kind == .episode ? m.grandparentRatingKey : (kind == .season ? m.parentRatingKey : nil),
            seriesName: kind == .episode ? m.grandparentTitle : (kind == .season ? m.parentTitle : nil),
            seasonID: kind == .episode ? m.parentRatingKey : nil,
            seasonNumber: kind == .episode ? m.parentIndex : (kind == .season ? m.index : nil),
            episodeNumber: kind == .episode ? m.index : nil,
            childCount: m.childCount ?? m.leafCount, userState: user, mediaSources: sources,
            providerIDs: providers, dateAdded: m.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

// MARK: - DTO

private struct PlexResponse: Decodable {
    let mediaContainer: PlexContainer
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

private struct PlexContainer: Decodable {
    struct Directory: Decodable {
        let key: String
        let title: String?
        let type: String?
        let thumb: String?
        let art: String?
    }

    struct Hub: Decodable {
        let type: String?
        let metadata: [PlexMetadata]?
        enum CodingKeys: String, CodingKey { case type, metadata = "Metadata" }
    }

    let size: Int?
    let totalSize: Int?
    let metadata: [PlexMetadata]?
    let directory: [Directory]?
    let hub: [Hub]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize
        case metadata = "Metadata"
        case directory = "Directory"
        case hub = "Hub"
    }
}

/// Plex 有时把单个 Marker 放成对象，有时放成数组
private struct PlexMarkers: Decodable {
    struct Marker: Decodable {
        let id: Int?
        let type: String?
        let startTimeOffset: Int?
        let endTimeOffset: Int?
    }

    let values: [Marker]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Marker].self) {
            values = many
        } else if let one = try? container.decode(Marker.self) {
            values = [one]
        } else {
            values = []
        }
    }
}

private struct PlexFlag: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            value = flag
        } else if let number = try? container.decode(Int.self) {
            value = number != 0
        } else if let text = try? container.decode(String.self) {
            value = text == "1" || text.lowercased() == "true"
        } else {
            value = false
        }
    }
}

private struct PlexUserState: Decodable {
    let favorite: PlexFlag?
}

private struct PlexMetadata: Decodable {
    struct Tag: Decodable { let tag: String }
    struct Guid: Decodable { let id: String }
    struct Image: Decodable { let type: String; let url: String }
    struct Role: Decodable {
        let id: Int?
        let tag: String
        let role: String?
        let thumb: String?
    }

    struct Media: Decodable {
        let id: Int
        let container: String?
        let bitrate: Int?
        let videoResolution: String?
        let part: [Part]?
        enum CodingKeys: String, CodingKey { case id, container, bitrate, videoResolution, part = "Part" }
    }

    struct Part: Decodable {
        let key: String
        let file: String?
        let size: Int64?
        let container: String?
        let stream: [Stream]?
        enum CodingKeys: String, CodingKey { case key, file, size, container, stream = "Stream" }
    }

    struct Stream: Decodable {
        let id: Int
        let streamType: Int
        let index: Int?
        let codec: String?
        let language: String?
        let languageCode: String?
        let displayTitle: String?
        let extendedDisplayTitle: String?
        let `default`: Bool?
        let selected: Bool?
        let forced: Bool?
        let key: String?
        let channels: Int?
        let width: Int?
        let height: Int?
        let bitrate: Int?
        let colorTrc: String?
        let doviPresent: Bool?
        let profile: String?
        let level: Int?
        let scanType: String?
        let frameRate: Double?
        let bitDepth: Int?
        let chromaSubsampling: String?
        let refFrames: Int?
        let samplingRate: Int?
        let audioChannelLayout: String?

        enum CodingKeys: String, CodingKey {
            case id, streamType, index, codec, language, languageCode, displayTitle, extendedDisplayTitle
            case `default`, selected, forced, key, channels, width, height, bitrate, colorTrc
            case profile, level, scanType, frameRate, bitDepth, chromaSubsampling, refFrames, samplingRate, audioChannelLayout
            case doviPresent = "DOVIPresent"
        }
    }

    let ratingKey: String
    let type: String?
    let title: String?
    let originalTitle: String?
    let summary: String?
    let tagline: String?
    let year: Int?
    let parentYear: Int?
    let originallyAvailableAt: String?
    let duration: Int?
    let rating: Double?
    let audienceRating: Double?
    let contentRating: String?
    let studio: String?
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let parentIndex: Int?
    let index: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let addedAt: Int?
    let favorite: PlexFlag?
    let userState: PlexUserState?
    let marker: PlexMarkers?
    let genre: [Tag]?
    let role: [Role]?
    let guid: [Guid]?
    let image: [Image]?
    let media: [Media]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, type, title, originalTitle, summary, tagline, year, parentYear, originallyAvailableAt
        case duration, rating, audienceRating, contentRating, studio, thumb, art, parentThumb, grandparentThumb
        case grandparentArt, parentTitle, grandparentTitle, parentRatingKey, grandparentRatingKey, parentIndex
        case index, leafCount, viewedLeafCount, childCount, viewCount, viewOffset, addedAt, favorite, userState
        case marker = "Marker"
        case genre = "Genre"
        case role = "Role"
        case guid = "Guid"
        case image = "Image"
        case media = "Media"
    }
}
