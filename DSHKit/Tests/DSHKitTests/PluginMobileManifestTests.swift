// PluginMobileManifestTests

import XCTest
@testable import DSHKit

/// 协议 v1 的解析约束（spec/2026-11-16-0600 的测试计划）。
///
/// 这些用例的共同前提：**任何畸形声明都不能让 App 崩溃**——
/// 插件由第三方发布，App 必须假设 manifest 可能残缺、可能是未来版本。
final class PluginMobileManifestTests: XCTestCase {

    func testAbsentWhenNoDeclaration() {
        XCTAssertEqual(PluginMobileManifest.parse(nil), .absent)
    }

    func testWebKindParses() {
        let result = PluginMobileManifest.parse([
            "version": 1,
            "kind": "web",
            "title": "插件",
            "path": "/dsh-plugin-panel/mobile",
        ])
        guard case .ok(let manifest) = result else {
            return XCTFail("应当解析成功，实际 \(result)")
        }
        XCTAssertEqual(manifest.kind, .web)
        XCTAssertEqual(manifest.title, "插件")
        XCTAssertEqual(manifest.path, "/dsh-plugin-panel/mobile")
        XCTAssertNil(manifest.schema)
    }

    func testNativeKindParses() {
        let result = PluginMobileManifest.parse([
            "version": 1,
            "kind": "native",
            "title": "知识树",
            "schema": "/parse-tree/mobile/schema",
        ])
        guard case .ok(let manifest) = result else {
            return XCTFail("应当解析成功，实际 \(result)")
        }
        XCTAssertEqual(manifest.kind, .native)
        XCTAssertEqual(manifest.schema, "/parse-tree/mobile/schema")
        XCTAssertNil(manifest.path)
    }

    /// 缺 version 属于「声明无效」，不是 absent——absent 专指「根本没声明」。
    func testMissingVersionIsUnsupported() {
        let result = PluginMobileManifest.parse(["kind": "web", "title": "x", "path": "/m"])
        guard case .unsupported = result else {
            return XCTFail("应当判为 unsupported，实际 \(result)")
        }
    }

    /// 未来版本的插件撞上旧 App：降级忽略，不能崩。
    func testFutureVersionIsUnsupportedNotCrash() {
        let result = PluginMobileManifest.parse([
            "version": 99, "kind": "native", "title": "未来", "schema": "/s",
        ])
        guard case .unsupported(let reason) = result else {
            return XCTFail("应当判为 unsupported，实际 \(result)")
        }
        XCTAssertTrue(reason.contains("99"), "原因里应带上版本号，便于排查：\(reason)")
    }

    func testWebWithoutPathIsUnsupported() {
        let result = PluginMobileManifest.parse(["version": 1, "kind": "web", "title": "x"])
        guard case .unsupported = result else {
            return XCTFail("缺 path 应当判为 unsupported，实际 \(result)")
        }
    }

    func testNativeWithoutSchemaIsUnsupported() {
        let result = PluginMobileManifest.parse(["version": 1, "kind": "native", "title": "x"])
        guard case .unsupported = result else {
            return XCTFail("缺 schema 应当判为 unsupported，实际 \(result)")
        }
    }

    func testEmptyTitleIsUnsupported() {
        let result = PluginMobileManifest.parse([
            "version": 1, "kind": "web", "title": "   ", "path": "/m",
        ])
        guard case .unsupported = result else {
            return XCTFail("空白 title 应当判为 unsupported，实际 \(result)")
        }
    }

    func testUnknownKindIsUnsupported() {
        let result = PluginMobileManifest.parse([
            "version": 1, "kind": "hologram", "title": "x", "path": "/m",
        ])
        guard case .unsupported = result else {
            return XCTFail("未知 kind 应当判为 unsupported，实际 \(result)")
        }
    }

    /// JSONSerialization 可能把整数读成 NSNumber / Double，解析要归一化。
    func testVersionNumberNormalization() {
        let asDouble: [String: Any] = [
            "version": 1.0 as Double, "kind": "web", "title": "x", "path": "/m",
        ]
        guard case .ok = PluginMobileManifest.parse(asDouble) else {
            return XCTFail("1.0 这种 Double 形式也应当接受")
        }
    }

    // MARK: - 聚合条目

    func testEntryParsesFromAggregatedShape() {
        let entry = PluginMobileEntry.parse([
            "module": "dsh-plugin-panel",
            "version": 1,
            "kind": "web",
            "title": "插件",
            "path": "/dsh-plugin-panel/mobile",
        ])
        XCTAssertEqual(entry?.module, "dsh-plugin-panel")
        XCTAssertEqual(entry?.title, "插件")
    }

    func testEntryRequiresModule() {
        XCTAssertNil(PluginMobileEntry.parse([
            "version": 1, "kind": "web", "title": "x", "path": "/m",
        ]))
    }
}
