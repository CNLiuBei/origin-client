import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var resume: [MediaItem] = []
    @State private var nextUp: [MediaItem] = []
    @State private var latest: [LibraryShelf] = []
    @State private var favorites: [MediaItem] = []
    @State private var featured: [MediaItem] = []
    @State private var featuredSelection: String?
    @State private var libraries: [MediaLibrary] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var loadedRevision: Int?
    /// 每台服务器各自的结果。哪台先回来先显示，连不上的那台不会挡住别的。
    @State private var contents: [UUID: ServerContent] = [:]
    @State private var loadID = 0

    struct LibraryShelf: Identifiable {
        let library: MediaLibrary
        let items: [MediaItem]
        var id: String { library.id }
    }

    private struct ServerContent {
        var libraries: [MediaLibrary] = []
        var shelves: [LibraryShelf] = []
        var resume: [MediaItem] = []
        var nextUp: [MediaItem] = []
        var favorites: [MediaItem] = []
        var failure: String?
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !featured.isEmpty {
                    FeaturedCarousel(items: featured, selection: $featuredSelection)
                }
                if !resume.isEmpty {
                    Shelf(title: "继续观看") {
                        ForEach(resume) { item in
                            ResumeCard(item: item, serverName: serverName(for: item)).frame(width: resumeWidth)
                        }
                    }
                }
                if !nextUp.isEmpty {
                    Shelf(title: "下一集") {
                        ForEach(nextUp) { item in
                            ResumeCard(item: item, serverName: serverName(for: item)).frame(width: resumeWidth)
                        }
                    }
                }
                if !libraries.isEmpty {
                    Shelf(title: "我的媒体") {
                        ForEach(libraries) { library in
                            NavigationLink(value: Route.library(library)) {
                                LibraryCollageCard(library: library, posters: collagePosters(for: library))
                                    .frame(width: resumeWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(latest) { shelf in
                    Shelf(title: shelf.library.displayName, destination: .library(shelf.library)) {
                        ForEach(shelf.items) { item in
                            NavigationLink(value: item) {
                                if item.kind == .episode {
                                    ThumbCard(item: item).frame(width: 220)
                                } else {
                                    PosterCard(item: item).frame(width: 130)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                }
                if !favorites.isEmpty {
                    Shelf(title: "收藏", destination: .favorites) {
                        ForEach(favorites) { item in
                            NavigationLink(value: item) {
                                VStack(alignment: .leading, spacing: 4) {
                                    PosterCard(item: item).frame(width: 130)
                                    if let name = serverName(for: item) {
                                        Text(name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 130, alignment: .leading)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
            .hideSystemScrollbars()
        }
        .scrollIndicators(.hidden)
        // macOS 的分栏只在第一次排版时采纳顶部安全区。若等海报加载后再改为忽略，
        // 标题栏下会留出一截空白，直到收起再展开侧边栏才会重算。因此从第一帧就忽略。
        .modifier(HomeTopChrome(extendsUnderTitlebar: !featured.isEmpty))
        .background {
            AmbientBackground(url: featured.first { $0.id == featuredSelection }.flatMap { $0.posterURL ?? $0.backdropURL })
        }
        .overlay {
            if let account = app.activeAccount, app.isLocked(account) {
                ContentUnavailableView {
                    Label("服务器已加密", systemImage: "lock")
                } description: {
                    Text("解锁后才能查看\(account.name)")
                } actions: {
                    Button("解锁") { Task { await app.unlock(account) } }
                        .buttonStyle(.glass)
                }
            } else if isLoading, resume.isEmpty, latest.isEmpty {
                ProgressView()
            } else if let errorText, latest.isEmpty, resume.isEmpty {
                ContentUnavailableView {
                    Label("无法连接服务器", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorText)
                } actions: {
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.glass)
                }
            }
        }
        .navigationTitle(app.activeAccount?.name ?? "首页")
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ServerMenu() }
        }
        #endif
        .refreshable { await load() }
        .task(id: app.contentRevision) {
            // 切换标签或从下一级返回时不重复加载，内容有变化（如播放进度更新）才刷新
            guard loadedRevision != app.contentRevision else { return }
            loadedRevision = app.contentRevision
            await load()
        }
    }

    private var resumeWidth: CGFloat { sizeClass == .regular ? 340 : 280 }

    private func serverName(for item: MediaItem) -> String? {
        guard app.homeAccounts.count > 1 else { return nil }
        return app.accounts.first { $0.id == item.serverID }?.name
    }

    private func collagePosters(for library: MediaLibrary) -> [URL] {
        let items = latest.first { $0.library.id == library.id }?.items ?? []
        return Array(items.compactMap(\.posterURL).prefix(3))
    }

    private func load() async {
        let accounts = app.homeAccounts
        loadID += 1
        guard !accounts.isEmpty else {
            contents = [:]
            apply(order: [])
            isLoading = false
            return
        }
        let current = loadID
        isLoading = true
        let order = accounts.map(\.id)
        contents = contents.filter { order.contains($0.key) }
        apply(order: order)
        let prefixNames = accounts.count > 1
        let tasks = accounts.compactMap { account -> Task<Void, Never>? in
            guard let client = app.client(for: account.id) else { return nil }
            return Task {
                let content = await Self.loadServer(client: client, account: account, prefixNames: prefixNames)
                guard current == loadID else { return }
                contents[account.id] = content
                apply(order: order)
            }
        }
        for task in tasks { await task.value }
        guard current == loadID else { return }
        isLoading = false
        errorText = libraries.isEmpty ? order.lazy.compactMap { contents[$0]?.failure }.first : nil
    }

    /// 按服务器列表的顺序合并已经回来的结果
    private func apply(order: [UUID]) {
        let parts = order.compactMap { contents[$0] }
        libraries = parts.flatMap(\.libraries)
        latest = parts.flatMap(\.shelves)
        resume = parts.flatMap(\.resume)
        nextUp = parts.flatMap(\.nextUp)
        favorites = parts.flatMap(\.favorites)
        let picks = Array(latest.flatMap(\.items).filter { $0.posterURL != nil && $0.kind != .episode }.prefix(8))
        if picks.map(\.id) != featured.map(\.id) {
            featured = picks
            if !featured.isEmpty { prefetchFeatured() }
        }
        if featuredSelection == nil || !featured.contains(where: { $0.id == featuredSelection }) {
            featuredSelection = featured.first?.id
        }
        if !libraries.isEmpty { errorText = nil }
    }

    private static func loadServer(client: any MediaServerClient, account: ServerAccount, prefixNames: Bool) async -> ServerContent {
        async let resumeTask = try? client.resumeItems(limit: 12)
        async let nextUpTask = try? client.nextUp(limit: 12)
        async let favoritesTask = client.supportsFavorites ? (try? client.favorites()) : nil
        var content = ServerContent()
        do {
            let libs = try await client.libraries().map { library in
                var copy = library
                copy.serverID = account.id
                if prefixNames { copy.serverName = account.name }
                return copy
            }
            content.libraries = libs
            content.shelves = await loadShelves(client: client, libraries: Array(libs.prefix(8)))
        } catch {
            content.failure = error.localizedDescription
        }
        content.resume = await resumeTask ?? []
        content.nextUp = await nextUpTask ?? []
        content.favorites = await favoritesTask ?? []
        return content
    }

    /// 预先下载轮播海报和对应的模糊背景，翻页时直接显示
    private func prefetchFeatured() {
        let urls = featured.flatMap { [$0.posterURL, $0.backdropURL] }.compactMap(\.self)
        let ambient = featured.compactMap { $0.posterURL ?? $0.backdropURL }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for url in urls { group.addTask { _ = await ImageLoader.load(url) } }
                for url in ambient { group.addTask { _ = await AmbientBlur.image(for: url) } }
            }
        }
    }

    /// 并发拉取各媒体库的“最近添加”，保持媒体库原有顺序
    private static func loadShelves(client: any MediaServerClient, libraries: [MediaLibrary]) async -> [LibraryShelf] {
        let tasks = libraries.map { library in
            Task {
                var items = (try? await client.latest(in: library, limit: 20)) ?? []
                if items.isEmpty {
                    let query = LibraryQuery(sort: .dateAdded, ascending: false)
                    items = (try? await client.items(parentID: library.id, kind: library.kind, query: query, start: 0, limit: 20))?.items ?? []
                }
                return (library, items)
            }
        }
        var shelves: [LibraryShelf] = []
        for task in tasks {
            let (library, items) = await task.value
            if !items.isEmpty { shelves.append(LibraryShelf(library: library, items: items)) }
        }
        return shelves
    }
}

/// 首页头图铺进标题栏。macOS 分栏的安全区只认第一次排版，不能等数据回来再改。
private struct HomeTopChrome: ViewModifier {
    var extendsUnderTitlebar: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .ignoresSafeArea(edges: .top)
            .scrollEdgeEffectHidden(true, for: .top)
            .contentMargins(.top, 0, for: .scrollContent)
        #else
        content
            .ignoresSafeArea(edges: extendsUnderTitlebar ? .top : [])
            .scrollEdgeEffectHidden(extendsUnderTitlebar, for: .top)
        #endif
    }
}

/// 顶部海报轮播：竖版海报铺满宽度，底部渐隐到氛围背景，标题与简介叠在渐隐区
private struct FeaturedCarousel: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let items: [MediaItem]
    @Binding var selection: String?
    @State private var cycle = FeaturedCycle(id: nil, start: .now)
    @State private var isDragging = false

    private static let interval: TimeInterval = 7

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            FeaturedPage(item: item, usesBackdrop: sizeClass == .regular)
                        }
                        .buttonStyle(.plain)
                        .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
                .hideSystemScrollbars()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selection)
            .onScrollPhaseChange { _, phase in
                isDragging = phase == .tracking || phase == .interacting
            }
            .aspectRatio(sizeClass == .regular ? 16 / 9 : 2 / 3.1, contentMode: .fit)

            FeaturedDots(items: items, selection: $selection, cycle: cycle, interval: Self.interval)
        }
        .task(id: FeaturedTrigger(selection: selection, isDragging: isDragging)) {
            let current = selection
            guard !isDragging else {
                cycle = FeaturedCycle(id: nil, start: .now)
                return
            }
            cycle = FeaturedCycle(id: current, start: .now)
            do {
                try await Task.sleep(for: .seconds(Self.interval))
            } catch {
                return
            }
            guard !items.isEmpty, selection == current else { return }
            let index = items.firstIndex { $0.id == current } ?? 0
            withAnimation { selection = items[(index + 1) % items.count].id }
        }
    }
}

/// 当前这一页从什么时候开始计时。读条和自动翻页共用这个起点。
private struct FeaturedCycle: Equatable {
    var id: String?
    var start: Date
}

private struct FeaturedTrigger: Equatable {
    var selection: String?
    var isDragging: Bool
}

/// 圆点指示器：当前页拉长成胶囊，内部按真实时间走读条
private struct FeaturedDots: View {
    let items: [MediaItem]
    @Binding var selection: String?
    let cycle: FeaturedCycle
    let interval: TimeInterval

    private let dot: CGFloat = 6
    private let active: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button {
                    withAnimation(.snappy(duration: 0.35)) { selection = item.id }
                } label: {
                    indicator(selected: selected, id: item.id)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.3), value: selection)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("精选")
    }

    @ViewBuilder
    private func indicator(selected: Bool, id: String) -> some View {
        let width = selected ? active : dot
        Capsule()
            .fill(.primary.opacity(selected ? 0.22 : 0.3))
            .overlay(alignment: .leading) {
                if selected {
                    TimelineView(.animation) { context in
                        Rectangle()
                            .fill(.primary)
                            .frame(width: active * progress(for: id, at: context.date))
                    }
                }
            }
            .clipShape(.capsule)
            .frame(width: width, height: dot)
    }

    /// 不是当前计时的那一页时从 0 开始，避免切页的第一帧闪出满格
    private func progress(for id: String, at date: Date) -> CGFloat {
        guard cycle.id == id else { return 0 }
        return CGFloat(min(max(date.timeIntervalSince(cycle.start) / interval, 0), 1))
    }
}

private struct FeaturedPage: View {
    let item: MediaItem
    let usesBackdrop: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // 占位用透明而不是灰块，翻页时图片未就绪也不会闪一下
            Color.clear
                .overlay {
                    AuthorizedImage(url: usesBackdrop ? (item.backdropURL ?? item.posterURL) : (item.posterURL ?? item.backdropURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
                .clipped()
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0.5),
                        .init(color: .black.opacity(0.6), location: 0.75),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            VStack(spacing: 8) {
                if let logo = item.logoURL {
                    AuthorizedImage(url: logo) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        title
                    }
                    .frame(maxWidth: 240, maxHeight: 72)
                } else {
                    title
                }
                MetaLine(item: item)
                if let overview = item.overview, !overview.isEmpty {
                    Text("\(Text("「\(item.name)」").fontWeight(.semibold))\(overview)")
                        .font(.footnote)
                        .lineLimit(3)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .contentShape(.rect)
    }

    private var title: some View {
        Text(item.name)
            .font(.title.bold())
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.25), radius: 6)
    }
}

/// ★7.9 | 2025 | 悬疑,惊悚,犯罪
struct MetaLine: View {
    let item: MediaItem
    var date: String?
    var extra: [String] = []

    var body: some View {
        let parts: [String?] = [date ?? item.yearRange, item.genres.prefix(3).joined(separator: ",")] + extra.map { Optional($0) }
        HStack(spacing: 6) {
            if let rating = item.communityRating, rating > 0 {
                Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    .labelStyle(RatingLabelStyle())
            }
            ForEach(Array(parts.compactMap(\.self).filter { !$0.isEmpty }.enumerated()), id: \.offset) { index, part in
                if index > 0 || item.communityRating ?? 0 > 0 {
                    Text("|").foregroundStyle(.tertiary)
                }
                Text(part)
            }
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
    }
}

private struct RatingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.foregroundStyle(.yellow)
            configuration.title
        }
    }
}

struct ServerMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Menu {
            Picker("服务器", selection: $app.activeAccountID) {
                ForEach(app.accounts) { account in
                    Label {
                        Text(account.name)
                    } icon: {
                        ServerMenuIcon(account: account)
                    }
                    .tag(Optional(account.id))
                }
            }
            Divider()
            NavigationLink(value: Route.servers) {
                Label("管理服务器", systemImage: "server.rack")
            }
        } label: {
            Image(systemName: "server.rack")
        }
    }
}
