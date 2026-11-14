import Foundation
import Observation

struct DownloadRecord: Identifiable, Codable, Hashable {
    enum State: String, Codable {
        case queued
        case downloading
        case paused
        case completed
        case failed
    }

    var id: String { item.id }
    var item: MediaItem
    var fileName: String
    var state: State
    var progress: Double = 0
    var totalBytes: Int64 = 0
    var errorText: String?
    var createdAt = Date()
}

/// 基于后台 URLSession 的离线下载。文件保存在“文稿/Downloads”，可在“文件”App 中看到。
@Observable
final class DownloadManager: NSObject {
    static let sessionIdentifier = "com.cn.Origin.downloads"

    private(set) var records: [DownloadRecord] = []
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    nonisolated static var directory: URL {
        let url = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var indexURL: URL {
        URL.applicationSupportDirectory.appending(path: "downloads.json")
    }

    override init() {
        super.init()
        load()
        Task {
            for case let task as URLSessionDownloadTask in await session.allTasks {
                guard let id = task.taskDescription else { continue }
                tasks[id] = task
                update(id) { $0.state = .downloading }
            }
        }
    }

    // MARK: - 查询

    func record(for id: String) -> DownloadRecord? {
        records.first { $0.id == id }
    }

    func completedRecord(for id: String) -> DownloadRecord? {
        guard let record = record(for: id), record.state == .completed, localURL(for: record) != nil else { return nil }
        return record
    }

    func localURL(for record: DownloadRecord) -> URL? {
        let url = Self.directory.appending(path: record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var totalSize: Int64 {
        records.filter { $0.state == .completed }.reduce(0) { $0 + $1.totalBytes }
    }

    // MARK: - 操作

    func download(_ item: MediaItem) {
        guard record(for: item.id) == nil,
              let source = item.mediaSources.first, let url = source.directURL else { return }
        let ext = (source.path.map { ($0 as NSString).pathExtension }).flatMap { $0.isEmpty ? nil : $0 }
            ?? source.container?.split(separator: ",").first.map(String.init) ?? "mp4"
        let safeName = item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ")
        let label = item.kind == .episode ? "\(item.seriesName ?? "") \(item.episodeLabel ?? "") \(safeName)" : safeName
        let fileName = "\(label.trimmingCharacters(in: .whitespaces)) [\(item.id.prefix(8))].\(ext)"
        records.insert(DownloadRecord(item: item, fileName: fileName, state: .downloading, totalBytes: source.size ?? 0), at: 0)
        start(id: item.id, url: url)
        save()
    }

    private func start(id: String, url: URL) {
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: MediaRequestAuth.request(for: url))
        }
        task.taskDescription = id
        tasks[id] = task
        task.resume()
    }

    func pause(_ record: DownloadRecord) {
        guard let task = tasks[record.id] else { return }
        update(record.id) { $0.state = .paused }
        Task {
            resumeData[record.id] = await task.cancelByProducingResumeData()
        }
    }

    func resume(_ record: DownloadRecord) {
        guard let url = record.item.mediaSources.first?.directURL else { return }
        update(record.id) {
            $0.state = .downloading
            $0.errorText = nil
        }
        start(id: record.id, url: url)
    }

    func delete(_ record: DownloadRecord) {
        tasks.removeValue(forKey: record.id)?.cancel()
        resumeData[record.id] = nil
        if let url = localURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        records.removeAll { $0.id == record.id }
        save()
    }

    /// 离线播放的进度写在下载记录上，下次打开仍从这里续播
    func notePlayback(id: String, position: TimeInterval, duration: TimeInterval) {
        guard position.isFinite, position >= 0 else { return }
        update(id) { record in
            if record.item.runtime == nil, duration > 0 { record.item.runtime = duration }
            record.item.userState.playbackPosition = position
            if duration > 0, position / duration >= 0.95 {
                record.item.userState.isPlayed = true
            }
        }
    }

    func deleteCompleted() {
        for record in records where record.state == .completed {
            if let url = localURL(for: record) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        records.removeAll { $0.state == .completed }
        save()
    }

    private func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        let downloading = records[index].state == .downloading
        if !downloading || Date().timeIntervalSince(lastProgressSave) >= 1 {
            lastProgressSave = Date()
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = saved.map { record in
            var record = record
            if record.state == .downloading || record.state == .queued { record.state = .paused }
            return record
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: Self.indexURL, options: .atomic)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // 系统会在回调返回后删除临时文件，必须同步移动
        let temp = Self.directory.appending(path: ".\(id).partial")
        try? FileManager.default.removeItem(at: temp)
        let moved = (try? FileManager.default.moveItem(at: location, to: temp)) != nil
        let bytes = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        MainActor.assumeIsolated {
            guard let record = record(for: id) else { return }
            let destination = Self.directory.appending(path: record.fileName)
            if moved, status < 400 {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: temp, to: destination)
                update(id) {
                    $0.state = .completed
                    $0.progress = 1
                    $0.totalBytes = bytes
                }
            } else {
                try? FileManager.default.removeItem(at: temp)
                update(id) {
                    $0.state = .failed
                    $0.errorText = "服务器返回 \(status)"
                }
            }
            tasks[id] = nil
        }
    }

    nonisolated func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            update(id) {
                $0.state = .downloading
                if totalBytesExpectedToWrite > 0 {
                    $0.totalBytes = totalBytesExpectedToWrite
                    $0.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                } else if $0.totalBytes > 0 {
                    $0.progress = Double(totalBytesWritten) / Double($0.totalBytes)
                }
            }
        }
    }

    nonisolated func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let nsError = error as NSError
        let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            if nsError.code == NSURLErrorCancelled, record(for: id)?.state == .paused { return }
            if let data { resumeData[id] = data }
            tasks[id] = nil
            update(id) {
                $0.state = nsError.code == NSURLErrorCancelled ? .paused : .failed
                $0.errorText = error.localizedDescription
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        MainActor.assumeIsolated {
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
