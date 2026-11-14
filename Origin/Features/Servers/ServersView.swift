import SwiftUI

// MARK: - 连接状态

nonisolated enum ServerStatus: Equatable, Sendable {
    case checking
    /// latency 为毫秒
    case online(latency: Int, version: String?)
    /// 服务器在线，但保存的登录令牌已失效
    case expired
    case offline(String)
}

enum ServerHealth {
    static func client(for account: ServerAccount) -> any MediaServerClient {
        account.kind == .plex ? PlexClient(account: account) : JellyfinClient(account: account)
    }

    /// Jellyfin / Emby / 飞牛影视先用公开接口测在线和延迟，再用媒体库接口验证令牌；Plex 直接取媒体库
    static func check(_ account: ServerAccount) async -> ServerStatus {
        let clock = ContinuousClock()
        var version: String?
        var latency: Duration?
        if account.kind != .plex {
            let start = clock.now
            do {
                version = try await JellyfinClient.probe(baseURL: account.connectionURL, timeout: min(6, account.advanced.timeout),
                                                         allowsInsecureTLS: account.advanced.allowsInsecureTLS).1.version
                latency = clock.now - start
            } catch {
                return .offline(friendlyMessage(for: error))
            }
        }
        let start = clock.now
        do {
            _ = try await client(for: account).libraries()
        } catch APIError.unauthorized {
            return .expired
        } catch {
            return .offline(friendlyMessage(for: error))
        }
        let elapsed = latency ?? (clock.now - start)
        return .online(latency: Int(elapsed / .milliseconds(1)), version: version)
    }

    /// 当前线路失败时改试主线路和备用线路。登录失效说明地址是通的，不再换线路。
    static func resolve(_ account: ServerAccount) async -> (ServerStatus, UUID?) {
        var seen = Set<String>()
        var lastOffline: ServerStatus = .offline("无法连接")
        for candidate in account.lineCandidates {
            var trial = account
            trial.activeLineID = candidate.id
            let key = trial.connectionURL.absoluteString
            guard seen.insert(key).inserted else { continue }
            let status = await check(trial)
            switch status {
            case .online, .expired:
                return (status, candidate.id)
            case .offline:
                lastOffline = status
            case .checking:
                break
            }
        }
        return (lastOffline, account.activeLineID)
    }
}

private struct ServerStatusLabel: View {
    let status: ServerStatus?

    var body: some View {
        switch status {
        case nil, .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("检测中…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .online(latency, _):
            labeled("在线 · \(latency) ms", systemImage: "circle.fill", tint: .green)
        case .expired:
            labeled("登录已失效", systemImage: "exclamationmark.circle.fill", tint: .orange)
        case .offline:
            labeled("无法连接", systemImage: "xmark.circle.fill", tint: .red)
        }
    }

    private func labeled(_ title: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption)
        .labelStyle(StatusLabelStyle(tint: tint))
    }
}

/// 只给状态符号上色，文字保持次要色，避免整行都变成绿字或红字
private struct StatusLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small).foregroundStyle(tint)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

// MARK: - 服务器列表

struct ServersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAdd = false
    @State private var statuses: [UUID: ServerStatus] = [:]
    @State private var editing: UUID?
    @State private var focusPassword = false
    @State private var iconEditing: UUID?
    @State private var pendingDelete: ServerAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if app.accounts.isEmpty {
                    ContentUnavailableView("还没有服务器", systemImage: "server.rack", description: Text("添加一台 Jellyfin、Emby、Plex 或飞牛影视"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    #if os(iOS)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(app.accounts) { account in
                            card(account)
                        }
                    }
                    #else
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(app.accounts) { account in
                            card(account)
                        }
                    }
                    #endif
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hideSystemScrollbars()
        }
        .scrollIndicators(.hidden)
        .navigationTitle("服务器")
        .inlineNavigationTitle()
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .primaryAction) {
                refreshButton.labelStyle(.iconOnly)
                addButton.labelStyle(.iconOnly)
            }
            #else
            ToolbarItem(placement: .primaryAction) { refreshButton }
            ToolbarItem(placement: .primaryAction) { addButton }
            #endif
        }
        .sheet(isPresented: $showAdd) { AddServerView() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), onDismiss: { focusPassword = false }) {
            if let editing {
                ServerDetailView(accountID: editing, focusPassword: focusPassword)
            }
        }
        .sheet(isPresented: Binding(get: { iconEditing != nil }, set: { if !$0 { iconEditing = nil } })) {
            if let iconEditing {
                ServerIconPicker(accountID: iconEditing)
            }
        }
        .confirmationDialog("删除服务器？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { account in
            Button("删除“\(account.name)”", role: .destructive) { app.remove(account) }
        } message: { _ in
            Text("将移除该服务器及其登录信息，之后需要重新添加。")
        }
        .task(id: app.accounts) { await refreshStatuses() }
        .refreshable { await refreshStatuses(force: true) }
    }

    private var horizontalPadding: CGFloat {
        #if os(iOS)
        16
        #else
        20
        #endif
    }

    private var refreshButton: some View {
        Button("重新检测", systemImage: "arrow.clockwise") {
            Task { await refreshStatuses(force: true) }
        }
        .disabled(statuses.values.contains(.checking))
    }

    private var addButton: some View {
        Button("添加", systemImage: "plus") { showAdd = true }
    }

    /// 左上名称、右上类型图标，底部左右各一行说明。iPhone 上一行两张，并用菜单露出操作。
    private func card(_ account: ServerAccount) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(account.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                ZStack(alignment: .bottomTrailing) {
                    ServerAccountIcon(account: account, size: iconSize)
                    if account.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.black.opacity(0.55), in: .circle)
                            .offset(x: 4, y: 4)
                    }
                }
            }
            Spacer(minLength: cardSpacer)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.note.isEmpty ? account.activeLineName : account.note)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(app.isLocked(account) ? "已加密" : statusCaption(statuses[account.id]))
                    .lineLimit(1)
                #if os(iOS)
                Color.clear.frame(width: 28, height: 1)
                #endif
            }
            .font(bottomFont)
            .foregroundStyle(.secondary)
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
        }
        .contentShape(.rect)
        .onTapGesture { openEditor(account, password: false) }
        .accessibilityLabel("\(account.name)，\(account.activeLineName)，\(app.isLocked(account) ? "已加密" : statusCaption(statuses[account.id]))")
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            Menu {
                serverActions(for: account)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(account.name)的操作")
            .padding(.trailing, 4)
            .padding(.bottom, 2)
            #endif
        }
        .contextMenu { serverActions(for: account) }
    }

    private var cardSpacer: CGFloat {
        #if os(iOS)
        16
        #else
        28
        #endif
    }

    private var cardHeight: CGFloat {
        #if os(iOS)
        112
        #else
        118
        #endif
    }

    private var cardPadding: CGFloat {
        #if os(iOS)
        12
        #else
        16
        #endif
    }

    private var iconSize: CGFloat {
        #if os(iOS)
        36
        #else
        44
        #endif
    }

    private var bottomFont: Font {
        #if os(iOS)
        .caption
        #else
        .subheadline
        #endif
    }

    @ViewBuilder
    private func serverActions(for account: ServerAccount) -> some View {
        Button("服务配置", systemImage: "slider.horizontal.3") { openEditor(account, password: false) }
        Button(account.aggregationDisabled ? "启用聚合" : "禁用聚合",
               systemImage: account.aggregationDisabled ? "square.stack.3d.up" : "square.stack.3d.up.slash") {
            var updated = account
            updated.aggregationDisabled.toggle()
            app.update(updated)
        }
        Button("设为默认首页", systemImage: "house") {
            Task { await app.setDefaultHome(account) }
        }
        .disabled(app.defaultHomeID == account.id)
        Button("修改密码", systemImage: "key") { openEditor(account, password: true) }
        Button("修改图标", systemImage: "photo") {
            Task {
                guard await app.unlock(account) else { return }
                iconEditing = account.id
            }
        }
        Button(account.isEncrypted ? "取消加密" : "加密", systemImage: account.isEncrypted ? "lock.open" : "lock") {
            toggleEncryption(account)
        }
        moveButtons(for: account)
        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = account }
    }

    private func openEditor(_ account: ServerAccount, password: Bool) {
        Task {
            guard await app.unlock(account) else { return }
            focusPassword = password
            editing = account.id
        }
    }

    private func toggleEncryption(_ account: ServerAccount) {
        Task {
            let reason = account.isEncrypted ? "取消“\(account.name)”的加密" : "加密服务器“\(account.name)”"
            guard await ServerLock.authenticate(reason: reason) else { return }
            app.setEncrypted(account, !account.isEncrypted)
        }
    }

    @ViewBuilder
    private func moveButtons(for account: ServerAccount) -> some View {
        if let index = app.accounts.firstIndex(where: { $0.id == account.id }), app.accounts.count > 1 {
            if index > 0 {
                Button("上移", systemImage: "arrow.up") {
                    app.moveAccounts(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                }
            }
            if index < app.accounts.count - 1 {
                Button("下移", systemImage: "arrow.down") {
                    app.moveAccounts(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                }
            }
        }
    }

    private func statusCaption(_ status: ServerStatus?) -> String {
        switch status {
        case nil, .checking: "检测中"
        case .online: "在线"
        case .expired: "登录已失效"
        case .offline: "无法连接"
        }
    }

    /// 左灰、右浅蓝，和参考卡片同一方向；深色外观用同一走向的暗色
    private var cardFill: LinearGradient {
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 0.17, green: 0.18, blue: 0.19), Color(red: 0.15, green: 0.22, blue: 0.28)]
            : [Color(red: 0.90, green: 0.91, blue: 0.914), Color(red: 0.776, green: 0.867, blue: 0.918)]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private func refreshStatuses(force: Bool = false) async {
        let accounts = app.accounts.filter { !app.isLocked($0) }
        for account in app.accounts where app.isLocked(account) {
            statuses[account.id] = nil
        }
        for account in accounts where force || statuses[account.id] == nil {
            statuses[account.id] = .checking
        }
        var switches: [(UUID, UUID?)] = []
        await withTaskGroup(of: (UUID, ServerStatus, UUID?).self) { group in
            for account in accounts {
                group.addTask { 
                    let (status, line) = await ServerHealth.resolve(account)
                    return (account.id, status, line)
                }
            }
            for await (id, status, line) in group {
                statuses[id] = status
                if case .online = status { switches.append((id, line)) }
            }
        }
        for (id, line) in switches {
            app.applyResolvedLine(id, lineID: line)
        }
    }
}

// MARK: - 服务器详情

/// 服务配置：名称、拆开的地址和登录信息，取消或保存后关闭
struct ServerDetailView: View {
    let accountID: UUID
    var focusPassword = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var note = ""
    @State private var host = ""
    @State private var path = ""
    @State private var port = ""
    @State private var useHTTPS = false
    @State private var username = ""
    @State private var password = ""
    @State private var plexToken = ""
    @State private var backupLines: [ServerLine] = []
    @State private var timeout = 20.0
    @State private var allowsInsecureTLS = false

    @State private var isWorking = false
    @State private var errorText: String?
    @State private var canForce = false
    @State private var didLoad = false
    @State private var passwordFocused = false

    private var account: ServerAccount? { app.accounts.first { $0.id == accountID } }

    var body: some View {
        NavigationStack {
            Group {
                if let account {
                    form(account)
                } else {
                    ContentUnavailableView("服务器已删除", systemImage: "server.rack")
                }
            }
            .navigationTitle(account?.kind.displayName ?? "服务器")
            .inlineNavigationTitle()
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 520)
        #endif
    }

    private func form(_ account: ServerAccount) -> some View {
        Form {
            Section {
                TextField("名称", text: $name, prompt: Text("可选"))
                    .plainTextEntry()
                TextField("备注", text: $note, prompt: Text("可选"))
                    .plainTextEntry()
            }

            Section("服务器地址") {
                ServerAddressFields(host: $host, path: $path, port: $port, useHTTPS: $useHTTPS, onEdit: clearError)
            }

            Section("登录信息") {
                TextField("用户", text: $username, prompt: Text("可选"))
                    .textContentType(.username)
                    .plainTextEntry()
                if account.kind == .plex {
                    PasswordField(title: "Token", text: $plexToken, prompt: "可选", canReveal: true,
                                  isFocused: $passwordFocused) { commit(force: false) }
                } else {
                    PasswordField(title: "密码", text: $password, identifier: "relogin-password",
                                  prompt: "可选", canReveal: true, isFocused: $passwordFocused) { commit(force: false) }
                }
            }

            Section {
                NavigationLink {
                    BackupLinesEditor(lines: $backupLines)
                } label: {
                    LabeledContent("备用线路", value: "\(backupLines.count)")
                }
                NavigationLink {
                    ServerAdvancedSettings(timeout: $timeout, allowsInsecureTLS: $allowsInsecureTLS)
                } label: {
                    Text("高级设置")
                }
            }

            Section {
                NavigationLink {
                    ServerSyncView()
                } label: {
                    HStack {
                        Text("iCloud同步")
                        Spacer()
                        SyncDeviceIcons()
                    }
                }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    if canForce {
                        Button("仍然保存") { commit(force: true) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isWorking)
        .animation(.snappy, value: errorText)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { commit(force: false) }
                    .disabled(isWorking || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        #else
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { commit(force: false) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        #endif
        .task {
            guard !didLoad else { return }
            didLoad = true
            load(account)
            if focusPassword { passwordFocused = true }
        }
    }

    private func clearError() {
        errorText = nil
        canForce = false
    }

    private func load(_ account: ServerAccount) {
        let parts = ServerAddress.parts(of: account.baseURL)
        name = account.name
        note = account.note
        host = parts.host
        path = parts.path
        port = parts.port
        useHTTPS = parts.https
        username = account.username
        backupLines = account.backupLines
        timeout = account.advanced.timeout
        allowsInsecureTLS = account.advanced.allowsInsecureTLS
    }

    private func composedURL() -> URL? {
        ServerAddress.compose(host: host, path: path, port: port, https: useHTTPS)
    }

    private func commit(force: Bool) {
        guard let account, !isWorking else { return }
        ServerAddress.absorb(host: &host, path: &path, port: &port, https: &useHTTPS)
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !portText.isEmpty, Int(portText).map({ (1 ... 65535).contains($0) }) != true {
            errorText = "端口应为 1 到 65535 的数字"
            canForce = false
            return
        }
        guard let url = composedURL() else {
            errorText = host.contains("/") ? "路径请写在下面的路径一栏" : "请填写主机"
            canForce = false
            return
        }
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? account.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalUser = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? account.username : username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (account.kind == .plex ? plexToken : password).trimmingCharacters(in: .whitespacesAndNewlines)
        let userChanged = finalUser != account.username
        if account.kind != .plex, userChanged, secret.isEmpty, !force {
            errorText = "更换用户需要填写密码"
            canForce = false
            return
        }
        let addressChanged = !ServerAddress.same(url, as: account.baseURL)
        let metadataChanged = finalName != account.name || finalNote != account.note || backupLines != account.backupLines
            || timeout != account.advanced.timeout || allowsInsecureTLS != account.advanced.allowsInsecureTLS
        if !addressChanged, !userChanged, secret.isEmpty, !metadataChanged {
            dismiss()
            return
        }

        isWorking = true
        errorText = nil
        canForce = false
        let shouldConnect = !force && (addressChanged || !secret.isEmpty || userChanged)
        Task {
            defer { isWorking = false }
            let targets = shouldConnect ? await ServerEndpoint.candidates(for: url, alternatePorts: []) : [url]
            var lastError: Error?
            for target in targets {
                var updated = account
                updated.name = finalName
                updated.note = finalNote
                updated.baseURL = target
                updated.backupLines = backupLines
                if updated.activeLineID != nil, !backupLines.contains(where: { $0.id == updated.activeLineID }) {
                    updated.activeLineID = nil
                }
                updated.advanced = ServerAdvanced(timeout: timeout, allowsInsecureTLS: allowsInsecureTLS)
                var newToken: String?
                do {
                    if shouldConnect {
                        if account.kind == .plex {
                            if addressChanged || !secret.isEmpty {
                                try await validatePlex(url: target, token: secret.isEmpty ? account.token ?? "" : secret)
                                if !secret.isEmpty { newToken = secret }
                            }
                        } else if !secret.isEmpty || userChanged {
                            let result = try await JellyfinClient.authenticate(baseURL: target, kind: account.kind, username: finalUser, password: secret,
                                                                               allowsInsecureTLS: allowsInsecureTLS, timeout: timeout)
                            updated.userID = result.userID
                            updated.username = result.username
                            newToken = result.token
                        } else if addressChanged {
                            let kind = try await JellyfinClient.probe(baseURL: target, timeout: timeout, allowsInsecureTLS: allowsInsecureTLS).0
                            guard kind == account.kind else {
                                errorText = "该地址是\(kind.displayName)服务器，与原来的\(account.kind.displayName)不一致，请添加为新服务器。"
                                return
                            }
                            _ = try await ServerHealth.client(for: updated).libraries()
                        }
                    }
                    if newToken == nil { updated.username = finalUser }
                    app.update(updated, token: newToken)
                    dismiss()
                    return
                } catch let error where ServerEndpoint.isUnreachable(error) {
                    lastError = error
                } catch APIError.unauthorized {
                    if !secret.isEmpty || userChanged {
                        errorText = account.kind == .plex ? "Token 无效或无权访问这台服务器" : "用户名或密码不正确"
                    } else {
                        errorText = "能连上该地址，但当前登录在这台服务器上无效，可能不是同一台服务器。"
                        canForce = true
                    }
                    return
                } catch {
                    errorText = friendlyMessage(for: error)
                    canForce = addressChanged && secret.isEmpty
                    return
                }
            }
            if let lastError {
                errorText = friendlyMessage(for: lastError)
                canForce = addressChanged && secret.isEmpty
            }
        }
    }

    private func validatePlex(url: URL, token: String) async throws {
        var headers = PlexClient.clientHeaders
        headers["X-Plex-Token"] = token
        _ = try await HTTPClient(timeout: timeout, allowsInsecureTLS: allowsInsecureTLS)
            .data(url.appending(path: "/library/sections", query: [:]), headers: headers)
    }
}
