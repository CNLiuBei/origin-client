import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var results: [MediaItem] = []
    @State private var shownTerm = ""
    @State private var isSearching = false
    @AppStorage("recentSearches") private var recentData = Data()

    private var recents: [String] {
        (try? JSONDecoder().decode([String].self, from: recentData)) ?? []
    }

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            Group {
                if text.isEmpty {
                    recentList
                } else {
                    resultsView
                }
            }
            .hideSystemScrollbars()
        }
        .scrollIndicators(.hidden)
        .navigationTitle("搜索")
        .inlineNavigationTitle()
        .searchable(text: $text, prompt: "电影、剧集、单集")
        .onSubmit(of: .search) { remember(text) }
        .task(id: text) {
            let term = text.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else {
                results = []
                shownTerm = ""
                isSearching = false
                return
            }
            // 取消旧搜索时不要把 isSearching 改回 false，否则新搜索还在跑，界面会闪出上一批结果
            isSearching = true
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let accounts = app.homeAccounts
            guard !accounts.isEmpty else {
                results = []
                shownTerm = term
                isSearching = false
                return
            }
            var merged: [MediaItem] = []
            for account in accounts {
                guard !Task.isCancelled else { return }
                if let found = try? await app.client(for: account.id)?.search(term, limit: 40) {
                    merged.append(contentsOf: found)
                }
            }
            guard !Task.isCancelled else { return }
            results = merged
            shownTerm = term
            isSearching = false
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if recents.isEmpty {
            ContentUnavailableView("搜索媒体库", systemImage: "magnifyingglass", description: Text("搜索首页里的电影、剧集和单集"))
                .padding(.top, 80)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("最近搜索").font(.title3.bold())
                    Spacer()
                    Button("清除") { recentData = Data() }
                }
                .padding(.bottom, 6)
                ForEach(recents, id: \.self) { term in
                    HStack(spacing: 8) {
                        Button {
                            text = term
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                        .tint(.primary)
                        Button {
                            forget(term)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("删除“\(term)”")
                    }
                    .contextMenu {
                        Button("删除", systemImage: "trash", role: .destructive) { forget(term) }
                    }
                    Divider()
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        let groups: [(String, [MediaItem])] = [
            ("电影", results.filter { $0.kind == .movie }),
            ("剧集", results.filter { $0.kind == .series }),
            ("合集", results.filter { $0.kind == .collection }),
            ("单集", results.filter { $0.kind == .episode }),
        ].filter { !$0.1.isEmpty }

        let term = text.trimmingCharacters(in: .whitespaces)
        if isSearching, shownTerm != term {
            ProgressView("正在搜索…").padding(.top, 80)
        } else if groups.isEmpty {
            ContentUnavailableView.search(text: text).padding(.top, 80)
        } else {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("\(results.count) 个结果")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(groups, id: \.0) { title, items in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.title3.bold())
                        if title == "单集" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .top)], spacing: 16) {
                                ForEach(items) { item in
                                    NavigationLink(value: item) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ThumbCard(item: item)
                                            serverCaption(item)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { ItemContextMenu(item: item) }
                                    .simultaneousGesture(TapGesture().onEnded { remember(text) })
                                }
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(items) { item in
                                    NavigationLink(value: item) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            PosterCard(item: item)
                                            serverCaption(item)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { ItemContextMenu(item: item) }
                                    .simultaneousGesture(TapGesture().onEnded { remember(text) })
                                }
                            }
                        }
                    }
                }
            }
            .padding()
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

    private func forget(_ term: String) {
        let list = recents.filter { $0 != term }
        recentData = (try? JSONEncoder().encode(list)) ?? Data()
    }

    private func remember(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        var list = recents.filter { $0 != term }
        list.insert(term, at: 0)
        recentData = (try? JSONEncoder().encode(Array(list.prefix(12)))) ?? Data()
    }
}
