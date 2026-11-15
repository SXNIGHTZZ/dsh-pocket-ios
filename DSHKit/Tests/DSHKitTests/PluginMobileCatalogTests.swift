// PluginMobileCatalogTests

import XCTest
@testable import DSHKit

/// 聚合接口响应的解析 —— 这部分以前只能靠真机验证，现在是纯逻辑单测。
///
/// 覆盖的正是 2026-11-16 踩到的两个坑：
/// ① 服务端漏 path → 整条被过滤 → 表现成「没装插件」
/// ② 服务端把不合格声明静默丢掉 → 用户看不出为什么
final class PluginMobileCatalogTests: XCTestCase {

    func testParsesValidPlugin() {
        let catalog = PluginMobileCatalog.parse([
            "version": 1,
            "plugins": [[
                "module": "dsh-plugin-panel",
                "version": 1,
                "kind": "web",
                "title": "插件",
                "path": "/dsh-plugin-panel/mobile",
            ]],
            "invalid": [],
        ])
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries.first?.module, "dsh-plugin-panel")
        XCTAssertEqual(catalog.entries.first?.manifest.path, "/dsh-plugin-panel/mobile")
        XCTAssertTrue(catalog.invalid.isEmpty)
    }

    /// 缺 path 的条目不能静默消失——要进 invalid，并能在空状态里说出来
    func testMissingPathGoesToInvalidNotDropped() {
        let catalog = PluginMobileCatalog.parse([
            "plugins": [[
                "module": "dsh-broken",
                "version": 1,
                "kind": "web",
                "title": "坏插件",
            ]],
            "invalid": [[
                "module": "dsh-broken",
                "problems": ["kind=web 但没有 path"],
            ]],
        ])
        XCTAssertTrue(catalog.entries.isEmpty)
        XCTAssertEqual(catalog.invalid.count, 1)
        XCTAssertEqual(catalog.invalid.first?.module, "dsh-broken")
    }

    func testEmptyStateExplainsInvalid() {
        let catalog = PluginMobileCatalog.parse([
            "plugins": [Any](),
            "invalid": [["module": "dsh-broken", "problems": ["kind=web 但没有 path"]]],
        ])
        let message = catalog.emptyStateMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.title.contains("dsh-broken") ?? false)
        XCTAssertTrue(message?.detail.contains("path") ?? false)
    }

    func testEmptyStateNilWhenNothingDeclared() {
        let catalog = PluginMobileCatalog.parse(["plugins": [Any](), "invalid": [Any]()])
        XCTAssertNil(catalog.emptyStateMessage, "真的没有插件声明时不该报错")
    }

    func testGarbageDegradesGracefully() {
        XCTAssertTrue(PluginMobileCatalog.parse(nil).entries.isEmpty)
        XCTAssertTrue(PluginMobileCatalog.parse("not a dict").entries.isEmpty)
        XCTAssertTrue(PluginMobileCatalog.parse(["plugins": "oops"]).entries.isEmpty)
    }

    /// 多插件时 invalid 与 entries 互不干扰
    func testMixedValidAndInvalid() {
        let catalog = PluginMobileCatalog.parse([
            "plugins": [
                ["module": "good", "version": 1, "kind": "web", "title": "好", "path": "/good"],
            ],
            "invalid": [
                ["module": "bad", "problems": ["缺少 title"]],
            ],
        ])
        XCTAssertEqual(catalog.entries.map(\.module), ["good"])
        XCTAssertEqual(catalog.invalid.map(\.module), ["bad"])
    }
}
