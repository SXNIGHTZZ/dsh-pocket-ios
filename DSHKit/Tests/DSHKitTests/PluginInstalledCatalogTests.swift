import XCTest
@testable import DSHKit

/// 原生插件列表的数据解析。
///
/// 这些用例锁的是「字段缺失时不能把插件丢掉」——少一个 description 就吞掉整条，
/// 用户会以为插件没装，比显示一个空简介糟得多。
final class PluginInstalledCatalogTests: XCTestCase {

    private func payload(_ rows: [[String: Any]]) -> [String: Any] {
        ["version": 1, "plugins": rows]
    }

    func testParsesFullRow() {
        let catalog = PluginInstalledCatalog.parse(payload([[
            "module": "dsh-audio-parse",
            "title": "音频解析",
            "version": "0.0.1",
            "description": "产出节奏档案",
            "enabled": true,
            "mobilePath": "/dsh-audio-parse/mobile",
        ]]))
        XCTAssertEqual(catalog.plugins.count, 1)
        let entry = catalog.plugins[0]
        XCTAssertEqual(entry.module, "dsh-audio-parse")
        XCTAssertEqual(entry.title, "音频解析")
        XCTAssertEqual(entry.version, "0.0.1")
        XCTAssertEqual(entry.summary, "产出节奏档案")
        XCTAssertTrue(entry.enabled)
        XCTAssertTrue(entry.canOpen)
    }

    func testMissingOptionalFieldsStillKeepsEntry() {
        // 只有 module：其余字段都缺，但这条必须留下。
        let catalog = PluginInstalledCatalog.parse(payload([["module": "only-module"]]))
        XCTAssertEqual(catalog.plugins.count, 1)
        let entry = catalog.plugins[0]
        XCTAssertEqual(entry.title, "only-module", "标题缺失时回退包名，不能显示空白")
        XCTAssertEqual(entry.summary, "")
        XCTAssertTrue(entry.enabled, "enabled 缺省当启用，不能误显示成关闭")
        XCTAssertFalse(entry.canOpen, "没有 mobilePath 就不能打开")
    }

    func testDisabledPluginParsesAsDisabled() {
        let catalog = PluginInstalledCatalog.parse(payload([[
            "module": "off-plugin", "enabled": false,
        ]]))
        XCTAssertEqual(catalog.plugins.first?.enabled, false)
    }

    func testEmptyMobilePathIsTreatedAsMissing() {
        // 后端偶尔给空串，别渲染出一个点了没反应的「打开」。
        let catalog = PluginInstalledCatalog.parse(payload([[
            "module": "m", "mobilePath": "",
        ]]))
        XCTAssertNil(catalog.plugins.first?.mobilePath)
        XCTAssertFalse(catalog.plugins.first?.canOpen ?? true)
    }

    func testRowWithoutModuleIsDropped() {
        // module 是唯一标识，没有它这条没法开关也没法打开。
        let catalog = PluginInstalledCatalog.parse(payload([
            ["title": "没有包名"],
            ["module": "ok"],
        ]))
        XCTAssertEqual(catalog.plugins.map(\.module), ["ok"])
    }

    func testOpenablePluginsFiltersToThoseWithPages() {
        let catalog = PluginInstalledCatalog.parse(payload([
            ["module": "a", "mobilePath": "/a/mobile"],
            ["module": "b"],
            ["module": "c", "mobilePath": "/c/mobile"],
        ]))
        XCTAssertEqual(catalog.openablePlugins.map(\.module), ["a", "c"])
    }

    func testParseRejectsMalformedPayload() {
        XCTAssertTrue(PluginInstalledCatalog.parse(nil).isEmpty)
        XCTAssertTrue(PluginInstalledCatalog.parse(["nope": 1]).isEmpty)
        XCTAssertTrue(PluginInstalledCatalog.parse(["plugins": "not-an-array"]).isEmpty)
    }
}
