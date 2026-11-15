import AVKit
import MediaPlayer
import SwiftUI
#if os(iOS)
import UIKit

/// 全屏承载系统播放器。不继承 AVPlayerViewController，只负责关闭时机和横竖屏。
final class NativePlayerHostController: UIViewController {
    let playerController = AVPlayerViewController()
    var onDismiss: (() -> Void)?
    weak var playback: NativePlayerController?
    private let closeTransition = PlayerCloseTransition()
    private var overlay: UIHostingController<NativePlayerScreen>?
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
    }

    func installOverlay(model: NativePlayerController) {
        let host = UIHostingController(rootView: NativePlayerScreen(model: model))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        overlay = host
    }

    func removeOverlay() {
        overlay?.willMove(toParent: nil)
        overlay?.view.removeFromSuperview()
        overlay?.removeFromParent()
        overlay = nil
    }

    func beginClose(completion: (() -> Void)? = nil) {
        closeTransition.start(on: self, completion: completion)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playback?.preparePictureInPicture()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if let closing = closeTransition.orientations(for: self) { return closing }
        return traitCollection.userInterfaceIdiom == .pad ? .all : .landscape
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        closeTransition.viewWillTransition(on: self, coordinator: coordinator)
    }

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

@Observable
final class SkipPromptState {
    var segment: MediaSegment?
}

/// 系统原生播放：AVPlayer + AVPlayerViewController（macOS 上为 AVPlayerView）。
/// 控制栏、画中画、AirPlay、锁屏控制、字幕与音轨菜单全部由系统提供。
@Observable
final class NativePlayerController: NSObject {
    private(set) var session: PlaybackSession
    #if os(iOS)
    let viewController = NativePlayerHostController()
    #else
    let playerView = AVPlayerView()
    #endif
    private let player = AVPlayer()
    private weak var presenter: PlayerPresenter?
    let settings: AppSettings
    let skipPrompt = SkipPromptState()
    var rate: Double = 1
    var controlsVisible = true
    var isScrubbing = false
    var scrubTime: TimeInterval = 0
    var isFill = false
    var isLocked = false
    var showInfo = false
    var showEpisodes = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var volume: Float = 1
    private(set) var audioChoices: [PlayerChoice] = []
    private(set) var audioSelection = ""
    private(set) var subtitleChoices: [PlayerChoice] = []
    private(set) var subtitleSelection = ""
    private(set) var chapterMarks: [PlayerChapterMark] = []
    var hud: PlayerHUD?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audioOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var subtitleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var subtitleOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var rateBeforeLongPress: Double?
    @ObservationIgnored private var panStartTime: TimeInterval = 0
    @ObservationIgnored private var panStartValue: Double = 0
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    #if os(iOS)
    @ObservationIgnored let volumeController = SystemVolumeController()
    #endif

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private(set) var isPictureInPicture = false
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
        rate = settings.defaultRate
        super.init()
        #if os(iOS)
        let playerController = viewController.playerController
        playerController.player = player
        playerController.delegate = self
        playerController.showsPlaybackControls = false
        playerController.videoGravity = .resizeAspect
        playerController.allowsPictureInPicturePlayback = false
        playerController.canStartPictureInPictureAutomaticallyFromInline = true
        playerController.updatesNowPlayingInfoCenter = true
        playerController.entersFullScreenWhenPlaybackBegins = false
        playerController.exitsFullScreenWhenPlaybackEnds = false
        playerController.speeds = Self.playbackSpeeds
        viewController.modalPresentationStyle = .overFullScreen
        viewController.modalPresentationCapturesStatusBarAppearance = true
        viewController.onDismiss = { [weak self] in self?.handleDismiss() }
        observeInterruptions()
        #else
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.allowsPictureInPicturePlayback = false
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
        #if os(iOS)
        viewController.playback = self
        viewController.installOverlay(model: self)
        #endif
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
        skipPrompt.segment = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isScrubbing = false
        audioChoices = []
        audioSelection = ""
        subtitleChoices = []
        subtitleSelection = ""
        chapterMarks = []
        audioGroup = nil
        audioOptions = []
        subtitleGroup = nil
        subtitleOptions = []

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
        timeControlObservation = Self.observeTimeControl(of: player) { [weak self] status in
            self?.timeControlChanged(status)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didPlayToEnd() }
        }
        player.defaultRate = Float(rate)
    }

    private func loadPresentation(for item: AVPlayerItem) {
        Task { await loadPresentationData(for: item) }
    }

    private func loadPresentationData(for item: AVPlayerItem) async {
        guard item == player.currentItem else { return }
        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            guard item == player.currentItem else { return }
            audioGroup = group
            audioOptions = group.options
            audioChoices = group.options.enumerated().map { index, option in
                PlayerChoice(id: String(index), title: option.displayName.ifEmpty("音轨 \(index + 1)"))
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                audioSelection = String(index)
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            guard item == player.currentItem else { return }
            subtitleGroup = group
            subtitleOptions = group.options
            subtitleChoices = group.options.enumerated().map { index, option in
                PlayerChoice(id: String(index), title: option.displayName.ifEmpty("字幕 \(index + 1)"))
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                subtitleSelection = String(index)
            } else {
                subtitleSelection = ""
            }
        }
        // Swift 只暴露了 @concurrent 的 async 版本，主线程上的 asset 不能直接传进去。
        nonisolated(unsafe) let source = asset
        let token = ObjectIdentifier(item)
        Task.detached { [weak self] in
            let groups = try? await source.loadChapterMetadataGroups(withTitleLocale: .current, containingItemsWithCommonKeys: [.commonKeyTitle])
            let marks = (groups ?? []).enumerated().map { index, group in
                let title = (group.items.first { $0.commonKey == .commonKeyTitle }?.value as? String) ?? ""
                return PlayerChapterMark(id: index, title: title, start: group.timeRange.start.seconds)
            }
            await MainActor.run { [weak self] in
                guard let self, let current = self.player.currentItem, ObjectIdentifier(current) == token else { return }
                self.chapterMarks = marks
            }
        }
    }

    /// KVO 可能在任意线程回调，观察闭包本身必须是非隔离的
    private nonisolated static func observeStatus(of item: AVPlayerItem, handler: @escaping @MainActor (AVPlayerItem) -> Void) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in handler(item) }
        }
    }

    private nonisolated static func observeTimeControl(of player: AVPlayer, handler: @escaping @MainActor (AVPlayer.TimeControlStatus) -> Void) -> NSKeyValueObservation {
        player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in handler(status) }
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        isPlaying = status == .playing
        isBuffering = status == .waitingToPlayAtSpecifiedRate
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
            loadPresentation(for: item)
            scheduleHide()
        case .failed:
            presenter?.report(error: Self.playbackMessage(for: item.error))
            dismiss()
        default:
            break
        }
    }

    private func beginPlayback() {
        player.play()
        if abs(rate - 1) > 0.01 { player.rate = Float(rate) }
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
        currentTime = seconds
        let length = player.currentItem?.duration.seconds ?? 0
        duration = length.isFinite ? length : 0
        session.update(position: seconds, duration: self.duration, paused: !isPlaying)
        _ = session.considerSegments(at: seconds, intro: settings.skipIntro, credits: settings.skipCredits) { [weak self] time in
            self?.seek(to: time)
        }
        if skipPrompt.segment?.id != session.skipPrompt?.id {
            skipPrompt.segment = session.skipPrompt
        }
    }

    func skipCurrentSegment() {
        _ = session.skipPromptedSegment { [weak self] time in
            self?.seek(to: time)
        }
        skipPrompt.segment = session.skipPrompt
    }

    func seek(to time: TimeInterval) {
        var target = max(0, time)
        if duration > 0 { target = min(target, duration) }
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        session.update(position: target, duration: duration, paused: !isPlaying, force: true)
    }

    private func didPlayToEnd() {
        session.update(position: session.duration, duration: session.duration, paused: true, force: true)
        session.stop()
        guard settings.autoPlayNext, let next = session.nextItem, let presenter else {
            if !isPictureInPicture { dismiss() }
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
                if !isPictureInPicture { dismiss() }
            }
        }
    }

    private func dismiss(then completion: (() -> Void)? = nil) {
        #if os(iOS)
        viewController.beginClose(completion: completion)
        #else
        presenter?.dismissPlayerWindow()
        completion?()
        #endif
    }

    func handleDismiss() {
        guard !isPictureInPicture else { return }
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
        #if os(iOS)
        viewController.removeOverlay()
        #endif
        presenter?.nativeDidFinish(self)
    }

    var displayTime: TimeInterval { isScrubbing ? scrubTime : currentTime }
    var supportsSubtitleDelay: Bool { false }
    var subtitleDelay: Double { 0 }
    var engineName: String { "系统" }

    func setSubtitleDelay(_ value: Double) {}

    func liveStatRows() -> [(String, String)] { [] }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
            player.play()
            if abs(rate - 1) > 0.01 { player.rate = Float(rate) }
            isPlaying = true
        }
        showControls()
    }

    func skip(_ seconds: Int) {
        let upper = duration > 0 ? duration : currentTime + Double(max(seconds, 0))
        seek(to: min(max(0, currentTime + Double(seconds)), upper))
        flash(.skip(seconds))
    }

    func setRate(_ value: Double) {
        rate = value
        player.defaultRate = Float(value)
        if isPlaying { player.rate = Float(value) }
    }

    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        player.volume = volume
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
        flash(.volume(Double(volume)))
    }

    func selectAudio(_ id: String) {
        guard let group = audioGroup, let index = Int(id), audioOptions.indices.contains(index) else { return }
        player.currentItem?.select(audioOptions[index], in: group)
        audioSelection = id
    }

    func selectSubtitle(_ id: String) {
        guard let group = subtitleGroup else { return }
        if id.isEmpty {
            player.currentItem?.select(nil, in: group)
            subtitleSelection = ""
            return
        }
        guard let index = Int(id), subtitleOptions.indices.contains(index) else { return }
        player.currentItem?.select(subtitleOptions[index], in: group)
        subtitleSelection = id
    }

    func toggleFill() {
        isFill.toggle()
        #if os(iOS)
        viewController.playerController.videoGravity = isFill ? .resizeAspectFill : .resizeAspect
        #else
        playerView.videoGravity = isFill ? .resizeAspectFill : .resizeAspect
        #endif
        flash(.message(isFill ? "填充屏幕" : "适应屏幕"))
    }

    func toggleLock() {
        isLocked.toggle()
        showControls()
    }

    var handoffTargets: [LANPeer] { presenter?.handoffTargets ?? [] }

    func handOff(to peer: LANPeer) {
        guard presenter?.handOff(session, at: currentTime, to: peer) == true else { return }
        player.pause()
        close()
    }

    func togglePiP() {
        preparePictureInPicture()
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    func preparePictureInPicture() {
        guard pipController == nil else { return }
        #if os(iOS)
        let layer = Self.playerLayer(in: viewController.playerController.view)
        #else
        let layer = Self.playerLayer(in: playerView)
        #endif
        guard let layer else { return }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        controller.delegate = self
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        pipController = controller
    }

    func close() {
        if !isPictureInPicture { player.pause() }
        #if os(iOS)
        viewController.beginClose()
        #else
        presenter?.dismissPlayerWindow()
        #endif
    }

    func playNext() {
        guard let next = session.nextItem else { return }
        play(next, resume: false)
    }

    func play(_ item: MediaItem, resume: Bool? = nil) {
        guard let presenter, !isSwitching, !isFinished else { return }
        isSwitching = true
        Task {
            defer { isSwitching = false }
            do {
                let next = try await presenter.makeSession(for: item, resume: resume)
                guard !isFinished else { return }
                if next.engine == .native {
                    load(next)
                } else {
                    finish()
                    dismiss { presenter.present(next) }
                }
            } catch {
                presenter.report(error: error.localizedDescription)
            }
        }
    }

    func showControls(autoHide: Bool = true) {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, isPlaying, !isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    func flash(_ value: PlayerHUD, duration: Double = 0.8) {
        hud = value
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation { hud = nil }
        }
    }

    #if os(iOS)
    func handleDoubleTap(xFraction: CGFloat) {
        guard !isLocked else { return }
        if xFraction < 0.35 {
            skip(-settings.skipBackward)
        } else if xFraction > 0.65 {
            skip(settings.skipForward)
        } else {
            togglePlay()
        }
    }

    func handlePan(_ phase: PlayerGestureView.PanPhase) {
        guard !isLocked else { return }
        switch phase {
        case let .began(axis, xFraction):
            switch axis {
            case .horizontal:
                panStartTime = currentTime
            case .vertical:
                panStartValue = xFraction < 0.5 ? volumeController.brightness : Double(volumeController.volume)
            }
        case let .changed(axis, xFraction, translation, size):
            switch axis {
            case .horizontal:
                let span = min(max(duration * 0.2, 90), 600)
                let target = max(0, min(duration, panStartTime + Double(translation.x / size.width) * span))
                hud = .seek(target: target, delta: target - panStartTime)
                hudTask?.cancel()
            case .vertical:
                let value = max(0, min(1, panStartValue - Double(translation.y / size.height) * 1.2))
                if xFraction < 0.5 {
                    volumeController.brightness = value
                    hud = .brightness(value)
                } else {
                    volumeController.volume = Float(value)
                    hud = .volume(value)
                }
                hudTask?.cancel()
            }
        case let .ended(axis):
            if axis == .horizontal, case let .seek(target, _) = hud {
                seek(to: target)
            }
            if let hud { flash(hud, duration: 0.4) }
        }
    }

    func handleLongPress(began: Bool) {
        guard !isLocked else { return }
        if began {
            rateBeforeLongPress = rate
            player.rate = Float(settings.longPressRate)
            hud = .rate(settings.longPressRate)
            hudTask?.cancel()
        } else if let previous = rateBeforeLongPress {
            player.rate = Float(previous)
            rateBeforeLongPress = nil
            withAnimation { hud = nil }
        }
    }

    func handlePinch(scale: CGFloat) {
        guard !isLocked else { return }
        if scale > 1.1, !isFill { toggleFill() }
        if scale < 0.9, isFill { toggleFill() }
    }
    #endif

    #if os(iOS)
    private typealias PlayerHostView = UIView
    #else
    private typealias PlayerHostView = NSView
    #endif

    private static func playerLayer(in view: PlayerHostView) -> AVPlayerLayer? {
        if let found = playerLayer(from: view.layer) { return found }
        for subview in view.subviews {
            if let found = playerLayer(in: subview) { return found }
        }
        return nil
    }

    private static func playerLayer(from layer: CALayer?) -> AVPlayerLayer? {
        guard let layer else { return nil }
        if let player = layer as? AVPlayerLayer { return player }
        for sub in layer.sublayers ?? [] {
            if let found = playerLayer(from: sub) { return found }
        }
        return nil
    }

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        timeControlObservation = nil
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
            guard let (data, _) = try? await OriginTrust.session(for: url).data(for: MediaRequestAuth.request(for: url)),
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
        isPictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_: AVPlayerViewController) {
        isPictureInPicture = false
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
        isPictureInPicture = true
    }

    func playerViewDidStopPicture(inPicture _: AVPlayerView) {
        isPictureInPicture = false
    }

    func playerView(_: AVPlayerView, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
#endif

extension NativePlayerController: PlayerSurface {}

extension NativePlayerController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        isPictureInPicture = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        isPictureInPicture = false
        #if os(iOS)
        if viewController.presentingViewController == nil { finish() }
        #endif
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        #if os(iOS)
        if viewController.presentingViewController != nil {
            completionHandler(true)
            return
        }
        guard let top = UIApplication.shared.topViewController else {
            completionHandler(false)
            return
        }
        top.present(viewController, animated: true) { completionHandler(true) }
        #else
        completionHandler(true)
        #endif
    }
}
