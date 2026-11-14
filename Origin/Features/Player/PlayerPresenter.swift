import AVKit
import Observation
#if os(iOS)
import UIKit
#endif

/// 负责选择播放引擎并呈现播放器：iOS 上全屏弹出，macOS 上在独立的播放窗口中显示
@Observable
final class PlayerPresenter {
    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private var native: NativePlayerController?
    #if os(iOS)
    @ObservationIgnored private weak var ffmpegHost: UIViewController?
    #else
    enum ActivePlayer {
        case native(NativePlayerController)
        case ffmpeg(FFmpegPlayerModel)
    }

    /// 播放窗口当前显示的播放器
    private(set) var active: ActivePlayer?
    /// 由主窗口注入的打开、关闭播放窗口操作
    @ObservationIgnored var windowActions: (open: () -> Void, dismiss: () -> Void)?
    #endif

    private(set) var isPreparing = false
    var errorMessage: String?

    init(app: AppModel) {
        self.app = app
    }

    /// - Parameter resume: nil 表示按设置决定是否续播
    func play(_ item: MediaItem, resume: Bool? = nil, sourceID: String? = nil) {
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let session = try await makeSession(for: item, resume: resume, sourceID: sourceID)
                present(session)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func makeSession(for item: MediaItem, resume: Bool?, sourceID: String? = nil) async throws -> PlaybackSession {
        let settings = app.settings
        let client = app.client(for: item.serverID)
        let playSessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        if let download = app.downloads.completedRecord(for: item.id), let localURL = app.downloads.localURL(for: download) {
            let saved = download.item
            let source = saved.mediaSources.first
            let native = source.map(PlaybackCompatibility.canPlayNatively) ?? false
            let engine: PlaybackEngineKind = settings.engine == .ffmpeg || !native ? .ffmpeg : .native
            let start = startTime(for: saved, resume: resume)
            return PlaybackSession(item: saved, source: source, url: localURL, headers: [:], engine: engine,
                                   externalSubtitles: [], startTime: start, isTranscoding: false, isOffline: true,
                                   playSessionID: playSessionID, client: client)
        }

        guard let client else { throw APIError.message("找不到该内容所属的服务器") }
        var full = item
        if full.mediaSources.isEmpty {
            full = try await client.item(id: item.id)
        }
        guard let source = full.mediaSources.first(where: { $0.id == sourceID }) ?? full.mediaSources.first else {
            throw APIError.message("没有可播放的媒体文件")
        }
        guard let directURL = source.directURL else {
            let isDisc = source.path?.lowercased().hasSuffix(".iso") ?? false
            throw APIError.message(isDisc ? "该影片是 ISO 原盘，服务器不提供它的播放流" : "没有可播放的媒体文件")
        }

        let subtitles = source.externalSubtitles.map {
            ExternalSubtitle(id: $0.id, name: $0.displayName, language: $0.language, url: $0.deliveryURL!,
                             isDefault: $0.isDefault, isForced: $0.isForced)
        }
        let compatible = PlaybackCompatibility.canPlayNatively(source)
        let nativeFriendly = compatible && subtitles.isEmpty && !PlaybackCompatibility.hasUnsupportedSubtitles(source)

        var engine = PlaybackEngineKind.ffmpeg
        var url = directURL
        var transcoding = false
        switch settings.engine {
        case .ffmpeg:
            break
        case .auto:
            if nativeFriendly { engine = .native }
        case .systemOnly:
            if nativeFriendly {
                engine = .native
            } else if client.supportsHLS, let hls = client.hlsURL(for: full, source: source, playSessionID: playSessionID) {
                engine = .native
                url = hls
                transcoding = true
            }
        }

        return PlaybackSession(item: full, source: source, url: url, headers: client.streamHeaders, engine: engine,
                               externalSubtitles: engine == .ffmpeg ? subtitles : [], startTime: startTime(for: full, resume: resume),
                               isTranscoding: transcoding, isOffline: false, playSessionID: playSessionID, client: client)
    }

    private func startTime(for item: MediaItem, resume: Bool?) -> TimeInterval {
        let shouldResume = resume ?? app.settings.autoResume
        return shouldResume && item.isResumable ? item.userState.playbackPosition : 0
    }

    #if os(iOS)
    func present(_ session: PlaybackSession) {
        stopCurrent()
        guard let top = UIApplication.shared.topViewController else { return }
        switch session.engine {
        case .native:
            let controller = NativePlayerController(session: session, presenter: self, settings: app.settings)
            native = controller
            top.present(controller.viewController, animated: true)
        case .ffmpeg:
            let host = FFmpegHostingController(session: session, presenter: self, settings: app.settings)
            ffmpegHost = host
            top.present(host, animated: true)
        }
    }

    private func stopCurrent() {
        if let native {
            native.finish()
            if native.viewController.presentingViewController != nil {
                native.viewController.dismiss(animated: false)
            }
        }
        native = nil
        ffmpegHost?.dismiss(animated: false)
    }
    #else
    func present(_ session: PlaybackSession) {
        stopCurrent()
        switch session.engine {
        case .native:
            let controller = NativePlayerController(session: session, presenter: self, settings: app.settings)
            native = controller
            active = .native(controller)
        case .ffmpeg:
            let model = FFmpegPlayerModel(session: session, presenter: self, settings: app.settings)
            model.dismissAction = { [weak self] in self?.dismissPlayerWindow() }
            active = .ffmpeg(model)
        }
        windowActions?.open()
    }

    /// 切换到下一个播放器前停止当前播放，但保留播放窗口
    private func stopCurrent() {
        native?.finish()
        native = nil
        if case let .ffmpeg(model) = active {
            model.dismissAction = nil
            model.close()
        }
        active = nil
    }

    func dismissPlayerWindow() {
        windowActions?.dismiss()
    }

    /// 播放窗口被关闭（关闭按钮、⌘W 或播放结束）
    func playerWindowClosed() {
        stopCurrent()
    }
    #endif

    func nativeDidFinish(_ controller: NativePlayerController) {
        if native === controller { native = nil }
        playbackEnded()
    }

    func playbackEnded() {
        app.contentChanged()
    }

    func report(error: String) {
        errorMessage = error
    }
}

#if os(iOS)
/// iPhone 上只有播放器能横屏，其余界面固定竖屏，播放器关闭后系统会自动转回竖屏；iPad 不限制
enum OrientationPolicy {
    static func mask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        return isPlayerPresented(in: window) ? .allButUpsideDown : .portrait
    }

    private static func isPlayerPresented(in window: UIWindow?) -> Bool {
        var controller = window?.rootViewController?.presentedViewController
        while let current = controller {
            if (current is FFmpegHostingController || current is NativePlayerHostController), !current.isBeingDismissed {
                return true
            }
            controller = current.presentedViewController
        }
        return false
    }

    /// 播放器关闭后让系统重新读取方向限制，并请求转回竖屏
    static func restorePortrait() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}
#endif
