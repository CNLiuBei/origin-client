import Foundation

/// Jellyfin、Emby 与飞牛影视共用的客户端（API 同源，仅部分路径和鉴权头不同）。
/// 飞牛影视内置的是一个不完整的 Jellyfin 兼容层：查询参数名区分大小写（只认小驼峰）、
/// 只接受请求头鉴权、没有 Resume / Latest / Genres / Similar / 收藏 / HLS 接口，
/// 条目里的媒体流信息也不全，需要另取 PlaybackInfo。
final class JellyfinClient: MediaServerClient {
    let account: ServerAccount
    private let http: HTTPClient
    private var token: String?

    var supportsFavorites: Bool { !isFnOS }
    var supportsHLS: Bool { !isFnOS }
    var supportsLibraryQuery: Bool { !isFnOS }

    private var isEmby: Bool { account.kind == .emby }
    private var isFnOS: Bool { account.kind == .fnos }
    private var baseURL: URL { account.connectionURL }
    private var userID: String { account.userID }

    private static let listFields = "Overview,Genres,ProductionYear,ProviderIds,DateCreated,ChildCount,PrimaryImageAspectRatio,OfficialRating,CommunityRating"
    private static let detailFields = listFields + ",People,Studios,Taglines,OriginalTitle,MediaSources,MediaStreams,Path,CriticRating,PremiereDate"

    init(account: ServerAccount) {
        self.account = account
        token = account.token
        http = HTTPClient(timeout: account.advanced.timeout, allowsInsecureTLS: account.advanced.allowsInsecureTLS)
    }

    // MARK: - 登录

    struct PublicInfo: Decodable {
        let serverName: String?
        let version: String?
        let productName: String?
        let operatingSystem: String?
        let id: String?
    }

    struct AuthResult {
        let userID: String
        let username: String
        let token: String
        let serverName: String
    }

    /// 探测服务器类型（Jellyfin / Emby / 飞牛影视）
    static func probe(baseURL: URL, timeout: TimeInterval = 10, allowsInsecureTLS: Bool = false) async throws -> (ServerKind, PublicInfo) {
        let info = try await HTTPClient(timeout: timeout, allowsInsecureTLS: allowsInsecureTLS).decode(
            PublicInfo.self,
            from: baseURL.appending(path: "/System/Info/Public", query: [:]),
            decoder: .pascalCase
        )
        let kind: ServerKind = if info.operatingSystem?.caseInsensitiveCompare("fnOS") == .orderedSame {
            .fnos
        } else if info.productName?.localizedCaseInsensitiveContains("jellyfin") ?? false {
            .jellyfin
        } else {
            .emby
        }
        return (kind, info)
    }

    static func authenticate(baseURL: URL, kind: ServerKind, username: String, password: String, allowsInsecureTLS: Bool = false, timeout: TimeInterval = 20) async throws -> AuthResult {
        struct Response: Decodable {
            struct User: Decodable { let id: String; let name: String }
            let user: User
            let accessToken: String
            let serverId: String?
        }
        let (_, info) = try await probe(baseURL: baseURL, timeout: timeout, allowsInsecureTLS: allowsInsecureTLS)
        let body = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password, "Password": password])
        let response = try await HTTPClient(timeout: timeout, allowsInsecureTLS: allowsInsecureTLS).decode(
            Response.self,
            from: baseURL.appending(path: "/Users/AuthenticateByName", query: [:]),
            method: "POST",
            headers: authHeaders(kind: kind, token: nil),
            body: body,
            decoder: .pascalCase
        )
        return AuthResult(userID: response.user.id, username: response.user.name, token: response.accessToken, serverName: info.serverName ?? kind.displayName)
    }

    private static func authHeaders(kind: ServerKind, token: String?) -> [String: String] {
        var value = "MediaBrowser Client=\"\(DeviceInfo.clientName)\", Device=\"\(DeviceInfo.deviceName)\", DeviceId=\"\(DeviceInfo.deviceID)\", Version=\"\(DeviceInfo.version)\""
        if let token { value += ", Token=\"\(token)\"" }
        var headers = ["Accept": "application/json"]
        if kind == .emby || kind == .fnos {
            headers["X-Emby-Authorization"] = value
            if let token { headers["X-Emby-Token"] = token }
        } else {
            headers["Authorization"] = value
        }
        return headers
    }

    private var headers: [String: String] { Self.authHeaders(kind: account.kind, token: token) }

    var streamHeaders: [String: String] { headers }

    // MARK: - 请求

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String?] = [:]) async throws -> T {
        try await http.decode(T.self, from: url(path, query), headers: headers, decoder: .pascalCase)
    }

    private func send(_ method: String, _ path: String, _ query: [String: String?] = [:], body: [String: Any]? = nil) async throws {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        _ = try await http.data(url(path, query), method: method, headers: headers, body: data)
    }

    private func url(_ path: String, _ query: [String: String?]) -> URL {
        guard isFnOS else { return baseURL.appending(path: path, query: query) }
        var camel: [String: String?] = [:]
        for (key, value) in query { camel[key.prefix(1).lowercased() + key.dropFirst()] = value }
        return baseURL.appending(path: path, query: camel)
    }

    /// Jellyfin 10.9+ 使用 /Items?userId= 形式；Emby 仍使用 /Users/{id}/Items
    private func userPath(_ jellyfin: String, emby: String) -> String {
        isEmby ? "/Users/\(userID)" + emby : jellyfin
    }

    private var userQuery: [String: String?] { ["userId": userID] }

    private func fetchItems(_ path: String, _ query: [String: String?]) async throws -> PagedResult {
        let result = try await get(ItemsResponse.self, path, query.merging(userQuery) { a, _ in a })
        return PagedResult(items: result.items.map(map), total: result.totalRecordCount ?? result.items.count)
    }

    private var commonQuery: [String: String?] {
        ["Fields": Self.listFields, "EnableImageTypes": "Primary,Backdrop,Thumb,Logo", "ImageTypeLimit": "1"]
    }

    // MARK: - 浏览

    func libraries() async throws -> [MediaLibrary] {
        let result = try await get(ItemsResponse.self, userPath("/UserViews", emby: "/Views"), userQuery)
        return result.items.compactMap { dto in
            let kind: LibraryKind
            switch dto.collectionType?.lowercased() {
            case "movies": kind = .movies
            case "tvshows": kind = .tvShows
            case "boxsets": kind = .collections
            case "music", "books", "photos", "playlists", "livetv", "audiobooks": return nil
            default: kind = .mixed
            }
            return MediaLibrary(id: dto.id, name: dto.name ?? "", kind: kind, imageURL: image(dto.id, "Primary", tag: dto.imageTags?.value("primary"), width: 800))
        }
    }

    func resumeItems(limit: Int) async throws -> [MediaItem] {
        if isFnOS { return try await fnOSResumeItems(limit: limit) }
        return try await fetchItems(userPath("/UserItems/Resume", emby: "/Items/Resume"), commonQuery.merging([
            "Limit": "\(limit)", "MediaTypes": "Video", "Recursive": "true",
        ]) { a, _ in a }).items
    }

    /// 飞牛影视忽略 filters / sortBy，includeItemTypes 只认单个类型，且不带 parentId 的查询一律为空，
    /// 只能逐库、逐类型取回后在本地筛选
    private func fnOSResumeItems(limit: Int) async throws -> [MediaItem] {
        let libraries = try await libraries()
        let tasks = libraries.flatMap { library in
            ["Movie", "Episode"].map { type in (library, type) }
        }.map { library, type in
            Task {
                let result = try? await get(ItemsResponse.self, "/Items", userQuery.merging([
                    "ParentId": library.id, "Recursive": "true", "IncludeItemTypes": type,
                    "Limit": "2000", "Fields": Self.listFields,
                ]) { a, _ in a })
                return (result?.items ?? []).filter { dto in
                    guard let data = dto.userData else { return false }
                    return (data.playbackPositionTicks ?? 0) > 0 && data.played != true
                }
            }
        }
        var candidates: [ItemDto] = []
        for task in tasks { candidates += await task.value }
        return candidates
            .sorted { ($0.userData?.lastPlayedDate ?? "") > ($1.userData?.lastPlayedDate ?? "") }
            .prefix(limit)
            .map(map)
    }

    func nextUp(limit: Int) async throws -> [MediaItem] {
        try await fetchItems("/Shows/NextUp", commonQuery.merging([
            "Limit": "\(limit)", "EnableResumable": "false", "UserId": userID,
        ]) { a, _ in a }).items
    }

    func latest(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] {
        if isFnOS {
            // 飞牛影视库内默认就按添加时间倒序
            return try await fetchItems("/Items", commonQuery.merging([
                "ParentId": library.id, "Limit": "\(limit)",
            ]) { a, _ in a }).items
        }
        var query = commonQuery.merging(userQuery) { a, _ in a }
        query["ParentId"] = library.id
        query["Limit"] = "\(limit)"
        query["GroupItems"] = "true"
        let items = try await get([ItemDto].self, userPath("/Items/Latest", emby: "/Items/Latest"), query)
        return items.map(map)
    }

    func items(parentID: String, kind: LibraryKind, query: LibraryQuery, start: Int, limit: Int) async throws -> PagedResult {
        var params = commonQuery
        params["ParentId"] = parentID
        params["StartIndex"] = "\(start)"
        params["Limit"] = "\(limit)"
        params["SortOrder"] = query.ascending ? "Ascending" : "Descending"
        params["SortBy"] = switch query.sort {
        case .name: "SortName"
        case .dateAdded: "DateCreated,SortName"
        case .premiereDate: "PremiereDate,ProductionYear,SortName"
        case .rating: "CommunityRating,SortName"
        case .runtime: "Runtime,SortName"
        case .random: "Random"
        }
        switch kind {
        case .movies:
            params["IncludeItemTypes"] = "Movie"
            params["Recursive"] = "true"
        case .tvShows:
            params["IncludeItemTypes"] = "Series"
            params["Recursive"] = "true"
        case .collections:
            params["Recursive"] = "false"
        case .mixed:
            params["Recursive"] = "false"
        }
        params["Filters"] = switch query.filter {
        case .all: nil
        case .unplayed: "IsUnplayed"
        case .played: "IsPlayed"
        case .resumable: "IsResumable"
        case .favorites: "IsFavorite"
        }
        params["Genres"] = query.genre
        return try await fetchItems(userPath("/Items", emby: "/Items"), params)
    }

    func genres(parentID: String) async throws -> [String] {
        if isFnOS { return [] }
        let result = try await get(ItemsResponse.self, "/Genres", ["ParentId": parentID, "UserId": userID, "SortBy": "SortName"])
        return result.items.compactMap(\.name)
    }

    func childrenParentID(of item: MediaItem) -> String { item.id }

    func item(id: String) async throws -> MediaItem {
        var dto = try await get(ItemDto.self, userPath("/Items/\(id)", emby: "/Items/\(id)"), userQuery.merging(["Fields": Self.detailFields]) { a, _ in a })
        // 飞牛影视的 PlaybackInfo 带 userId 时部分条目会返回 400，改用 mediaSourceId
        if isFnOS, let sourceID = dto.mediaSources?.first?.id,
           let info = try? await get(PlaybackInfoResponse.self, "/Items/\(id)/PlaybackInfo", ["MediaSourceId": sourceID]) {
            dto.mediaSources = info.mediaSources
        }
        return map(dto)
    }

    func seasons(seriesID: String) async throws -> [MediaItem] {
        try await fetchItems("/Shows/\(seriesID)/Seasons", commonQuery.merging(["UserId": userID]) { a, _ in a }).items
    }

    func episodes(seriesID: String) async throws -> [MediaItem] {
        let query: [String: String?] = [
            "Fields": Self.listFields + ",MediaSources", "UserId": userID,
            "EnableImageTypes": "Primary,Thumb", "ImageTypeLimit": "1",
        ]
        guard isFnOS else {
            return try await fetchItems("/Shows/\(seriesID)/Episodes", query).items
        }
        // 飞牛影视不带 seasonId 时返回 null，只能逐季获取
        var result: [MediaItem] = []
        for season in try await seasons(seriesID: seriesID) {
            result += try await fetchItems("/Shows/\(seriesID)/Episodes", query.merging(["SeasonId": season.id]) { a, _ in a }).items
        }
        return result
    }

    func similar(to item: MediaItem, limit: Int) async throws -> [MediaItem] {
        if isFnOS { return [] }
        return try await fetchItems("/Items/\(item.seriesID ?? item.id)/Similar", commonQuery.merging(["Limit": "\(limit)"]) { a, _ in a }).items
    }

    func favorites() async throws -> [MediaItem] {
        if isFnOS { return [] }
        return try await fetchItems(userPath("/Items", emby: "/Items"), commonQuery.merging([
            "Filters": "IsFavorite", "Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode",
            "SortBy": "SortName", "Limit": "60",
        ]) { a, _ in a }).items
    }

    func segments(for item: MediaItem) async -> [MediaSegment] {
        if let remote = try? await get(MediaSegmentsResponse.self, "/MediaSegments/\(item.id)"), !remote.items.isEmpty {
            return MediaSegment.sanitized(remote.items.compactMap(Self.segment))
        }
        return await chapterSegments(for: item)
    }

    /// 没有 MediaSegments 时，用名为片头/片尾的章节推算区间
    private func chapterSegments(for item: MediaItem) async -> [MediaSegment] {
        struct Response: Decodable {
            struct Chapter: Decodable {
                let startPositionTicks: Int64
                let name: String?
            }

            let chapters: [Chapter]?
            let runTimeTicks: Int64?
        }
        guard let dto = try? await get(Response.self, userPath("/Items/\(item.id)", emby: "/Items/\(item.id)"),
                                       userQuery.merging(["Fields": "Chapters"]) { current, _ in current }),
              let chapters = dto.chapters, !chapters.isEmpty else { return [] }
        let runtime = TimeInterval(dto.runTimeTicks ?? 0) / 10_000_000
        let sorted = chapters.sorted { $0.startPositionTicks < $1.startPositionTicks }
        var result: [MediaSegment] = []
        for (index, chapter) in sorted.enumerated() {
            guard let kind = Self.chapterKind(chapter.name) else { continue }
            let start = TimeInterval(chapter.startPositionTicks) / 10_000_000
            let end: TimeInterval
            if index + 1 < sorted.count {
                end = TimeInterval(sorted[index + 1].startPositionTicks) / 10_000_000
            } else if runtime > start {
                end = runtime
            } else {
                continue
            }
            result.append(MediaSegment(id: "chapter-\(index)-\(kind.rawValue)", kind: kind, start: start, end: end))
        }
        return MediaSegment.sanitized(result)
    }

    private static func segment(_ segment: MediaSegmentsResponse.Segment) -> MediaSegment? {
        guard let kind = MediaSegment.Kind.fromServer(segment.type) else { return nil }
        return MediaSegment(
            id: segment.id ?? "\(segment.type)-\(segment.startTicks)",
            kind: kind,
            start: TimeInterval(segment.startTicks) / 10_000_000,
            end: TimeInterval(segment.endTicks) / 10_000_000
        )
    }

    /// “Intro End”只是片头的结束点，不能再当成一段片头
    private static func chapterKind(_ name: String?) -> MediaSegment.Kind? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else { return nil }
        let intro = name.contains("片头") || name.contains("intro") || name.contains("opening") || name == "op"
        let recap = name.contains("前情") || name.contains("recap") || name.contains("previously")
        let preview = name.contains("预告") || name.contains("preview") || name.contains("coming up")
        let credits = name.contains("片尾") || name.contains("credit") || name.contains("ending") || name == "ed"
        let endBoundary = (name.contains("end") || name.contains("结束")) && !credits && (intro || recap)
        if endBoundary { return nil }
        if recap { return .recap }
        if preview { return .preview }
        if intro { return .intro }
        if credits { return .credits }
        return nil
    }

    func search(_ term: String, limit: Int) async throws -> [MediaItem] {
        try await fetchItems(userPath("/Items", emby: "/Items"), commonQuery.merging([
            "SearchTerm": term, "Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode,BoxSet",
            "Limit": "\(limit)",
        ]) { a, _ in a }).items
    }

    func setPlayed(_ played: Bool, item: MediaItem) async throws {
        if isFnOS {
            try await send(played ? "POST" : "DELETE", "/Users/\(userID)/PlayedItems/\(item.id)")
            return
        }
        let path = userPath("/UserPlayedItems/\(item.id)", emby: "/PlayedItems/\(item.id)")
        try await send(played ? "POST" : "DELETE", path, isEmby ? [:] : userQuery)
    }

    func setFavorite(_ favorite: Bool, item: MediaItem) async throws {
        let path = userPath("/UserFavoriteItems/\(item.id)", emby: "/FavoriteItems/\(item.id)")
        try await send(favorite ? "POST" : "DELETE", path, isEmby ? [:] : userQuery)
    }

    // MARK: - 播放

    private var authQuery: [String: String?] {
        isEmby ? ["api_key": token] : ["ApiKey": token, "api_key": token]
    }

    func hlsURL(for item: MediaItem, source: MediaSourceInfo, playSessionID: String) -> URL? {
        baseURL.appending(path: "/Videos/\(item.id)/master.m3u8", query: authQuery.merging([
            "MediaSourceId": source.id,
            "DeviceId": DeviceInfo.deviceID,
            "PlaySessionId": playSessionID,
            "VideoCodec": "hevc,h264",
            "AudioCodec": "aac,ac3,eac3,mp3,flac,alac",
            "SegmentContainer": "mp4",
            "AllowVideoStreamCopy": "true",
            "AllowAudioStreamCopy": "true",
            "TranscodingMaxAudioChannels": "8",
            "RequireAvc": "false",
            "SubtitleMethod": "Hls",
            "BreakOnNonKeyFrames": "true",
        ]) { a, _ in a })
    }

    private func reportBody(_ report: PlaybackReport) -> [String: Any] {
        var body: [String: Any] = [
            "ItemId": report.item.id,
            "PlaySessionId": report.playSessionID,
            "PositionTicks": Int64(report.position * 10_000_000),
            "IsPaused": report.isPaused,
            "CanSeek": true,
            "PlayMethod": report.isTranscoding ? "Transcode" : "DirectPlay",
        ]
        if let id = report.mediaSourceID { body["MediaSourceId"] = id }
        return body
    }

    func reportStart(_ report: PlaybackReport) async {
        try? await send("POST", "/Sessions/Playing", body: reportBody(report))
    }

    func reportProgress(_ report: PlaybackReport) async {
        var body = reportBody(report)
        body["EventName"] = report.isPaused ? "Pause" : "TimeUpdate"
        try? await send("POST", "/Sessions/Playing/Progress", body: body)
    }

    func reportStop(_ report: PlaybackReport) async {
        try? await send("POST", "/Sessions/Playing/Stopped", body: reportBody(report))
        if report.isTranscoding {
            try? await send("DELETE", "/Videos/ActiveEncodings", ["DeviceId": DeviceInfo.deviceID, "PlaySessionId": report.playSessionID])
        }
    }

    // MARK: - 映射

    private func image(_ id: String?, _ type: String, tag: String?, width: Int, index: Int? = nil) -> URL? {
        guard let id, let tag else { return nil }
        // 飞牛影视不支持带序号的图片路径
        let path = "/Items/\(id)/Images/\(type)" + ((isFnOS ? nil : index).map { "/\($0)" } ?? "")
        return baseURL.appending(path: path, query: ["tag": tag, "maxWidth": "\(width)", "quality": "90"])
    }

    private func runtime(of dto: ItemDto) -> TimeInterval? {
        // 未解析的文件（如 ISO）媒体源时长是占位的 1 秒
        if let ticks = dto.mediaSources?.first?.runTimeTicks, ticks > 60 * 10_000_000 {
            return TimeInterval(ticks) / 10_000_000
        }
        guard let ticks = dto.runTimeTicks, ticks > 0 else { return nil }
        let value = TimeInterval(ticks) / 10_000_000
        // 飞牛影视条目上的 RunTimeTicks 实际是“分钟 × 10⁷”，媒体源上的才是真正的 ticks
        return isFnOS && value < 600 ? value * 60 : value
    }

    private func map(_ dto: ItemDto) -> MediaItem {
        let kind: MediaKind = switch dto.type?.lowercased() {
        case "movie": .movie
        case "series": .series
        case "season": .season
        case "episode": .episode
        case "boxset": .collection
        case "folder", "collectionfolder", "userview", "playlist": .folder
        case "video", "musicvideo", "trailer": .video
        default: dto.isFolder == true ? .folder : .other
        }
        let tags = dto.imageTags ?? [:]

        let ownPoster = image(dto.id, "Primary", tag: tags.value("primary"), width: 500)
        let seriesPoster = image(dto.seriesId, "Primary", tag: dto.seriesPrimaryImageTag, width: 500)
        let poster: URL? = switch kind {
        case .episode: seriesPoster ?? ownPoster
        case .season: ownPoster ?? seriesPoster
        default: ownPoster
        }

        let backdrop = image(dto.id, "Backdrop", tag: dto.backdropImageTags?.first, width: 1600, index: 0)
            ?? image(dto.parentBackdropItemId, "Backdrop", tag: dto.parentBackdropImageTags?.first, width: 1600, index: 0)

        let thumb: URL? = switch kind {
        case .episode: ownPoster ?? image(dto.parentThumbItemId, "Thumb", tag: dto.parentThumbImageTag, width: 800) ?? backdrop
        default: image(dto.id, "Thumb", tag: tags.value("thumb"), width: 800)
            ?? image(dto.parentThumbItemId, "Thumb", tag: dto.parentThumbImageTag, width: 800)
            ?? backdrop
        }

        let logo = image(dto.id, "Logo", tag: tags.value("logo"), width: 800)
            ?? image(dto.parentLogoItemId, "Logo", tag: dto.parentLogoImageTag, width: 800)

        var user = UserState()
        if let data = dto.userData {
            user.isPlayed = data.played ?? false
            user.isFavorite = data.isFavorite ?? false
            user.playbackPosition = TimeInterval(data.playbackPositionTicks ?? 0) / 10_000_000
            user.playCount = data.playCount ?? 0
            user.unplayedCount = data.unplayedItemCount
        }

        // 飞牛影视条目里的媒体源缺少容器和音视频流，丢弃后由 item(id:) 用 PlaybackInfo 补齐
        let rawSources = (dto.mediaSources ?? []).filter { !isFnOS || $0.container != nil || $0.isDiscImage }
        let sources = rawSources.map { source in
            let streams = (source.mediaStreams ?? []).enumerated().compactMap { position, stream -> MediaStreamInfo? in
                let kind: MediaStreamInfo.Kind
                switch stream.type?.lowercased() {
                case "video": kind = .video
                case "audio": kind = .audio
                case "subtitle": kind = .subtitle
                default: return nil
                }
                var delivery: URL?
                if kind == .subtitle, stream.isExternal == true, let index = stream.index {
                    let format = (stream.codec?.lowercased()).flatMap { ["ass", "ssa", "srt", "vtt"].contains($0) ? $0 : nil } ?? "srt"
                    delivery = baseURL.appending(path: "/Videos/\(dto.id)/\(source.id)/Subtitles/\(index)/0/Stream.\(format)", query: authQuery)
                }
                return MediaStreamInfo(
                    // 飞牛影视所有流的 Index 都是 0，改用出现顺序
                    index: isFnOS ? position : stream.index ?? 0, kind: kind, codec: stream.codec, language: stream.language,
                    title: stream.displayTitle ?? stream.title, isDefault: stream.isDefault ?? false,
                    isForced: stream.isForced ?? false, isExternal: stream.isExternal ?? false,
                    deliveryURL: delivery, channels: stream.channels, width: stream.width, height: stream.height,
                    bitRate: stream.bitRate, videoRange: stream.videoRangeType ?? stream.videoRange,
                    profile: stream.profile.flatMap { $0.isEmpty ? nil : $0 }, level: stream.level.flatMap { $0 > 0 ? Int($0) : nil },
                    aspectRatio: stream.aspectRatio, isInterlaced: kind == .video ? stream.isInterlaced : nil,
                    frameRate: stream.realFrameRate ?? stream.averageFrameRate, bitDepth: stream.bitDepth,
                    pixelFormat: stream.pixelFormat, refFrames: stream.refFrames, sampleRate: stream.sampleRate,
                    channelLayout: stream.channelLayout
                )
            }
            // 飞牛影视只认 static + MediaSourceId（大写 M）这一种写法，鉴权走请求头；ISO 原盘不提供播放流
            let direct = isFnOS
                ? (source.isDiscImage ? nil : baseURL.appending(path: "/Videos/\(dto.id)/stream", query: ["static": "true", "MediaSourceId": source.id]))
                : baseURL.appending(path: "/Videos/\(dto.id)/stream", query: authQuery.merging([
                    "static": "true", "mediaSourceId": source.id, "deviceId": DeviceInfo.deviceID,
                ]) { a, _ in a })
            return MediaSourceInfo(
                id: source.id, name: source.name ?? dto.name ?? "", container: source.container,
                size: source.size, bitrate: source.bitrate, path: source.path, streams: streams, directURL: direct
            )
        }

        var providers: [String: String] = [:]
        for (key, value) in dto.providerIds ?? [:] { providers[key.lowercased()] = value }

        return MediaItem(
            id: dto.id, serverID: account.id, kind: kind, name: dto.name ?? "",
            originalTitle: dto.originalTitle, overview: dto.overview, tagline: dto.taglines?.first,
            year: dto.productionYear, premiereDate: DateParsing.parse(dto.premiereDate),
            runtime: runtime(of: dto),
            communityRating: dto.communityRating, criticRating: dto.criticRating, officialRating: dto.officialRating,
            genres: dto.genres ?? [], studios: dto.studios?.compactMap(\.name) ?? [],
            people: (dto.people ?? []).map { person in
                MediaPerson(id: person.id ?? person.name ?? UUID().uuidString, name: person.name ?? "",
                            role: person.role ?? person.type,
                            imageURL: image(person.id, "Primary", tag: person.primaryImageTag, width: 300))
            },
            posterURL: poster, backdropURL: backdrop, thumbURL: thumb, logoURL: logo,
            seriesID: dto.seriesId, seriesName: dto.seriesName, seasonID: dto.seasonId,
            seasonNumber: kind == .season ? dto.indexNumber : dto.parentIndexNumber,
            episodeNumber: kind == .episode ? dto.indexNumber : nil,
            childCount: dto.childCount, userState: user, mediaSources: sources,
            providerIDs: providers, dateAdded: DateParsing.parse(dto.dateCreated),
            endDate: DateParsing.parse(dto.endDate), seriesStatus: dto.status
        )
    }
}

// MARK: - DTO（键名统一由 PascalCase 转为 camelCase）

private struct MediaSegmentsResponse: Decodable {
    struct Segment: Decodable {
        let id: String?
        let type: String
        let startTicks: Int64
        let endTicks: Int64
    }

    let items: [Segment]
}

private struct ItemsResponse: Decodable {
    let items: [ItemDto]
    let totalRecordCount: Int?
}

private struct PlaybackInfoResponse: Decodable {
    let mediaSources: [ItemDto.Source]
}

private struct ItemDto: Decodable {
    struct UserData: Decodable {
        let playbackPositionTicks: Int64?
        let lastPlayedDate: String?
        let playCount: Int?
        let isFavorite: Bool?
        let played: Bool?
        let unplayedItemCount: Int?
    }

    struct Person: Decodable {
        let id: String?
        let name: String?
        let role: String?
        let type: String?
        let primaryImageTag: String?
    }

    struct NamePair: Decodable { let name: String? }

    struct Source: Decodable {
        let id: String
        let name: String?
        let container: String?
        let size: Int64?
        let bitrate: Int?
        let path: String?
        let runTimeTicks: Int64?
        let mediaStreams: [Stream]?

        var isDiscImage: Bool { path?.lowercased().hasSuffix(".iso") ?? false }
    }

    struct Stream: Decodable {
        let type: String?
        let codec: String?
        let language: String?
        let title: String?
        let displayTitle: String?
        let isDefault: Bool?
        let isForced: Bool?
        let isExternal: Bool?
        let index: Int?
        let channels: Int?
        let width: Int?
        let height: Int?
        let bitRate: Int?
        let videoRange: String?
        let videoRangeType: String?
        let profile: String?
        let level: Double?
        let aspectRatio: String?
        let isInterlaced: Bool?
        let realFrameRate: Double?
        let averageFrameRate: Double?
        let bitDepth: Int?
        let pixelFormat: String?
        let refFrames: Int?
        let sampleRate: Int?
        let channelLayout: String?
    }

    let id: String
    let name: String?
    let originalTitle: String?
    let type: String?
    let isFolder: Bool?
    let collectionType: String?
    let overview: String?
    let taglines: [String]?
    let productionYear: Int?
    let premiereDate: String?
    let endDate: String?
    let status: String?
    let dateCreated: String?
    let runTimeTicks: Int64?
    let communityRating: Double?
    let criticRating: Double?
    let officialRating: String?
    let genres: [String]?
    let studios: [NamePair]?
    let people: [Person]?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemId: String?
    let parentLogoImageTag: String?
    let parentThumbItemId: String?
    let parentThumbImageTag: String?
    let seriesId: String?
    let seriesName: String?
    let seriesPrimaryImageTag: String?
    let seasonId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let childCount: Int?
    let userData: UserData?
    var mediaSources: [Source]?
    let providerIds: [String: String]?
}

private extension Dictionary where Key == String, Value == String {
    func value(_ key: String) -> String? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

private nonisolated struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = "\(intValue)"; self.intValue = intValue }
}

extension JSONDecoder {
    /// Jellyfin / Emby 返回 PascalCase 键名
    static var pascalCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!
            if key.intValue != nil { return key }
            let s = key.stringValue
            return AnyCodingKey(stringValue: s.prefix(1).lowercased() + s.dropFirst())
        }
        return decoder
    }
}
