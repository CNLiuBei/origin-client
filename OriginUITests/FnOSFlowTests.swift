import XCTest

/// 飞牛影视（飞牛私有云）核心流程。地址与账号通过环境变量传入，避免写进源码：
/// TEST_RUNNER_FNOS_ADDRESS / TEST_RUNNER_FNOS_USERNAME / TEST_RUNNER_FNOS_PASSWORD
@MainActor
final class FnOSFlowTests: XCTestCase {
    private let app = XCUIApplication()
    private let outputDirectory = URL(fileURLWithPath: "/tmp/origin_fnos", isDirectory: true)
    private let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: outputDirectory.appending(path: "\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEpisodeCards() throws {
        try signIn()
        openLibraries()
        let tvLibrary = app.buttons.matching(NSPredicate(format: "label CONTAINS '国产剧'")).firstMatch
        XCTAssertTrue(tvLibrary.waitForExistence(timeout: 20))
        tvLibrary.tap()
        let show = app.scrollViews.buttons.matching(NSPredicate(format: "label CONTAINS '兰香如故'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        sleep(5)
        app.swipeUp()
        sleep(2)
        snapshot("11-episode-cards")

        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '第 ' AND label CONTAINS '集'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        let screen = app.windows.firstMatch.frame
        let visible = cards.allElementsBoundByIndex.first { screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        XCTAssertNotNil(visible, "没有可见的单集卡片")
        visible?.tap()
        sleep(10)
        snapshot("12-episode-playing")

        // 横着拿手机看完再关闭播放器，界面应转回竖屏
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        app.tap()
        let close = app.buttons["关闭播放器"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        sleep(3)
        snapshot("20-after-player")
        let frame = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = .portrait
        XCTAssertLessThan(frame.width, frame.height, "关闭播放器后界面仍是横屏")
    }

    func testSeasonMenu() throws {
        try signIn()
        openLibraries()
        let library = app.buttons.matching(NSPredicate(format: "label CONTAINS '欧美剧'")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let show = app.scrollViews.buttons.matching(NSPredicate(format: "label CONTAINS '绝命毒师'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        sleep(5)
        app.swipeUp()
        sleep(2)
        snapshot("13-seasons")

        let seasonButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '轻点切换'")).firstMatch
        XCTAssertTrue(seasonButton.waitForExistence(timeout: 5))
        seasonButton.tap()
        sleep(1)
        snapshot("14-season-menu")
        let season2 = app.buttons.matching(NSPredicate(format: "label CONTAINS '第 2 季'")).firstMatch
        XCTAssertTrue(season2.waitForExistence(timeout: 5))
        season2.tap()
        sleep(3)
        snapshot("15-season-2")

        // 详情页隐藏了底部标签栏；系统返回按钮与左边缘右滑都能回到列表
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        snapshot("19-detail-top")
        let libraryTab = app.tabBars.buttons["媒体库"]
        XCTAssertFalse(libraryTab.exists && libraryTab.isHittable, "详情页不应显示底部标签栏")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()
        sleep(3)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(1)
        XCTAssertTrue(show.waitForExistence(timeout: 5), "边缘右滑没有返回")
    }

    /// 首页各分区截图：海报轮播、继续观看、我的媒体、媒体库分区
    func testHomeLayout() throws {
        try signIn()
        sleep(6)
        snapshot("16-home-top")
        app.swipeUp()
        sleep(2)
        snapshot("17-home-shelves")
        app.swipeUp()
        sleep(2)
        snapshot("18-home-libraries")
    }

    /// 首页与详情页滑动时的掉帧（hitch）指标
    func testHomeScrollPerformance() throws {
        try signIn()
        sleep(6)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func testDetailScrollPerformance() throws {
        try signIn()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        openLibraries()
        let library = app.buttons.matching(NSPredicate(format: "label CONTAINS '欧美剧'")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let show = app.scrollViews.buttons.matching(NSPredicate(format: "label CONTAINS '绝命毒师'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        sleep(5)
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    /// 轮播翻页过程中连续截图，用于检查背景是否闪白
    func testHeroTransition() throws {
        try signIn()
        sleep(8)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.35)))
        for index in 0..<10 {
            snapshot(String(format: "hero-%02d", index))
        }
    }

    func testFnOSFlow() throws {
        try signIn()
        try browseAndPlay()
    }

    /// 标签栏可能处于滚动后的缩小状态，先展开再切到媒体库
    private func openLibraries() {
        let tab = app.tabBars.buttons["媒体库"]
        if !tab.waitForExistence(timeout: 3) { app.tabBars.buttons.firstMatch.tap() }
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }

    private func signIn() throws {
        guard let address = env["FNOS_ADDRESS"], let user = env["FNOS_USERNAME"], let password = env["FNOS_PASSWORD"] else {
            throw XCTSkip("未提供飞牛服务器信息")
        }
        app.launch()
        if app.tabBars.buttons["首页"].waitForExistence(timeout: 3) { return }

        let addButton = app.buttons["添加媒体服务器"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "需要从未添加服务器的状态开始")
        addButton.tap()
        app.buttons["manual-fnos"].tap()
        let addressField = app.textFields["server-host"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        addressField.tap()
        addressField.typeText(address)
        let username = app.textFields["username"]
        username.tap()
        username.typeText(user)
        let passwordField = app.secureTextFields["password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["连接"].tap()

        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 30))
        // 系统“保存密码？”弹窗
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for later in [app.buttons["以后"], springboard.buttons["以后"]] where later.waitForExistence(timeout: 4) {
            later.tap()
            break
        }
        sleep(6)
        snapshot("01-home")
    }

    private func browseAndPlay() throws {
        // 剧集：媒体库 → 国产剧 → 第一部剧 → 季与分集
        app.tabBars.buttons["媒体库"].tap()
        let tvLibrary = app.buttons.matching(NSPredicate(format: "label CONTAINS '国产剧'")).firstMatch
        XCTAssertTrue(tvLibrary.waitForExistence(timeout: 20))
        sleep(2)
        snapshot("02-libraries")
        tvLibrary.tap()
        sleep(4)
        snapshot("03-tv-grid")
        let firstShow = app.scrollViews.buttons.element(boundBy: 0)
        XCTAssertTrue(firstShow.waitForExistence(timeout: 10))
        firstShow.tap()
        sleep(5)
        snapshot("04-series-detail")
        app.swipeUp()
        sleep(2)
        snapshot("05-series-episodes")

        // 电影：外语电影 → 蝙蝠侠（MKV，4K HEVC + DTS）→ 播放
        app.tabBars.buttons["媒体库"].tap()
        app.tabBars.buttons["媒体库"].tap()
        let movieLibrary = app.buttons.matching(NSPredicate(format: "label CONTAINS '外语电影'")).firstMatch
        XCTAssertTrue(movieLibrary.waitForExistence(timeout: 10))
        movieLibrary.tap()
        sleep(4)
        snapshot("06-movies-grid")
        let movie = app.scrollViews.buttons.matching(NSPredicate(format: "label CONTAINS '黑暗骑士崛起'")).firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
        movie.tap()
        sleep(5)
        snapshot("07-movie-detail")
        app.swipeUp()
        sleep(2)
        snapshot("08-movie-detail-scrolled")
        app.swipeDown()
        sleep(1)

        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '播放' OR label BEGINSWITH '继续'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        sleep(12)
        snapshot("09-player")
        sleep(6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        sleep(1)
        snapshot("10-player-controls")
    }
}
