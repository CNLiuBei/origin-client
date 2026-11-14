import AVFoundation
import AVKit
import Combine
@preconcurrency import KSPlayer
import MediaPlayer
import SwiftUI

/// 按语言偏好自动挑选音轨
nonisolated final class OriginPlayerOptions: KSOptions {
    var preferredAudioCodes: [String] = []

    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        tracks.firstIndex { track in
            guard let code = track.languageCode?.lowercased() else { return false }
            return preferredAudioCodes.contains { code.hasPrefix($0) }
        }
    }
}

enum PlayerHUD: Equatable {
    case seek(target: TimeInterval, delta: TimeInterval)
    case skip(Int)
    case brightness(Double)
    case volume(Double)
    case rate(Double)
    case message(String)
}

@Observable
final class FFmpegPlayerModel {
    private(set) var session: PlaybackSession
    let settings: AppSettings
    @ObservationIgnored let coordinator = KSVideoPlayer.Coordinator()
    @ObservationIgnored private weak var presenter: PlayerPresenter?
    /// 参数在播放界面真正消失后调用，用来接上进度刷新或下一个播放器
    @ObservationIgnored var dismissAction: ((@escaping () -> Void) -> Void)?

    private(set) var url: URL
    private(set) var options: OriginPlayerOptions
    private(set) var state: KSPlayerState = .initialized
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var audioTracks: [MediaPlayerTrack] = []
    private(set) var selectedAudioID: Int32?
    private(set) var subtitleChoices: [PlayerChoice] = []
    private(set) var subtitleSelection = ""
    private(set) var chapters: [Chapter] = []
    var controlsVisible = true {
        didSet {
            #if os(macOS)
            syncWindowChrome()
            #endif
        }
    }
    var isLocked = false
    var isScrubbing = false
    var scrubTime: TimeInterval = 0
    var hud: PlayerHUD?
    var rate: Double
    var isFill = false
    var subtitleDelay: Double = 0
    var upNextDismissed = false
    var showInfo = false
    var showEpisodes = false
    private(set) var errorText: String?
    #if os(macOS)
    private(set) var volume: Float = 1
    /// 已缓冲到的位置
    private(set) var playableTime: TimeInterval = 0
    /// 网络读取速度（字节/秒）
    private(set) var bytesPerSecond: Int64 = 0
    /// 系统画中画已经接走画面。为 true 时播放窗口不再留在屏幕上。
    private(set) var isPictureInPicture = false
    @ObservationIgnored private var lastBytesSample: (date: Date, bytes: Int64)?
    @ObservationIgnored private var pipCancellable: AnyCancellable?
    @ObservationIgnored private var pipHideTask: Task<Void, Never>?
    #endif

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var rateBeforeLongPress: Double?
    @ObservationIgnored private var panStartTime: TimeInterval = 0
    @ObservationIgnored private var panStartValue: Double = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var playbackGeneration = 0
    @ObservationIgnored private var artworkSessionID: String?
    @ObservationIgnored private var nextCommandTarget: Any?
    @ObservationIgnored private var previousCommandTarget: Any?
    @ObservationIgnored private var remoteNextEnabled: Bool?
    @ObservationIgnored private var remotePreviousEnabled: Bool?
    #if os(iOS)
    @ObservationIgnored let volumeController = SystemVolumeController()
    #endif

    init(session: PlaybackSession, presenter: PlayerPresenter, settings: AppSettings) {
        self.session = session
        self.presenter = presenter
        self.settings = settings
        rate = settings.defaultRate
        url = session.url
        options = Self.makeOptions(session: session, settings: settings)
        Self.configureGlobals(settings)
        session.onLibraryUpdated = { [weak self] in self?.syncRemoteNavigation() }
    }

    private static func configureGlobals(_ settings: AppSettings) {
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.isSeekedAutoPlay = true
        KSOptions.canStartPictureInPictureAutomaticallyFromInline = true
    }

    private static func makeOptions(session: PlaybackSession, settings: AppSettings) -> OriginPlayerOptions {
        let options = OriginPlayerOptions()
        options.preferredAudioCodes = settings.audioLanguage.codes
        options.hardwareDecode = settings.hardwareDecode
        options.startPlayTime = session.startTime
        options.startPlayRate = Float(settings.defaultRate)
        options.autoSelectEmbedSubtitle = false
        options.registerRemoteControll = true
        options.userAgent = "\(DeviceInfo.clientName)/\(DeviceInfo.version)"
        if !session.headers.isEmpty, !session.isOffline {
            options.appendHeader(session.headers)
        }
        return options
    }

    var playerLayer: KSPlayerLayer? { coordinator.playerLayer }
    var isPlaying: Bool { state.isPlaying }
    var isBuffering: Bool {
        switch state {
        case .buffering, .preparing, .readyToPlay: true
        default: false
        }
    }
    var displayTime: TimeInterval { isScrubbing ? scrubTime : currentTime }

    var showUpNext: Bool {
        guard settings.autoPlayNext, !upNextDismissed, session.nextItem != nil, duration > 120 else { return false }
        return duration - currentTime <= 20 && currentTime > 0
    }

    // MARK: - 播放器回调

    func stateChanged(_ layer: KSPlayerLayer, _ newState: KSPlayerState) {
        state = newState
        #if os(macOS)
        // KSPlayer 在此回调之后会按自身状态改写 isMaskShow（并显隐窗口标题栏），下一轮再以本模型为准
        Task { @MainActor in self.syncWindowChrome() }
        observePictureInPicture(layer)
        #endif
        switch newState {
        case .readyToPlay:
            refreshTracks(layer)
            layer.player.playbackRate = Float(rate)
            session.didStart()
            publishNowPlayingMetadata()
            configureRemoteCommands()
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                addSubtitles()
            }
            scheduleHide()
        case .paused:
            session.update(position: currentTime, duration: duration, paused: true, force: true)
            publishNowPlayingClock()
            showControls(autoHide: false)
        case .bufferFinished:
            publishNowPlayingClock()
            scheduleHide()
        case .error:
            errorText = "播放失败，文件可能已损坏或网络不可用"
            showControls(autoHide: false)
        default:
            break
        }
    }

    func timeChanged(_ current: TimeInterval, _ total: TimeInterval) {
        guard current.isFinite, total.isFinite else { return }
        currentTime = current
        duration = total
        session.update(position: current, duration: total, paused: !state.isPlaying)
        if let skipped = session.considerSegments(at: current, intro: settings.skipIntro, credits: settings.skipCredits, seek: { [weak self] time in
            self?.seek(to: time)
        }) {
            flash(.message(skipped.kind.doneTitle))
        }
        syncLiveRate()
        syncRemoteNavigation()
        syncSubtitleChoices()
        #if os(macOS)
        sampleNetwork()
        #endif
    }

    func finished(_ error: Error?) {
        if let error {
            errorText = error.localizedDescription
            showControls(autoHide: false)
            return
        }
        session.update(position: duration, duration: duration, paused: true, force: true)
        session.stop()
        if settings.autoPlayNext, session.nextItem != nil {
            playNext()
        } else {
            close()
        }
    }

    private func refreshTracks(_ layer: KSPlayerLayer) {
        audioTracks = layer.player.tracks(mediaType: .audio)
        selectedAudioID = audioTracks.first { $0.isEnabled }?.trackID
        chapters = layer.player.chapters
    }

    private func addSubtitles() {
        defer { syncSubtitleChoices() }
        let model = coordinator.subtitleModel
        for subtitle in session.externalSubtitles {
            model.addSubtitle(info: URLSubtitleInfo(subtitleID: subtitle.id, name: subtitle.name, url: subtitle.url, userAgent: options.userAgent))
        }
        guard model.selectedSubtitleInfo == nil, settings.subtitleLanguage != .none else { return }
        let preferred = settings.subtitleLanguage
        // 优先外挂中匹配语言的，其次内嵌中名称包含语言的
        if let external = session.externalSubtitles.first(where: { preferred.matches($0.language) }),
           let info = model.subtitleInfos.first(where: { $0.subtitleID == external.id }) {
            model.selectedSubtitleInfo = info
        } else if let embedded = model.subtitleInfos.first(where: { info in
            preferred.codes.contains { info.name.lowercased().contains($0) } || preferred == .chinese && (info.name.contains("中") || info.name.contains("简") || info.name.contains("繁"))
        }) {
            model.selectedSubtitleInfo = embedded
        } else if let external = session.externalSubtitles.first(where: \.isDefault),
                  let info = model.subtitleInfos.first(where: { $0.subtitleID == external.id }) {
            model.selectedSubtitleInfo = info
        }
    }

    /// 换集时写完整元数据。进度只在这时和暂停、跳转、倍速变化时写，不跟播放时钟走。
    private func publishNowPlayingMetadata() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = session.title
        if let subtitle = session.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        applyClock(to: &info, elapsed: currentTime, playbackRate: state.isPlaying ? rate : 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadNowPlayingArtworkIfNeeded()
    }

    private func publishNowPlayingClock(elapsed: TimeInterval? = nil, playbackRate: Double? = nil) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let rate = playbackRate ?? (state.isPlaying ? self.rate : 0)
        applyClock(to: &info, elapsed: elapsed ?? currentTime, playbackRate: rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func applyClock(to info: inout [String: Any], elapsed: TimeInterval, playbackRate: Double) {
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    }

    private func loadNowPlayingArtworkIfNeeded() {
        guard artworkSessionID != session.playSessionID else { return }
        let sessionID = session.playSessionID
        artworkSessionID = sessionID
        guard let artworkURL = session.item.thumbURL ?? session.item.posterURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: MediaRequestAuth.request(for: artworkURL)),
                  let image = await ImageDecoding.decode(data, maxPixelSize: 1200),
                  sessionID == session.playSessionID else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = Self.artwork(image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// 系统会在后台队列调用图片回调。闭包标成 Sendable，并按值捕获 CGImage，避免继承主线程隔离。
    private nonisolated static func artwork(_ cgImage: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return MPMediaItemArtwork(boundsSize: size) { @Sendable [cgImage] _ in
            PlatformImage(cgImage: cgImage)
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBackward)]
        if let nextCommandTarget { center.nextTrackCommand.removeTarget(nextCommandTarget) }
        nextCommandTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        if let previousCommandTarget { center.previousTrackCommand.removeTarget(previousCommandTarget) }
        previousCommandTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let previous = self.session.previousItem else { return }
                self.play(previous, resume: false)
            }
            return .success
        }
        remoteNextEnabled = nil
        remotePreviousEnabled = nil
        syncRemoteNavigation()
    }

    private func syncRemoteNavigation() {
        let hasNext = session.nextItem != nil
        let hasPrevious = session.previousItem != nil
        guard hasNext != remoteNextEnabled || hasPrevious != remotePreviousEnabled else { return }
        remoteNextEnabled = hasNext
        remotePreviousEnabled = hasPrevious
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = hasPrevious
    }

    private func syncSubtitleChoices() {
        let infos = coordinator.subtitleModel.subtitleInfos
        let choices = infos.map { PlayerChoice(id: $0.subtitleID, title: $0.name.ifEmpty("字幕")) }
        let selected = coordinator.subtitleModel.selectedSubtitleInfo?.subtitleID ?? ""
        if choices != subtitleChoices { subtitleChoices = choices }
        if selected != subtitleSelection { subtitleSelection = selected }
    }

    private func syncLiveRate() {
        #if os(iOS)
        if rateBeforeLongPress != nil { return }
        #endif
        guard let live = playerLayer?.player.playbackRate, live > 0 else { return }
        let value = Double(live)
        guard abs(value - rate) > 0.05 else { return }
        rate = value
        publishNowPlayingClock(playbackRate: value)
    }

    // MARK: - 控制

    func togglePlay() {
        guard let layer = playerLayer else { return }
        if state.isPlaying {
            layer.pause()
        } else {
            if state == .playedToTheEnd { coordinator.seek(time: 0) }
            layer.play()
        }
        showControls()
    }

    func skip(_ seconds: Int) {
        let upper = duration > 0 ? duration : currentTime + Double(max(seconds, 0))
        seek(to: min(max(0, currentTime + Double(seconds)), upper))
        flash(.skip(seconds))
    }

    func seek(to time: TimeInterval) {
        let upper = duration > 0 ? duration : time
        let target = min(max(0, time), upper)
        coordinator.seek(time: target)
        currentTime = target
        session.update(position: target, duration: duration, paused: !state.isPlaying, force: true)
        publishNowPlayingClock(elapsed: target)
    }

    func setRate(_ value: Double) {
        rate = value
        coordinator.playbackRate = Float(value)
        publishNowPlayingClock(playbackRate: value)
    }

    func toggleFill() {
        isFill.toggle()
        coordinator.isScaleAspectFill = isFill
        flash(.message(isFill ? "填充屏幕" : "适应屏幕"))
    }

    func selectAudio(_ id: String) {
        guard let trackID = Int32(id), let track = audioTracks.first(where: { $0.trackID == trackID }) else { return }
        playerLayer?.player.select(track: track)
        selectedAudioID = trackID
    }

    func selectSubtitle(_ id: String) {
        let subtitles = coordinator.subtitleModel
        subtitles.selectedSubtitleInfo = id.isEmpty ? nil : subtitles.subtitleInfos.first { $0.subtitleID == id }
        subtitleSelection = id
    }

    func setSubtitleDelay(_ value: Double) {
        subtitleDelay = value
        coordinator.subtitleModel.subtitleDelay = value
    }

    func togglePiP() {
        guard let layer = playerLayer else { return }
        layer.isPipActive.toggle()
    }

    func toggleLock() {
        isLocked.toggle()
        showControls()
    }

    func retry() {
        guard let layer = playerLayer else { return }
        errorText = nil
        options.startPlayTime = currentTime
        layer.player.replace(url: url, options: options)
        layer.prepareToPlay()
    }

    func skipCurrentSegment() {
        if let segment = session.skipPromptedSegment(seek: { [weak self] time in self?.seek(to: time) }) {
            flash(.message(segment.kind.doneTitle))
        }
    }

    func playNext() {
        guard let next = session.nextItem else { return }
        play(next, resume: false)
    }

    /// 切换到同一剧集中的另一集（选集、上一集、下一集）
    func play(_ item: MediaItem, resume: Bool? = nil) {
        guard let presenter, !closed, !isSwitching else { return }
        isSwitching = true
        let generation = playbackGeneration
        Task {
            defer { isSwitching = false }
            do {
                let nextSession = try await presenter.makeSession(for: item, resume: resume)
                guard !closed, generation == playbackGeneration else { return }
                if nextSession.engine == .ffmpeg {
                    load(nextSession)
                } else {
                    close {
                        presenter.present(nextSession)
                    }
                }
            } catch {
                guard !closed, generation == playbackGeneration else { return }
                errorText = error.localizedDescription
                showControls(autoHide: false)
            }
        }
    }

    private func load(_ newSession: PlaybackSession) {
        playbackGeneration += 1
        session.onLibraryUpdated = nil
        session.stop()
        session = newSession
        options = Self.makeOptions(session: newSession, settings: settings)
        currentTime = 0
        duration = 0
        audioTracks = []
        chapters = []
        upNextDismissed = false
        showEpisodes = false
        artworkSessionID = nil
        #if os(macOS)
        playableTime = 0
        lastBytesSample = nil
        #endif
        errorText = nil
        url = newSession.url
        newSession.onLibraryUpdated = { [weak self] in self?.syncRemoteNavigation() }
        publishNowPlayingMetadata()
    }

    func close(completion: (() -> Void)? = nil) {
        guard !closed else {
            completion?()
            return
        }
        closed = true
        playbackGeneration += 1
        session.update(position: currentTime, duration: duration, paused: true, force: true)
        session.stop()
        playerLayer?.pause()
        if playerLayer?.isPipActive == true { playerLayer?.isPipActive = false }
        let finish = { [weak self] in
            self?.releasePlayback()
            completion?()
        }
        if let dismissAction {
            dismissAction(finish)
        } else {
            finish()
        }
    }

    /// 界面转场结束后再释放会话和刷新资料库，避免和关闭动画抢主线程
    private func releasePlayback() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        if let nextCommandTarget { center.nextTrackCommand.removeTarget(nextCommandTarget) }
        if let previousCommandTarget { center.previousTrackCommand.removeTarget(previousCommandTarget) }
        nextCommandTarget = nil
        previousCommandTarget = nil
        PlaybackAudioSession.deactivate()
        presenter?.playbackEnded()
    }

    // MARK: - 控制栏显隐与提示

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
            guard !Task.isCancelled, state.isPlaying, !isScrubbing else { return }
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

    #if os(macOS)
    // MARK: - 键盘与鼠标

    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        coordinator.playbackVolume = volume
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
        flash(.volume(Double(volume)))
    }

    /// 窗口标题栏随控制栏一起显隐（由 KSPlayer 的 isMaskShow 驱动）
    private func syncWindowChrome() {
        if coordinator.isMaskShow != controlsVisible { coordinator.isMaskShow = controlsVisible }
    }

    /// 等系统画中画真正开始再标记，避免窗口先消失、画中画还没出现。
    private func observePictureInPicture(_ layer: KSPlayerLayer) {
        guard pipCancellable == nil else { return }
        pipCancellable = layer.$isPipActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                Task { @MainActor in
                    self?.updatePictureInPicture(active)
                }
            }
    }

    private func updatePictureInPicture(_ active: Bool) {
        pipHideTask?.cancel()
        guard !closed else { return }
        guard active else {
            isPictureInPicture = false
            return
        }
        pipHideTask = Task { @MainActor in
            for _ in 0 ..< 30 {
                if Task.isCancelled || closed { return }
                if playerLayer?.player.pipController?.isPictureInPictureActive == true {
                    isPictureInPicture = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func sampleNetwork() {
        guard let player = playerLayer?.player else { return }
        playableTime = player.playableTime
        let bytes = player.dynamicInfo?.bytesRead ?? 0
        let now = Date.now
        if let last = lastBytesSample {
            let elapsed = now.timeIntervalSince(last.date)
            guard elapsed >= 1 else { return }
            bytesPerSecond = max(0, Int64(Double(bytes - last.bytes) / elapsed))
        }
        lastBytesSample = (now, bytes)
    }
    #endif

    #if os(iOS)
    var volume: Float { 1 }

    func setVolume(_ value: Float) {}

    func adjustVolume(by delta: Float) {}

    // MARK: - 手势

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
            coordinator.playbackRate = Float(settings.longPressRate)
            publishNowPlayingClock(playbackRate: settings.longPressRate)
            hud = .rate(settings.longPressRate)
            hudTask?.cancel()
        } else if let previous = rateBeforeLongPress {
            coordinator.playbackRate = Float(previous)
            rateBeforeLongPress = nil
            publishNowPlayingClock(playbackRate: previous)
            withAnimation { hud = nil }
        }
    }

    func handlePinch(scale: CGFloat) {
        guard !isLocked else { return }
        if scale > 1.1, !isFill { toggleFill() }
        if scale < 0.9, isFill { toggleFill() }
    }
    #endif
}

extension FFmpegPlayerModel: PlayerSurface {
    func close() { close(completion: nil) }

    var audioChoices: [PlayerChoice] {
        audioTracks.map { track in
            let language = track.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            let title = [language, track.name.isEmpty ? nil : track.name].compactMap(\.self).joined(separator: " · ").ifEmpty("轨道 \(track.trackID)")
            return PlayerChoice(id: String(track.trackID), title: title)
        }
    }

    var audioSelection: String { selectedAudioID.map(String.init) ?? "" }

    var chapterMarks: [PlayerChapterMark] {
        chapters.enumerated().map { index, chapter in
            PlayerChapterMark(id: index, title: chapter.title, start: chapter.start)
        }
    }

    var supportsSubtitleDelay: Bool { true }

    var engineName: String { playerLayer?.player is KSMEPlayer ? "FFmpeg" : "AVPlayer" }

    func liveStatRows() -> [(String, String)] {
        guard let info = playerLayer?.player.dynamicInfo else { return [] }
        return [
            ("帧率", info.displayFPS.formatted(.number.precision(.fractionLength(1)))),
            ("丢帧", "\(info.droppedVideoFrameCount + info.droppedVideoPacketCount)"),
            ("音画差", String(format: "%.3f 秒", info.audioVideoSyncDiff)),
            ("视频码率", "\(info.videoBitrate / 1000) kbps"),
            ("音频码率", "\(info.audioBitrate / 1000) kbps"),
            ("已读取", ByteCountFormatter.string(fromByteCount: info.bytesRead, countStyle: .file)),
        ]
    }
}

#if os(iOS)

/// 通过系统 MPVolumeView 调节音量，通过 UIScreen 调节亮度
final class SystemVolumeController {
    let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
    weak var screen: UIScreen?

    var volume: Float {
        get { AVAudioSession.sharedInstance().outputVolume }
        set {
            let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
            slider?.setValue(newValue, animated: false)
        }
    }

    var brightness: Double {
        get { Double(screen?.brightness ?? 0.5) }
        set { screen?.brightness = CGFloat(newValue) }
    }
}
#endif
