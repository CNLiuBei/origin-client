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

    struct LibraryShelf: Identifiable {
        let library: MediaLibrary
        let items: [MediaItem]
        var id: String { library.id }
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
                            ResumeCard(item: item).frame(width: resumeWidth)
                        }
                    }
                }
                if !nextUp.isEmpty {
                    Shelf(title: "下一集") {
                        ForEach(nextUp) { item in
                            ResumeCard(item: item).frame(width: resumeWidth)
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
                                PosterCard(item: item).frame(width: 130)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ServerMenu() }
        }
        .refreshable { await load() }
        .task(id: app.contentRevision) {
            // 切换标签或从下一级返回时不重复加载，内容有变化（如播放进度更新）才刷新
            guard loadedRevision != app.contentRevision else { return }
            loadedRevision = app.contentRevision
            await load()
        }
    }

    private var resumeWidth: CGFloat { sizeClass == .regular ? 340 : 280 }

    private func collagePosters(for library: MediaLibrary) -> [URL] {
        let items = latest.first { $0.library.id == library.id }?.items ?? []
        return Array(items.compactMap(\.posterURL).prefix(3))
    }

    private func load() async {
        let accounts = app.homeAccounts
        guard !accounts.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        let prefixNames = accounts.count > 1
        var allLibraries: [MediaLibrary] = []
        var resumeAll: [MediaItem] = []
        var nextAll: [MediaItem] = []
        var favoriteAll: [MediaItem] = []
        var shelves: [LibraryShelf] = []
        var failure: String?
        for account in accounts {
            guard let client = app.client(for: account.id) else { continue }
            async let resumeTask = try? client.resumeItems(limit: 12)
            async let nextUpTask = try? client.nextUp(limit: 12)
            async let favoritesTask = client.supportsFavorites ? (try? client.favorites()) : nil
            do {
                let libs = try await client.libraries().map { library in
                    var copy = library
                    copy.serverID = account.id
                    if prefixNames { copy.serverName = account.name }
                    return copy
                }
                allLibraries.append(contentsOf: libs)
                shelves.append(contentsOf: await Self.loadShelves(client: client, libraries: Array(libs.prefix(8))))
            } catch {
                if failure == nil { failure = error.localizedDescription }
            }
            resumeAll.append(contentsOf: await resumeTask ?? [])
            nextAll.append(contentsOf: await nextUpTask ?? [])
            favoriteAll.append(contentsOf: await favoritesTask ?? [])
        }
        libraries = allLibraries
        latest = shelves
        resume = resumeAll
        nextUp = nextAll
        favorites = favoriteAll
        featured = Array(shelves.flatMap(\.items).filter { $0.posterURL != nil && $0.kind != .episode }.prefix(8))
        if featuredSelection == nil || !featured.contains(where: { $0.id == featuredSelection }) {
            featuredSelection = featured.first?.id
        }
        errorText = allLibraries.isEmpty ? failure : nil
        if !featured.isEmpty { prefetchFeatured() }
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
            .aspectRatio(sizeClass == .regular ? 16 / 9 : 2 / 3.1, contentMode: .fit)

            FeaturedPicker(items: items, selection: $selection)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard !items.isEmpty else { continue }
                let index = items.firstIndex { $0.id == selection } ?? 0
                withAnimation { selection = items[(index + 1) % items.count].id }
            }
        }
    }
}

/// 用海报本身切换焦点内容，代替一排圆点
private struct FeaturedPicker: View {
    let items: [MediaItem]
    @Binding var selection: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            rail
            ScrollView(.horizontal) {
                rail.padding(.horizontal).hideSystemScrollbars()
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("精选")
    }

    private var rail: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button {
                    withAnimation(.snappy(duration: 0.35)) { selection = item.id }
                }                 label: {
                    RemoteImage(url: item.posterURL ?? item.backdropURL)
                        .frame(width: 36, height: 54)
                        .clipShape(.rect(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 1.5)
                        }
                        .scaleEffect(selected ? 1 : 0.84)
                        .opacity(selected ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.3), value: selection)
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
