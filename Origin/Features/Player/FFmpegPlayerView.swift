import AVKit
@preconcurrency import KSPlayer
import SwiftUI

#if os(iOS)
/// 横屏全屏承载 FFmpeg 播放界面
final class FFmpegHostingController: UIHostingController<FFmpegPlayerView> {
    private let model: FFmpegPlayerModel

    init(session: PlaybackSession, presenter: PlayerPresenter, settings: AppSettings) {
        model = FFmpegPlayerModel(session: session, presenter: presenter, settings: settings)
        super.init(rootView: FFmpegPlayerView(model: model))
        modalPresentationStyle = .fullScreen
        view.backgroundColor = .black
        model.dismissAction = { [weak self] in self?.dismiss(animated: true) }
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder _: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .pad ? .all : .landscape
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { OrientationPolicy.restorePortrait() }
    }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
}
#endif

struct FFmpegPlayerView: View {
    @Bindable var model: FFmpegPlayerModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            KSVideoPlayer(coordinator: model.coordinator, url: model.url, options: model.options)
                .onStateChanged { layer, state in model.stateChanged(layer, state) }
                .onPlay { current, total in model.timeChanged(current, total) }
                .onFinish { _, error in model.finished(error) }
                .ignoresSafeArea()

            SubtitleOverlay(subtitleModel: model.coordinator.subtitleModel, settings: model.settings)
                .allowsHitTesting(false)

            #if os(iOS)
            PlayerGestureView(
                volumeController: model.volumeController,
                onTap: { model.toggleControls() },
                onDoubleTap: { model.handleDoubleTap(xFraction: $0) },
                onPan: { model.handlePan($0) },
                onLongPress: { model.handleLongPress(began: $0) },
                onPinch: { model.handlePinch(scale: $0) }
            )
            .ignoresSafeArea()
            #else
            MousePlayerSurface(model: model)
            #endif

            if model.isBuffering, model.errorText == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }

            if let hud = model.hud {
                HUDView(hud: hud)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if model.controlsVisible {
                #if os(macOS)
                MacPlayerControls(model: model)
                    .transition(.opacity)
                #else
                if model.isLocked {
                    lockOverlay
                } else {
                    PlayerControls(model: model)
                        .transition(.opacity)
                }
                #endif
            }

            UpNextOverlay(model: model)

            if let error = model.errorText {
                ContentUnavailableView {
                    Label("无法播放", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("关闭") { model.close() }
                        .buttonStyle(.glassProminent)
                }
                .foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #else
        .playerKeyboardShortcuts(model)
        #endif
        .sheet(isPresented: $model.showInfo) {
            PlaybackInfoSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        #if os(iOS)
        .sheet(isPresented: $model.showEpisodes) {
            EpisodeBrowser(model: model)
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    #if os(iOS)
    private var lockOverlay: some View {
        HStack {
            Button {
                model.toggleLock()
            } label: {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(model.isLocked ? "解锁" : "锁定")
            Spacer()
        }
        .padding(.horizontal, 40)
    }
    #endif
}

// MARK: - 控制层

#if os(iOS)
private struct PlayerControls: View {
    @Bindable var model: FFmpegPlayerModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerControls
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    model.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("关闭播放器")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.session.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = model.session.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                Spacer()

                HStack(spacing: 4) {
                    if !model.session.episodes.isEmpty {
                        iconButton("list.bullet", label: "选集") { model.showEpisodes = true }
                    }
                    AirPlayButton()
                        .frame(width: 40, height: 40)
                        .accessibilityLabel("AirPlay")
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        iconButton("pip.enter", label: "画中画") { model.togglePiP() }
                    }
                    iconButton("info.circle", label: "播放信息") { model.showInfo = true }
                }
                .padding(.horizontal, 6)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
    }

    private var centerControls: some View {
        PlayerTransport(model: model)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            PlayerTimeline(model: model, showsRemaining: true)
                .font(.footnote)

            HStack(spacing: 8) {
                rateMenu
                audioMenu
                SubtitleMenu(subtitleModel: model.coordinator.subtitleModel)
                if !model.chapters.isEmpty {
                    chapterMenu
                }
                iconButton(model.isFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: model.isFill ? "适应屏幕" : "填充屏幕") {
                    model.toggleFill()
                }
                iconButton("lock.open", label: "锁定") { model.toggleLock() }
                Spacer()
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 28))
    }

    private var rateMenu: some View {
        Menu {
            Picker("播放速度", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0], id: \.self) { rate in
                    Text(rate.formatted() + "×").tag(rate)
                }
            }
        } label: {
            Text(model.rate == 1 ? "1×" : model.rate.formatted() + "×")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 40)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("播放速度")
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                Button("\(chapter.title.isEmpty ? "第 \(index + 1) 章" : chapter.title)  \(chapter.start.clockString)") {
                    model.seek(to: chapter.start)
                }
            }
        } label: {
            Image(systemName: "book")
                .font(.title3)
                .frame(width: 44, height: 40)
        }
        .accessibilityLabel("章节")
    }

    private var audioMenu: some View {
        Menu {
            Picker("音轨", selection: Binding(get: { model.selectedAudioID ?? -1 }, set: { model.selectAudio($0) })) {
                ForEach(model.audioTracks, id: \.trackID) { track in
                    Text(Self.trackName(track)).tag(track.trackID)
                }
            }
        } label: {
            Image(systemName: "waveform")
                .font(.title3)
                .frame(width: 44, height: 40)
        }
        .disabled(model.audioTracks.count < 2)
        .accessibilityLabel("音轨")
    }

    static func trackName(_ track: MediaPlayerTrack) -> String {
        let language = track.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return [language, track.name.isEmpty ? nil : track.name].compactMap(\.self).joined(separator: " · ").ifEmpty("轨道 \(track.trackID)")
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 40)
        }
        .accessibilityLabel(label)
    }
}

private struct PlayerTransport: View {
    @Bindable var model: FFmpegPlayerModel

    var body: some View {
        HStack(spacing: 22) {
            transport("backward.end.fill", label: "上一集", diameter: 56) {
                if let previous = model.session.previousItem { model.play(previous, resume: false) }
            }
            .disabled(model.session.previousItem == nil)

            transport("gobackward.\(model.settings.skipBackward)", label: "快退 \(model.settings.skipBackward) 秒", diameter: 64) {
                model.skip(-model.settings.skipBackward)
            }

            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 80, height: 80)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(model.isPlaying ? "暂停" : "播放")

            transport("goforward.\(model.settings.skipForward)", label: "快进 \(model.settings.skipForward) 秒", diameter: 64) {
                model.skip(model.settings.skipForward)
            }

            transport("forward.end.fill", label: "下一集", diameter: 56) {
                model.playNext()
            }
            .disabled(model.session.nextItem == nil)
        }
    }

    private func transport(_ symbol: String, label: String, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

private struct SubtitleMenu: View {
    @ObservedObject var subtitleModel: SubtitleModel

    var body: some View {
        Menu {
            Picker("字幕", selection: Binding<String>(
                get: { subtitleModel.selectedSubtitleInfo?.subtitleID ?? "" },
                set: { id in subtitleModel.selectedSubtitleInfo = subtitleModel.subtitleInfos.first { $0.subtitleID == id } }
            )) {
                Text("关闭").tag("")
                ForEach(subtitleModel.subtitleInfos, id: \.subtitleID) { info in
                    Text(info.name.ifEmpty("字幕")).tag(info.subtitleID)
                }
            }
        } label: {
            Image(systemName: subtitleModel.selectedSubtitleInfo == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3)
                .frame(width: 44, height: 40)
        }
        .accessibilityLabel("字幕")
    }
}

private struct EpisodeBrowser: View {
    @Bindable var model: FFmpegPlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(model.session.episodes) { episode in
                    Button {
                        dismiss()
                        if episode.id != model.session.item.id { model.play(episode, resume: nil) }
                    } label: {
                        HStack(spacing: 10) {
                            RemoteImage(url: episode.thumbURL, aspectRatio: 16 / 9)
                                .frame(width: 96)
                                .clipShape(.rect(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(episode.shortEpisodeLabel ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(episode.name)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if episode.id == model.session.item.id {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                        }
                    }
                    .id(episode.id)
                }
                .onAppear { proxy.scrollTo(model.session.item.id, anchor: .center) }
            }
            .navigationTitle("选集")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

#endif

// MARK: - 字幕渲染

private struct SubtitleOverlay: View {
    @ObservedObject var subtitleModel: SubtitleModel
    let settings: AppSettings

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(subtitleModel.parts) { part in
                    if let image = part.image {
                        let rect = image.fitRect(proxy.size)
                        Image(platformImage: image)
                            .resizable()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    } else if let text = part.text {
                        VStack {
                            if part.textPosition?.verticalAlign == .top {
                                textView(text).padding(.top, 24)
                                Spacer()
                            } else {
                                Spacer()
                                textView(text).padding(.bottom, settings.subtitleBottomPadding)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .ignoresSafeArea(edges: .bottom)
    }

    private func textView(_ text: NSAttributedString) -> some View {
        Text(text.string)
            .font(.system(size: settings.subtitleSize, weight: .semibold))
            .foregroundStyle(settings.subtitleColor)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 1)
            .shadow(color: .black.opacity(0.6), radius: 6)
            .padding(.horizontal, settings.subtitleBackground ? 10 : 0)
            .padding(.vertical, settings.subtitleBackground ? 4 : 0)
            .background(settings.subtitleBackground ? Color.black.opacity(0.55) : .clear, in: .rect(cornerRadius: 6))
    }
}

// MARK: - 提示

private struct HUDView: View {
    let hud: PlayerHUD

    var body: some View {
        HStack(spacing: 10) {
            switch hud {
            case let .seek(target, delta):
                Image(systemName: delta >= 0 ? "goforward" : "gobackward")
                Text(target.clockString).monospacedDigit()
                Text((delta >= 0 ? "+" : "-") + abs(delta).clockString)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case let .skip(seconds):
                Image(systemName: seconds > 0 ? "goforward" : "gobackward")
                Text("\(seconds > 0 ? "+" : "")\(seconds) 秒")
            case let .brightness(value):
                Image(systemName: "sun.max.fill")
                ProgressView(value: value).frame(width: 120)
            case let .volume(value):
                Image(systemName: value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                ProgressView(value: value).frame(width: 120)
            case let .rate(rate):
                Image(systemName: "forward.fill")
                Text("\(rate.formatted())× 倍速播放中")
            case let .message(text):
                Text(text)
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }
}

struct PlayerTimeline: View {
    @Bindable var model: FFmpegPlayerModel
    var showsRemaining = false
    var controlSize: ControlSize = .regular

    var body: some View {
        HStack(spacing: 10) {
            Text(model.displayTime.clockString)
            Slider(
                value: Binding(
                    get: { model.isScrubbing ? model.scrubTime : model.currentTime },
                    set: { model.scrubTime = $0 }
                ),
                in: 0 ... max(model.duration, 1)
            ) { editing in
                if editing {
                    model.scrubTime = model.currentTime
                    model.isScrubbing = true
                    model.showControls(autoHide: false)
                } else {
                    model.seek(to: model.scrubTime)
                    model.isScrubbing = false
                    model.scheduleHide()
                }
            }
            .controlSize(controlSize)
            .tint(.white)
            .accessibilityLabel("播放进度")
            Text(trailing)
        }
        .monospacedDigit()
    }

    private var trailing: String {
        if showsRemaining {
            "-" + max(0, model.duration - model.displayTime).clockString
        } else {
            model.duration.clockString
        }
    }
}

private struct UpNextOverlay: View {
    @Bindable var model: FFmpegPlayerModel

    var body: some View {
        Group {
            if model.showUpNext, let next = model.session.nextItem {
                UpNextCard(item: next, remaining: max(0, model.duration - model.currentTime)) {
                    model.playNext()
                } onCancel: {
                    model.upNextDismissed = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(32)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showUpNext)
    }
}

private struct UpNextCard: View {
    let item: MediaItem
    let remaining: TimeInterval
    let onPlay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: item.thumbURL, aspectRatio: 16 / 9)
                .frame(width: 150)
                .clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Int(remaining)) 秒后播放下一集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text([item.episodeLabel, item.name].compactMap(\.self).joined(separator: " · "))
                    .font(.headline)
                    .lineLimit(2)
                HStack {
                    Button("立即播放", systemImage: "play.fill", action: onPlay)
                        .buttonStyle(.glassProminent)
                    Button("取消", action: onCancel)
                        .buttonStyle(.glass)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .frame(maxWidth: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .foregroundStyle(.white)
    }
}

// MARK: - 播放信息

private struct PlaybackInfoSheet: View {
    @Bindable var model: FFmpegPlayerModel

    var body: some View {
        NavigationStack {
            Form {
                Section("字幕") {
                    Stepper(value: Binding(get: { model.subtitleDelay }, set: { model.setSubtitleDelay($0) }), in: -30 ... 30, step: 0.5) {
                        LabeledContent("字幕偏移", value: String(format: "%+.1f 秒", model.subtitleDelay))
                    }
                }
                if let source = model.session.source {
                    Section("文件") {
                        if let name = source.fileName { LabeledContent("文件名", value: name) }
                        if let container = source.container { LabeledContent("容器", value: container.uppercased()) }
                        if let size = source.size { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        if let bitrate = source.bitrate { LabeledContent("码率", value: "\(bitrate / 1000) kbps") }
                    }
                    if let video = source.videoStream {
                        Section("视频") {
                            LabeledContent("编码", value: video.codec?.uppercased() ?? "-")
                            if let w = video.width, let h = video.height { LabeledContent("分辨率", value: "\(w)×\(h)") }
                            if let range = video.videoRange { LabeledContent("动态范围", value: range) }
                        }
                    }
                }
                Section("实时") {
                    LabeledContent("播放内核", value: model.playerLayer?.player is KSMEPlayer ? "FFmpeg" : "AVPlayer")
                    if let info = model.playerLayer?.player.dynamicInfo {
                        LabeledContent("帧率", value: info.displayFPS.formatted(.number.precision(.fractionLength(1))))
                        LabeledContent("丢帧", value: "\(info.droppedVideoFrameCount + info.droppedVideoPacketCount)")
                        LabeledContent("音画差", value: String(format: "%.3f 秒", info.audioVideoSyncDiff))
                        LabeledContent("视频码率", value: "\(info.videoBitrate / 1000) kbps")
                        LabeledContent("音频码率", value: "\(info.audioBitrate / 1000) kbps")
                        LabeledContent("已读取", value: ByteCountFormatter.string(fromByteCount: info.bytesRead, countStyle: .file))
                    }
                }
            }
            .navigationTitle("播放信息")
            .inlineNavigationTitle()
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

#if os(macOS)
/// macOS：移动鼠标显示控制栏，单击暂停或继续，双击切换全屏；控制栏隐藏后鼠标指针也一并隐藏
private struct MousePlayerSurface: View {
    let model: FFmpegPlayerModel

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active: if !model.controlsVisible { model.showControls() }
                case .ended: model.scheduleHide()
                }
            }
            .gesture(
                TapGesture(count: 2).onEnded { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .exclusively(before: TapGesture().onEnded { model.togglePlay() })
            )
            .onChange(of: model.controlsVisible) { _, visible in
                if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
            }
    }
}

private extension View {
    /// 空格播放/暂停，左右方向键快退/快进，上下方向键调节音量，F 全屏，Esc 退出全屏
    func playerKeyboardShortcuts(_ model: FFmpegPlayerModel) -> some View {
        focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) {
                model.togglePlay()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                model.skip(-model.settings.skipBackward)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                model.skip(model.settings.skipForward)
                return .handled
            }
            .onKeyPress(.upArrow) {
                model.adjustVolume(by: 0.1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                model.adjustVolume(by: -0.1)
                return .handled
            }
            .onKeyPress("f") {
                NSApp.keyWindow?.toggleFullScreen(nil)
                return .handled
            }
            .onKeyPress(.escape) {
                guard let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) else { return .ignored }
                window.toggleFullScreen(nil)
                return .handled
            }
    }
}
#endif
