import AVKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct PlayerChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

struct PlayerChapterMark: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let start: TimeInterval
}

/// 播放控件需要的状态和操作。FFmpeg 与系统播放器都实现它，界面只写一份。
protocol PlayerSurface: AnyObject, Observable {
    var session: PlaybackSession { get }
    var settings: AppSettings { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var displayTime: TimeInterval { get }
    var isPlaying: Bool { get }
    var isScrubbing: Bool { get set }
    var scrubTime: TimeInterval { get set }
    var rate: Double { get }
    var controlsVisible: Bool { get }
    var isLocked: Bool { get }
    var isFill: Bool { get }
    var showInfo: Bool { get set }
    var showEpisodes: Bool { get set }
    var audioChoices: [PlayerChoice] { get }
    var audioSelection: String { get }
    var subtitleChoices: [PlayerChoice] { get }
    var subtitleSelection: String { get }
    var chapterMarks: [PlayerChapterMark] { get }
    var supportsSubtitleDelay: Bool { get }
    var subtitleDelay: Double { get }
    var engineName: String { get }
    var volume: Float { get }

    func togglePlay()
    func skip(_ seconds: Int)
    func seek(to time: TimeInterval)
    func setRate(_ value: Double)
    func selectAudio(_ id: String)
    func selectSubtitle(_ id: String)
    func play(_ item: MediaItem, resume: Bool?)
    func playNext()
    func close()
    func togglePiP()
    func toggleFill()
    func toggleLock()
    func showControls(autoHide: Bool)
    func scheduleHide()
    func toggleControls()
    func setVolume(_ value: Float)
    func adjustVolume(by delta: Float)
    func setSubtitleDelay(_ value: Double)
    func liveStatRows() -> [(String, String)]
}

/// 控制栏显隐和播放信息、选集。控件本身只在需要时出现。
struct PlayerScreenChrome<Model: PlayerSurface>: View {
    @Bindable var model: Model

    var body: some View {
        Group {
            if model.controlsVisible {
                #if os(iOS)
                if model.isLocked {
                    PlayerLockButton(model: model)
                } else {
                    PlayerChrome(model: model)
                }
                #else
                PlayerChrome(model: model)
                #endif
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
        .sheet(isPresented: $model.showInfo) {
            PlaybackInfoSheet(model: model)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
        #if os(iOS)
        .sheet(isPresented: $model.showEpisodes) {
            EpisodeBrowser(model: model)
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
        #endif
    }
}

struct PlayerChrome<Model: PlayerSurface>: View {
    @Bindable var model: Model
    #if os(macOS)
    @State private var isFullScreen = false
    #endif

    var body: some View {
        #if os(iOS)
        phoneChrome
        #else
        macChrome
        #endif
    }

    #if os(iOS)
    private var phoneChrome: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 72)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 108)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                iconButton("xmark", label: "关闭播放器") { model.close() }
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
                HStack(spacing: 12) {
                    if !model.session.episodes.isEmpty {
                        iconButton("list.bullet", label: "选集") { model.showEpisodes = true }
                    }
                    AirPlayButton()
                        .frame(width: 36, height: 36)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .accessibilityLabel("AirPlay")
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        iconButton("pip.enter", label: "画中画") { model.togglePiP() }
                    }
                    iconButton("info.circle", label: "播放信息") { model.showInfo = true }
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private var macChrome: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            Spacer()
            bottomBar
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                        .allowsHitTesting(false)
                }
        }
        .foregroundStyle(.white)
        .onAppear { isFullScreen = PlayerWindowChrome.isFullScreen }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === PlayerWindowChrome.playerWindow else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === PlayerWindowChrome.playerWindow else { return }
            isFullScreen = false
        }
        .onContinuousHover { phase in
            if case .active = phase { model.showControls(autoHide: false) } else { model.scheduleHide() }
        }
    }
    #endif

    private var bottomBar: some View {
        VStack(spacing: 6) {
            PlayerTimeline(model: model, showsRemaining: true)
                #if os(macOS)
                .font(.callout)
                #else
                .font(.footnote)
                #endif
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    PlayerTransport(model: model)
                    Spacer(minLength: 8)
                    #if os(macOS)
                    volumeControl
                    #endif
                    HStack(spacing: 8) {
                        #if os(macOS)
                        if !model.session.episodes.isEmpty {
                            EpisodeMenu(model: model)
                        }
                        AirPlayButton()
                            .frame(width: 36, height: 36)
                            .glassEffect(.clear.interactive(), in: .circle)
                            .accessibilityLabel("AirPlay")
                            .help("AirPlay")
                        iconButton("pip.enter", label: "画中画") { model.togglePiP() }
                        iconButton("info.circle", label: "播放信息") { model.showInfo = true }
                        #endif
                        rateMenu
                        audioMenu
                        subtitleMenu
                        if !model.chapterMarks.isEmpty {
                            chapterMenu
                        }
                        #if os(iOS)
                        iconButton(model.isFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: model.isFill ? "适应屏幕" : "填充屏幕") {
                            model.toggleFill()
                        }
                        iconButton("lock.open", label: "锁定") { model.toggleLock() }
                        #else
                        iconButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: isFullScreen ? "退出全屏" : "全屏") {
                            PlayerWindowChrome.toggleFullScreen()
                        }
                        #endif
                    }
                }
            }
        }
    }

    #if os(macOS)
    private var volumeControl: some View {
        HStack(spacing: 6) {
            iconButton(volumeSymbol, label: model.volume == 0 ? "取消静音" : "静音") {
                model.setVolume(model.volume == 0 ? 1 : 0)
            }
            Slider(value: Binding(get: { Double(model.volume) }, set: { model.setVolume(Float($0)) }), in: 0 ... 1)
                .controlSize(.mini)
                .tint(.white)
                .frame(width: 72)
                .accessibilityLabel("音量")
        }
    }

    private var volumeSymbol: String {
        switch model.volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
    #endif

    private var rateMenu: some View {
        Menu {
            Picker("播放速度", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0], id: \.self) { rate in
                    Text(rate.formatted() + "×").tag(rate)
                }
            }
        } label: {
            Text(model.rate == 1 ? "1×" : model.rate.formatted() + "×")
                .font(.subheadline)
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.capsule)
        .menuOrder(.fixed)
        .accessibilityLabel("播放速度")
        .playerHelp("播放速度")
    }

    private var audioMenu: some View {
        symbolMenu("音轨", systemImage: "waveform") {
            Picker("音轨", selection: Binding(get: { model.audioSelection }, set: { model.selectAudio($0) })) {
                ForEach(model.audioChoices) { choice in
                    Text(choice.title).tag(choice.id)
                }
            }
        }
        .disabled(model.audioChoices.count < 2)
    }

    private var subtitleMenu: some View {
        symbolMenu("字幕", systemImage: model.subtitleSelection.isEmpty ? "captions.bubble" : "captions.bubble.fill") {
            Picker("字幕", selection: Binding(get: { model.subtitleSelection }, set: { model.selectSubtitle($0) })) {
                Text("关闭").tag("")
                ForEach(model.subtitleChoices) { choice in
                    Text(choice.title).tag(choice.id)
                }
            }
        }
    }

    private var chapterMenu: some View {
        symbolMenu("章节", systemImage: "book") {
            ForEach(model.chapterMarks) { chapter in
                Button("\(chapter.title.isEmpty ? "第 \(chapter.id + 1) 章" : chapter.title)  \(chapter.start.clockString)") {
                    model.seek(to: chapter.start)
                }
            }
        }
    }

    /// 菜单自带指示箭头。圆玻璃只包住按钮的一部分，符号会落到圆外面。
    /// 用系统的胶囊玻璃把符号和箭头放进同一块底。
    private func symbolMenu<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        #if os(macOS)
        .buttonBorderShape(.capsule)
        #else
        .buttonBorderShape(.circle)
        #endif
        .buttonStyle(.glass(.clear))
        .accessibilityLabel(title)
        .playerHelp(title)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .buttonStyle(.glass(.clear))
            .accessibilityLabel(label)
            .playerHelp(label)
    }
}

private struct PlayerTransport<Model: PlayerSurface>: View {
    @Bindable var model: Model

    var body: some View {
        HStack(spacing: 8) {
            if model.session.previousItem != nil {
                transport("backward.end.fill", label: "上一集") {
                    if let previous = model.session.previousItem { model.play(previous, resume: false) }
                }
            }
            transport("gobackward.\(model.settings.skipBackward)", label: "快退 \(model.settings.skipBackward) 秒") {
                model.skip(-model.settings.skipBackward)
            }
            Button {
                model.togglePlay()
            } label: {
                Label(model.isPlaying ? "暂停" : "播放", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonBorderShape(.circle)
            .buttonStyle(.glass(.clear))
            .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
            .playerHelp(model.isPlaying ? "暂停" : "播放")
            transport("goforward.\(model.settings.skipForward)", label: "快进 \(model.settings.skipForward) 秒") {
                model.skip(model.settings.skipForward)
            }
            if model.session.nextItem != nil {
                transport("forward.end.fill", label: "下一集") { model.playNext() }
            }
        }
    }

    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .buttonStyle(.glass(.clear))
            .accessibilityLabel(label)
            .playerHelp(label)
    }
}

struct PlayerTimeline<Model: PlayerSurface>: View {
    @Bindable var model: Model
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

#if os(iOS)
struct PlayerLockButton<Model: PlayerSurface>: View {
    @Bindable var model: Model

    var body: some View {
        HStack {
            Button(model.isLocked ? "解锁" : "锁定", systemImage: "lock.fill") {
                model.toggleLock()
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .buttonStyle(.glass(.clear))
            .accessibilityLabel(model.isLocked ? "解锁" : "锁定")
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}
#endif

#if os(macOS)
private struct EpisodeMenu<Model: PlayerSurface>: View {
    @Bindable var model: Model
    @State private var isPresented = false

    var body: some View {
        iconButton
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                EpisodeList(model: model) { isPresented = false }
                    .frame(width: 560)
            }
    }

    private var iconButton: some View {
        Button("选集", systemImage: "list.bullet") { isPresented.toggle() }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .buttonStyle(.glass(.clear))
        .accessibilityLabel("选集")
        .help("选集")
    }
}
#endif

private struct EpisodeBrowser<Model: PlayerSurface>: View {
    @Bindable var model: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EpisodeList(model: model) { dismiss() }
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

private struct EpisodeList<Model: PlayerSurface>: View {
    @Bindable var model: Model
    var onSelect: () -> Void
    @State private var seasonKey: String?
    @State private var focusedEpisode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if seasonGroups.count > 1 {
                Picker("季", selection: seasonSelection) {
                    ForEach(seasonGroups, id: \.key) { group in
                        Text(group.title).tag(group.key)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .accessibilityLabel("季")
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(visibleEpisodes) { episode in
                        Button {
                            guard episode.id != model.session.item.id else { return }
                            onSelect()
                            model.play(episode, resume: nil)
                        } label: {
                            EpisodeRow(episode: episode, isCurrent: episode.id == model.session.item.id)
                        }
                        .buttonStyle(.plain)
                        .id(episode.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focusedEpisode, anchor: .center)
            .scrollIndicators(.visible)
            .frame(height: 176)
            .onAppear { focusCurrent() }
            .onChange(of: seasonKey ?? currentSeasonKey) { _, _ in focusCurrent() }
        }
        .padding(.vertical, 12)
    }

    private var seasonSelection: Binding<String> {
        Binding(
            get: { seasonKey ?? currentSeasonKey },
            set: { seasonKey = $0 }
        )
    }

    private var currentSeasonKey: String {
        let item = model.session.item
        return item.seasonID ?? "s\(item.seasonNumber ?? 0)"
    }

    private var visibleEpisodes: [MediaItem] {
        let key = seasonKey ?? currentSeasonKey
        return seasonGroups.first { $0.key == key }?.items ?? model.session.episodes
    }

    private var seasonGroups: [(key: String, title: String, items: [MediaItem])] {
        var order: [String] = []
        var groups: [String: [MediaItem]] = [:]
        for episode in model.session.episodes {
            let key = episode.seasonID ?? "s\(episode.seasonNumber ?? 0)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(episode)
        }
        return order.map { key in
            let items = groups[key] ?? []
            let number = items.first?.seasonNumber
            let title = number.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "剧集"
            return (key, title, items)
        }
    }

    private func focusCurrent() {
        let current = model.session.item.id
        focusedEpisode = visibleEpisodes.contains { $0.id == current } ? current : visibleEpisodes.first?.id
    }
}

private struct EpisodeRow: View {
    let episode: MediaItem
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: episode.thumbURL, aspectRatio: 16 / 9)
                .frame(width: 168)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if !isCurrent {
                        WatchBadge(item: episode).padding(6)
                    }
                }
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white, lineWidth: 2.5)
                    }
                }
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 168, alignment: .topLeading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var title: String {
        episode.episodeNumber.map { "\($0). \(episode.name)" } ?? episode.name
    }

    private var detail: String? {
        if episode.userState.isPlayed, !isCurrent { return "已观看" }
        if episode.progress > 0.01, !isCurrent { return "看到 \(episode.userState.playbackPosition.clockString)" }
        let runtime = episode.runtime?.durationString
        return runtime?.isEmpty == false ? runtime : nil
    }

    private var accessibilityText: String {
        [episode.episodeNumber.map { "第 \($0) 集" }, episode.name, detail]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}

private struct PlaybackInfoSheet<Model: PlayerSurface>: View {
    @Bindable var model: Model

    var body: some View {
        NavigationStack {
            Form {
                if model.supportsSubtitleDelay {
                    Section("字幕") {
                        Stepper(value: Binding(get: { model.subtitleDelay }, set: { model.setSubtitleDelay($0) }), in: -30 ... 30, step: 0.5) {
                            LabeledContent("字幕偏移", value: String(format: "%+.1f 秒", model.subtitleDelay))
                        }
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
                    LabeledContent("播放内核", value: model.engineName)
                    LabeledContent("时间", value: model.displayTime.clockString)
                    ForEach(Array(model.liveStatRows().enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.0, value: row.1)
                    }
                }
            }
            .navigationTitle("播放信息")
            .inlineNavigationTitle()
        }
    }
}

struct HUDView: View {
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

#if os(macOS)
struct PlayerPointerSurface<Model: PlayerSurface>: View {
    @Bindable var model: Model

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active: if !model.controlsVisible { model.showControls(autoHide: true) }
                case .ended: model.scheduleHide()
                }
            }
            .gesture(
                TapGesture(count: 2).onEnded { PlayerWindowChrome.toggleFullScreen() }
                    .exclusively(before: TapGesture().onEnded { model.togglePlay() })
            )
            .onChange(of: model.controlsVisible) { _, visible in
                if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
            }
    }
}

extension View {
    func playerKeyboardShortcuts<Model: PlayerSurface>(_ model: Model) -> some View {
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
                PlayerWindowChrome.toggleFullScreen()
                return .handled
            }
            .onKeyPress(.escape) {
                guard PlayerWindowChrome.isFullScreen else { return .ignored }
                PlayerWindowChrome.toggleFullScreen()
                return .handled
            }
    }

    func playerHelp(_ text: String) -> some View { help(text) }
}
#else
extension View {
    func playerHelp(_ text: String) -> some View { self }
}
#endif

struct NativePlayerScreen: View {
    @Bindable var model: NativePlayerController

    var body: some View {
        ZStack {
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
            PlayerPointerSurface(model: model)
            #endif

            if model.isBuffering {
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
            }

            PlayerScreenChrome(model: model)

            if !model.isLocked, let segment = model.skipPrompt.segment {
                SkipSegmentPlacement(title: segment.kind.title, leading: false, bottomPadding: model.controlsVisible ? 96 : 28) {
                    model.skipCurrentSegment()
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .playerKeyboardShortcuts(model)
        #endif
    }
}
