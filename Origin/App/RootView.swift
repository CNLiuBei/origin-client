import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = AppTab.home

    enum AppTab: Hashable {
        case home, libraries, servers, settings, search
    }

    var body: some View {
        @Bindable var player = app.player
        Group {
            if app.accounts.isEmpty {
                NavigationStack { WelcomeView() }
            } else {
                TabView(selection: $tab) {
                    Tab("首页", systemImage: "play.house", value: .home) {
                        NavigationStack { HomeView().mediaDestinations() }
                    }
                    Tab("媒体库", systemImage: "square.stack", value: .libraries) {
                        NavigationStack { LibrariesView().mediaDestinations() }
                    }
                    Tab("服务器", systemImage: "server.rack", value: .servers) {
                        NavigationStack { ServersView().mediaDestinations() }
                    }
                    Tab("设置", systemImage: "gearshape", value: .settings) {
                        NavigationStack { SettingsView().mediaDestinations() }
                    }
                    Tab(value: .search, role: .search) {
                        NavigationStack { SearchView().mediaDestinations() }
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .id(app.activeAccountID)
                .onChange(of: app.activeAccountID) { previous, current in
                    guard let current, let account = app.accounts.first(where: { $0.id == current }), app.isLocked(account) else { return }
                    app.activeAccountID = previous
                    Task {
                        if await app.unlock(account) { app.activeAccountID = account.id }
                    }
                }
            }
        }
        .onAppear { HorizontalScrollbarSuppression.start() }
        .lanPairRequestAlert()
        .overlay {
            if app.player.isPreparing {
                VStack(spacing: 12) {
                    ProgressView("正在准备播放…")
                    Button("取消") { app.player.cancelPrepare() }
                        .buttonStyle(.glass)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .alert("播放出错", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("重试") { player.retryLast() }
            Button("好", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }
}
