import AVFoundation
import Foundation
import VideoToolbox

/// 判断一个媒体源能否直接交给 AVPlayer（系统播放器）播放
enum PlaybackCompatibility {
    private static let containers: Set<String> = ["mp4", "m4v", "mov", "m3u8", "hls", "3gp", "mp3", "m4a"]
    private static let audioCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac", "flac", "pcm_s16le", "pcm_s24le", "opus"]

    private static var videoCodecs: Set<String> {
        var codecs: Set<String> = ["h264", "avc", "avc1", "hevc", "h265", "hvc1", "hev1", "mpeg4"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { codecs.insert("av1") }
        return codecs
    }

    static func canPlayNatively(_ source: MediaSourceInfo) -> Bool {
        guard let container = source.container?.lowercased() else { return false }
        let containerOK = container.split(separator: ",").contains { containers.contains(String($0)) }
        guard containerOK else { return false }
        if let video = source.videoStream, let codec = video.codec?.lowercased(), !videoCodecs.contains(codec) {
            return false
        }
        // 只要默认音轨可播即可，其余音轨系统会自动跳过
        let audio = source.audioStreams.first { $0.isDefault } ?? source.audioStreams.first
        if let codec = audio?.codec?.lowercased(), !audioCodecs.contains(codec) {
            return false
        }
        return true
    }

    /// 内嵌的图形字幕（PGS 等）系统播放器无法显示
    static func hasUnsupportedSubtitles(_ source: MediaSourceInfo) -> Bool {
        source.subtitleStreams.contains { !$0.isExternal && !["mov_text", "tx3g", "webvtt", "eia_608", "eia_708"].contains($0.codec?.lowercased() ?? "") }
    }
}
