import SwiftUI

/// 设置首页只列分组入口，具体选项放进各自的子页面
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            #if os(macOS)
            ServerSettingsSection()
            #endif
            Section {
                row("播放", symbol: "play.fill", color: .red, value: app.settings.engine.shortTitle) {
                    SettingsPage("播放") {
                        EngineSettingsSection()
                        PlaybackSettingsSection()
                    }
                }
                row("音频与字幕", symbol: "captions.bubble.fill", color: .orange, value: app.settings.audioLanguage.title) {
                    SettingsPage("音频与字幕") {
                        LanguageSettingsSection()
                        SubtitleStyleSection()
                    }
                }
                row("元数据", symbol: "film.stack.fill", color: .indigo, value: app.settings.tmdbEnabled ? "TMDB" : "关闭") {
                    SettingsPage("元数据") { MetadataSettingsSection() }
                }
            }
            Section {
                row("同步", symbol: "arrow.triangle.2.circlepath", color: .blue,
                    value: app.lanSync.enabled ? app.lanSync.statusTitle : app.cloudSync.statusTitle) {
                    ServerSyncView()
                }
                row("存储", symbol: "internaldrive.fill", color: .gray,
                    value: ByteCountFormatter.string(fromByteCount: Int64(app.downloads.totalSize), countStyle: .file)) {
                    SettingsPage("存储") { StorageSettingsSection() }
                }
            }
            Section {
                row("关于", symbol: "info.circle.fill", color: .gray, value: "版本 \(DeviceInfo.version)") {
                    SettingsPage("关于") { AboutSettingsSection() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .inlineNavigationTitle()
    }

    private func row(_ title: String, symbol: String, color: Color, value: String,
                     @ViewBuilder destination: @escaping () -> some View) -> some View {
        NavigationLink(destination: destination) {
            LabeledContent {
                Text(value).lineLimit(1)
            } label: {
                Label {
                    Text(title)
                } icon: {
                    TintedIcon(symbol: symbol, color: color, size: iconSize)
                }
            }
        }
    }

    private var iconSize: CGFloat {
        #if os(macOS)
        22
        #else
        29
        #endif
    }
}

/// 设置子页面：同样的分组表单，只换标题
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(title)
            .inlineNavigationTitle()
    }
}

// MARK: - 服务器

#if os(macOS)
private struct ServerSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section("服务器") {
            NavigationLink(value: Route.servers) {
                if let account = app.activeAccount {
                    HStack(spacing: 12) {
                        ServerAccountIcon(account: account, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(detail(for: account))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Label("添加媒体服务器", systemImage: "plus")
                }
            }
            .accessibilityHint("管理服务器")
        }
    }

    private func detail(for account: ServerAccount) -> String {
        var parts = [account.kind.displayName]
        if !account.username.isEmpty { parts.append(account.username) }
        if let host = account.baseURL.hostWithPort { parts.append(host) }
        return parts.joined(separator: " · ")
    }
}
#endif

// MARK: - 播放

private struct EngineSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Picker("播放内核", selection: $settings.engine) {
                ForEach(PlayerEngine.allCases) { engine in
                    Text(engine.shortTitle)
                        .accessibilityLabel(engine.title)
                        .tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("播放内核")
        } header: {
            Text("播放内核")
        } footer: {
            Text(settings.engine.footnote)
        }
    }
}

private struct PlaybackSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("硬件解码", isOn: $settings.hardwareDecode)
            Toggle("自动从上次位置继续", isOn: $settings.autoResume)
            Toggle("自动播放下一集", isOn: $settings.autoPlayNext)
            Picker("片头", selection: $settings.skipIntro) {
                ForEach(SegmentSkip.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("片尾", selection: $settings.skipCredits) {
                ForEach(SegmentSkip.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("默认倍速", selection: $settings.defaultRate) {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Text(rate.formatted() + "×").tag(rate)
                }
            }
            .pickerStyle(.menu)
            Picker("长按倍速", selection: $settings.longPressRate) {
                ForEach([1.5, 2.0, 3.0], id: \.self) { rate in
                    Text(rate.formatted() + "×").tag(rate)
                }
            }
            .pickerStyle(.menu)
            Picker("快退", selection: $settings.skipBackward) {
                ForEach([5, 10, 15, 30], id: \.self) { seconds in
                    Text("\(seconds) 秒").tag(seconds)
                }
            }
            .pickerStyle(.menu)
            Picker("快进", selection: $settings.skipForward) {
                ForEach([10, 15, 30, 45, 60], id: \.self) { seconds in
                    Text("\(seconds) 秒").tag(seconds)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("播放控制")
        } footer: {
            Text("有标记时，询问会显示跳过按钮，自动跳过会直接跳过。片头含前情和广告，片尾含预告。")
        }
    }
}

private struct LanguageSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section("首选语言") {
            Picker("首选音轨", selection: $settings.audioLanguage) {
                ForEach(LanguagePreference.allCases.filter { $0 != .none }) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.menu)
            Picker("首选字幕", selection: $settings.subtitleLanguage) {
                ForEach(LanguagePreference.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

// MARK: - 字幕样式

private struct SubtitleStyleSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            SubtitlePreview(settings: settings)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                .listRowSeparator(.hidden, edges: .bottom)
            slider("字号", value: $settings.subtitleSize, range: 14 ... 44, step: 1)
            slider("底部边距", value: $settings.subtitleBottomPadding, range: 0 ... 120, step: 2)
            SubtitleColorRow(settings: settings)
            Toggle("半透明背景", isOn: $settings.subtitleBackground)
        } header: {
            Text("字幕样式")
        } footer: {
            Text("只影响 FFmpeg 内核。系统播放器沿用系统的字幕样式。")
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        let number = Text(value.wrappedValue, format: .number.precision(.fractionLength(0)))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .accessibilityHidden(true)
        let control = Slider(value: value, in: range, step: step)
            .accessibilityLabel(title)
            .accessibilityValue(Text(value.wrappedValue, format: .number.precision(.fractionLength(0))))
        return ViewThatFits(in: .horizontal) {
            LabeledContent(title) {
                HStack(spacing: 12) {
                    control
                    number.frame(minWidth: 32, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent { number } label: { Text(title) }
                control
            }
        }
    }
}

private struct SubtitlePreview: View {
    @Bindable var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.black.opacity(0.72), .black], startPoint: .top, endPoint: .bottom)
            Text("字幕预览")
                .font(.system(size: settings.subtitleSize, weight: .semibold))
                .foregroundStyle(settings.subtitleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 1)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(.horizontal, settings.subtitleBackground ? 10 : 0)
                .padding(.vertical, settings.subtitleBackground ? 4 : 0)
                .background(settings.subtitleBackground ? Color.black.opacity(0.55) : .clear, in: .rect(cornerRadius: 6))
                .padding(.bottom, previewBottomInset)
                .padding(.horizontal, 16)
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.14))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("字幕预览")
        .animation(reduceMotion ? nil : .snappy, value: settings.subtitleBackground)
        .animation(reduceMotion ? nil : .snappy, value: settings.subtitleColorHex)
    }

    /// 预览比真实画面小，边距按比例压缩，滑杆仍能看出字幕在上下移动。
    private var previewBottomInset: CGFloat {
        14 + settings.subtitleBottomPadding / 120 * 34
    }
}

private struct SubtitleColorRow: View {
    @Bindable var settings: AppSettings

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("颜色")
                Spacer(minLength: 8)
                choices
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("颜色")
                choices
            }
        }
    }

    private var choices: some View {
        HStack(spacing: 0) {
            ForEach(SubtitleSwatch.allCases) { swatch in
                SubtitleSwatchButton(swatch: swatch, isSelected: isSelected(swatch)) {
                    settings.subtitleColorHex = swatch.hex
                }
            }
            ColorPicker("自定义颜色", selection: subtitleColor, supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel("自定义颜色")
        }
    }

    private var subtitleColor: Binding<Color> {
        Binding(get: { settings.subtitleColor }, set: { settings.subtitleColor = $0 })
    }

    private func isSelected(_ swatch: SubtitleSwatch) -> Bool {
        settings.subtitleColorHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
    }
}

private enum SubtitleSwatch: String, CaseIterable, Identifiable {
    case white = "#FFFFFF"
    case yellow = "#FFE14A"
    case cyan = "#7FDBFF"
    case green = "#C6F25A"

    var id: String { rawValue }
    var hex: String { rawValue }

    var name: String {
        switch self {
        case .white: "白色"
        case .yellow: "黄色"
        case .cyan: "青色"
        case .green: "绿色"
        }
    }
}

private struct SubtitleSwatchButton: View {
    let swatch: SubtitleSwatch
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter = 26
    @ScaledMetric(relativeTo: .caption) private var mark = 11

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: swatch.hex))
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-4)
                    }
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: mark, weight: .bold))
                            .foregroundStyle(.black.opacity(0.72))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 元数据

private struct MetadataSettingsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var status = TMDBStatus.idle
    @State private var checkID = 0

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("使用 TMDB 补充信息", isOn: $settings.tmdbEnabled)
            if settings.tmdbEnabled {
                PasswordField(title: "访问令牌", text: $settings.customTMDBToken, prompt: "可选") {
                    app.refreshTMDB()
                }
                Button(action: test) {
                    LabeledContent("测试连接") { statusMark }
                }
                .disabled(status == .checking)
                if status == .failed {
                    Text("连接失败，请检查令牌或网络")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("元数据")
        } footer: {
            Text("补充 Logo、预告片、标语和演员头像。令牌留空时使用内置的。")
        }
        .animation(reduceMotion ? nil : .snappy, value: settings.tmdbEnabled)
        .animation(reduceMotion ? nil : .snappy, value: status)
        .onChange(of: settings.tmdbEnabled) {
            app.refreshTMDB()
            invalidateCheck()
        }
        .onChange(of: settings.customTMDBToken) {
            invalidateCheck()
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("连接正常")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("连接失败")
        }
    }

    private func test() {
        app.refreshTMDB()
        checkID += 1
        let id = checkID
        status = .checking
        Task {
            let ok = await app.tmdb.validate()
            guard id == checkID else { return }
            status = ok ? .succeeded : .failed
        }
    }

    private func invalidateCheck() {
        checkID += 1
        status = .idle
    }
}

private enum TMDBStatus: Equatable {
    case idle
    case checking
    case succeeded
    case failed
}

// MARK: - 存储

private struct StorageSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var cacheSize = URLCache.shared.currentDiskUsage
    @State private var confirmClear = false

    var body: some View {
        Section("存储") {
            LabeledContent("图片缓存") {
                Text(byteCount(cacheSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("清除图片缓存", role: .destructive) { confirmClear = true }
                .disabled(cacheSize == 0)
            NavigationLink(value: Route.downloads) {
                LabeledContent("离线下载") {
                    Text(byteCount(app.downloads.totalSize))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .onAppear { cacheSize = URLCache.shared.currentDiskUsage }
        .confirmationDialog("清除图片缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                URLCache.shared.removeAllCachedResponses()
                ImageLoader.clearMemory()
                cacheSize = URLCache.shared.currentDiskUsage
            }
        } message: {
            Text("已缓存的海报和剧照会在下次浏览时重新下载。")
        }
    }

    private func byteCount(_ count: some BinaryInteger) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - 关于

private struct AboutSettingsSection: View {
    private static let github = URL(string: "https://github.com/CNLiuBei/origin-client")!
    private static let telegramApp = URL(string: "tg://resolve?domain=NextOrigin")!
    private static let telegram = URL(string: "https://t.me/NextOrigin")!
    private static let qq = URL(string: "https://qm.qq.com/q/SwwYWu9FiA")!
    private static let ksplayer = URL(string: "https://github.com/kingslay/KSPlayer")!
    private static let tmdb = URL(string: "https://www.themoviedb.org")!
    private static let telegramBlue = Color(red: 0x26 / 255, green: 0xA5 / 255, blue: 0xE4 / 255)
    private static let qqBlue = Color(red: 0x1E / 255, green: 0xBA / 255, blue: 0xFC / 255)

    var body: some View {
        Section {
            HStack(spacing: 12) {
                AppMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Origin")
                        .font(.headline)
                    Text("版本 \(DeviceInfo.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            communityLink("GitHub", asset: "BrandGitHub", tint: .primary, appScheme: nil, web: Self.github)
            communityLink("Telegram", asset: "BrandTelegram", tint: Self.telegramBlue, appScheme: Self.telegramApp, web: Self.telegram)
            communityLink("QQ群", asset: "BrandQQ", tint: Self.qqBlue, appScheme: nil, web: Self.qq)

            Link(destination: Self.ksplayer) {
                LabeledContent("KSPlayer", value: "GPL-3.0")
            }
            Link(destination: Self.tmdb) {
                LabeledContent("元数据来源", value: "TMDB")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("本产品使用 TMDB API，但未获得 TMDB 的认可或认证。播放内核使用 KSPlayer 与 FFmpeg（GPL-3.0）。")
        }
    }

    private func communityLink(_ title: String, asset: String, tint: Color, appScheme: URL?, web: URL) -> some View {
        Button {
            AppLink.open(appScheme: appScheme, web: web)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }
}
