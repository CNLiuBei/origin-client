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
    /// 离线播放时把进度写回本机下载记录，下次仍从这里续播
    @ObservationIgnored var onLocalProgress: ((TimeInterval, TimeInterval) -> Void)?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var skipper = SegmentSkipController()

    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// 服务器上的片头片尾标记
    private(set) var segments: [MediaSegment] = []
    /// 当前需要显示的跳过按钮。自动跳过时保持为空
    private(set) var skipPrompt: MediaSegment?
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
        loadSegments()
    }

    /// 根据当前进度决定显示跳过按钮，或直接跳过。返回本次自动跳过的标记。
    @discardableResult
    func considerSegments(at time: TimeInterval, intro: SegmentSkip, credits: SegmentSkip, seek: (TimeInterval) -> Void) -> MediaSegment? {
        guard time.isFinite else { return nil }
        switch skipper.evaluate(time: time, segments: segments, intro: intro, credits: credits) {
        case .none:
            if skipPrompt != nil { skipPrompt = nil }
            return nil
        case let .show(segment):
            if skipPrompt?.id != segment.id { skipPrompt = segment }
            return nil
        case let .skip(segment):
            if skipPrompt != nil { skipPrompt = nil }
            let target = Self.skipTarget(segment.end, duration: duration)
            skipper.noteSeek(to: target)
            seek(target)
            return segment
        }
    }

    /// 用户点了跳过按钮
    func skipPromptedSegment(seek: (TimeInterval) -> Void) -> MediaSegment? {
        guard let segment = skipPrompt else { return nil }
        skipper.consume(segment.id)
        skipPrompt = nil
        let target = Self.skipTarget(segment.end, duration: duration)
        skipper.noteSeek(to: target)
        seek(target)
        return segment
    }

    private static func skipTarget(_ end: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 1, end >= duration - 0.8 else { return end }
        return max(0, duration - 0.35)
    }

    private func loadSegments() {
        guard let client else { return }
        let item = item
        Task {
            let found = await client.segments(for: item)
            guard !stopped else { return }
            segments = found
        }
    }

    /// 播放过程中周期性调用；每 10 秒或暂停状态变化时上报一次
    func update(position: TimeInterval, duration: TimeInterval, paused: Bool, force: Bool = false) {
        guard position.isFinite, duration.isFinite else { return }
        self.position = position
        if duration > 0 { self.duration = duration }
        guard started, !stopped, force || Date.now.timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = .now
        if isOffline { onLocalProgress?(position, duration) }
        let report = report(paused: paused)
        Task { await client?.reportProgress(report) }
    }

    func stop() {
        guard started, !stopped else { return }
        stopped = true
        if isOffline { onLocalProgress?(position, duration) }
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

/// 同一段标记只自动跳过一次。用户手动拖进标记时改为显示按钮。
private struct SegmentSkipController {
    private var consumed = Set<String>()
    private var dismissed = Set<String>()
    private var left = Set<String>()
    private var lastTime: TimeInterval?
    private var suppressJumpUntil = Date.distantPast

    mutating func noteSeek(to time: TimeInterval) {
        lastTime = time
        suppressJumpUntil = .now.addingTimeInterval(1.5)
    }

    mutating func consume(_ id: String) {
        consumed.insert(id)
        dismissed.insert(id)
    }

    mutating func evaluate(time: TimeInterval, segments: [MediaSegment], intro: SegmentSkip, credits: SegmentSkip) -> Decision {
        // 自己发起的跳转完成前，播放器还会报一次旧进度
        if Date.now < suppressJumpUntil, let lastTime, abs(time - lastTime) > 2 {
            return decision(at: lastTime, jumped: false, segments: segments, intro: intro, credits: credits)
        }
        let jumped = Date.now < suppressJumpUntil ? false : (lastTime.map { abs(time - $0) > 8 } ?? false)
        lastTime = time
        return decision(at: time, jumped: jumped, segments: segments, intro: intro, credits: credits)
    }

    private mutating func decision(at time: TimeInterval, jumped: Bool, segments: [MediaSegment], intro: SegmentSkip, credits: SegmentSkip) -> Decision {
        guard let segment = segments.filter({ $0.contains(time) }).max(by: { $0.end < $1.end }) else {
            left.formUnion(consumed)
            return .none
        }
        let mode = segment.kind.isOpening ? intro : credits
        switch mode {
        case .off:
            return .none
        case .ask:
            return dismissed.contains(segment.id) ? .none : .show(segment)
        case .automatic:
            if consumed.contains(segment.id) {
                if left.contains(segment.id), !dismissed.contains(segment.id) { return .show(segment) }
                return .none
            }
            consumed.insert(segment.id)
            if jumped {
                left.insert(segment.id)
                return .show(segment)
            }
            return .skip(segment)
        }
    }

    enum Decision {
        case none
        case show(MediaSegment)
        case skip(MediaSegment)
    }
}
