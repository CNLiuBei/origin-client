import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    var backgroundDownloadHandler: ((@escaping () -> Void) -> Void)?

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        URLCache.shared = URLCache(memoryCapacity: 128 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        return true
    }

    func application(_: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationPolicy.mask(for: window)
    }

    func application(_: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else { return completionHandler() }
        backgroundDownloadHandler?(completionHandler)
    }
}

@main
struct OriginApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onAppear {
                    delegate.backgroundDownloadHandler = { [app] handler in
                        app.downloads.backgroundCompletionHandler = handler
                    }
                }
        }
    }
}
