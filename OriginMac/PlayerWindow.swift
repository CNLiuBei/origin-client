import AVKit
import SwiftUI

/// 独立的播放窗口：系统引擎使用 AVPlayerView，其余格式使用 FFmpeg 播放界面
struct PlayerWindowView: View {
    static let id = "player"
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch app.player.active {
            case let .native(controller):
                NativePlayerSurface(playerView: controller.playerView)
                    .id(ObjectIdentifier(controller))
            case let .ffmpeg(model):
                FFmpegPlayerView(model: model)
                    .id(ObjectIdentifier(model))
            case nil:
                EmptyView()
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .preferredColorScheme(.dark)
        .navigationTitle(app.player.activeTitle ?? "播放器")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(app.player.activeTitle ?? "播放器")
                    .font(.headline)
                    .lineLimit(1)
            }
            if case let .ffmpeg(model) = app.player.active {
                ToolbarItem(placement: .primaryAction) {
                    PlayerStatusLabel(model: model)
                }
            }
        }
        .toolbarBackgroundVisibility(isFFmpeg ? .hidden : .automatic, for: .windowToolbar)
        .windowToolbarFullScreenVisibility(.onHover)
        .onDisappear { app.player.playerWindowClosed() }
    }
}

extension PlayerWindowView {
    private var isFFmpeg: Bool {
        if case .ffmpeg = app.player.active { true } else { false }
    }
}

/// 工具栏右侧：网速与当前时间
private struct PlayerStatusLabel: View {
    let model: FFmpegPlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.bytesPerSecond, format: .byteCount(style: .file, allowedUnits: [.kb, .mb, .gb], spellsOutZero: false)) + Text("/s")
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

private struct NativePlayerSurface: NSViewRepresentable {
    let playerView: AVPlayerView

    func makeNSView(context _: Context) -> AVPlayerView { playerView }
    func updateNSView(_: AVPlayerView, context _: Context) {}
}

extension PlayerPresenter {
    /// 窗口标题，如「公寓黑风暴 第1季 第1集 - 公寓内暗藏不知名巨款」
    var activeTitle: String? {
        let session: PlaybackSession? = switch active {
        case let .native(controller): controller.session
        case let .ffmpeg(model): model.session
        case nil: nil
        }
        guard let session else { return nil }
        let item = session.item
        guard item.kind == .episode else { return session.title }
        let label = [item.seasonNumber.map { "第\($0)季" }, item.episodeNumber.map { "第\($0)集" }].compactMap(\.self).joined(separator: " ")
        return "\(session.title) \(label) - \(item.name)"
    }

    func togglePlay() {
        switch active {
        case let .native(controller): controller.togglePlay()
        case let .ffmpeg(model): model.togglePlay()
        case nil: break
        }
    }

    func skip(forward: Bool) {
        let settings = app.settings
        let seconds = forward ? settings.skipForward : -settings.skipBackward
        switch active {
        case let .native(controller): controller.skip(seconds)
        case let .ffmpeg(model): model.skip(seconds)
        case nil: break
        }
    }

    func adjustVolume(by delta: Float) {
        switch active {
        case let .native(controller): controller.adjustVolume(by: delta)
        case let .ffmpeg(model): model.adjustVolume(by: delta)
        case nil: break
        }
    }
}

/// 菜单栏命令：刷新与「播放」菜单
struct OriginCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("刷新") { app.contentChanged() }
                .keyboardShortcut("r")
        }
        CommandMenu("播放") {
            let player = app.player
            let hasPlayer = player.active != nil
            // 空格键由播放窗口自行处理，避免在主窗口输入文字时误触
            Button("播放/暂停") { player.togglePlay() }
                .disabled(!hasPlayer)
            Button("快进") { player.skip(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!hasPlayer)
            Button("快退") { player.skip(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!hasPlayer)
            Divider()
            Button("增大音量") { player.adjustVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!hasPlayer)
            Button("减小音量") { player.adjustVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!hasPlayer)
            Divider()
            Button("关闭播放器") { player.dismissPlayerWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!hasPlayer)
        }
    }
}
