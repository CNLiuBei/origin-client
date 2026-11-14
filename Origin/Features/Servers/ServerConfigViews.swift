import SwiftUI

/// 与服务配置相同的地址栏：主机、路径、端口、https。
struct ServerAddressFields: View {
    @Binding var host: String
    @Binding var path: String
    @Binding var port: String
    @Binding var useHTTPS: Bool
    var onEdit: () -> Void = {}
    var onSubmitHost: () -> Void = {}
    /// 进入页面后把焦点放在主机栏，方便直接粘贴地址
    var focusOnAppear = false

    @FocusState private var hostFocused: Bool

    var body: some View {
        TextField("主机", text: $host, prompt: Text("必填"))
            .accessibilityIdentifier("server-host")
            .urlKeyboard()
            .textContentType(.URL)
            .plainTextEntry()
            .focused($hostFocused)
            .onSubmit {
                absorbPastedAddress()
                onSubmitHost()
            }
            .onChange(of: host) { onEdit() }
            .onChange(of: hostFocused) { _, focused in
                if !focused { absorbPastedAddress() }
            }
            .task {
                guard focusOnAppear else { return }
                try? await Task.sleep(for: .milliseconds(450))
                hostFocused = true
            }
        TextField("路径", text: $path, prompt: Text("可选"))
            .accessibilityIdentifier("server-path")
            .plainTextEntry()
            .onChange(of: path) { onEdit() }
        TextField("端口", text: $port, prompt: Text("可选"))
            .accessibilityIdentifier("server-port")
            .plainTextEntry()
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
            .onChange(of: port) { onEdit() }
        Toggle("https", isOn: $useHTTPS)
            .onChange(of: useHTTPS) { onEdit() }
    }

    private func absorbPastedAddress() {
        ServerAddress.absorb(host: &host, path: &path, port: &port, https: &useHTTPS)
        onEdit()
    }
}

/// 与服务配置相同的超时和证书开关。
struct ServerAdvancedSettings: View {
    @Binding var timeout: Double
    @Binding var allowsInsecureTLS: Bool

    var body: some View {
        Form {
            Stepper(value: $timeout, in: 5 ... 120, step: 5) {
                LabeledContent("超时", value: "\(Int(timeout)) 秒")
            }
            Toggle("允许自签名证书", isOn: $allowsInsecureTLS)
        }
        .formStyle(.grouped)
        .navigationTitle("高级设置")
        .inlineNavigationTitle()
    }
}

struct BackupLinesEditor: View {
    @Binding var lines: [ServerLine]
    @State private var draft: LineDraft?

    var body: some View {
        Form {
            Section {
                if lines.isEmpty {
                    Text("主线路无法连接时，会按这里的顺序尝试。")
                        .foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    Button {
                        draft = LineDraft(line)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.name.isEmpty ? "备用线路" : line.name)
                                .foregroundStyle(.primary)
                            Text(line.url.hostWithPort ?? line.url.absoluteString)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { lines.remove(atOffsets: $0) }
            }
            Button("添加线路", systemImage: "plus") {
                draft = LineDraft()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("备用线路")
        .inlineNavigationTitle()
        .sheet(item: $draft) { draft in
            LineEditor(draft: draft) { saved in
                if let index = lines.firstIndex(where: { $0.id == saved.id }) {
                    lines[index] = saved
                } else {
                    lines.append(saved)
                }
            }
        }
    }
}

private struct LineDraft: Identifiable {
    let id: UUID
    var name: String
    var host: String
    var path: String
    var port: String
    var https: Bool
    var isNew: Bool

    init() {
        id = UUID()
        name = ""
        host = ""
        path = ""
        port = ""
        https = false
        isNew = true
    }

    init(_ line: ServerLine) {
        id = line.id
        name = line.name
        let parts = ServerAddress.parts(of: line.url)
        host = parts.host
        path = parts.path
        port = parts.port
        https = parts.https
        isNew = false
    }
}

private struct LineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: LineDraft
    var onSave: (ServerLine) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $draft.name, prompt: Text("可选"))
                    .plainTextEntry()
                Section("服务器地址") {
                    ServerAddressFields(host: $draft.host, path: $draft.path, port: $draft.port, useHTTPS: $draft.https)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isNew ? "添加线路" : "编辑线路")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func save() {
        var editing = draft
        ServerAddress.absorb(host: &editing.host, path: &editing.path, port: &editing.port, https: &editing.https)
        guard let url = ServerAddress.compose(host: editing.host, path: editing.path, port: editing.port, https: editing.https) else { return }
        let name = editing.name.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(ServerLine(id: editing.id, name: name.isEmpty ? "备用线路" : name, url: url))
        dismiss()
    }
}

struct ServerSyncView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var sync = app.cloudSync
        Form {
            Toggle("同步服务器和播放设置", isOn: $sync.enabled)
            if sync.enabled {
                Section("已同步的设备") {
                    if sync.devices.isEmpty {
                        Text("开启后，这台设备和同一 iCloud 账号下的 iPhone、iPad、Mac 会显示在这里。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sync.devices) { device in
                        Label(device.name, systemImage: device.symbol)
                    }
                }
                Section {
                    LabeledContent("状态", value: sync.statusTitle)
                    LabeledContent("方式", value: sync.transportTitle)
                    if let lastSynced = sync.lastSynced {
                        LabeledContent("上次同步", value: lastSynced.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("立即同步") { sync.refreshNow() }
                } footer: {
                    Text(sync.footer)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("iCloud同步")
        .inlineNavigationTitle()
    }
}

struct SyncDeviceIcons: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.cloudSync
        HStack(spacing: 6) {
            ForEach(sync.deviceKinds, id: \.self) { kind in
                Image(systemName: SyncDevice(id: kind, name: "", kind: kind, seen: .now).symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ServerIconPicker: View {
    let accountID: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let symbols = [
        "server.rack", "externaldrive.fill", "externaldrive.connected.to.line.below",
        "play.rectangle.on.rectangle", "film", "tv", "play.tv.fill",
        "house.fill", "star.fill", "heart.fill", "bookmark.fill",
        "cloud.fill", "wifi", "network", "desktopcomputer",
        "laptopcomputer", "appletv.fill", "music.note", "photo.fill",
        "folder.fill", "person.2.fill", "bolt.fill"
    ]

    private var account: ServerAccount? { app.accounts.first { $0.id == accountID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16)], spacing: 16) {
                    if let account {
                        Button { choose(nil) } label: {
                            VStack(spacing: 6) {
                                ServerKindIcon(kind: account.kind, size: 48)
                                Text("默认").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(symbols, id: \.self) { symbol in
                        Button { choose(symbol) } label: {
                            TintedIcon(symbol: symbol, color: account?.kind.tint ?? .blue, size: 48)
                                .overlay {
                                    if account?.customSymbol == symbol {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(.primary, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("修改图标")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func choose(_ symbol: String?) {
        guard var account else { return }
        account.customSymbol = symbol
        app.update(account)
        dismiss()
    }
}
