import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmClear = false

    var body: some View {
        let downloads = app.downloads
        let completed = downloads.records.filter { $0.state == .completed }
        List {
            if !downloads.records.isEmpty {
                Section {
                    ForEach(downloads.records) { record in
                        DownloadRow(record: record)
                            .swipeActions {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    downloads.delete(record)
                                }
                            }
                    }
                } footer: {
                    Text("已占用 \(ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))。下载的文件也可以在“文件”App 的 Origin 文件夹中找到。")
                }
            }
        }
        .overlay {
            if downloads.records.isEmpty {
                ContentUnavailableView("没有下载内容", systemImage: "arrow.down.circle",
                                       description: Text("在影片详情页轻点下载按钮，即可离线观看。"))
            }
        }
        .navigationTitle("下载")
        .inlineNavigationTitle()
        .navigationSubtitle(downloads.records.isEmpty ? "" : "\(downloads.records.count) 项 · \(ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))")
        .toolbar {
            if !completed.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("清除已完成", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog("清除已完成的下载？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除 \(completed.count) 项", role: .destructive) { downloads.deleteCompleted() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些文件会从本机删除。")
        }
    }
}

private struct DownloadRow: View {
    @Environment(AppModel.self) private var app
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: record.item.kind == .episode ? record.item.thumbURL : record.item.posterURL,
                        aspectRatio: record.item.kind == .episode ? 16 / 9 : 2 / 3)
                .frame(width: record.item.kind == .episode ? 110 : 56)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.item.cardTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let subtitle = record.item.cardSubtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                status
            }
            Spacer()
            actionButton
        }
        .contentShape(.rect)
        .onTapGesture {
            if record.state == .completed { app.player.play(record.item) }
        }
        .contextMenu {
            NavigationLink(value: record.item) {
                Label("查看详情", systemImage: "info.circle")
            }
            if record.state == .completed {
                Button("播放", systemImage: "play.fill") { app.player.play(record.item) }
                #if os(macOS)
                Button("在访达中显示", systemImage: "folder") { reveal() }
                #endif
            }
            if record.state == .downloading || record.state == .queued {
                Button("暂停", systemImage: "pause") { app.downloads.pause(record) }
            }
            if record.state == .paused || record.state == .failed {
                Button("继续下载", systemImage: "arrow.clockwise") { app.downloads.resume(record) }
            }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) { app.downloads.delete(record) }
        }
    }

    #if os(macOS)
    private func reveal() {
        guard let url = app.downloads.localURL(for: record) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    @ViewBuilder
    private var status: some View {
        let size = ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file)
        switch record.state {
        case .completed:
            Text("已下载 · \(size)").font(.caption).foregroundStyle(.secondary)
        case .downloading, .queued:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: record.progress)
                Text("\(Int(record.progress * 100))% · \(size)").font(.caption2).foregroundStyle(.secondary)
            }
        case .paused:
            Text("已暂停 · \(Int(record.progress * 100))%").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text(record.errorText ?? "下载失败").font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch record.state {
        case .completed:
            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
        case .downloading, .queued:
            Button { app.downloads.pause(record) } label: { Image(systemName: "pause.circle").font(.title2) }
                .buttonStyle(.borderless)
        case .paused, .failed:
            Button { app.downloads.resume(record) } label: { Image(systemName: "arrow.clockwise.circle").font(.title2) }
                .buttonStyle(.borderless)
        }
    }
}
