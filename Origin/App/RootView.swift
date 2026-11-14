import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = AppTab.home

    enum AppTab: Hashable {
        case home, libraries, downloads, settings, search
    }

    var body: some View {
        @Bindable var player = app.player
        Group {
            if app.accounts.isEmpty {
                WelcomeView()
            } else {
                TabView(selection: $tab) {
                    Tab("首页", systemImage: "play.house", value: .home) {
                        NavigationStack { HomeView().mediaDestinations() }
                    }
                    Tab("媒体库", systemImage: "square.stack", value: .libraries) {
                        NavigationStack { LibrariesView().mediaDestinations() }
                    }
                    Tab("下载", systemImage: "arrow.down.circle", value: .downloads) {
                        NavigationStack { DownloadsView().mediaDestinations() }
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
    }
}
