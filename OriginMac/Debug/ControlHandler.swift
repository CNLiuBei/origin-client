#if DEBUG
import AppKit
import Carbon
@preconcurrency import KSPlayer
import SwiftUI

final class ControlHandler {
    private let app: AppModel
    private let navigation: MacNavigation
    private let openSettings: () -> Void
    /// 最近一次 /ui 返回的元素，可按序号操作
    private var lastNodes: [UINode] = []

    init(app: AppModel, navigation: MacNavigation, openSettings: @escaping () -> Void) {
        self.app = app
        self.navigation = navigation
        self.openSettings = openSettings
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            switch (request.method, request.path) {
            case (_, "/"), (_, "/help"): return .text(Self.help)
            case ("GET", "/state"): return .json(state())
            case ("GET", "/libraries"): return try await libraries()
            case ("GET", "/items"): return try await items(request)
            case ("GET", "/item"): return try await item(request)
            case ("POST", "/sign-in"): return try await signIn(request)
            case ("POST", "/server"): return selectServer(request)
            case ("POST", "/navigate"): return navigate(request)
            case ("POST", "/open"): return try await open(request)
            case ("POST", "/back"): return back(request)
            case ("POST", "/play"): return try await play(request)
            case ("POST", "/player"): return player(request)
            case ("POST", "/config"):
                if let value = request.string("engine") {
                    guard let engine = PlayerEngine(rawValue: value) else { return .error("engine 取值：auto / systemOnly / ffmpeg") }
                    app.settings.engine = engine
                }
                return .json(["engine": app.settings.engine.rawValue])
            case ("POST", "/settings"):
                openSettings()
                return .ok
            case ("GET", "/ui"): return ui(request)
            case ("POST", "/press"): return press(request)
            case ("POST", "/click"): return click(request)
            case ("POST", "/type"): return type(request)
            case ("POST", "/key"): return key(request)
            case ("POST", "/scroll"): return scroll(request)
            case ("GET", "/wait"), ("POST", "/wait"): return await wait(request)
            case ("GET", "/screenshot"): return screenshot(request)
            case ("GET", "/menus"): return .text(menus())
            case ("GET", "/input"): return .json(inputState(request))
            default: return .error("未知接口 \(request.method) \(request.path)，见 GET /help", status: 404)
            }
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    // MARK: - 状态

    private func state() -> [String: Any] {
        var result: [String: Any] = [
            "accounts": app.accounts.map { account in
                ["id": account.id.uuidString, "name": account.name, "kind": account.kind.rawValue,
                 "username": account.username, "active": account.id == app.activeAccountID] as [String: Any]
            },
            "sidebar": sidebarDescription(navigation.selection),
            "navigationStack": navigation.trail,
            "libraries": navigation.libraries.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] },
            "isPreparingPlayback": app.player.isPreparing,
            "windows": NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }.map(windowInfo),
        ]
        if let error = app.player.errorMessage { result["playbackError"] = error }
        result["player"] = playerState().map { $0 as Any } ?? NSNull()
        return result
    }

    private func playerState() -> [String: Any]? {
        switch app.player.active {
        case let .native(controller):
            return ["engine": "native", "title": controller.session.title, "playing": controller.isPlaying,
                    "time": controller.currentTime.rounded(), "duration": controller.duration.isFinite ? controller.duration.rounded() : 0,
                    "volume": controller.volume]
        case let .ffmpeg(model):
            var info: [String: Any] = ["engine": "ffmpeg", "title": model.session.title, "playing": model.isPlaying,
                                       "buffering": model.isBuffering, "time": model.currentTime.rounded(),
                                       "duration": model.duration.rounded(), "volume": model.volume,
                                       "rate": model.rate, "controlsVisible": model.controlsVisible,
                                       "audioTracks": model.audioTracks.map { $0.name }]
            if let error = model.errorText { info["error"] = error }
            return info
        case nil:
            return nil
        }
    }

    private func sidebarDescription(_ item: SidebarItem?) -> String {
        switch item {
        case .home, nil: "home"
        case .search: "search"
        case .servers: "servers"
        case .favorites: "favorites"
        case let .library(library): "library:\(library.id) \(library.name)"
        }
    }

    private func windowInfo(_ window: NSWindow) -> [String: Any] {
        let frame = window.frame
        return ["name": windowName(window), "title": window.title, "number": window.windowNumber, "key": window.isKeyWindow,
                "sheet": window.attachedSheet != nil,
                "fullScreen": window.styleMask.contains(.fullScreen),
                "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height].map { Int($0) }]
    }

    private func windowName(_ window: NSWindow) -> String {
        let identifier = window.identifier?.rawValue ?? ""
        if identifier.hasPrefix(PlayerWindowView.id) { return "player" }
        if identifier.hasPrefix("main") { return "main" }
        if identifier.localizedCaseInsensitiveContains("settings") { return "settings" }
        return identifier.isEmpty ? window.title : identifier
    }

    /// 目标窗口挂着 sheet 时返回 sheet（模态，是当前唯一可操作的界面）
    private func window(_ request: ControlRequest) -> NSWindow? {
        var window = baseWindow(request)
        while let sheet = window?.attachedSheet { window = sheet }
        return window
    }

    private func baseWindow(_ request: ControlRequest) -> NSWindow? {
        let visible = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }
        guard let name = request.string("window"), name != "key" else {
            return visible.first { windowName($0) == "main" } ?? visible.first
        }
        return visible.first { windowName($0) == name } ?? visible.first { $0.title.localizedCaseInsensitiveContains(name) }
    }

    // MARK: - 数据

    private var client: any MediaServerClient {
        get throws {
            guard let client = app.client else { throw APIError.message("还没有登录服务器，先调用 POST /sign-in") }
            return client
        }
    }

    private func libraries() async throws -> ControlResponse {
        let libraries = try await client.libraries()
        navigation.libraries = libraries
        return .json(libraries.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] })
    }

    private func items(_ request: ControlRequest) async throws -> ControlResponse {
        let client = try client
        let limit = request.string("limit").flatMap(Int.init) ?? 30
        let start = request.string("start").flatMap(Int.init) ?? 0
        let items: [MediaItem]
        if let term = request.string("search") {
            items = try await client.search(term, limit: limit)
        } else if let libraryID = request.string("library") {
            let kind = navigation.libraries.first { $0.id == libraryID }?.kind ?? .mixed
            items = try await client.items(parentID: libraryID, kind: kind, query: LibraryQuery(), start: start, limit: limit).items
        } else if let parentID = request.string("parent") {
            let parent = try await client.item(id: parentID)
            if parent.kind == .series {
                items = try await client.episodes(seriesID: parent.id)
            } else {
                items = try await client.items(parentID: client.childrenParentID(of: parent), kind: .mixed, query: LibraryQuery(), start: start, limit: limit).items
            }
        } else if request.string("resume") != nil {
            items = try await client.resumeItems(limit: limit)
        } else if request.string("favorites") != nil {
            items = try await client.favorites()
        } else {
            return .error("需要 library、parent、search、resume 或 favorites 参数之一")
        }
        return .json(items.map(summary))
    }

    private func item(_ request: ControlRequest) async throws -> ControlResponse {
        guard let id = request.string("id") else { return .error("缺少 id") }
        let item = try await client.item(id: id)
        var info = summary(item)
        info["overview"] = item.overview ?? ""
        info["sources"] = item.mediaSources.map { ["id": $0.id, "name": $0.fileName ?? "", "container": $0.container ?? ""] }
        return .json(info)
    }

    private func summary(_ item: MediaItem) -> [String: Any] {
        var info: [String: Any] = ["id": item.id, "name": item.name, "kind": item.kind.rawValue]
        if let year = item.year { info["year"] = year }
        if let label = item.episodeLabel { info["episode"] = label }
        if item.isResumable { info["position"] = item.userState.playbackPosition.rounded() }
        return info
    }

    // MARK: - 账号

    /// 凭据只在请求中传入，不会写入源码；登录成功后令牌照常存入 Keychain
    private func signIn(_ request: ControlRequest) async throws -> ControlResponse {
        guard let address = request.string("address")?.normalizedServerURL, let username = request.string("username") else {
            return .error("需要 address 与 username（password 可选）")
        }
        let targets = await ServerEndpoint.candidates(for: address)
        let found: (URL, ServerKind)
        do {
            found = try await ServerEndpoint.firstReachable(targets, isMiss: { error in
                if error is CancellationError { return true }
                if let urlError = error as? URLError, urlError.code == .cancelled { return true }
                return true
            }) { candidate in
                let kind = try await JellyfinClient.probe(baseURL: candidate, timeout: 6).0
                return (candidate, kind)
            }
        } catch {
            return .error("未识别到 Jellyfin、Emby 或飞牛影视服务器")
        }
        let (url, kind) = found
        let stored = ServerEndpoint.addressToStore(entered: address, reached: url)
        let result = try await JellyfinClient.authenticate(baseURL: url, kind: kind, username: username, password: request.string("password") ?? "")
        if let existing = app.accounts.first(where: { $0.baseURL == stored && $0.userID == result.userID }) {
            app.add(existing, token: result.token)
            return .json(["ok": true, "account": existing.id.uuidString, "url": stored.absoluteString, "note": "账号已存在，已更新令牌并切换"])
        }
        let account = ServerAccount(id: UUID(), kind: kind, name: result.serverName, baseURL: stored, userID: result.userID, username: result.username)
        app.add(account, token: result.token)
        return .json(["ok": true, "account": account.id.uuidString, "kind": kind.rawValue, "server": result.serverName, "url": stored.absoluteString])
    }

    private func selectServer(_ request: ControlRequest) -> ControlResponse {
        guard let key = request.string("id") ?? request.string("name"),
              let account = app.accounts.first(where: { $0.id.uuidString == key || $0.name == key }) else {
            return .error("找不到该服务器")
        }
        app.activeAccountID = account.id
        return .ok
    }

    // MARK: - 导航

    private func navigate(_ request: ControlRequest) -> ControlResponse {
        let target = request.string("to") ?? ""
        switch target {
        case "home": navigation.selection = .home
        case "search": navigation.selection = .search
        case "downloads":
            navigation.trail.append("下载")
            navigation.path.append(Route.downloads)
        case "favorites": navigation.selection = .favorites
        case "servers": navigation.selection = .servers
        case "library":
            let key = request.string("id") ?? request.string("name") ?? ""
            guard let library = navigation.libraries.first(where: { $0.id == key || $0.name == key }) else {
                return .error("找不到媒体库 \(key)，可用：\(navigation.libraries.map(\.name).joined(separator: "、"))")
            }
            navigation.selection = .library(library)
        default:
            return .error("to 取值：home / search / downloads / favorites / servers / library（配合 id 或 name）")
        }
        return .ok
    }

    private func open(_ request: ControlRequest) async throws -> ControlResponse {
        guard let id = request.string("id") else { return .error("缺少 id") }
        let item = try await client.item(id: id)
        navigation.push(item)
        return .json(["ok": true, "opened": summary(item)])
    }

    private func back(_ request: ControlRequest) -> ControlResponse {
        let count = min(Int(request.double("count") ?? 1), navigation.path.count)
        if request.string("root") != nil {
            navigation.path = NavigationPath()
        } else if count > 0 {
            navigation.path.removeLast(count)
        }
        return .ok
    }

    // MARK: - 播放

    private func play(_ request: ControlRequest) async throws -> ControlResponse {
        guard let id = request.string("id") else { return .error("缺少 id") }
        let item = try await client.item(id: id)
        let resume = request.string("resume").map { $0 == "true" || $0 == "1" }
        app.player.play(item, resume: resume, sourceID: request.string("source"))
        return .json(["ok": true, "playing": summary(item)])
    }

    private func player(_ request: ControlRequest) -> ControlResponse {
        let presenter = app.player
        guard presenter.active != nil else { return .error("当前没有播放") }
        let value = request.double("value")
        switch request.string("action") ?? "" {
        case "toggle": presenter.togglePlay()
        case "forward": presenter.skip(forward: true)
        case "backward": presenter.skip(forward: false)
        case "volume": presenter.adjustVolume(by: Float(value ?? 0.1))
        case "seek":
            guard let value else { return .error("seek 需要 value（秒）") }
            switch presenter.active {
            case let .ffmpeg(model): model.seek(to: value)
            case let .native(controller): controller.skip(Int(value - controller.currentTime))
            case nil: break
            }
        case "rate":
            guard case let .ffmpeg(model) = presenter.active, let value else { return .error("仅 FFmpeg 引擎支持，需要 value") }
            model.setRate(value)
        case "fullscreen":
            NSApp.windows.first { windowName($0) == "player" }?.toggleFullScreen(nil)
        case "close": presenter.dismissPlayerWindow()
        default:
            return .error("action 取值：toggle / forward / backward / seek / volume / rate / fullscreen / close")
        }
        return .json(["ok": true, "player": playerState().map { $0 as Any } ?? NSNull()])
    }

    // MARK: - 界面元素（进程内无障碍树，无需系统授权）

    private func ui(_ request: ControlRequest) -> ControlResponse {
        guard let window = window(request) else { return .error("找不到窗口") }
        lastNodes = UINode.collect(in: window, includeAll: request.string("all") != nil)
        let filter = request.string("filter")
        let lines = lastNodes.enumerated().compactMap { index, node -> String? in
            let line = "#\(index) " + node.description
            return filter.map { line.localizedCaseInsensitiveContains($0) ? line : nil } ?? line
        }
        return .text("窗口：\(windowName(window))  共 \(lastNodes.count) 个元素\n" + lines.joined(separator: "\n"))
    }

    private func findNode(_ request: ControlRequest) -> UINode? {
        if let index = request.string("index").flatMap(Int.init), lastNodes.indices.contains(index) {
            return lastNodes[index]
        }
        guard let window = window(request) else { return nil }
        let nodes = UINode.collect(in: window, includeAll: true)
        if let id = request.string("id") {
            return nodes.first { $0.identifier == id }
        }
        guard let text = request.string("label") ?? request.string("text") else { return nil }
        let role = request.string("role")
        let candidates = nodes.filter { role == nil || $0.role.localizedCaseInsensitiveContains(role!) }
        return candidates.first { $0.label == text || $0.value == text }
            ?? candidates.first { $0.label.localizedCaseInsensitiveContains(text) }
    }

    private func press(_ request: ControlRequest) -> ControlResponse {
        guard let node = findNode(request) else { return .error("找不到元素（可用 id / label / index，配合 role、window）", status: 404) }
        guard node.press(in: window(request)) else { return .error("元素不支持点按：\(node.description)") }
        return .json(["ok": true, "pressed": node.description])
    }

    /// 按窗口坐标点击：以窗口左上角为原点的点坐标（与 originctl shot 截图按比例对应）
    private func click(_ request: ControlRequest) -> ControlResponse {
        guard let x = request.double("x"), let y = request.double("y"), let base = baseWindow(request) else {
            return .error("需要 x、y（窗口内左上角为原点的点坐标），可选 window")
        }
        let target = window(request) ?? base
        let screenPoint = CGPoint(x: base.frame.minX + x, y: base.frame.maxY - y)
        guard MouseInput.click(screenPoint: screenPoint, in: target) else { return .error("无法生成点击事件") }
        return .ok
    }

    private func type(_ request: ControlRequest) -> ControlResponse {
        guard let text = request.string("text") else { return .error("缺少 text") }
        if request.string("id") != nil || request.string("label") != nil || request.string("index") != nil {
            guard let node = findNode(request) else { return .error("找不到输入框", status: 404) }
            node.focus()
        }
        guard let window = window(request) else { return .error("找不到窗口") }
        if let editor = window.firstResponder as? NSTextView {
            if request.string("replace") != nil { editor.selectAll(nil) }
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            for character in text { KeyInput.send(String(character), modifiers: [], to: window) }
        }
        if request.string("submit") != nil { KeyInput.send("return", modifiers: [], to: window) }
        return .ok
    }

    private func key(_ request: ControlRequest) -> ControlResponse {
        guard let key = request.string("key"), let window = window(request) else { return .error("需要 key，可选 modifiers 与 window") }
        let modifiers = (request.string("modifiers") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard KeyInput.send(key, modifiers: modifiers, to: window) else { return .error("不支持的按键 \(key)") }
        return .ok
    }

    private func scroll(_ request: ControlRequest) -> ControlResponse {
        guard let window = window(request) else { return .error("找不到窗口") }
        let dy = request.double("dy") ?? -400
        let dx = request.double("dx") ?? 0
        let point = request.double("x").flatMap { x in request.double("y").map { CGPoint(x: x, y: $0) } }
            ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            return .error("无法生成滚动事件")
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: point.x, y: screenHeight - point.y)
        guard let nsEvent = NSEvent(cgEvent: event) else { return .error("无法生成滚动事件") }
        let local = window.convertPoint(fromScreen: point)
        window.contentView?.hitTest(local)?.scrollWheel(with: nsEvent)
        return .ok
    }

    /// 轮询界面直到出现指定文字或标识，避免盲等加截图
    private func wait(_ request: ControlRequest) async -> ControlResponse {
        let timeout = request.double("timeout") ?? 15
        let deadline = Date.now.addingTimeInterval(timeout)
        let text = request.string("text"), id = request.string("id")
        let gone = request.string("gone") != nil
        let playing = request.string("playing") != nil
        repeat {
            if playing {
                if let state = playerState(), state["playing"] as? Bool == true, (state["time"] as? Double ?? 0) > 0 {
                    return .json(["ok": true, "player": state])
                }
            } else if let window = window(request) {
                let nodes = UINode.collect(in: window, includeAll: true)
                let match = nodes.first { node in
                    if let id { return node.identifier == id }
                    if let text { return node.label.localizedCaseInsensitiveContains(text) || node.value.localizedCaseInsensitiveContains(text) }
                    return false
                }
                if gone ? match == nil : match != nil {
                    return .json(["ok": true, "element": match?.description ?? ""])
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
        } while Date.now < deadline
        return .error("等待超时（\(timeout) 秒）", status: 408)
    }

    // MARK: - 输入法

    /// 当前第一响应者及其输入法上下文，排查输入法吞键问题
    private func inputState(_ request: ControlRequest) -> [String: Any] {
        guard let window = window(request) else { return ["error": "找不到窗口"] }
        let responder = window.firstResponder
        var info: [String: Any] = [
            "firstResponder": responder.map { String(describing: Swift.type(of: $0)) } ?? "nil",
            "secureEventInput": IsSecureEventInputEnabled(),
        ]
        if let textView = responder as? NSTextView {
            info["fieldEditorOf"] = (textView.delegate as AnyObject?).map { String(describing: Swift.type(of: $0)) } ?? "nil"
            info["isSecureFieldEditor"] = textView.delegate is NSSecureTextField
            if let context = textView.inputContext {
                info["selectedInputSource"] = context.selectedKeyboardInputSource ?? "nil"
                info["allowedInputSourceLocales"] = context.allowedInputSourceLocales ?? ["(全部)"]
                info["keyboardInputSources"] = context.keyboardInputSources ?? []
            }
        }
        return info
    }

    // MARK: - 菜单

    /// 列出菜单栏所有菜单项及快捷键，排查快捷键冲突
    private func menus() -> String {
        var lines: [String] = []
        func walk(_ menu: NSMenu, prefix: String) {
            for item in menu.items where !item.isSeparatorItem {
                let path = prefix.isEmpty ? item.title : "\(prefix) › \(item.title)"
                if !item.keyEquivalent.isEmpty {
                    var mods: [String] = []
                    let flags = item.keyEquivalentModifierMask
                    if flags.contains(.control) { mods.append("⌃") }
                    if flags.contains(.option) { mods.append("⌥") }
                    if flags.contains(.shift) { mods.append("⇧") }
                    if flags.contains(.command) { mods.append("⌘") }
                    let key = item.keyEquivalent.unicodeScalars.map { String(format: $0.value < 0x20 || $0.value > 0x7e ? "U+%04X" : "%@", $0.value < 0x20 || $0.value > 0x7e ? $0.value : String($0) as NSString) }.joined()
                    lines.append("\(mods.joined())\(key)\t\(path)\(item.isEnabled ? "" : "（禁用）")")
                }
                if let submenu = item.submenu { walk(submenu, prefix: path) }
            }
        }
        if let main = NSApp.mainMenu { walk(main, prefix: "") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 截图（按需调用）

    private func screenshot(_ request: ControlRequest) -> ControlResponse {
        guard let window = window(request), let view = window.contentView?.superview ?? window.contentView else {
            return .error("找不到窗口")
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return .error("无法截图") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return .error("无法编码 PNG") }
        return ControlResponse(contentType: "image/png", body: png)
    }

    // MARK: - 帮助

    private static let help = """
    Origin 调试控制接口（仅 Debug 构建，127.0.0.1）。参数可用查询串或 JSON 请求体传入。

    状态与数据
      GET  /state                         账号、侧边栏、导航栈、窗口、播放器状态
      GET  /libraries                     媒体库列表
      GET  /items?library=ID|parent=ID|search=词|resume=1|favorites=1  [&limit=30&start=0]
      GET  /item?id=ID                    条目详情与媒体源

    账号与导航
      POST /sign-in  {address, username, password}   Jellyfin / Emby / 飞牛影视
      POST /server   {id|name}                       切换当前服务器
      POST /navigate {to: home|search|downloads|favorites|servers|library, id|name}
      POST /open     {id}                            在当前栏目中打开条目详情
      POST /back     {count?, root?}
      POST /settings                                 打开设置窗口
      POST /config   {engine: auto|systemOnly|ffmpeg}   修改播放引擎设置

    播放
      POST /play   {id, resume?: true|false, source?}
      POST /player {action: toggle|forward|backward|seek|volume|rate|fullscreen|close, value?}

    通用界面操作（进程内无障碍树）
      GET  /ui?window=main|player|settings|key&filter=文字&all=1   列出元素（带序号）
      POST /press  {id|label|index, role?, window?}
      POST /click  {x, y, window?}       窗口内坐标（左上角为原点，单位为点），用于无障碍树里没有的元素
      POST /type   {text, id|label|index?, replace?, submit?}
      POST /key    {key: space|return|escape|tab|left|right|up|down|delete|字母, modifiers: "cmd,shift,option,ctrl"}
      POST /scroll {dy: -400, dx?, window?}
      GET  /wait?text=文字|id=标识|playing=1 [&gone=1&timeout=15]

    排查
      GET  /menus                         菜单项与快捷键
      GET  /input                         第一响应者与输入法上下文

    截图（只在需要看画面时调用）
      GET  /screenshot?window=main|player   应用内渲染的 PNG（不含视频与毛玻璃，仅作兜底）
      推荐：scripts/originctl shot main|player [输出路径]  按窗口编号调用系统截屏，画面真实

    说明：SwiftUI 内容的元素树需要在“系统设置 › 隐私与安全性 › 辅助功能”中允许 Origin，
    否则 /ui 只能看到侧边栏等 AppKit 控件；语义接口（navigate/open/play/player）不受影响。
    """
}
#endif
