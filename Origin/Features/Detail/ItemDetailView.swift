import SwiftUI

struct ItemDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass
    let item: MediaItem

    @State private var detail: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var episodes: [MediaItem] = []
    @State private var selectedSeasonKey: String?
    @State private var similar: [MediaItem] = []
    @State private var tmdb: TMDBEnrichment?
    @State private var selectedSourceID: String?
    @State private var overviewExpanded = false
    @State private var errorText: String?
    @State private var loadedRevision: Int?
    @State private var contentWidth: CGFloat = 390

    private var current: MediaItem { detail ?? item }
    private var client: (any MediaServerClient)? { app.client(for: item.serverID) }
    private var source: MediaSourceInfo? {
        current.mediaSources.first { $0.id == selectedSourceID } ?? current.mediaSources.first
    }

    private var seriesID: String? {
        switch current.kind {
        case .series: current.id
        case .season, .episode: current.seriesID
        default: nil
        }
    }

    /// 剧集的“播放”目标：观看中的一集，否则第一集未看的
    private var playTarget: MediaItem? {
        switch current.kind {
        case .series, .season:
            let pool = current.kind == .season ? episodes.filter { $0.seasonID == current.id || $0.seasonNumber == current.seasonNumber } : episodes
            return pool.first { $0.isResumable } ?? pool.first { !$0.userState.isPlayed } ?? pool.first
        default:
            return current.kind.isPlayable ? current : nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                VStack(alignment: .leading, spacing: 28) {
                    overview
                    if !episodes.isEmpty, seriesID != nil {
                        EpisodesSection(current: current, groups: seasonGroups, playTargetID: playTarget?.id,
                                        selectedSeasonKey: $selectedSeasonKey)
                    }
                    castSection
                    infoSection
                    if current.kind.isPlayable, let source { MediaInfoSection(source: source, runtime: current.runtime) }
                    if !similar.isEmpty {
                        Shelf(title: "相似推荐") {
                            ForEach(similar) { item in
                                NavigationLink(value: item) { PosterCard(item: item).frame(width: 120) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, -16)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 32)
            .hideSystemScrollbars()
        }
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .scrollEdgeEffectHidden(true, for: .top)
        .ignoresSafeArea(edges: .top)
        .background { AmbientBackground(url: current.posterURL ?? heroImageURL) }
        .hidesTabBar()
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
        .task(id: app.contentRevision) {
            // 切换标签或从下一级返回时不重复加载，内容有变化（如播放进度更新）才刷新
            guard loadedRevision != app.contentRevision else { return }
            loadedRevision = app.contentRevision
            await load()
        }
    }

    // MARK: - 头图

    /// 手机上电影/剧集用竖版海报铺满宽度，单集与 iPad 用横版剧照
    private var usesPortraitHero: Bool {
        sizeClass != .regular && current.kind != .episode && current.posterURL != nil
    }

    private var heroImageURL: URL? {
        if usesPortraitHero { return current.posterURL }
        let landscape = current.kind == .episode
            ? current.thumbURL ?? current.backdropURL
            : current.backdropURL ?? tmdb?.backdropURL ?? current.thumbURL
        return landscape ?? current.posterURL
    }

    private var heroImageHeight: CGFloat {
        let height = contentWidth / (usesPortraitHero ? 2 / 3 : 16 / 9)
        return min(height, sizeClass == .regular ? 560 : 640)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            RemoteImage(url: heroImageURL)
                .frame(height: heroImageHeight)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0.45),
                        .init(color: .black.opacity(0.45), location: 0.72),
                        .init(color: .clear, location: 0.94),
                    ], startPoint: .top, endPoint: .bottom)
                }
                // 下拉时放大头图；visualEffect 只影响绘制，滚动不会触发重新布局
                .visualEffect { content, proxy in
                    let pull = max(0, proxy.frame(in: .scrollView).minY)
                    return content.scaleEffect(1 + pull / max(proxy.size.height, 1), anchor: .bottom)
                }

            titleBlock
                .padding(.horizontal)
                .padding(.top, usesPortraitHero ? -230 : -200)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 8) {
            if current.kind == .episode, let seriesName = current.seriesName {
                Text(seriesName).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let logo = (current.kind == .episode ? nil : current.logoURL ?? tmdb?.logoURL) {
                AuthorizedImage(url: logo) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    titleText
                }
                .frame(maxWidth: 260, maxHeight: 90)
            } else {
                titleText
            }
            detailMeta
            if current.kind.isPlayable, let source { MediaBadges(source: source) }
            if let target = playTarget {
                playButton(target)
                    .padding(.top, 4)
            }
            actionRow
        }
        .frame(maxWidth: .infinity)
    }

    private var titleText: some View {
        Text(current.kind == .episode ? [current.episodeLabel, current.name].compactMap(\.self).joined(separator: " · ") : current.name)
            .font(.title.bold())
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .shadow(color: .black.opacity(0.2), radius: 6)
    }

    private var metaDate: String? {
        if current.kind == .series, let range = current.yearRange, range.contains("-") { return range }
        guard let date = current.premiereDate else { return current.yearRange }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    private var metaExtra: [String] {
        var extra: [String] = []
        if current.kind.isPlayable, let runtime = current.runtime { extra.append(runtime.durationString) }
        if current.kind == .series, seasons.count > 1 { extra.append("\(seasons.count) 季") }
        if let official = current.officialRating { extra.append(official) }
        return extra
    }

    // MARK: - 操作

    private func playButton(_ target: MediaItem) -> some View {
        Button {
            app.player.play(target, resume: true, sourceID: target.id == current.id ? selectedSourceID : nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text(playTitle(for: target))
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: 340)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("detail-play")
    }

    private func playTitle(for target: MediaItem) -> String {
        let prefix = target.isResumable ? "继续" : "播放"
        if target.id != current.id, let label = target.episodeLabel {
            return "\(prefix) \(label)"
        }
        if target.isResumable, let runtime = target.runtime {
            return "\(prefix) · 剩余 \((runtime - target.userState.playbackPosition).durationString)"
        }
        return prefix
    }

    private var actionRow: some View {
        HStack(spacing: 36) {
            if client?.supportsFavorites == true {
                iconButton(current.userState.isFavorite ? "heart.fill" : "heart", label: current.userState.isFavorite ? "取消收藏" : "收藏") {
                    Task { try? await app.toggleFavorite(current) }
                }
            }
            iconButton(current.userState.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                       label: current.userState.isPlayed ? "标记为未看" : "标记为已看") {
                Task { try? await app.togglePlayed(current) }
            }
            if let target = playTarget, target.isResumable {
                iconButton("arrow.counterclockwise", label: "从头播放") {
                    app.player.play(target, resume: false, sourceID: target.id == current.id ? selectedSourceID : nil)
                }
            }
            if current.kind.isPlayable { downloadButton }
            if let trailer = tmdb?.trailerURL {
                iconButton("play.rectangle", label: "预告片") { openURL(trailer) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var downloadButton: some View {
        let record = app.downloads.record(for: current.id)
        Button {
            if record == nil, !current.mediaSources.isEmpty {
                app.downloads.download(current)
            }
        } label: {
            Group {
                switch record?.state {
                case .completed:
                    Image(systemName: "arrow.down.circle.fill")
                case .downloading, .queued:
                    ProgressView(value: record?.progress ?? 0)
                        .progressViewStyle(.circular)
                case .paused, .failed:
                    Image(systemName: "pause.circle")
                case nil:
                    Image(systemName: "arrow.down.circle")
                }
            }
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("下载")
    }

    private var moreMenu: some View {
        Menu {
            if current.mediaSources.count > 1 {
                Picker("版本", selection: Binding(get: { selectedSourceID ?? current.mediaSources.first?.id }, set: { selectedSourceID = $0 })) {
                    ForEach(current.mediaSources) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if current.kind == .episode, let seriesID = current.seriesID {
                NavigationLink(value: MediaItem(id: seriesID, serverID: current.serverID, kind: .series, name: current.seriesName ?? "")) {
                    Label("前往剧集", systemImage: "tv")
                }
            }
            if let url = tmdb?.tmdbURL {
                Link(destination: url) { Label("在 TMDB 查看", systemImage: "safari") }
            }
            if let url = tmdb?.tmdbURL {
                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    // MARK: - 简介与信息

    /// 简介前的「剧名 · 第1季 · 第1集」
    private var overviewPrefix: String {
        switch current.kind {
        case .series:
            let season = seasonGroups.count == 1 ? seasonGroups.first?.title : nil
            return [current.name, season].compactMap(\.self).joined(separator: " · ")
        case .season:
            return [current.seriesName, current.name].compactMap(\.self).joined(separator: " · ")
        case .episode:
            return [current.seriesName, current.seasonNumber.map { "第\($0)季" }, current.episodeNumber.map { "第\($0)集" }]
                .compactMap(\.self).joined(separator: " · ")
        default:
            return current.name
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let text = current.overview ?? tmdb?.overview, !text.isEmpty {
            Text("\(Text("「\(overviewPrefix)」").fontWeight(.semibold))\(text)")
                .font(.subheadline)
                .lineLimit(overviewExpanded ? nil : 3)
                .onTapGesture { withAnimation { overviewExpanded.toggle() } }
        }
    }

    /// 星级、TMDB、烂番茄原来分两处，这里并进标题下的同一行
    private var detailMeta: some View {
        let tmdbScore = tmdb?.voteAverage.flatMap { $0 > 0 ? $0 : nil }
        let community = current.communityRating.flatMap { $0 > 0 ? $0 : nil }
        let critic = current.criticRating.flatMap { $0 > 0 ? $0 : nil }
        let parts = ([metaDate, current.genres.prefix(3).joined(separator: ",")] + metaExtra.map { Optional($0) })
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        let hasScore = tmdbScore != nil || community != nil || critic != nil
        return HStack(spacing: 6) {
            if let tmdbScore {
                ratingChip("TMDB", color: .teal, value: tmdbScore.formatted(.number.precision(.fractionLength(1))))
            } else if let community {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(community.formatted(.number.precision(.fractionLength(1))))
                }
            }
            if let critic {
                ratingChip("烂番茄", color: .red, value: "\(Int(critic.rounded()))%")
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 || hasScore {
                    Text("|").foregroundStyle(.tertiary)
                }
                Text(part)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func ratingChip(_ name: String, color: Color, value: String) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color, in: .rect(cornerRadius: 3))
            Text(value).font(.footnote.weight(.medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var castSection: some View {
        let people = current.people.filter { $0.role?.lowercased() != "director" && $0.role?.lowercased() != "writer" }
        let cast = people.contains { $0.imageURL != nil } ? people : (tmdb?.cast ?? people)
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("演职人员").font(.title3.bold())
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(cast.prefix(30)) { person in
                            VStack(spacing: 6) {
                                RemoteImage(url: person.imageURL, aspectRatio: 1, placeholderSymbol: "person.fill")
                                    .clipShape(.circle)
                                Text(person.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text(person.role ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            // 固定按一屏 5 人（iPad 8 人）等分，人数不足时也不会被拉大
                            .containerRelativeFrame(.horizontal, count: sizeClass == .regular ? 8 : 5, spacing: 12)
                        }
                    }
                    .scrollTargetLayout()
                    .hideSystemScrollbars()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        let directors = current.people.filter { $0.role?.lowercased() == "director" }.map(\.name)
        let rows: [(String, String)] = [
            ("类型", current.genres.joined(separator: "、")),
            ("导演", directors.joined(separator: "、")),
            ("出品", current.studios.prefix(3).joined(separator: "、")),
            ("原标题", current.originalTitle != current.name ? current.originalTitle ?? "" : ""),
            ("首映", current.premiereDate?.formatted(date: .long, time: .omitted) ?? ""),
        ].filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        Text(row.1)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    // MARK: - 季与集

    private var seasonGroups: [SeasonGroup] {
        var order: [String] = []
        var groups: [String: [MediaItem]] = [:]
        for episode in episodes {
            let key = episode.seasonID ?? "s\(episode.seasonNumber ?? 0)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(episode)
        }
        return order.map { key in
            let first = groups[key]!.first!
            let season = seasons.first { $0.id == key }
            let title = season?.name ?? first.seasonNumber.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "剧集"
            return (key, title, groups[key]!)
        }
    }

    // MARK: - 加载

    private func load() async {
        guard let client else { return }
        do {
            let full = try await client.item(id: item.id)
            detail = full
            errorText = nil
            if let seriesID = full.kind == .series ? full.id : full.seriesID {
                async let seasonsTask = try? client.seasons(seriesID: seriesID)
                async let episodesTask = try? client.episodes(seriesID: seriesID)
                seasons = await seasonsTask ?? []
                episodes = await episodesTask ?? []
                if selectedSeasonKey == nil {
                    let anchor = full.kind == .episode ? full : (full.kind == .season ? nil : playTarget)
                    selectedSeasonKey = full.kind == .season ? full.id : anchor.map { $0.seasonID ?? "s\($0.seasonNumber ?? 0)" }
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
        if similar.isEmpty, current.kind == .movie || current.kind == .series {
            similar = (try? await client.similar(to: current, limit: 16)) ?? []
        }
        if tmdb == nil, app.settings.tmdbEnabled {
            tmdb = await app.tmdb.enrichment(for: current)
        }
    }
}

// MARK: - 季与集

typealias SeasonGroup = (key: String, title: String, items: [MediaItem])

/// 剧集区单独成视图：横向滚动只刷新这一块，不会带动整个详情页重算
private struct EpisodesSection: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let current: MediaItem
    let groups: [SeasonGroup]
    let playTargetID: String?
    @Binding var selectedSeasonKey: String?
    @State private var episodeScrollID: String?
    @State private var hoveringEpisodes = false

    /// 每 10 集一段：1-10、11-20…
    private func episodeRanges(_ items: [MediaItem]) -> [(label: String, firstID: String, ids: Set<String>)] {
        stride(from: 0, to: items.count, by: 10).map { start in
            let chunk = items[start..<min(start + 10, items.count)]
            let lower = chunk.first?.episodeNumber ?? start + 1
            let upper = chunk.last?.episodeNumber ?? start + chunk.count
            return ("\(lower)-\(upper)", chunk.first!.id, Set(chunk.map(\.id)))
        }
    }

    var body: some View {
        let selected = groups.first { $0.key == selectedSeasonKey } ?? groups.first
        let items = selected?.items ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                seasonTitle(groups: groups, selected: selected)
                Spacer()
                if items.count > 2 {
                    NavigationLink {
                        EpisodeGridView(title: [current.seriesName ?? (current.kind == .series ? current.name : nil), selected?.title]
                                            .compactMap(\.self).joined(separator: " "),
                                        episodes: items, currentID: current.id)
                    } label: {
                        SeeAllLabel()
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { episode in
                        EpisodeCard(episode: episode, isCurrent: episode.id == current.id)
                            .containerRelativeFrame(.horizontal, count: sizeClass == .regular ? 4 : 2, spacing: 14, alignment: .leading)
                    }
                }
                .scrollTargetLayout()
                .hideSystemScrollbars()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $episodeScrollID, anchor: .leading)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
            .onAppear { focusEpisode(in: items) }
            .onChange(of: selected?.key) { focusEpisode(in: items) }
            .overlay(alignment: .leading) { episodeButton(items, forward: false) }
            .overlay(alignment: .trailing) { episodeButton(items, forward: true) }
            .onHover { hoveringEpisodes = $0 }

            let ranges = episodeRanges(items)
            if ranges.count > 1 {
                let active = ranges.firstIndex { $0.ids.contains(episodeScrollID ?? "") } ?? 0
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                                Button {
                                    withAnimation { episodeScrollID = range.firstID }
                                } label: {
                                    Text(range.label)
                                        .font(.footnote.weight(index == active ? .semibold : .regular))
                                        .monospacedDigit()
                                        .foregroundStyle(index == active ? .primary : .secondary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(index == active ? .regular.tint(Color.primary.opacity(0.12)).interactive() : .regular.interactive(),
                                             in: .capsule)
                                .accessibilityLabel("第 \(range.label) 集")
                                .accessibilityAddTraits(index == active ? .isSelected : [])
                            }
                        }
                    }
                }
                .hideSystemScrollbars()
                // 不裁剪内容，玻璃的阴影才不会在上下边缘被切成一条色带
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
            }
        }
    }

    @ViewBuilder
    private func seasonTitle(groups: [SeasonGroup], selected: SeasonGroup?) -> some View {
        if groups.count > 1 {
            Picker("季", selection: Binding(
                get: { selected?.key ?? "" },
                set: { key in withAnimation { selectedSeasonKey = key } }
            )) {
                ForEach(groups, id: \.key) { group in
                    Text(group.title).tag(group.key)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.headline)
            .tint(.primary)
            .accessibilityLabel("\(selected?.title ?? "剧集")，共 \(groups.count) 季，轻点切换")
        } else {
            Text(selected?.title ?? "剧集").font(.headline)
        }
    }

    /// 鼠标没有滚动条可拖时，悬停后用两侧按钮翻页
    private func episodeButton(_ items: [MediaItem], forward: Bool) -> some View {
        let index = items.firstIndex { $0.id == episodeScrollID } ?? 0
        let canMove = forward ? index < items.count - 1 : index > 0
        let visible = hoveringEpisodes && canMove
        return Button {
            let step = sizeClass == .regular ? 4 : 2
            let next = min(max(0, index + (forward ? step : -step)), items.count - 1)
            guard items.indices.contains(next) else { return }
            withAnimation(.snappy(duration: 0.35)) { episodeScrollID = items[next].id }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: .circle)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityLabel(forward ? "后面的剧集" : "前面的剧集")
        .animation(.snappy(duration: 0.2), value: visible)
    }

    /// 定位到当前单集，或系列里接下来要播放的那一集
    private func focusEpisode(in items: [MediaItem]) {
        let focused = items.first { $0.id == current.id } ?? items.first { $0.id == playTargetID } ?? items.first
        episodeScrollID = focused?.id
    }

}

// MARK: - 全部单集

/// “查看全部”：两列网格列出本季所有单集
private struct EpisodeGridView: View {
    let title: String
    let episodes: [MediaItem]
    var currentID: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], alignment: .leading, spacing: 18) {
                ForEach(episodes) { episode in
                    EpisodeCard(episode: episode, isCurrent: episode.id == currentID)
                }
            }
            .padding()
            .hideSystemScrollbars()
        }
        .scrollIndicators(.hidden)
        .navigationTitle(title)
        .inlineNavigationTitle()
    }
}

// MARK: - 单集卡片

/// 单集卡片：点击直接播放，长按查看更多操作
private struct EpisodeCard: View {
    @Environment(AppModel.self) private var app
    let episode: MediaItem
    var isCurrent = false

    private var title: String {
        episode.episodeNumber.map { "\($0).\(episode.name)" } ?? episode.name
    }

    private var accessibilityText: String {
        [episode.episodeNumber.map { "第 \($0) 集" }, episode.name, episode.runtime?.durationString]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    var body: some View {
        Button {
            app.player.play(episode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: episode.thumbURL, aspectRatio: 16 / 9)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        WatchBadge(item: episode).padding(6)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        RatingBadge(rating: episode.communityRating).padding(6)
                    }
                    .overlay(alignment: .bottom) {
                        if episode.progress > 0, !episode.userState.isPlayed {
                            ProgressBar(progress: episode.progress).padding(8)
                        }
                    }
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(.white, lineWidth: 2.5)
                                .shadow(color: .black.opacity(0.2), radius: 3)
                        }
                    }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("播放")
        .contextMenu {
            NavigationLink(value: episode) {
                Label("查看详情", systemImage: "info.circle")
            }
            ItemContextMenu(item: episode)
        } preview: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: episode.thumbURL, aspectRatio: 16 / 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let overview = episode.overview {
                        Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(5)
                    }
                }
                .padding([.horizontal, .bottom], 12)
            }
            .frame(width: 320)
        }
    }
}

// MARK: - 媒体规格

struct MediaBadges: View {
    let source: MediaSourceInfo

    private var badges: [String] {
        var result: [String] = []
        if let video = source.videoStream {
            if let width = video.width {
                result.append(width >= 3800 ? "4K" : width >= 1900 ? "1080P" : width >= 1260 ? "720P" : "SD")
            }
            switch video.videoRange?.uppercased() {
            case let range? where range.contains("DOVI") || range.contains("DOLBY"): result.append("杜比视界")
            case let range? where range.contains("HDR10PLUS") || range.contains("HDR10+"): result.append("HDR10+")
            case let range? where range.contains("HDR") || range.contains("PQ"): result.append("HDR10")
            case let range? where range.contains("HLG"): result.append("HLG")
            default: break
            }
            if let codec = video.codec?.uppercased() { result.append(codec == "H265" ? "HEVC" : codec) }
        }
        if let audio = source.audioStreams.first(where: \.isDefault) ?? source.audioStreams.first {
            if (audio.title ?? "").localizedCaseInsensitiveContains("atmos") {
                result.append("杜比全景声")
            } else if let codec = audio.codec?.uppercased() {
                result.append(codec)
            }
            if let channels = audio.channels, channels > 2 { result.append(MediaStreamInfo.channelLayout(channels)) }
        }
        if !source.subtitleStreams.isEmpty { result.append("字幕") }
        return result
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.6)))
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// 音视频字幕信息：每条流一张卡片横向排列，下方是文件卡片
struct MediaInfoSection: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let source: MediaSourceInfo
    var runtime: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音视频字幕信息").font(.title3.bold())
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    if let video = source.videoStream {
                        card("视频", symbol: "video.fill", rows: videoRows(video))
                    }
                    ForEach(source.audioStreams) { audio in
                        card("音频", symbol: "music.note", rows: audioRows(audio))
                    }
                    ForEach(source.subtitleStreams) { subtitle in
                        card("字幕", symbol: "captions.bubble.fill", rows: subtitleRows(subtitle))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .hideSystemScrollbars()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)

            fileCard
        }
    }

    private func card(_ title: String, symbol: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text("\(Text("\(row.0)：").foregroundStyle(.secondary))\(row.1)")
                    .font(.footnote)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(width: sizeClass == .regular ? 300 : 260, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
    }

    private var fileCard: some View {
        VStack(spacing: 6) {
            if let path = source.path, !path.isEmpty {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            let summary = [runtime?.durationString, source.videoStream?.title, source.container?.uppercased(),
                           source.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                .compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "  ")
            if !summary.isEmpty {
                Text(summary).font(.caption.weight(.semibold))
            }
            Text(PlaybackCompatibility.canPlayNatively(source) ? "系统播放器可直接播放" : "使用 FFmpeg 解码播放")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
    }

    private func yesNo(_ value: Bool?) -> String? {
        value.map { $0 ? "是" : "否" }
    }

    private func kbps(_ bitRate: Int?) -> String? {
        bitRate.map { "\($0 / 1000) kbps" }
    }

    private func compact(_ rows: [(String, String?)]) -> [(String, String)] {
        rows.compactMap { title, value in
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return (title, value)
        }
    }

    private func videoRows(_ s: MediaStreamInfo) -> [(String, String)] {
        compact([
            ("标题", s.title),
            ("编码", s.codec?.uppercased()),
            ("配置文件", s.profile),
            ("等级", s.level.map(String.init)),
            ("分辨率", s.width.flatMap { w in s.height.map { "\(w)x\($0)" } }),
            ("宽高比", s.aspectRatio),
            ("隔行扫描", yesNo(s.isInterlaced)),
            ("帧率", s.frameRate.map { $0.formatted(.number.precision(.fractionLength(0...3))) }),
            ("比特率", kbps(s.bitRate)),
            ("视频范围", s.videoRange),
            ("位深度", s.bitDepth.map { "\($0) bit" }),
            ("像素格式", s.pixelFormat),
            ("参考帧", s.refFrames.map(String.init)),
        ])
    }

    private func audioRows(_ s: MediaStreamInfo) -> [(String, String)] {
        compact([
            ("标题", s.title),
            ("语言", s.language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }),
            ("编码", s.codec?.uppercased()),
            ("声道", s.channelLayout ?? s.channels.map(MediaStreamInfo.channelLayout)),
            ("采样率", s.sampleRate.map { "\($0) Hz" }),
            ("比特率", kbps(s.bitRate)),
            ("默认", yesNo(s.isDefault)),
        ])
    }

    private func subtitleRows(_ s: MediaStreamInfo) -> [(String, String)] {
        compact([
            ("标题", s.title),
            ("语言", s.language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }),
            ("编码", s.codec?.uppercased()),
            ("默认", yesNo(s.isDefault)),
            ("强制", yesNo(s.isForced)),
            ("外挂", yesNo(s.isExternal)),
        ])
    }
}
