import XCTest

/// 使用 Jellyfin 官方演示服务器走一遍核心流程：添加服务器 → 首页 → 媒体库 → 详情 → 播放
@MainActor
final class DemoServerFlowTests: XCTestCase {
    private let app = XCUIApplication()
    private let outputDirectory = URL(fileURLWithPath: "/tmp/origin_ui", isDirectory: true)

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

    func testDemoServerFlow() throws {
        app.launch()

        let addButton = app.buttons["添加媒体服务器"]
        if addButton.waitForExistence(timeout: 5) {
            snapshot("01-welcome")
            addButton.tap()
            app.buttons["manual-account"].tap()
            let address = app.textFields["server-address"]
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            address.tap()
            address.typeText("https://demo.jellyfin.org/stable")
            let username = app.textFields["username"]
            username.tap()
            username.typeText("demo")
            snapshot("02-add-server")
            app.buttons["连接"].tap()
        }

        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 30))
        sleep(6)
        snapshot("03-home")

        app.tabBars.buttons["媒体库"].tap()
        let movies = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Movies'")).firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: 20))
        sleep(2)
        snapshot("05-libraries")
        movies.tap()
        sleep(5)
        snapshot("06-movies-grid")

        let firstPoster = app.scrollViews.buttons.element(boundBy: 0)
        XCTAssertTrue(firstPoster.waitForExistence(timeout: 10))
        firstPoster.tap()
        sleep(5)
        snapshot("07-detail")
        app.swipeUp()
        sleep(2)
        snapshot("08-detail-scrolled")
        app.swipeDown()
        sleep(1)

        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '播放' OR label BEGINSWITH '继续'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        sleep(10)
        snapshot("09-player")
        // 等控制栏自动隐藏后，点击不含按钮的区域唤出
        sleep(6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        sleep(1)
        snapshot("10-player-controls")
    }
}
