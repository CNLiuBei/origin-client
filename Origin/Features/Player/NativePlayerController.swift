import AVKit
import MediaPlayer
#if os(iOS)
import UIKit

/// 全屏承载系统播放器。不继承 AVPlayerViewController，只负责关闭时机和横竖屏。
final class NativePlayerHostController: UIViewController {
    let playerController = AVPlayerViewController()
    var onDismiss: (() -> Void)?
    private let closeButton = UIButton(type: .system)
    private var notified = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        addChild(playerController)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerController.view)
        NSLayoutConstraint.activate([
            playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerController.didMove(toParent: self)

        let image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        closeButton.setImage(image, for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        closeButton.layer.cornerRadius = 22
        closeButton.accessibilityLabel = "关闭播放器"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func close() { dismiss(animated: true) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        notified = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !notified, isBeingDismissed || presentingViewController == nil else { return }
        notified = true
        OrientationPolicy.restorePortrait()
        onDismiss?()
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
}
#endif

/// 系统原生播放：AVPlayer + AVPlayerViewController（macOS 上为 AVPlayerView）。
/// 控制栏、画中画、AirPlay、锁屏控制、字幕与音轨菜单全部由系统提供。
final class NativePlayerController: NSObject {
    private(set) var session: PlaybackSession
    #if os(iOS)
    let viewController = NativePlayerHostController()
    #else
    let playerView = AVPlayerView()
    #endif
    private let player = AVPlayer()
    private weak var presenter: PlayerPresenter?
    private let settings: AppSettings

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var isPiPActive = false
    private var isFinished = false
    /// 续播位置只跳一次。否则用户再拖回开头时，ready 回调会把进度拉回记忆点。
    private var didApplyStart = false
    private var isSeekingToStart = false
    private var didSchedulePlayback = false
    private var resumeAfterInterruption = false

    init(session: PlaybackSession, presenter: PlayerPresenter, settings: AppSettings) {
        self.session = session
        self.presenter = presenter
        self.settings = settings
        super.init()
        #if os(iOS)
        let playerController = viewController.playerController
        playerController.player = player
        playerController.delegate = self
        playerController.showsPlaybackControls = true
        playerController.videoGravity = .resizeAspect
        playerController.allowsPictureInPicturePlayback = true
        playerController.canStartPictureInPictureAutomaticallyFromInline = true
        playerController.updatesNowPlayingInfoCenter = true
        playerController.entersFullScreenWhenPlaybackBegins = false
        playerController.exitsFullScreenWhenPlaybackEnds = false
        playerController.speeds = Self.playbackSpeeds
        viewController.modalPresentationStyle = .fullScreen
        viewController.onDismiss = { [weak self] in self?.handleDismiss() }
        observeInterruptions()
        #else
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.allowsPictureInPicturePlayback = true
        playerView.showsFullScreenToggleButton = true
        playerView.showsSharingServiceButton = false
        playerView.updatesNowPlayingInfoCenter = true
        playerView.pictureInPictureDelegate = self
        playerView.speeds = Self.playbackSpeeds
        #endif
        player.allowsExternalPlayback = true
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        applySelectionCriteria()
        load(session)
    }

    private static let playbackSpeeds: [AVPlaybackSpeed] = [
        AVPlaybackSpeed(rate: 0.5, localizedName: "0.5×"),
        AVPlaybackSpeed(rate: 0.75, localizedName: "0.75×"),
        AVPlaybackSpeed(rate: 1.0, localizedName: "正常"),
        AVPlaybackSpeed(rate: 1.25, localizedName: "1.25×"),
        AVPlaybackSpeed(rate: 1.5, localizedName: "1.5×"),
        AVPlaybackSpeed(rate: 1.75, localizedName: "1.75×"),
        AVPlaybackSpeed(rate: 2.0, localizedName: "2×"),
        AVPlaybackSpeed(rate: 3.0, localizedName: "3×"),
    ]

    private func applySelectionCriteria() {
        let audio = settings.audioLanguage.codes
        if !audio.isEmpty {
            player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(preferredLanguages: audio, preferredMediaCharacteristics: nil), forMediaCharacteristic: .audible)
        }
        let subtitles = settings.subtitleLanguage.codes
        if !subtitles.isEmpty {
            player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(preferredLanguages: subtitles, preferredMediaCharacteristics: nil), forMediaCharacteristic: .legible)
        }
    }

    private func load(_ session: PlaybackSession) {
        removeObservers()
        self.session = session
        isFinished = false
        didApplyStart = session.startTime <= 1
        isSeekingToStart = false
        didSchedulePlayback = false
        resumeAfterInterruption = false

        var assetOptions: [String: Any] = [:]
        if !session.headers.isEmpty, !session.isOffline {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = session.headers
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: session.url, options: assetOptions))
        #if os(iOS)
        item.externalMetadata = Self.metadata(for: session, artwork: nil)
        #endif
        player.replaceCurrentItem(with: item)
        #if os(iOS)
        loadArtwork(for: session, item: item)
        #endif

        statusObservation = Self.observeStatus(of: item) { [weak self] item in
            self?.itemStatusChanged(item)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didPlayToEnd() }
        }
        player.defaultRate = Float(settings.defaultRate)
    }

    /// KVO 可能在任意线程回调，观察闭包本身必须是非隔离的
    private nonisolated static func observeStatus(of item: AVPlayerItem, handler: @escaping @MainActor (AVPlayerItem) -> Void) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in handler(item) }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            guard item == player.currentItem, !didSchedulePlayback else { return }
            didSchedulePlayback = true
            PlaybackAudioSession.activate()
            if !didApplyStart {
                didApplyStart = true
                isSeekingToStart = true
                let start = session.startTime
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.isSeekingToStart = false
                        self.beginPlayback()
                    }
                }
            } else {
                beginPlayback()
            }
            if settings.subtitleLanguage == .none {
                Task {
                    if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                        item.select(nil, in: group)
                    }
                }
            }
            session.didStart()
        case .failed:
            presenter?.report(error: Self.playbackMessage(for: item.error))
            dismiss()
        default:
            break
        }
    }

    private func beginPlayback() {
        player.play()
    }

    private static func playbackMessage(for error: Error?) -> String {
        let nsError = error as NSError?
        if nsError?.domain == NSURLErrorDomain {
            switch nsError?.code {
            case NSURLErrorNotConnectedToInternet: return "网络不可用，请检查连接后重试"
            case NSURLErrorTimedOut: return "连接超时，请重试"
            default: break
            }
        }
        return error?.localizedDescription ?? "无法播放该视频"
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        if isSeekingToStart { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        session.update(position: seconds, duration: duration.isFinite ? duration : 0,
                       paused: player.timeControlStatus == .paused)
    }

    private func didPlayToEnd() {
        session.update(position: session.duration, duration: session.duration, paused: true, force: true)
        session.stop()
        guard settings.autoPlayNext, let next = session.nextItem, let presenter else {
            if !isPiPActive { dismiss() }
            return
        }
        Task {
            do {
                let nextSession = try await presenter.makeSession(for: next, resume: false)
                if nextSession.engine == .native {
                    load(nextSession)
                } else {
                    finish()
                    dismiss {
                        presenter.present(nextSession)
                    }
                }
            } catch {
                presenter.report(error: error.localizedDescription)
                if !isPiPActive { dismiss() }
            }
        }
    }

    private func dismiss(then completion: (() -> Void)? = nil) {
        #if os(iOS)
        viewController.dismiss(animated: true, completion: completion)
        #else
        presenter?.dismissPlayerWindow()
        completion?()
        #endif
    }

    func handleDismiss() {
        guard !isPiPActive else { return }
        finish()
    }

    /// 结束播放并上报进度
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        tick(player.currentTime())
        session.update(position: session.position, duration: session.duration, paused: true, force: true)
        session.stop()
        player.pause()
        removeObservers()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        player.replaceCurrentItem(with: nil)
        PlaybackAudioSession.deactivate()
        presenter?.nativeDidFinish(self)
    }

    #if os(macOS)
    // MARK: - 菜单栏控制

    func togglePlay() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func skip(_ seconds: Int) {
        let duration = player.currentItem?.duration.seconds ?? 0
        var target = max(0, player.currentTime().seconds + Double(seconds))
        if duration.isFinite, duration > 0 { target = min(target, duration) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func adjustVolume(by delta: Float) {
        player.volume = max(0, min(1, player.volume + delta))
    }

    var currentTime: TimeInterval { player.currentTime().seconds }
    var duration: TimeInterval { player.currentItem?.duration.seconds ?? 0 }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var volume: Float { player.volume }
    #endif

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
    }

    #if os(iOS)
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = player.timeControlStatus == .playing
            player.pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if options.contains(.shouldResume), resumeAfterInterruption, !isFinished {
                PlaybackAudioSession.activate()
                player.play()
            }
            resumeAfterInterruption = false
        default:
            break
        }
    }
    #endif

    #if os(iOS)
    // MARK: - 元数据（锁屏、控制中心、系统播放器标题）

    private static func metadata(for session: PlaybackSession, artwork: Data?) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, dataType: String? = nil) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            if let dataType { item.dataType = dataType }
            return item.copy() as! AVMetadataItem
        }
        var items = [item(.commonIdentifierTitle, session.title as NSString)]
        if let subtitle = session.subtitle {
            items.append(item(.iTunesMetadataTrackSubTitle, subtitle as NSString))
        }
        if let overview = session.item.overview {
            items.append(item(.commonIdentifierDescription, overview as NSString))
        }
        if let artwork {
            items.append(item(.commonIdentifierArtwork, artwork as NSData, dataType: kCMMetadataBaseDataType_JPEG as String))
        }
        return items
    }

    private func loadArtwork(for session: PlaybackSession, item: AVPlayerItem) {
        guard let url = session.item.thumbURL ?? session.item.backdropURL ?? session.item.posterURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: MediaRequestAuth.request(for: url)),
                  let jpeg = await ImageDecoding.jpegData(from: data) else { return }
            item.externalMetadata = Self.metadata(for: session, artwork: jpeg)
        }
    }
    #endif
}

// MARK: - 画中画

#if os(iOS)
extension NativePlayerController: AVPlayerViewControllerDelegate {
    func playerViewControllerDidStartPictureInPicture(_: AVPlayerViewController) {
        isPiPActive = true
    }

    func playerViewControllerDidStopPictureInPicture(_: AVPlayerViewController) {
        isPiPActive = false
        if viewController.presentingViewController == nil {
            finish()
        }
    }

    func playerViewController(_: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if viewController.presentingViewController != nil {
            completionHandler(true)
            return
        }
        guard let top = UIApplication.shared.topViewController else {
            completionHandler(false)
            return
        }
        top.present(viewController, animated: true) { completionHandler(true) }
    }
}

extension UIApplication {
    var activeWindowScene: UIWindowScene? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    var topViewController: UIViewController? {
        var controller = activeWindowScene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}
#else
extension NativePlayerController: AVPlayerViewPictureInPictureDelegate {
    func playerViewWillStartPicture(inPicture _: AVPlayerView) {
        isPiPActive = true
    }

    func playerViewDidStopPicture(inPicture _: AVPlayerView) {
        isPiPActive = false
    }

    func playerView(_: AVPlayerView, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
#endif
