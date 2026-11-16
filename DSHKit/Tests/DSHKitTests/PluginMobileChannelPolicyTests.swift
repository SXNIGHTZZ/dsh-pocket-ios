import XCTest
@testable import DSHKit

/// 聚合通道策略。
///
/// 这些用例锁住的是「什么时候该换通道」——判断错了会让用户看到误导性的错误：
/// 把认证失败说成「插件版本旧」，或者把版本旧说成「需要重新连接」。
final class PluginMobileChannelPolicyTests: XCTestCase {

    func testChannelsPreferCompanionPlugin() {
        // 必装插件（dsh-pocket-ios）在前，选装插件兜底。
        XCTAssertEqual(PluginMobileChannelPolicy.channels.first, "/dsh-pocket/plugins")
        XCTAssertTrue(PluginMobileChannelPolicy.channels.contains("/dsh-plugin-panel/mobile"))
        XCTAssertEqual(PluginMobileChannelPolicy.channels.count, 2)
    }

    func testChannelsHaveNoTrailingSlash() {
        // 调用方用 "\(channel)/token" 拼接，尾斜杠会拼出双斜杠。
        for channel in PluginMobileChannelPolicy.channels {
            XCTAssertTrue(channel.hasPrefix("/"), "\(channel) 应以 / 开头")
            XCTAssertFalse(channel.hasSuffix("/"), "\(channel) 不应以 / 结尾")
        }
    }

    func testFallsBackOnMissingEndpoint() {
        // 电脑端插件版本旧：路径不存在。
        XCTAssertTrue(PluginMobileChannelPolicy.shouldFallBack(statusCode: 404))
        XCTAssertTrue(PluginMobileChannelPolicy.shouldFallBack(statusCode: 405))
    }

    func testDoesNotFallBackOnAuthFailure() {
        // 认证问题换通道也一样失败，回退只会把原因说错。
        XCTAssertFalse(PluginMobileChannelPolicy.shouldFallBack(statusCode: 401))
        XCTAssertFalse(PluginMobileChannelPolicy.shouldFallBack(statusCode: 403))
    }

    func testDoesNotFallBackOnServerError() {
        // 5xx 是电脑端出错，报出来才有排查价值。
        XCTAssertFalse(PluginMobileChannelPolicy.shouldFallBack(statusCode: 500))
        XCTAssertFalse(PluginMobileChannelPolicy.shouldFallBack(statusCode: 502))
    }

    func testDoesNotFallBackOnSuccessOrRedirect() {
        XCTAssertFalse(PluginMobileChannelPolicy.shouldFallBack(statusCode: 200))
        XCTAssertFalse(PluginMobileChannelPolicy.shouldFallBack(statusCode: 302))
    }

    func testMissingAggregatorMessageIsActionable() {
        // 文案必须告诉用户「做什么」，而不只是「哪里错了」。
        let message = PluginMobileChannelPolicy.missingAggregatorMessage
        XCTAssertTrue(message.contains("dsh-pocket-ios"), "应指出要装哪个插件")
        XCTAssertTrue(message.contains("dsh plugin add"), "应给出可执行的命令")
    }
}
