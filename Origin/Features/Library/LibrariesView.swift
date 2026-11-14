import SwiftUI

struct LibrariesView: View {
    @Environment(AppModel.self) private var app
    @State private var libraries: [MediaLibrary] = []
    @State private var errorText: String?
    @State private var partialError: String?
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let partialError {
                    Label(partialError, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(libraries) { library in
                        NavigationLink(value: Route.library(library)) {
                            LibraryCard(library: library)
                        }
                        .buttonStyle(.plain)
                    }
                    if app.client?.supportsFavorites == true {
                        NavigationLink(value: Route.favorites) {
                            LibraryCard(library: MediaLibrary(id: "favorites", name: "收藏", kind: .collections, imageURL: nil), symbol: "heart.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .hideSystemScrollbars()
        }
        .scrollIndicators(.hidden)
        .overlay {
            if isLoading, libraries.isEmpty {
                ProgressView()
            } else if let errorText, libraries.isEmpty {
                ContentUnavailableView("无法加载媒体库", systemImage: "exclamationmark.triangle", description: Text(errorText))
            }
        }
        .navigationTitle("媒体库")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ServerMenu() }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard !app.homeAccounts.isEmpty else {
            libraries = []
            partialError = nil
            errorText = nil
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        let result = await app.collectLibraries()
        libraries = result.libraries
        partialError = result.libraries.isEmpty ? nil : result.failure.map { "有的服务器暂时连不上：\($0)" }
        errorText = result.libraries.isEmpty ? result.failure : nil
    }
}

private struct LibraryCard: View {
    let library: MediaLibrary
    var symbol: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: library.imageURL, aspectRatio: 16 / 9, placeholderSymbol: symbol ?? library.kind.symbol)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            Label(library.displayName, systemImage: symbol ?? library.kind.symbol)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding()
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

/// 媒体库 / 合集 / 收藏的网格浏览
struct ItemsGridView: View {
    enum Source: Hashable {
        case library(MediaLibrary)
        case children(MediaItem)
        case favorites

        var title: String {
            switch self {
            case let .library(library): library.displayName
            case let .children(item): item.name
            case .favorites: "收藏"
            }
        }
    }

    @Environment(AppModel.self) private var app
    let source: Source

    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var query = LibraryQuery()
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private let pageSize = 60
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 14, alignment: .top)]

    private var client: (any MediaServerClient)? {
        switch source {
        case let .children(item): app.client(for: item.serverID)
        case let .library(library): library.serverID.flatMap { app.client(for: $0) } ?? app.client
        case .favorites: app.client
        }
    }

    private var parentID: String? {
        switch source {
        case let .library(library): library.id
        case let .children(item): client?.childrenParentID(of: item)
        case .favorites: nil
        }
    }

    private var kind: LibraryKind {
        switch source {
        case let .library(library): library.kind
        case .children, .favorites: .mixed
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 18) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 4) {
                            itemCard(item)
                            if case .favorites = source { serverCaption(item) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ItemContextMenu(item: item) }
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }
                }
            }
            .padding()
            .hideSystemScrollbars()
            if isLoading, !items.isEmpty {
                ProgressView().padding()
            }
        }
        .scrollIndicators(.hidden)
        .overlay {
            if isLoading, items.isEmpty {
                ProgressView()
            } else if let errorText, items.isEmpty {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else if !isLoading, items.isEmpty {
                ContentUnavailableView("没有内容", systemImage: "film.stack", description: Text(query.filter == .all && query.genre == nil ? "这里还是空的" : "试试调整筛选条件"))
            }
        }
        .navigationTitle(source.title)
        .inlineNavigationTitle()
        .navigationSubtitle(gridSubtitle)
        .toolbar {
            if source != .favorites, client?.supportsLibraryQuery != false {
                ToolbarItem(placement: .primaryAction) { sortMenu }
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
        }
        .refreshable { await reload() }
        .task(id: query) { await reload() }
        .task {
            if let parentID, case .library = source {
                genres = (try? await client?.genres(parentID: parentID)) ?? []
            }
        }
    }

    private var gridColumns: [GridItem] {
        let episodesOnly = !items.isEmpty && items.allSatisfy { $0.kind == .episode }
        if episodesOnly {
            return [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .top)]
        }
        return columns
    }

    @ViewBuilder
    private func itemCard(_ item: MediaItem) -> some View {
        if item.kind == .episode {
            ThumbCard(item: item)
        } else {
            PosterCard(item: item)
        }
    }

    @ViewBuilder
    private func serverCaption(_ item: MediaItem) -> some View {
        if app.homeAccounts.count > 1, let name = app.accounts.first(where: { $0.id == item.serverID })?.name {
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var gridSubtitle: String {
        var parts: [String] = []
        if total > 0 { parts.append("\(total) 项") }
        if source != .favorites {
            parts.append(query.sort.title)
            if !query.ascending { parts.append("降序") }
            if query.filter != .all { parts.append(query.filter.title) }
            if let genre = query.genre { parts.append(genre) }
        }
        return parts.joined(separator: " · ")
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $query.sort) {
                ForEach(SortOption.allCases) { Text($0.title).tag($0) }
            }
            Picker("顺序", selection: $query.ascending) {
                Label("升序", systemImage: "arrow.up").tag(true)
                Label("降序", systemImage: "arrow.down").tag(false)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("筛选", selection: $query.filter) {
                ForEach(FilterOption.allCases.filter { $0 != .favorites || client?.supportsFavorites == true }) {
                    Text($0.title).tag($0)
                }
            }
            if !genres.isEmpty {
                Picker("类型", selection: $query.genre) {
                    Text("全部类型").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: query.filter == .all && query.genre == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private func reload() async {
        items = []
        total = 0
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, let client else { return }
        if total > 0, items.count >= total { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if source == .favorites {
                var merged: [MediaItem] = []
                for account in app.homeAccounts {
                    guard let serverClient = app.client(for: account.id), serverClient.supportsFavorites else { continue }
                    if let page = try? await serverClient.favorites() { merged.append(contentsOf: page) }
                }
                if merged.isEmpty { merged = try await client.favorites() }
                items = merged
                total = items.count
                return
            }
            guard let parentID else { return }
            let page = try await client.items(parentID: parentID, kind: kind, query: query, start: items.count, limit: pageSize)
            let existing = Set(items.map(\.id))
            items += page.items.filter { !existing.contains($0.id) }
            total = page.total
            if page.items.isEmpty { total = items.count }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
