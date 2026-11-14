import XCTest

/// 使用 Jellyfin 官方演示服务器走一遍 Mac 端核心流程：添加服务器 → 首页 → 媒体库 → 详情 → 播放窗口 → 设置
@MainActor
final class MacDemoFlowTests: XCTestCase {
    private let app = XCUIApplication()
    private let outputDirectory = URL(fileURLWithPath: "/tmp/origin_mac", isDirectory: true)

    override func setUp() async throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func snapshot(_ name: String, window: XCUIElement? = nil) {
        let shot = (window ?? app.windows.firstMatch).screenshot()
        try? shot.pngRepresentation.write(to: outputDirectory.appending(path: "\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func signInIfNeeded() {
        let addButton = app.buttons["添加媒体服务器"]
        guard addButton.waitForExistence(timeout: 5) else { return }
        snapshot("01-welcome")
        addButton.click()
        let manual = app.descendants(matching: .any)["manual-jellyfin"].firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        sleep(1)
        snapshot("02-add-server")
        manual.click()
        let address = app.textFields["server-host"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click()
        address.typeText("https://demo.jellyfin.org/stable\r")
        let username = app.textFields["username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        app.typeText("demo")
        sleep(3)
        snapshot("03-login")
        app.buttons["连接"].firstMatch.click()
    }

    func testMacDemoFlow() throws {
        app.launch()
        signInIfNeeded()

        let home = app.outlines.staticTexts["首页"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        sleep(8)
        snapshot("04-home")

        let movies = app.outlines.staticTexts["Movies"].firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: 20))
        movies.click()
        sleep(6)
        snapshot("05-movies-grid")

        let firstPoster = app.scrollViews.buttons.element(boundBy: 0)
        XCTAssertTrue(firstPoster.waitForExistence(timeout: 10))
        firstPoster.click()
        sleep(6)
        snapshot("06-detail")
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
        sleep(2)
        snapshot("07-detail-scrolled")
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 600)
        sleep(1)

        app.outlines.staticTexts["搜索"].firstMatch.click()
        sleep(2)
        snapshot("08-search")

        app.outlines.staticTexts["Movies"].firstMatch.click()
        sleep(3)
        app.scrollViews.buttons.element(boundBy: 0).click()
        sleep(4)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '播放' OR label BEGINSWITH '继续'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.click()
        let playerWindow = app.windows["播放器"].firstMatch
        _ = playerWindow.waitForExistence(timeout: 20)
        sleep(10)
        snapshot("09-player", window: app.windows.element(boundBy: 0))
        app.windows.element(boundBy: 0).hover()
        sleep(1)
        snapshot("10-player-controls", window: app.windows.element(boundBy: 0))
        app.typeKey("w", modifierFlags: [.command, .shift])
        sleep(2)

        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        snapshot("11-settings", window: app.windows.element(boundBy: 0))
    }
}
