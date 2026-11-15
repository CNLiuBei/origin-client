import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    let navigation = MacNavigation()

    func applicationDidFinishLaunching(_: Notification) {
        URLCache.shared = URLCache(memoryCapacity: 128 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024)
        #if DEBUG
        ControlServer.shared.start(app: app, navigation: navigation)
        #endif
    }
}

@main
struct OriginMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    private var app: AppModel { delegate.app }
    private var navigation: MacNavigation { delegate.navigation }

    var body: some Scene {
        Window("Origin", id: "main") {
            MacRootView()
                .environment(app)
                .environment(navigation)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            OriginCommands(app: app)
        }

        Window("播放器", id: PlayerWindowView.id) {
            PlayerWindowView()
                .environment(app)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Settings {
            NavigationStack {
                SettingsView().mediaDestinations()
            }
            .lanPairRequestAlert()
            .environment(app)
            .frame(width: 560, height: 700)
        }
    }
}
