#if os(macOS)
@preconcurrency import KSPlayer
import SwiftUI

/// macOS 底部控制栏：标题与网速由窗口标题栏 / 工具栏显示，这里只放进度与按钮，全部使用系统控件
struct MacPlayerControls: View {
    @Bindable var model: FFmpegPlayerModel

    var body: some View {
        ZStack {
            // 标题栏透明叠在画面上，加一层暗色渐变保证标题可读
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            bottomBar
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            progressRow
            ZStack {
                HStack(spacing: 14) {
                    leadingGroup
                    Spacer()
                    trailingGroup
                }
                transportGroup
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
        .padding(.bottom, 10)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.title3)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onContinuousHover { phase in
            // 鼠标停在控制栏上时不自动隐藏
            if case .active = phase { model.showControls(autoHide: false) } else { model.scheduleHide() }
        }
    }

    // MARK: - 进度

    private var progressRow: some View {
        PlayerTimeline(model: model, controlSize: .small)
            .font(.callout)
    }

    // MARK: - 左侧：选集、AirPlay、音量、倍速

    private var leadingGroup: some View {
        HStack(spacing: 14) {
            if !model.session.episodes.isEmpty {
                EpisodeListButton(model: model)
            }
            AirPlayButton()
                .frame(width: 22, height: 22)
                .help("AirPlay")
            volumeControl
            rateMenu
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Button {
                model.setVolume(model.volume == 0 ? 1 : 0)
            } label: {
                Label(model.volume == 0 ? "取消静音" : "静音", systemImage: volumeSymbol)
                    .frame(width: 22)
            }
            .help(model.volume == 0 ? "取消静音" : "静音")
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

    private var rateMenu: some View {
        Menu {
            Picker("播放速度", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0], id: \.self) { rate in
                    Text(rate.formatted() + "×").tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(model.rate.formatted() + "×")
                .font(.callout.weight(.semibold))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度")
    }

    // MARK: - 中间：上一集、快退、播放、快进、下一集

    private var transportGroup: some View {
        HStack(spacing: 22) {
            Button {
                if let previous = model.session.previousItem { model.play(previous, resume: false) }
            } label: {
                Label("上一集", systemImage: "backward.end.fill")
            }
            .disabled(model.session.previousItem == nil)
            .help("上一集")

            Button { model.skip(-model.settings.skipBackward) } label: {
                Label("快退", systemImage: "gobackward.\(model.settings.skipBackward)")
            }
            .help("快退 \(model.settings.skipBackward) 秒（←）")

            Button { model.togglePlay() } label: {
                Label(model.isPlaying ? "暂停" : "播放", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32)
            }
            .help(model.isPlaying ? "暂停（空格）" : "播放（空格）")

            Button { model.skip(model.settings.skipForward) } label: {
                Label("快进", systemImage: "goforward.\(model.settings.skipForward)")
            }
            .help("快进 \(model.settings.skipForward) 秒（→）")

            Button { model.playNext() } label: {
                Label("下一集", systemImage: "forward.end.fill")
            }
            .disabled(model.session.nextItem == nil)
            .help("下一集")
        }
    }

    // MARK: - 右侧：章节、字幕、音轨、画中画、设置

    private var trailingGroup: some View {
        HStack(spacing: 14) {
            if !model.chapters.isEmpty {
                chapterMenu
            }
            MacSubtitleMenu(subtitleModel: model.coordinator.subtitleModel)
            audioMenu
            Button { model.togglePiP() } label: {
                Label("画中画", systemImage: "pip.enter")
            }
            .help("画中画")
            PlayerSettingsButton(model: model)
        }
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                Button("\(chapter.title.isEmpty ? "第 \(index + 1) 章" : chapter.title)  \(chapter.start.clockString)") {
                    model.seek(to: chapter.start)
                }
            }
        } label: {
            Label("章节", systemImage: "book")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("章节")
    }

    private var audioMenu: some View {
        Menu {
            Picker("音轨", selection: Binding(get: { model.selectedAudioID ?? -1 }, set: { model.selectAudio($0) })) {
                ForEach(model.audioTracks, id: \.trackID) { track in
                    Text(Self.trackName(track)).tag(track.trackID)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("音轨", systemImage: "waveform")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.audioTracks.count < 2)
        .help("音轨")
    }

    static func trackName(_ track: MediaPlayerTrack) -> String {
        let language = track.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return [language, track.name.isEmpty ? nil : track.name].compactMap(\.self).joined(separator: " · ").ifEmpty("轨道 \(track.trackID)")
    }
}

private struct MacSubtitleMenu: View {
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
            .pickerStyle(.inline)
        } label: {
            Label("字幕", systemImage: subtitleModel.selectedSubtitleInfo == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕")
    }
}

/// 选集：系统 popover 中的列表
private struct EpisodeListButton: View {
    let model: FFmpegPlayerModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("选集", systemImage: "list.bullet")
        }
        .help("选集")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ScrollViewReader { proxy in
                List(model.session.episodes) { episode in
                    Button {
                        isPresented = false
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
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .id(episode.id)
                }
                .frame(width: 360, height: 420)
                .onAppear { proxy.scrollTo(model.session.item.id, anchor: .center) }
            }
        }
    }
}

/// 设置：字幕偏移、画面比例、播放信息
private struct PlayerSettingsButton: View {
    @Bindable var model: FFmpegPlayerModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("设置", systemImage: "gearshape")
        }
        .help("设置")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Form {
                Stepper(value: Binding(get: { model.subtitleDelay }, set: { model.setSubtitleDelay($0) }), in: -30 ... 30, step: 0.5) {
                    LabeledContent("字幕偏移", value: String(format: "%+.1f 秒", model.subtitleDelay))
                }
                Picker("画面", selection: Binding(get: { model.isFill }, set: { if $0 != model.isFill { model.toggleFill() } })) {
                    Text("适应").tag(false)
                    Text("填充").tag(true)
                }
                .pickerStyle(.segmented)
                Button("播放信息…") {
                    isPresented = false
                    model.showInfo = true
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
