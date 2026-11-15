// PluginMobileManifest

import Foundation

/// 插件在 `package.json` 里对移动端的声明（协议 v1，见 spec/2026-11-16-0600）。
///
/// 为什么解析放在 DSHKit 而不是 App 层：这段逻辑纯数据、可单测，
/// 而 App 层没有测试 target（详见 spec 的测试计划）。
///
/// 协议要点：
/// - `version` 必填；大于 App 当前认识的版本时**降级**而不是崩（新插件撞旧 App 是常态）
/// - `kind` 二选一：`web` 走 WebView（`path` 必须有），`native` 走 Schema（`schema` 必须有）
/// - 任何必填缺失都判为「声明无效」，App 忽略这个插件而不是崩
public struct PluginMobileManifest: Equatable, Sendable {

    /// App 当前支持的最高协议版本。
    public static let supportedVersion = 1

    public enum Kind: String, Equatable, Sendable {
        case native
        case web
    }

    public let version: Int
    public let kind: Kind
    public let title: String
    public let icon: String?
    /// `kind == .web` 时必填：移动版页面的路径（相对连接地址）。
    public let path: String?
    /// `kind == .native` 时必填：返回 Schema JSON 的路径。
    public let schema: String?

    /// 解析结果。`absent` = 插件没声明移动端（正常，绝大多数插件如此）。
    public enum ParseResult: Equatable, Sendable {
        case ok(PluginMobileManifest)
        case unsupported(reason: String)
        case absent
    }

    /// 从 `package.json` 里 `dsh.mobile` 那段原始字典解析。
    ///
    /// 入参是 `[String: Any]?`——取不到就打 `absent`，不视作错误：
    /// 189 个插件里只有 28 个有 client UI，声明移动端的会更少。
    public static func parse(_ raw: [String: Any]?) -> ParseResult {
        guard let raw else { return .absent }

        guard let version = intValue(raw["version"]) else {
            return .unsupported(reason: "缺 version")
        }
        // 新版插件可能用 App 不认识的协议：记录并忽略，不要当成坏插件
        guard version <= supportedVersion else {
            return .unsupported(reason: "协议版本 \(version) 高于 App 支持的 \(supportedVersion)")
        }
        guard let kindRaw = raw["kind"] as? String,
              let kind = Kind(rawValue: kindRaw.trimmingCharacters(in: .whitespaces)) else {
            return .unsupported(reason: "kind 缺失或非法")
        }
        let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            return .unsupported(reason: "缺 title")
        }
        let icon = nonEmptyString(raw["icon"])
        let path = nonEmptyString(raw["path"])
        let schema = nonEmptyString(raw["schema"])

        switch kind {
        case .web:
            guard let path else { return .unsupported(reason: "kind=web 但缺 path") }
            return .ok(.init(version: version, kind: kind, title: title, icon: icon, path: path, schema: nil))
        case .native:
            guard let schema else { return .unsupported(reason: "kind=native 但缺 schema") }
            return .ok(.init(version: version, kind: kind, title: title, icon: icon, path: nil, schema: schema))
        }
    }

    // MARK: - 兼容各种 JSON 数字表示

    /// `JSONSerialization` 会把同一段 JSON 里的整数读成 `Int` / `NSNumber` / `Double`，
    /// 不做归一化会出现「同样的 manifest 有时解析成功有时失败」。
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let double as Double: return Int(double)
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

/// 插件声明的移动端页面在 App 里的一次呈现。
///
/// `module` 是插件包名，用来去重和打诊断；`title` 是按钮/面板标题。
public struct PluginMobileEntry: Equatable, Sendable, Identifiable {
    public let module: String
    public let manifest: PluginMobileManifest

    public var id: String { module }
    public var title: String { manifest.title }

    public init(module: String, manifest: PluginMobileManifest) {
        self.module = module
        self.manifest = manifest
    }

    /// 从聚合接口的单个条目解析。
    /// 接口返回的形状见 spec：`{ module, title, kind, version, icon, path?, schema? }`
    public static func parse(_ raw: [String: Any]) -> PluginMobileEntry? {
        guard let module = (raw["module"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !module.isEmpty else { return nil }
        guard case .ok(let manifest) = PluginMobileManifest.parse(raw) else { return nil }
        return PluginMobileEntry(module: module, manifest: manifest)
    }
}
