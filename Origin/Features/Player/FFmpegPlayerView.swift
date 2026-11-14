import AVKit
@preconcurrency import KSPlayer
import SwiftUI

#if os(iOS)
/// 横屏全屏承载 FFmpeg 播放界面
final class FFmpegHostingController: UIHostingController<FFmpegPlayerView> {
    private let model: FFmpegPlayerModel
    private let closeTransition = PlayerCloseTransition()

    init(session: PlaybackSession, presenter: PlayerPresenter, settings: AppSettings) {
        model = FFmpegPlayerModel(session: session, presenter: presenter, settings: settings)
        super.init(rootView: FFmpegPlayerView(model: model))
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        model.dismissAction = { [weak self] done in
            guard let self else {
                done()
                return
            }
            self.closeTransition.start(on: self, completion: done)
        }
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder _: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if let closing = closeTransition.orientations(for: self) { return closing }
        return traitCollection.userInterfaceIdiom == .pad ? .all : .landscape
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        closeTransition.viewWillTransition(on: self, coordinator: coordinator)
    }

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
            PlayerPointerSurface(model: model)
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

            PlayerScreenChrome(model: model)

            if !model.isLocked, let segment = model.session.skipPrompt {
                SkipSegmentPlacement(title: segment.kind.title, leading: model.showUpNext, bottomPadding: model.controlsVisible ? 96 : 28) {
                    model.skipCurrentSegment()
                }
            }

            UpNextOverlay(model: model)

            if let error = model.errorText {
                ContentUnavailableView {
                    Label("无法播放", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { model.retry() }
                        .buttonStyle(.glassProminent)
                    Button("关闭") { model.close() }
                        .buttonStyle(.glass)
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
    }
}


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


struct SkipPromptButton: View {
    var state: SkipPromptState
    let action: () -> Void

    var body: some View {
        if let segment = state.segment {
            Button(segment.kind.title, systemImage: "forward.fill", action: action)
                .buttonStyle(.glassProminent)
                .accessibilityLabel(segment.kind.title)
        }
    }
}

struct SkipSegmentPlacement: View {
    let title: String
    var leading = false
    var bottomPadding: CGFloat = 72
    let action: () -> Void

    var body: some View {
        VStack {
            Spacer().allowsHitTesting(false)
            HStack {
                if !leading { Spacer().allowsHitTesting(false) }
                Button(title, systemImage: "forward.fill", action: action)
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel(title)
                if leading { Spacer().allowsHitTesting(false) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, bottomPadding)
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

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

