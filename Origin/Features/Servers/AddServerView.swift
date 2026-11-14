import AuthenticationServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WelcomeView: View {
    @State private var showAdd = false
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize = 76

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            AppMark(size: heroIconSize, pulses: true)
            VStack(spacing: 10) {
                Text("欢迎使用 Origin")
                    .font(.largeTitle.bold())
                Text("连接你的 Emby、Jellyfin、Plex 或飞牛影视，\n在 iPhone、iPad 和 Mac 上欣赏整个影音库。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAdd = true
            } label: {
                Text("添加媒体服务器")
                    .font(.headline)
                    .frame(maxWidth: 360)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showAdd) {
            AddServerView()
        }
    }
}

// MARK: - 添加服务器：选择来源

/// 第一级只做选择：局域网里发现的服务器（地址已知，只需登录），或手动添加
struct AddServerView: View {
    private enum Route: Hashable {
        case discovered(DiscoveredServer)
        case manual(ServerKind)
        case plex
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            List {
                nearbySection
                Section("手动添加") {
                    ForEach([ServerKind.jellyfin, .emby, .fnos]) { kind in
                        NavigationLink(value: Route.manual(kind)) {
                            SourceRow(icon: ServerKindIcon(kind: kind), title: kind.displayName,
                                      subtitle: "输入地址和账号，端口 \(kind.defaultPort)")
                        }
                        .accessibilityIdentifier("manual-\(kind.rawValue)")
                    }
                    NavigationLink(value: Route.plex) {
                        SourceRow(icon: ServerKindIcon(kind: .plex), title: "Plex", subtitle: "使用 Plex 账号登录，或填写地址与 Token")
                    }
                    .accessibilityIdentifier("manual-plex")
                }
            }
            .navigationTitle("添加服务器")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .discovered(server) where server.kind == .plex:
                    PlexLoginView(discovered: server) { dismiss() }
                case let .discovered(server):
                    AccountLoginView(discovered: server, expected: server.kind) { dismiss() }
                case let .manual(kind):
                    AccountLoginView(discovered: nil, expected: kind) { dismiss() }
                case .plex:
                    PlexLoginView(discovered: nil) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 620)
        #endif
        .task { app.browser.start() }
    }

    private var nearbySection: some View {
        Section {
            ForEach(app.browser.servers) { server in
                NavigationLink(value: Route.discovered(server)) {
                    SourceRow(icon: ServerKindIcon(kind: server.kind), title: server.name,
                              subtitle: server.address.isEmpty
                                  ? "\(server.kind.displayName) · 正在获取地址…"
                                  : "\(server.kind.displayName) · \(server.address)")
                }
                .disabled(server.address.isEmpty)
            }
            if app.browser.servers.isEmpty {
                if app.browser.isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索局域网…").foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("没有发现服务器").foregroundStyle(.secondary)
                        Spacer()
                        Button("重新搜索") { app.browser.restart() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("附近的服务器")
        } footer: {
            Text("可自动发现局域网中的 Jellyfin、Emby、飞牛影视与 Plex，选择后只需登录账号。")
        }
    }
}

// MARK: - Jellyfin / Emby / 飞牛影视登录

private struct AccountLoginView: View {
    private enum Field: Hashable {
        case username, password
    }

    /// 为 nil 时为手动添加，需要填写地址
    let discovered: DiscoveredServer?
    /// 用户选择的服务器类型。手动添加时只连接这一类，不再把三种服务当成同一个入口。
    let expected: ServerKind
    let close: () -> Void

    init(discovered: DiscoveredServer?, expected: ServerKind, close: @escaping () -> Void) {
        self.discovered = discovered
        self.expected = expected
        self.close = close
        if discovered == nil {
            _port = State(initialValue: String(expected.defaultPort))
        }
    }

    @Environment(AppModel.self) private var app
    @FocusState private var focus: Field?

    @State private var name = ""
    @State private var note = ""
    @State private var host = ""
    @State private var path = ""
    @State private var port = ""
    @State private var useHTTPS = false
    @State private var username = ""
    @State private var password = ""
    @State private var backupLines: [ServerLine] = []
    @State private var timeout = 20.0
    @State private var allowsInsecureTLS = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        Form {
            if let discovered {
                ServerHeader(kind: discovered.kind, name: discovered.name, detail: discovered.address)
            } else {
                Section {
                    TextField("名称", text: $name, prompt: Text("可选"))
                        .plainTextEntry()
                    TextField("备注", text: $note, prompt: Text("可选"))
                        .plainTextEntry()
                }
                Section("服务器地址") {
                    ServerAddressFields(host: $host, path: $path, port: $port, useHTTPS: $useHTTPS, onEdit: clearError, onSubmitHost: { focus = .username }, focusOnAppear: true)
                }
            }

            loginSection

            if discovered == nil {
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
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if discovered != nil {
                Section {
                    ConnectButton(isWorking: isWorking, action: connect)
                        .disabled(!canConnect)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .formStyle(.grouped)
        .navigationTitle(discovered == nil ? expected.displayName : "登录")
        .inlineNavigationTitle()
        .disabled(isWorking)
        .animation(.snappy, value: errorText)
        .task {
            guard discovered != nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            focus = .username
        }
        #if os(iOS)
        .toolbar {
            if discovered == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") { connect() }
                        .disabled(!canConnect)
                }
            }
        }
        #else
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if discovered == nil {
                HStack {
                    Spacer()
                    Button("连接") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canConnect)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        #endif
    }

    private var loginSection: some View {
        Section("登录信息") {
            TextField("用户", text: $username, prompt: Text(discovered == nil ? "必填" : "用户名"))
                .accessibilityIdentifier("username")
                .textContentType(.username)
                .plainTextEntry()
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = .password }
            PasswordField(title: "密码", text: $password, identifier: "password",
                          prompt: discovered == nil ? "可选" : nil, canReveal: true,
                          isFocused: Binding(get: { focus == .password },
                                             set: { focus = $0 ? .password : (focus == .password ? nil : focus) })) {
                if canConnect { connect() }
            }
            .focused($focus, equals: .password)
            .submitLabel(.go)
        }
    }

    private var canConnect: Bool {
        if isWorking { return false }
        if discovered != nil { return !username.isEmpty }
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !username.isEmpty
    }

    private func clearError() {
        errorText = nil
    }

    private func connect() {
        focus = nil
        let typed: URL
        if let discovered {
            guard let url = URL(string: "http://\(discovered.address)") else {
                errorText = APIError.invalidURL.localizedDescription
                return
            }
            typed = url
        } else {
            ServerAddress.absorb(host: &host, path: &path, port: &port, https: &useHTTPS)
            let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
            if !portText.isEmpty, Int(portText).map({ (1 ... 65535).contains($0) }) != true {
                errorText = "端口应为 1 到 65535 的数字"
                return
            }
            guard let url = ServerAddress.compose(host: host, path: path, port: port, https: useHTTPS) else {
                errorText = host.contains("/") ? "路径请写在下面的路径一栏" : "请填写主机"
                return
            }
            typed = url
        }
        isWorking = true
        errorText = nil
        let alternates = port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !useHTTPS ? [expected.defaultPort] : []
        let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isWorking = false }
            do {
                let url: URL
                let kind: ServerKind
                if let discovered {
                    url = typed
                    kind = discovered.kind
                } else {
                    url = try await locate(typed, alternates: alternates)
                    kind = expected
                }
                let result = try await JellyfinClient.authenticate(
                    baseURL: url, kind: kind, username: username, password: password,
                    allowsInsecureTLS: allowsInsecureTLS, timeout: timeout
                )
                if let existing = app.accounts.first(where: { $0.baseURL == url && $0.userID == result.userID }) {
                    app.add(existing, token: result.token)
                    close()
                    return
                }
                let account = ServerAccount(
                    id: UUID(), kind: kind, name: enteredName.isEmpty ? result.serverName : enteredName, baseURL: url,
                    userID: result.userID, username: result.username, note: enteredNote, backupLines: backupLines,
                    advanced: ServerAdvanced(timeout: timeout, allowsInsecureTLS: allowsInsecureTLS)
                )
                app.add(account, token: result.token)
                close()
            } catch {
                errorText = friendlyMessage(for: error)
            }
        }
    }

    /// 只接受用户选中的那一种服务器。地址属于另一种时，提示改走对应入口。
    private func locate(_ url: URL, alternates: [Int]) async throws -> URL {
        let targets = await ServerEndpoint.candidates(for: url, alternatePorts: alternates)
        let timeout = max(timeout, 4)
        for candidate in targets {
            if let (kind, _) = try? await JellyfinClient.probe(baseURL: candidate, timeout: timeout, allowsInsecureTLS: allowsInsecureTLS) {
                guard kind == expected else {
                    throw APIError.message("这是\(kind.displayName)，请从\(kind.displayName)入口添加")
                }
                return candidate
            }
        }
        throw APIError.message("没有连上\(expected.displayName)，请检查地址和端口")
    }
}

// MARK: - Plex 登录

private struct PlexLoginView: View {
    let discovered: DiscoveredServer?
    let close: () -> Void

    init(discovered: DiscoveredServer?, close: @escaping () -> Void) {
        self.discovered = discovered
        self.close = close
        if discovered == nil {
            _port = State(initialValue: String(ServerKind.plex.defaultPort))
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var plexToken: String?
    @State private var plexUsername = ""
    @State private var plexServers: [PlexClient.Resource] = []
    @State private var name = ""
    @State private var note = ""
    @State private var host = ""
    @State private var path = ""
    @State private var port = ""
    @State private var useHTTPS = false
    @State private var manualUser = ""
    @State private var manualToken = ""
    @State private var backupLines: [ServerLine] = []
    @State private var timeout = 20.0
    @State private var allowsInsecureTLS = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        Form {
            if let discovered {
                ServerHeader(kind: .plex, name: discovered.name, detail: discovered.address)
            }
            if plexToken == nil {
                Section {
                    Button {
                        signIn()
                    } label: {
                        Label("使用 Plex 账号登录", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("将在系统安全浏览器中打开 plex.tv 完成登录，Origin 不会接触你的密码。")
                }
                if discovered == nil {
                    Section {
                        TextField("名称", text: $name, prompt: Text("可选"))
                            .plainTextEntry()
                        TextField("备注", text: $note, prompt: Text("可选"))
                            .plainTextEntry()
                    }
                    Section("服务器地址") {
                        ServerAddressFields(host: $host, path: $path, port: $port, useHTTPS: $useHTTPS, onEdit: { errorText = nil }, focusOnAppear: true)
                    }
                }
                Section("登录信息") {
                    if discovered == nil {
                        TextField("用户", text: $manualUser, prompt: Text("可选"))
                            .textContentType(.username)
                            .plainTextEntry()
                    }
                    PasswordField(title: "Token", text: $manualToken, prompt: "必填", canReveal: true)
                }
                if discovered == nil {
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
                }
            } else {
                Section {
                    if plexServers.isEmpty {
                        Text("该账号下没有可用的服务器").foregroundStyle(.secondary)
                    }
                    ForEach(plexServers) { server in
                        Button {
                            connect(server)
                        } label: {
                            HStack {
                                SourceRow(icon: ServerKindIcon(kind: .plex), title: server.name,
                                          subtitle: "\(server.connections.count) 个连接地址")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("选择服务器 · \(plexUsername)")
                }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(discovered == nil ? "Plex" : "登录")
        .inlineNavigationTitle()
        .disabled(isWorking)
        .overlay {
            if isWorking { ProgressView().controlSize(.large) }
        }
        #if os(iOS)
        .toolbar {
            if plexToken == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") { connectManual() }
                        .disabled(!canConnectManually)
                }
            }
        }
        #else
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if plexToken == nil {
                HStack {
                    Spacer()
                    Button("连接") { connectManual() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canConnectManually)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        #endif
    }

    private var canConnectManually: Bool {
        if isWorking || manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if discovered != nil { return true }
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func signIn() {
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                let pin = try await PlexClient.createPin()
                let authURL = PlexClient.authURL(for: pin, forwardURL: "origin://plex-auth")
                _ = try? await webAuthenticationSession.authenticate(using: authURL, callback: .customScheme("origin"), additionalHeaderFields: [:])
                var token: String?
                for _ in 0 ..< 10 {
                    token = try await PlexClient.checkPin(pin)
                    if token != nil { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard let token else {
                    errorText = "未完成登录，请重试"
                    return
                }
                plexUsername = await PlexClient.username(token: token) ?? "Plex"
                plexServers = try await PlexClient.servers(token: token)
                plexToken = token
            } catch {
                errorText = friendlyMessage(for: error)
            }
        }
    }

    private func connect(_ server: PlexClient.Resource) {
        guard let token = plexToken else { return }
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            guard let url = await PlexClient.bestConnection(for: server) else {
                errorText = "无法连接到 \(server.name)，请确认服务器在线"
                return
            }
            let account = ServerAccount(id: UUID(), kind: .plex, name: server.name, baseURL: url,
                                        userID: plexUsername, username: plexUsername, machineID: server.clientIdentifier)
            app.add(account, token: server.accessToken ?? token)
            close()
        }
    }

    private func connectManual() {
        let typed: URL
        if let discovered {
            guard let url = URL(string: "http://\(discovered.address)") else {
                errorText = APIError.invalidURL.localizedDescription
                return
            }
            typed = url
        } else {
            ServerAddress.absorb(host: &host, path: &path, port: &port, https: &useHTTPS)
            let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
            if !portText.isEmpty, Int(portText).map({ (1 ... 65535).contains($0) }) != true {
                errorText = "端口应为 1 到 65535 的数字"
                return
            }
            guard let url = ServerAddress.compose(host: host, path: path, port: port, https: useHTTPS) else {
                errorText = host.contains("/") ? "路径请写在下面的路径一栏" : "请填写主机"
                return
            }
            typed = url
        }
        let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isWorking = true
        errorText = nil
        let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternates = port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !useHTTPS ? [ServerKind.plex.defaultPort] : []
        Task {
            defer { isWorking = false }
            var headers = PlexClient.clientHeaders
            headers["X-Plex-Token"] = token
            let targets = await ServerEndpoint.candidates(for: typed, alternatePorts: alternates)
            var lastError: Error?
            for target in targets {
                do {
                    _ = try await HTTPClient(timeout: timeout, allowsInsecureTLS: allowsInsecureTLS)
                        .data(target.appending(path: "/library/sections", query: [:]), headers: headers)
                    let fallback = discovered?.name ?? target.host() ?? "Plex"
                    let user = manualUser.trimmingCharacters(in: .whitespacesAndNewlines)
                    let account = ServerAccount(
                        id: UUID(), kind: .plex, name: enteredName.isEmpty ? fallback : enteredName, baseURL: target,
                        userID: "local", username: user.isEmpty ? "Plex" : user, note: enteredNote, backupLines: backupLines,
                        advanced: ServerAdvanced(timeout: timeout, allowsInsecureTLS: allowsInsecureTLS)
                    )
                    app.add(account, token: token)
                    close()
                    return
                } catch let error where ServerEndpoint.isUnreachable(error) {
                    lastError = error
                } catch {
                    errorText = friendlyMessage(for: error)
                    return
                }
            }
            errorText = friendlyMessage(for: lastError ?? APIError.message("无法连接到服务器，请检查地址和端口"))
        }
    }
}

// MARK: - 共用组件

func friendlyMessage(for error: Error) -> String {
    switch error {
    case APIError.unauthorized:
        return "用户名或密码错误"
    case let urlError as URLError:
        switch urlError.code {
        case .timedOut:
            return "连接超时，请确认服务器在线，且地址和端口正确"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return "无法连接到服务器，请检查地址和端口"
        case .notConnectedToInternet:
            return "网络未连接"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "HTTPS 证书无效，可以尝试改用 http://"
        default:
            return urlError.localizedDescription
        }
    default:
        return error.localizedDescription
    }
}

/// 登录页顶部的服务器信息
private struct ServerHeader: View {
    let kind: ServerKind
    let name: String
    let detail: String

    var body: some View {
        Section {
            VStack(spacing: 10) {
                ServerKindIcon(kind: kind, size: 64)
                Text(name).font(.title2.bold())
                Text("\(kind.displayName) · \(detail)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }
}

private struct ConnectButton: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text("连接")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}

private struct SourceRow<Icon: View>: View {
    let icon: Icon
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Origin 的应用标志。图形是系统符号，不是单独绘制的插画。
/// 主屏幕和程序坞图标是同一图形的整幅版本，见 AppIcon。
struct AppMark: View {
    var size: CGFloat = 44
    var pulses = false

    private var symbolSize: CGFloat { size * 28 / 44 }

    var body: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.pulse, options: .repeating, isActive: pulses)
            .frame(width: size, height: size)
            .background(Color.accentColor.gradient, in: .rect(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

/// 圆角彩色图标，用于用户自己选的符号。
struct TintedIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.2237))
            .accessibilityHidden(true)
    }
}

/// 服务器类型的官方应用图标。
struct ServerKindIcon: View {
    let kind: ServerKind
    var size: CGFloat = 32

    var body: some View {
        Image(kind.iconAsset)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.2237))
            .accessibilityHidden(true)
    }
}

/// 账号图标：用户改过就用所选符号，否则用该服务的官方图标。
struct ServerAccountIcon: View {
    let account: ServerAccount
    var size: CGFloat = 32

    var body: some View {
        if let symbol = account.customSymbol {
            TintedIcon(symbol: symbol, color: account.kind.tint, size: size)
        } else {
            ServerKindIcon(kind: account.kind, size: size)
        }
    }
}

/// 菜单和选择器里的小图标。Mac 菜单会按图片的点尺寸绘制，这里固定成 16 点。
struct ServerMenuIcon: View {
    let account: ServerAccount

    var body: some View {
        if let symbol = account.customSymbol {
            Image(systemName: symbol)
        } else {
            #if os(macOS)
            Image(nsImage: Self.sized(account.kind.iconAsset))
            #else
            ServerKindIcon(kind: account.kind, size: 20)
            #endif
        }
    }

    #if os(macOS)
    private static func sized(_ name: String) -> NSImage {
        let side: CGFloat = 16
        let source = NSImage(named: name) ?? NSImage()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }
    #endif
}

extension ServerKind {
    var tint: Color {
        switch self {
        case .jellyfin: .purple
        case .emby: .green
        case .plex: .orange
        case .fnos: .blue
        }
    }
}

extension URL {
    var hostWithPort: String? {
        guard let host = host() else { return nil }
        let literal = host.contains(":") ? "[\(host)]" : host
        return port.map { "\(literal):\($0)" } ?? literal
    }
}
