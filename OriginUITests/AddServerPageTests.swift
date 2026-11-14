import XCTest

/// 添加服务器页：局域网发现、端口自动补全、错误提示与登录。
/// 需要局域网里有飞牛影视，账号通过 TEST_RUNNER_FNOS_USERNAME / TEST_RUNNER_FNOS_PASSWORD 传入，
/// TEST_RUNNER_FNOS_HOST 为不带端口的地址（如 10.10.10.10）。
@MainActor
final class AddServerPageTests: XCTestCase {
    private let app = XCUIApplication()
    private let outputDirectory = URL(fileURLWithPath: "/tmp/origin_add", isDirectory: true)
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

    private func clear(_ element: XCUIElement, count: Int) {
        element.tap()
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
    }

    func testAddServerPage() throws {
        guard let host = env["FNOS_HOST"], let user = env["FNOS_USERNAME"], let password = env["FNOS_PASSWORD"] else {
            throw XCTSkip("未提供飞牛服务器信息")
        }
        app.launch()
        let addButton = app.buttons["添加媒体服务器"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "需要从未添加服务器的状态开始")
        addButton.tap()

        // 局域网发现
        let nearby = app.buttons.matching(NSPredicate(format: "label CONTAINS '飞牛影视 ·'")).firstMatch
        XCTAssertTrue(nearby.waitForExistence(timeout: 10), "没有发现局域网里的飞牛影视")
        sleep(1)
        snapshot("01-sources")

        // 手动添加：飞牛默认端口 8005，地址栏与服务配置一致
        app.buttons["manual-fnos"].tap()
        let address = app.textFields["server-host"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        let port = app.textFields["server-port"]
        XCTAssertEqual(port.value as? String, "8005")
        address.tap()
        address.typeText(host)
        snapshot("02-manual-port-detected")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 附近的服务器：只需填账号密码
        XCTAssertTrue(nearby.waitForExistence(timeout: 5))
        nearby.tap()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["server-address"].exists)
        sleep(1)
        snapshot("03-discovered-login")

        // 错误密码
        app.textFields["username"].typeText(user)
        let passwordField = app.secureTextFields["password"]
        passwordField.tap()
        passwordField.typeText("wrong-password\n")
        XCTAssertTrue(app.staticTexts["用户名或密码错误"].waitForExistence(timeout: 10))
        snapshot("04-wrong-password")

        // 正确登录
        clear(passwordField, count: 20)
        passwordField.typeText(password)
        app.buttons["连接"].tap()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 30))
    }
}
