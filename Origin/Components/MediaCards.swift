import CoreImage
import SwiftUI
#if os(macOS)
import AppKit
import ObjectiveC
#endif

/// 与 AsyncImage 用法一致，但请求会带上服务器鉴权头（飞牛影视的图片接口必须鉴权）。
/// 磁盘缓存由 URLCache.shared 负责，内存中另缓存解码后的图片避免列表滚动时闪烁。
struct AuthorizedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: PlatformImage?

    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        // 已缓存的图片首帧直接显示，避免占位图闪一下再重新布局
        _image = State(initialValue: url.flatMap(ImageLoader.cached))
    }

    var body: some View {
        ZStack {
            if let image {
                content(Image(platformImage: image))
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImageLoader.cached(url) {
                if image !== cached { image = cached }
                return
            }
            image = nil
            guard let loaded = await ImageLoader.load(url) else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// 带鉴权的图片下载与解码，解码在后台线程完成
enum ImageLoader {
    private static let cache: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.countLimit = 300
        return cache
    }()

    static func cached(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    static func clearMemory() {
        cache.removeAllObjects()
        AmbientBlur.clearMemory()
    }

    static func load(_ url: URL) async -> PlatformImage? {
        if let cached = cached(url) { return cached }
        guard let (data, response) = try? await OriginTrust.session(for: url).data(for: MediaRequestAuth.request(for: url)),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let decoded = await decode(data) else { return nil }
        cache.setObject(decoded, forKey: url as NSURL)
        return decoded
    }

    private static func decode(_ data: Data) async -> PlatformImage? {
        await ImageDecoding.decode(data).map(PlatformImage.init(cgImage:))
    }
}

struct RemoteImage: View {
    let url: URL?
    var aspectRatio: CGFloat? = nil
    var contentMode: ContentMode = .fill
    var placeholderSymbol = "film"

    var body: some View {
        frame
            .overlay {
                AuthorizedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: contentMode)
                } placeholder: {
                    placeholder
                }
            }
            .clipped()
    }

    /// 不指定比例时直接填满给定空间，避免 aspectRatio(nil) 退化成正方形
    @ViewBuilder
    private var frame: some View {
        if let aspectRatio {
            Color.clear.aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            Color.clear
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

/// 2:3 海报卡片
struct PosterCard: View {
    let item: MediaItem
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.posterURL, aspectRatio: 2 / 3, placeholderSymbol: item.kind.isBrowsable ? "folder" : "film")
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { WatchBadge(item: item).padding(6) }
                .overlay(alignment: .bottomTrailing) {
                    RatingBadge(rating: item.communityRating).padding(6).padding(.bottom, item.isResumable ? 10 : 0)
                }
                .overlay(alignment: .bottom) {
                    if item.isResumable {
                        ProgressBar(progress: item.progress).padding(8)
                    }
                }
            if showTitle {
                Text(item.cardTitle)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if let subtitle = item.cardSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
    }
}

/// 16:9 横幅卡片（继续观看、单集）
struct ThumbCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.thumbURL ?? item.backdropURL, aspectRatio: 16 / 9)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    if item.progress > 0 {
                        ProgressBar(progress: item.progress).padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) { WatchBadge(item: item).padding(8) }
            Text(item.cardTitle)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if let subtitle = item.cardSubtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }
}

struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.black.opacity(0.45))
                .overlay(alignment: .leading) {
                    Capsule().fill(.tint).frame(width: proxy.size.width * progress)
                }
        }
        .frame(height: 4)
    }
}

struct WatchBadge: View {
    let item: MediaItem

    var body: some View {
        if item.userState.isPlayed {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
                .font(.callout)
                .shadow(color: .black.opacity(0.3), radius: 2)
        } else if let count = item.userState.unplayedCount, count > 0, item.kind == .series || item.kind == .season {
            Text("\(count)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint, in: .capsule)
        }
    }
}

/// 首页横向滚动的分区。不显示滚动条：两端淡出表示还能滑，Mac 上悬停出现翻页按钮。
struct Shelf<Content: View>: View {
    let title: String
    var destination: Route?
    @ViewBuilder var content: Content

    @State private var position = ScrollPosition(edge: .leading)
    @State private var cache = ShelfScrollCache()
    @State private var showsLeadingFade = false
    @State private var showsTrailingFade = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.bold())
                Spacer()
                if let destination {
                    NavigationLink(value: destination) { SeeAllLabel() }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content
                }
                .scrollTargetLayout()
                .padding(.horizontal)
                .hideSystemScrollbars()
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .onScrollGeometryChange(for: ShelfSnapshot.self) { geo in
                ShelfSnapshot(offset: geo.contentOffset.x, visible: geo.containerSize.width, content: geo.contentSize.width)
            } action: { _, new in
                cache.update(new)
                if cache.canGoBack != showsLeadingFade { showsLeadingFade = cache.canGoBack }
                if cache.canGoForward != showsTrailingFade { showsTrailingFade = cache.canGoForward }
            }
            .mask { edgeMask }
            .overlay(alignment: .leading) { scrollButton(forward: false) }
            .overlay(alignment: .trailing) { scrollButton(forward: true) }
            .onHover { hovering = $0 }
        }
    }

    private var edgeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: showsLeadingFade ? [.clear, .black] : [.black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
            Rectangle().fill(.black)
            LinearGradient(colors: showsTrailingFade ? [.black, .clear] : [.black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
        }
    }

    private func scrollButton(forward: Bool) -> some View {
        let visible = hovering && (forward ? showsTrailingFade : showsLeadingFade)
        return Button {
            let target = min(max(0, cache.offset + cache.page * (forward ? 1 : -1)), cache.maxOffset)
            withAnimation(.snappy(duration: 0.35)) { position.scrollTo(x: target) }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: .circle)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityLabel(forward ? "向右滚动" : "向左滚动")
        .animation(.snappy(duration: 0.2), value: visible)
    }
}

private struct ShelfSnapshot: Equatable {
    var offset: CGFloat
    var visible: CGFloat
    var content: CGFloat
}

private final class ShelfScrollCache {
    var offset: CGFloat = 0
    var page: CGFloat = 0
    var maxOffset: CGFloat = 0
    var canGoBack = false
    var canGoForward = false

    func update(_ snapshot: ShelfSnapshot) {
        offset = max(0, snapshot.offset)
        page = snapshot.visible * 0.8
        maxOffset = max(0, snapshot.content - snapshot.visible)
        canGoBack = offset > 8
        canGoForward = offset < maxOffset - 8
    }
}

enum HorizontalScrollbarSuppression {
    /// 关掉所有滚动区域底部的系统横条，列表和表单也算在内
    static func start() {
        #if os(macOS)
        install
        #endif
    }

    #if os(macOS)
    private static let install: Void = {
        guard let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
              let swizzled = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.origin_tileWithoutHorizontalScroller)) else { return }
        method_exchangeImplementations(original, swizzled)
    }()
    #endif
}

extension View {
    /// macOS 在“始终显示滚动条”时会忽略 scrollIndicators(.hidden)，这里直接关掉系统滚动条
    @ViewBuilder
    func hideSystemScrollbars() -> some View {
        #if os(macOS)
        background { SystemScrollbarHider() }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct SystemScrollbarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> SystemScrollbarHidingView { SystemScrollbarHidingView() }
    func updateNSView(_ view: SystemScrollbarHidingView, context: Context) { view.hide() }
}

extension NSScrollView {
    private static var adjustingKey: UInt8 = 0

    private var originIsAdjustingScroller: Bool {
        get { objc_getAssociatedObject(self, &Self.adjustingKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &Self.adjustingKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 只把横条画成透明。hasHorizontalScroller 必须保持打开，关掉之后 macOS 就不再接受左右滑动。
    @objc func origin_tileWithoutHorizontalScroller() {
        origin_tileWithoutHorizontalScroller()
        guard !originIsAdjustingScroller else { return }
        originIsAdjustingScroller = true
        if scrollerStyle != .overlay { scrollerStyle = .overlay }
        autohidesScrollers = true
        horizontalScroller?.alphaValue = 0
        originIsAdjustingScroller = false
    }
}

private final class SystemScrollbarHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hide()
    }

    override func layout() {
        super.layout()
        hide()
    }

    func hide() {
        guard let scroll = enclosingScrollView else { return }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        scroll.autohidesScrollers = true
        scroll.horizontalScroller?.alphaValue = 0
    }
}
#endif

struct SeeAllLabel: View {
    var body: some View {
        HStack(spacing: 2) {
            Text("查看全部")
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .contentShape(.rect)
    }
}

/// 海报右下角的评分角标
struct RatingBadge: View {
    let rating: Double?

    var body: some View {
        if let rating, rating > 0 {
            Text(rating.formatted(.number.precision(.fractionLength(1))))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 5))
        }
    }
}

/// 把海报模糊后铺满整页，作为氛围背景。
/// 模糊在后台对缩到很小的图做一次，界面上只是拉伸显示，滚动时没有实时模糊的开销。
struct AmbientBackground: View {
    let url: URL?
    /// 新图叠在旧图上淡入，完成后再替换底图，过渡中不会透出底色闪白
    @State private var base: PlatformImage?
    @State private var incoming: PlatformImage?
    @State private var incomingOpacity = 0.0

    var body: some View {
        ZStack {
            Color.appBackground
            if let base { layer(base) }
            if let incoming { layer(incoming).opacity(incomingOpacity) }
            if base != nil { Color.appBackground.opacity(0.45) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url, let image = await AmbientBlur.image(for: url), image !== base else { return }
            guard base != nil else {
                withAnimation(.easeInOut(duration: 0.6)) { base = image }
                return
            }
            incoming = image
            incomingOpacity = 0
            withAnimation(.easeInOut(duration: 0.6)) {
                incomingOpacity = 1
            } completion: {
                guard incoming === image else { return }
                base = image
                incoming = nil
                incomingOpacity = 0
            }
        }
    }

    private func layer(_ image: PlatformImage) -> some View {
        Image(platformImage: image)
            .resizable()
            .interpolation(.medium)
            .scaledToFill()
    }
}

enum AmbientBlur {
    private static let cache = NSCache<NSURL, PlatformImage>()

    static func clearMemory() {
        cache.removeAllObjects()
    }
    private nonisolated static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for url: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = await ImageLoader.load(url)?.cgImageRef, let blurred = await blur(source) else { return nil }
        let result = PlatformImage(cgImage: blurred)
        cache.setObject(result, forKey: url as NSURL)
        return result
    }

    @concurrent
    private static func blur(_ cgImage: CGImage) async -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        let scale = 48 / max(input.extent.width, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let output = small.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: small.extent)
        return context.createCGImage(output, from: small.extent)
    }
}

/// 继续观看卡片：点击直接续播，长按可进入详情
struct ResumeCard: View {
    @Environment(AppModel.self) private var app
    let item: MediaItem
    var serverName: String? = nil

    var body: some View {
        Button {
            app.player.play(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: item.thumbURL ?? item.backdropURL, aspectRatio: 16 / 9)
                    .overlay {
                        LinearGradient(colors: [.clear, .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    }
                    .overlay {
                        Image(systemName: "play.circle")
                            .font(.largeTitle.weight(.light))
                            .imageScale(.large)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 4)
                    }
                    .overlay(alignment: .bottom) {
                        VStack(alignment: .trailing, spacing: 6) {
                            if let runtime = item.runtime {
                                Text("\(item.userState.playbackPosition.clockString) / \(runtime.clockString)")
                                    .font(.caption2.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                            }
                            ProgressBar(progress: item.progress).tint(.white)
                        }
                        .padding(12)
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    Text(item.cardTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = item.cardSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let serverName {
                    Text(serverName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("继续播放")
        .contextMenu {
            NavigationLink(value: item) { Label("查看详情", systemImage: "info.circle") }
            ItemContextMenu(item: item)
        }
    }
}

/// “我的媒体”里的媒体库卡片：用库内三张海报拼贴
struct LibraryCollageCard: View {
    let library: MediaLibrary
    let posters: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if posters.isEmpty {
                        RemoteImage(url: library.imageURL, placeholderSymbol: library.kind.symbol)
                    } else {
                        HStack(spacing: 0) {
                            ForEach(Array(posters.prefix(3).enumerated()), id: \.offset) { index, url in
                                RemoteImage(url: url)
                                    .overlay(alignment: .leading) {
                                        if index > 0 {
                                            LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                                                .frame(width: 6)
                                        }
                                    }
                            }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
            Text(library.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .contentShape(.rect)
    }
}

/// 卡片通用长按菜单
struct ItemContextMenu: View {
    @Environment(AppModel.self) private var app
    let item: MediaItem

    var body: some View {
        if item.kind.isPlayable {
            Button("播放", systemImage: "play.fill") { app.player.play(item) }
            if item.isResumable {
                Button("从头播放", systemImage: "arrow.counterclockwise") { app.player.play(item, resume: false) }
            }
            if app.downloads.record(for: item.id) == nil {
                Button("下载", systemImage: "arrow.down.circle") {
                    Task { await download(item) }
                }
            }
        }
        Button(item.userState.isPlayed ? "标记为未看" : "标记为已看",
               systemImage: item.userState.isPlayed ? "eye.slash" : "checkmark.circle") {
            Task { try? await app.togglePlayed(item) }
        }
        if app.client(for: item.serverID)?.supportsFavorites == true {
            Button(item.userState.isFavorite ? "取消收藏" : "收藏",
                   systemImage: item.userState.isFavorite ? "heart.slash" : "heart") {
                Task { try? await app.toggleFavorite(item) }
            }
        }
    }

    /// 列表里的条目通常没有直链，先把详情补全再交给下载
    private func download(_ item: MediaItem) async {
        let full: MediaItem
        if item.mediaSources.contains(where: { $0.directURL != nil }) {
            full = item
        } else {
            full = (try? await app.client(for: item.serverID)?.item(id: item.id)) ?? item
        }
        app.downloads.download(full)
    }
}
