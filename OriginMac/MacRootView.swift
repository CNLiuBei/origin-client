import SwiftUI

enum SidebarItem: Hashable {
    case home, search, servers, favorites
    case library(MediaLibrary)
}

/// 主窗口的导航状态，供侧边栏、导航栈和调试控制接口共用
@Observable
final class MacNavigation {
    var selection: SidebarItem? = .home {
        didSet {
            guard selection != oldValue else { return }
            path = NavigationPath()
            trail = []
        }
    }

    var path = NavigationPath()
    /// 导航栈中每一层的说明（NavigationPath 无法读取内容，单独记录）
    var trail: [String] = []
    var libraries: [MediaLibrary] = []

    func push(_ item: MediaItem) {
        trail.append("\(item.kind) · \(item.name) · \(item.id)")
        path.append(item)
    }

    func syncTrail() {
        if path.count < trail.count {
            trail.removeLast(trail.count - path.count)
        }
        while trail.count < path.count {
            trail.append("（界面内跳转）")
        }
    }
}

/// macOS 主窗口：左侧边栏切换栏目与媒体库，右侧为各栏目的导航栈
struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(MacNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var player = app.player
        Group {
            if app.accounts.isEmpty {
                NavigationStack { WelcomeView().mediaDestinations() }
            } else {
                MacSidebarSplitView()
                    .id(app.activeAccountID)
            }
        }
        .overlay {
            if app.player.isPreparing {
                ProgressView("正在准备播放…")
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .alert("播放出错", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
        .lanPairRequestAlert()
        .onAppear {
            app.player.windowActions = (
                open: { openWindow(id: PlayerWindowView.id) },
                dismiss: { dismissWindow(id: PlayerWindowView.id) }
            )
            #if DEBUG
            ControlServer.shared.openSettings = { openSettings() }
            #endif
        }
    }
}

private struct MacSidebarSplitView: View {
    @Environment(AppModel.self) private var app
    @Environment(MacNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section {
                    Label("首页", systemImage: "play.house").tag(SidebarItem.home)
                    Label("搜索", systemImage: "magnifyingglass").tag(SidebarItem.search)
                    Label("收藏", systemImage: "heart").tag(SidebarItem.favorites)
                    Label("服务器", systemImage: "server.rack").tag(SidebarItem.servers)
                }
                if !navigation.libraries.isEmpty {
                    Section("媒体库") {
                        ForEach(navigation.libraries) { library in
                            Label(library.displayName, systemImage: library.kind.symbol)
                                .tag(SidebarItem.library(library))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) { serverPicker }
        } detail: {
            NavigationStack(path: $navigation.path) {
                content
                    .mediaDestinations()
            }
            .id(navigation.selection)
            .onChange(of: navigation.path.count) { navigation.syncTrail() }
        }
        .task(id: app.contentRevision) {
            let result = await app.collectLibraries()
            if !result.libraries.isEmpty || app.homeAccounts.isEmpty {
                navigation.libraries = result.libraries
            }
        }
        .onChange(of: app.activeAccountID) { previous, current in
            guard let current, let account = app.accounts.first(where: { $0.id == current }), app.isLocked(account) else { return }
            app.activeAccountID = previous
            Task {
                if await app.unlock(account) { app.activeAccountID = account.id }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.selection ?? .home {
        case .home: HomeView()
        case .search: SearchView()
        case .servers: ServersView()
        case .favorites: ItemsGridView(source: .favorites)
        case let .library(library): ItemsGridView(source: .library(library))
        }
    }

    private var serverPicker: some View {
        @Bindable var app = app
        return HStack {
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
            .labelsHidden()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置与服务器管理")
        }
        .padding(12)
    }
}
