import XCTest

/// 手机端插件面板：**连真实 DSH** 的端到端验证。
///
/// 为什么不用 Demo 模式跑：Demo 是内置假数据，不联网，看不到真实插件列表——
/// 这一层要验证的正是「从电脑拿插件清单并渲染成原生列表」。
///
/// 需要环境变量（跑法见脚本 scripts/run-plugin-ui-test.sh）：
/// - `DSH_TEST_SERVER` 电脑地址，如 http://172.20.10.9:3091
/// - `DSH_TEST_PIN`    访问密码（~/.dsh/dsh-pocket-ios/pin）
///
/// 缺任一个就 skip，而不是失败——避免在没配环境的机器上红。
final class PluginPanelUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func env(_ key: String) -> String {
        (ProcessInfo.processInfo.environment[key] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testPluginPanelListsInstalledPlugins() throws {
        let server = env("DSH_TEST_SERVER")
        let pin = env("DSH_TEST_PIN")
        if server.isEmpty {
            // 诊断：把看到的 DSH_/TEST_ 变量名打出来，便于排查环境变量为什么没传到。
            let relevant = ProcessInfo.processInfo.environment.keys
                .filter { $0.hasPrefix("DSH") || $0.hasPrefix("TEST") }
                .sorted()
            try XCTSkipIf(true, "没有 DSH_TEST_SERVER；可见变量：\(relevant.joined(separator: ","))")
        }
        try XCTSkipIf(pin.isEmpty, "没有 DSH_TEST_PIN，跳过真实环境 UI 测试")

        let app = XCUIApplication()
        app.launchEnvironment["DSH_RESET"] = "1"
        app.launch()

        // ① 连接
        let address = app.textFields["connect-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20), "地址输入框未出现")
        address.tap()
        // 全选清空已有内容，再输入
        address.press(forDuration: 1.2)
        if app.menuItems["全选"].waitForExistence(timeout: 1) {
            app.menuItems["全选"].tap()
        }
        address.typeText(server)

        let pinField = app.textFields["connect-pin"].exists
            ? app.textFields["connect-pin"]
            : app.secureTextFields["connect-pin"]
        if pinField.waitForExistence(timeout: 5) {
            pinField.tap()
            pinField.typeText(pin)
        }

        let connect = app.buttons["连接"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "连接按钮未出现")
        connect.tap()

        // ② 进到对话页（出现插件按钮）
        let pluginButton = app.buttons["plugin-button"]
        XCTAssertTrue(
            pluginButton.waitForExistence(timeout: 40),
            "连接后没出现插件按钮——检查地址/密码是否有效"
        )

        // ③ 打开插件面板
        pluginButton.tap()

        // ④ 原生列表必须有内容，且带开关
        //    用一个已知会出现的插件名断言，说明数据确实来自电脑。
        let anyPlugin = app.staticTexts["音频解析"]
        XCTAssertTrue(
            anyPlugin.waitForExistence(timeout: 30),
            "插件列表里没有「音频解析」——原生列表可能没拿到数据"
        )

        let switches = app.switches
        XCTAssertGreaterThan(switches.count, 0, "列表里没有开关控件")

        // ⑤ 截图留证（附到测试报告里，方便回看视觉）
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "插件原生列表"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
