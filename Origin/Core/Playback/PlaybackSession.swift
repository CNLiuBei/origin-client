import AVFoundation
import Foundation

/// 播放开始时再激活音频会话，结束时交还给其他 App。类别在启动时已经设好。
enum PlaybackAudioSession {
    static func activate() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? session.setActive(true)
        #endif
    }

    static func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

enum PlaybackEngineKind {
    case native
    case ffmpeg
}

/// 一次播放的上下文：地址、引擎、字幕，以及向服务器上报进度
@Observable
final class PlaybackSession: Identifiable {
    let id = UUID()
    let item: MediaItem
    let source: MediaSourceInfo?
    let url: URL
    let headers: [String: String]
    let engine: PlaybackEngineKind
    let externalSubtitles: [ExternalSubtitle]
    let startTime: TimeInterval
    let isTranscoding: Bool
    let isOffline: Bool
    let playSessionID: String

    @ObservationIgnored private weak var client: (any MediaServerClient)?
    /// 选集预取完成后通知播放器刷新上一集 / 下一集
    @ObservationIgnored var onLibraryUpdated: (() -> Void)?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false

    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// 预取的下一集
    var nextItem: MediaItem?
    /// 当前剧集的全部单集（用于选集与上一集）
    private(set) var episodes: [MediaItem] = []

    var previousItem: MediaItem? {
        guard let index = episodes.firstIndex(where: { $0.id == item.id }), index > 0 else { return nil }
        return episodes[index - 1]
    }

    init(item: MediaItem, source: MediaSourceInfo?, url: URL, headers: [String: String], engine: PlaybackEngineKind,
         externalSubtitles: [ExternalSubtitle], startTime: TimeInterval, isTranscoding: Bool, isOffline: Bool,
         playSessionID: String, client: (any MediaServerClient)?) {
        self.item = item
        self.source = source
        self.url = url
        self.headers = headers
        self.engine = engine
        self.externalSubtitles = externalSubtitles
        self.startTime = startTime
        self.isTranscoding = isTranscoding
        self.isOffline = isOffline
        self.playSessionID = playSessionID
        self.client = client
        position = startTime
    }

    var title: String { item.kind == .episode ? (item.seriesName ?? item.name) : item.name }

    var subtitle: String? {
        item.kind == .episode ? [item.episodeLabel, item.name].compactMap(\.self).joined(separator: " · ") : item.year.map(String.init)
    }

    var remaining: TimeInterval { max(0, duration - position) }

    private func report(paused: Bool) -> PlaybackReport {
        PlaybackReport(item: item, mediaSourceID: source?.id, playSessionID: playSessionID, position: position,
                       duration: duration, isPaused: paused, isTranscoding: isTranscoding)
    }

    func didStart() {
        guard !started else { return }
        started = true
        lastReport = .now
        let report = report(paused: false)
        Task { await client?.reportStart(report) }
        prefetchNext()
    }

    /// 播放过程中周期性调用；每 10 秒或暂停状态变化时上报一次
    func update(position: TimeInterval, duration: TimeInterval, paused: Bool, force: Bool = false) {
        guard position.isFinite, duration.isFinite else { return }
        self.position = position
        if duration > 0 { self.duration = duration }
        guard started, !stopped, force || Date.now.timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = .now
        let report = report(paused: paused)
        Task { await client?.reportProgress(report) }
    }

    func stop() {
        guard started, !stopped else { return }
        stopped = true
        let report = report(paused: true)
        Task { await client?.reportStop(report) }
    }

    private func prefetchNext() {
        guard item.kind == .episode, let seriesID = item.seriesID, let client else { return }
        Task {
            guard let all = try? await client.episodes(seriesID: seriesID) else { return }
            episodes = all
            if let index = all.firstIndex(where: { $0.id == item.id }), index + 1 < all.count {
                nextItem = all[index + 1]
            }
            onLibraryUpdated?()
        }
    }
}
