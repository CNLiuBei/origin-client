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
        case manualAccount
        case plex
    }

    @Environment(\.dismiss) private var dismiss
    @State private var browser = LocalServerBrowser()

    var body: some View {
        NavigationStack {
            List {
                nearbySection
                Section("手动添加") {
                    NavigationLink(value: Route.manualAccount) {
                        SourceRow(icon: TintedIcon(symbol: "server.rack", color: .indigo),
                                  title: "Jellyfin · Emby · 飞牛影视", subtitle: "输入服务器地址和账号")
                    }
                    .accessibilityIdentifier("manual-account")
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
                    AccountLoginView(discovered: server) { dismiss() }
                case .manualAccount:
                    AccountLoginView(discovered: nil) { dismiss() }
                case .plex:
                    PlexLoginView(discovered: nil) { dismiss() }
                }
            }
            .animation(.snappy, value: browser.servers)
            .animation(.snappy, value: browser.isSearching)
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 620)
        #endif
        .task { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var nearbySection: some View {
        Section {
            ForEach(browser.servers) { server in
                NavigationLink(value: Route.discovered(server)) {
                    SourceRow(icon: ServerKindIcon(kind: server.kind), title: server.name,
                              subtitle: "\(server.kind.displayName) · \(server.address)")
                }
            }
            if browser.servers.isEmpty {
                if browser.isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索局域网…").foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("没有发现服务器").foregroundStyle(.secondary)
                        Spacer()
                        Button("重新搜索") { browser.restart() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("附近的服务器")
        } footer: {
            Text("可自动发现局域网中的飞牛影视与 Plex，选择后只需登录账号。Jellyfin 与 Emby 请手动添加。")
        }
    }
}

// MARK: - Jellyfin / Emby / 飞牛影视登录

private struct AccountLoginView: View {
    private enum Field: Hashable {
        case address, username, password
    }

    private enum ProbeState: Equatable {
        case idle
        case probing
        case found(url: URL, kind: ServerKind, name: String, version: String?)
        case failed(String)
    }

    /// 为 nil 时为手动添加，需要填写地址
    let discovered: DiscoveredServer?
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @FocusState private var focus: Field?

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var probe = ProbeState.idle
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        Form {
            if let discovered {
                ServerHeader(kind: discovered.kind, name: discovered.name, detail: discovered.address)
            } else {
                addressSection
            }

            Section("账号") {
                TextField("用户名", text: $username)
                    .accessibilityIdentifier("username")
                    .textContentType(.username)
                    .plainTextEntry()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                PasswordField(title: "密码", text: $password, identifier: "password",
                              isFocused: Binding(get: { focus == .password },
                                                 set: { focus = $0 ? .password : (focus == .password ? nil : focus) })) {
                    if canConnect { connect() }
                }
                .focused($focus, equals: .password)
                .submitLabel(.go)
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                ConnectButton(isWorking: isWorking, action: connect)
                    .disabled(!canConnect)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .formStyle(.grouped)
        .navigationTitle(discovered == nil ? "手动添加" : "登录")
        .inlineNavigationTitle()
        .disabled(isWorking)
        .animation(.snappy, value: probe)
        .animation(.snappy, value: errorText)
        .task(id: address) { await detectServer() }
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            focus = discovered == nil ? .address : .username
        }
    }

    private var addressSection: some View {
        Section {
            TextField("服务器地址", text: $address, prompt: Text("192.168.1.10:8096"))
                .accessibilityIdentifier("server-address")
                .urlKeyboard()
                .textContentType(.URL)
                .plainTextEntry()
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .username }
            probeRow
        } header: {
            Text("地址")
        } footer: {
            Text("会自动识别服务器类型；不写端口时依次尝试 8096（Jellyfin / Emby）和 8005（飞牛影视）。不写协议时使用 http。")
        }
    }

    @ViewBuilder
    private var probeRow: some View {
        switch probe {
        case .idle:
            EmptyView()
        case .probing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在识别服务器…").font(.subheadline).foregroundStyle(.secondary)
            }
        case let .found(url, kind, name, version):
            HStack(spacing: 12) {
                ServerKindIcon(kind: kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline.weight(.semibold))
                    Text([kind.displayName, version, url.hostWithPort].compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var canConnect: Bool {
        (discovered != nil || !address.isEmpty) && !username.isEmpty && !isWorking
    }

    /// 停止输入片刻后探测地址，未写端口时补全常见端口
    private func detectServer() async {
        probe = .idle
        guard discovered == nil, let base = address.normalizedServerURL, base.host() != nil else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        probe = .probing
        for candidate in Self.candidates(for: base) {
            let result = try? await JellyfinClient.probe(baseURL: candidate, timeout: 4)
            guard !Task.isCancelled else { return }
            if let (kind, info) = result {
                probe = .found(url: candidate, kind: kind, name: info.serverName ?? kind.displayName, version: info.version)
                return
            }
        }
        probe = .failed("未识别到 Jellyfin、Emby 或飞牛影视，请检查地址和端口")
    }

    private static func candidates(for url: URL) -> [URL] {
        guard url.port == nil, url.path().isEmpty || url.path() == "/",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        return [url] + [8096, 8005].compactMap { port in
            components.port = port
            return components.url
        }
    }

    private func connect() {
        let typed = discovered.flatMap { URL(string: "http://\($0.address)") } ?? address.normalizedServerURL
        guard let typed else {
            errorText = APIError.invalidURL.localizedDescription
            return
        }
        focus = nil
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                var url = typed
                let kind: ServerKind
                if let discovered {
                    kind = discovered.kind
                } else if case let .found(foundURL, foundKind, _, _) = probe {
                    url = foundURL
                    kind = foundKind
                } else {
                    kind = try await JellyfinClient.probe(baseURL: typed).0
                }
                let result = try await JellyfinClient.authenticate(baseURL: url, kind: kind, username: username, password: password)
                // 已添加过的账号视为重新登录：更新令牌并切换过去
                if let existing = app.accounts.first(where: { $0.baseURL == url && $0.userID == result.userID }) {
                    app.add(existing, token: result.token)
                    close()
                    return
                }
                let account = ServerAccount(id: UUID(), kind: kind, name: result.serverName, baseURL: url,
                                            userID: result.userID, username: result.username)
                app.add(account, token: result.token)
                close()
            } catch {
                errorText = friendlyMessage(for: error)
            }
        }
    }
}

// MARK: - Plex 登录

private struct PlexLoginView: View {
    let discovered: DiscoveredServer?
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var plexToken: String?
    @State private var plexUsername = ""
    @State private var plexServers: [PlexClient.Resource] = []
    @State private var manualURL = ""
    @State private var manualToken = ""
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
                Section {
                    if discovered == nil {
                        TextField("服务器地址", text: $manualURL, prompt: Text("http://192.168.1.10:32400"))
                            .urlKeyboard()
                            .plainTextEntry()
                    }
                    PasswordField(title: "X-Plex-Token", text: $manualToken)
                    Button("使用 Token 连接") { connectManual() }
                        .disabled((discovered == nil && manualURL.isEmpty) || manualToken.isEmpty)
                } header: {
                    Text("使用 Token")
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
        .onAppear {
            if let discovered, manualURL.isEmpty { manualURL = "http://\(discovered.address)" }
        }
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
        guard let url = manualURL.normalizedServerURL else {
            errorText = APIError.invalidURL.localizedDescription
            return
        }
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            var headers = PlexClient.clientHeaders
            headers["X-Plex-Token"] = manualToken
            do {
                _ = try await HTTPClient(timeout: 10).data(url.appending(path: "/library/sections", query: [:]), headers: headers)
                let account = ServerAccount(id: UUID(), kind: .plex, name: discovered?.name ?? url.host() ?? "Plex",
                                            baseURL: url, userID: "local", username: "Plex")
                app.add(account, token: manualToken)
                close()
            } catch {
                errorText = friendlyMessage(for: error)
            }
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
        return port.map { "\(host):\($0)" } ?? host
    }
}
