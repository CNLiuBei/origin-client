import SwiftUI

/// 与服务配置相同的地址栏：主机、路径、端口、协议。
struct ServerAddressFields: View {
    @Binding var host: String
    @Binding var path: String
    @Binding var port: String
    @Binding var scheme: ServerScheme
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
        Picker("协议", selection: $scheme) {
            ForEach(ServerScheme.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("server-scheme")
        .onChange(of: scheme) { onEdit() }
    }

    private func absorbPastedAddress() {
        ServerAddress.absorb(host: &host, path: &path, port: &port, scheme: &scheme)
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
    var scheme: ServerScheme
    var isNew: Bool

    init() {
        id = UUID()
        name = ""
        host = ""
        path = ""
        port = ""
        scheme = .automatic
        isNew = true
    }

    init(_ line: ServerLine) {
        id = line.id
        name = line.name
        let parts = ServerAddress.parts(of: line.url)
        host = parts.host
        path = parts.path
        port = parts.port
        scheme = parts.scheme
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
                    ServerAddressFields(host: $draft.host, path: $draft.path, port: $draft.port, scheme: $draft.scheme)
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
        ServerAddress.absorb(host: &editing.host, path: &editing.path, port: &editing.port, scheme: &editing.scheme)
        guard let url = ServerAddress.compose(host: editing.host, path: editing.path, port: editing.port, scheme: editing.scheme) else { return }
        let name = editing.name.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(ServerLine(id: editing.id, name: name.isEmpty ? "备用线路" : name, url: url))
        dismiss()
    }
}

struct ServerSyncView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var sync = app.cloudSync
        let lan = app.lanSync
        Form {
            Section {
                Toggle("局域网实时同步", isOn: Binding(get: { lan.enabled }, set: { lan.enabled = $0 }))
                if lan.enabled, lan.isPaired {
                    ForEach(lan.peers) { peer in
                        LabeledContent {
                            Text(peer.isConnected ? "已连接" : "连接中")
                        } label: {
                            Label(peer.name, systemImage: peer.symbol)
                        }
                    }
                    if lan.peers.isEmpty {
                        Text("已配对的设备在同一网络里打开 Origin 后会显示在这里。")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("局域网")
            } footer: {
                Text(lanFooter(lan))
            }
            if lan.enabled {
                Section {
                    pairingStatus(lan)
                    ForEach(lan.nearby) { peer in
                        Button {
                            lan.requestPairing(with: peer)
                        } label: {
                            Label(peer.name, systemImage: peer.symbol)
                        }
                        .disabled(isWaiting(lan))
                    }
                    if lan.nearby.isEmpty {
                        LabeledContent("正在查找") {
                            ProgressView()
                        }
                    }
                } header: {
                    Text("附近的设备")
                } footer: {
                    Text("在另一台设备上打开 Origin，它会出现在这里。点一下发起配对，再在那台设备上核对数字并允许。")
                }
                if lan.isPaired {
                    Section {
                        Button("退出配对", role: .destructive) { lan.leaveGroup() }
                    }
                }
            }

            Section {
                Toggle("iCloud 同步", isOn: $sync.enabled)
            } header: {
                Text("iCloud")
            }
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
        .navigationTitle("同步")
        .inlineNavigationTitle()
        .onDisappear { lan.dismissPairingResult() }
    }

    @ViewBuilder
    private func pairingStatus(_ lan: LANSync) -> some View {
        switch lan.pairing {
        case .idle:
            EmptyView()
        case let .waiting(name, code):
            if let code {
                LabeledContent("核对数字") {
                    Text("\(code.prefix(3)) \(code.dropFirst(3))")
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text("请在“\(name)”上确认显示的是同一组数字，然后点“允许”。")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("正在连接“\(name)”") {
                    ProgressView()
                }
            }
            Button("取消配对") { lan.cancelPairing() }
        case let .paired(name):
            Label("已和“\(name)”配对", systemImage: "checkmark.circle.fill")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func isWaiting(_ lan: LANSync) -> Bool {
        if case .waiting = lan.pairing { return true }
        return false
    }

    private func lanFooter(_ lan: LANSync) -> String {
        if lan.isBlocked {
            #if os(iOS)
            return "Origin 没有本地网络权限。请在“设置 > 隐私与安全性 > 本地网络”中打开 Origin。"
            #else
            return "系统暂时不允许 Origin 在局域网里查找设备。请在“系统设置 > 隐私与安全性 > 本地网络”中打开 Origin；已经打开的话，重启 Mac 后再试。"
            #endif
        }
        return "同一网络下的 iPhone、iPad、Mac 之间直接同步服务器、登录状态和播放设置，改动马上生效，不经过 iCloud。每台设备第一次需要配对，两台设备都要打开这个开关。观看进度由媒体服务器保存。"
    }
}

/// 另一台设备请求配对时弹出确认框，在应用任何页面都能看到
private struct LANPairRequestAlert: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let lan = app.lanSync
        content.alert(
            "配对请求",
            isPresented: Binding(get: { lan.request != nil }, set: { _ in }),
            presenting: lan.request
        ) { _ in
            Button("拒绝", role: .cancel) { lan.respond(allow: false) }
            Button("允许") { lan.respond(allow: true) }
        } message: { request in
            Text("“\(request.name)”想和这台设备同步服务器、登录状态和播放设置。\n请确认两台设备上显示的数字相同：\(request.code.prefix(3)) \(request.code.dropFirst(3))")
        }
    }
}

extension View {
    func lanPairRequestAlert() -> some View {
        modifier(LANPairRequestAlert())
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
