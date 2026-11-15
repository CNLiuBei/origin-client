import AVKit
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
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
    @ObservationIgnored private var playGeneration = 0
    @ObservationIgnored private var lastRequest: (MediaItem, Bool?, String?, TimeInterval?)?

    init(app: AppModel) {
        self.app = app
    }

    /// - Parameters:
    ///   - resume: nil 表示按设置决定是否续播
    ///   - startAt: 从指定位置开始，优先于续播设置
    func play(_ item: MediaItem, resume: Bool? = nil, sourceID: String? = nil, startAt: TimeInterval? = nil) {
        guard !isPreparing else { return }
        lastRequest = (item, resume, sourceID, startAt)
        playGeneration += 1
        let generation = playGeneration
        isPreparing = true
        Task {
            let session: PlaybackSession
            do {
                session = try await makeSession(for: item, resume: resume, sourceID: sourceID, startAt: startAt)
            } catch {
                guard playGeneration == generation else { return }
                isPreparing = false
                errorMessage = error.localizedDescription
                return
            }
            guard playGeneration == generation else { return }
            isPreparing = false
            present(session)
        }
    }

    func cancelPrepare() {
        playGeneration += 1
        isPreparing = false
    }

    func retryLast() {
        guard let lastRequest else { return }
        play(lastRequest.0, resume: lastRequest.1, sourceID: lastRequest.2, startAt: lastRequest.3)
    }

    /// 已连上、可以接着播放的同组设备
    var handoffTargets: [LANPeer] {
        app.lanSync.enabled ? app.lanSync.peers.filter(\.isConnected) : []
    }

    /// 让另一台设备从当前位置接着播放
    func handOff(_ session: PlaybackSession, at position: TimeInterval, to peer: LANPeer) -> Bool {
        let playback = LANPlayback(serverID: session.item.serverID, itemID: session.item.id, sourceID: session.source?.id,
                                   position: max(0, position))
        return app.lanSync.handOff(playback, to: peer.id)
    }

    /// 另一台设备交过来的播放
    func continuePlayback(_ playback: LANPlayback) {
        #if os(macOS)
        NSApp.activate()
        #endif
        if let download = app.downloads.completedRecord(for: playback.itemID) {
            play(download.item, sourceID: playback.sourceID, startAt: playback.position)
            return
        }
        guard let client = app.client(for: playback.serverID) else {
            errorMessage = "这台设备上没有这个内容所在的服务器"
            return
        }
        Task {
            do {
                let item = try await client.item(id: playback.itemID)
                play(item, sourceID: playback.sourceID, startAt: playback.position)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func makeSession(for item: MediaItem, resume: Bool?, sourceID: String? = nil, startAt: TimeInterval? = nil) async throws -> PlaybackSession {
        let settings = app.settings
        let client = app.client(for: item.serverID)
        let playSessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        if let download = app.downloads.completedRecord(for: item.id), let localURL = app.downloads.localURL(for: download) {
            let saved = download.item
            let source = saved.mediaSources.first
            let native = source.map(PlaybackCompatibility.canPlayNatively) ?? false
            let engine: PlaybackEngineKind = settings.engine == .ffmpeg || !native ? .ffmpeg : .native
            let start = startAt ?? startTime(for: saved, resume: resume)
            let session = PlaybackSession(item: saved, source: source, url: localURL, headers: [:], engine: engine,
                                          externalSubtitles: [], startTime: start, isTranscoding: false, isOffline: true,
                                          playSessionID: playSessionID, client: client)
            let itemID = saved.id
            session.onLocalProgress = { [weak app] position, duration in
                app?.downloads.notePlayback(id: itemID, position: position, duration: duration)
            }
            return session
        }

        guard let client else { throw APIError.message("找不到该内容所属的服务器") }
        let route = await ServerRoute.shared.resolve(
            client.account.connectionURL,
            timeout: client.account.advanced.timeout,
            allowsInsecureTLS: client.account.advanced.allowsInsecureTLS,
            alternates: client.account.backupLines.map(\.url)
        )
        MediaRequestAuth.register(route, headers: client.streamHeaders)
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
            ExternalSubtitle(id: $0.id, name: $0.displayName, language: $0.language, url: ServerEndpoint.redirect($0.deliveryURL!, through: route),
                             isDefault: $0.isDefault, isForced: $0.isForced)
        }
        let compatible = PlaybackCompatibility.canPlayNatively(source)
        let nativeFriendly = compatible && subtitles.isEmpty && !PlaybackCompatibility.hasUnsupportedSubtitles(source)

        var engine = PlaybackEngineKind.ffmpeg
        var url = ServerEndpoint.redirect(directURL, through: route)
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
                url = ServerEndpoint.redirect(hls, through: route)
                transcoding = true
            }
        }

        return PlaybackSession(item: full, source: source, url: url, headers: client.streamHeaders, engine: engine,
                               externalSubtitles: engine == .ffmpeg ? subtitles : [], startTime: startAt ?? startTime(for: full, resume: resume),
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
            model.dismissAction = { [weak self] done in
                self?.dismissPlayerWindow()
                done()
            }
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
            guard scene.interfaceOrientation.isLandscape else { continue }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

/// 关闭播放器：iPhone 上淡出和转回竖屏是同一次动画，iPad 上只淡出。
/// 默认的滑出和中途改方向会叠在一起，画面会顿一下。
@MainActor
final class PlayerCloseTransition {
    private var isClosing = false
    private var didStart = false
    private var didFinish = false
    private var completion: (() -> Void)?
    private var fallback: DispatchWorkItem?

    func start(on controller: UIViewController, completion: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        self.completion = completion
        controller.view.isUserInteractionEnabled = false

        guard !UIAccessibility.isReduceMotionEnabled else {
            controller.dismiss(animated: false) { [weak self] in
                OrientationPolicy.restorePortrait()
                self?.complete()
            }
            return
        }

        let phone = controller.traitCollection.userInterfaceIdiom == .phone
        if phone {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            let work = DispatchWorkItem { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.fadeAndFinish(controller)
            }
            fallback = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            controller.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { [weak self, weak controller] _ in
                Task { @MainActor in
                    guard let self, let controller else { return }
                    self.fadeAndFinish(controller)
                }
            }
        } else {
            fadeAndFinish(controller)
        }
    }

    /// 关闭过程中手机只允许竖屏，转场才能和淡出一起进行
    func orientations(for controller: UIViewController) -> UIInterfaceOrientationMask? {
        guard isClosing, controller.traitCollection.userInterfaceIdiom == .phone else { return nil }
        return .portrait
    }

    func viewWillTransition(on controller: UIViewController, coordinator: UIViewControllerTransitionCoordinator) {
        guard isClosing, !didStart else { return }
        didStart = true
        fallback?.cancel()
        coordinator.animate(alongsideTransition: { _ in
            controller.view.alpha = 0
        }, completion: { [weak self, weak controller] _ in
            guard let controller else { return }
            self?.finish(controller)
        })
    }

    private func fadeAndFinish(_ controller: UIViewController) {
        guard !didStart else { return }
        didStart = true
        fallback?.cancel()
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            controller.view.alpha = 0
        } completion: { [weak self, weak controller] _ in
            guard let controller else { return }
            self?.finish(controller)
        }
    }

    private func finish(_ controller: UIViewController) {
        guard !didFinish else { return }
        didFinish = true
        fallback?.cancel()
        guard controller.presentingViewController != nil else {
            complete()
            return
        }
        controller.dismiss(animated: false) { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        let done = completion
        completion = nil
        done?()
    }
}
#endif
