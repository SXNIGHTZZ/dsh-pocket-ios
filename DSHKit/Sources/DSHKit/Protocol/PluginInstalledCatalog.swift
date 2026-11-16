import Foundation

/// 原生列表用的已装插件条目。
///
/// 和 `PluginMobileEntry` 的区别：那条是「这个插件声明了手机端页面」，只有三五个；
/// 这条是「电脑上装了什么」，全部都在——原生列表要能给任意插件开关。
public struct PluginInstalledEntry: Equatable, Sendable, Identifiable {
    public let module: String
    public let title: String
    public let version: String
    public let summary: String
    /// **配置上**是否启用（Loader enablement）。开关拨的就是这个。
    public let enabled: Bool
    /// **实际运行阶段**。`enabled == true` 不代表在跑：
    /// 加载失败时 enabled 仍是 true，但 fiberPhase 会给出失败态。
    /// 服务端取自 DSH 的 `PluginInventoryEntry.fiberPhase`。
    public let fiberPhase: String
    /// 启动失败的诊断信息（`fiberPhase` 失败时才有值）。
    public let diagnostic: String
    /// 非空表示这个条目不能让手机改（受管理 / 不可寻址），开关要禁用。
    public let readOnlyReason: String
    /// 有值才显示「打开」按钮；没有说明这个插件没有手机端页面。
    public let mobilePath: String?

    public var id: String { module }
    /// 能不能点「打开」。
    public var canOpen: Bool { mobilePath != nil }
    /// 能不能改开关。
    public var canToggle: Bool { readOnlyReason.isEmpty }

    /// 运行阶段的人话（**只看 fiberPhase，不看 enabled**）。
    /// 「未启用」由 UI 按开关的**当前**值判断——用这里的 enabled 会停在旧数据上：
    /// 用户刚拨开开关、服务端还没返回新状态时，会错误地继续显示「未启用」。
    public var runStateLabel: String {
        switch fiberPhase {
        case "": return ""
        case "active", "ready", "running": return "运行中"
        case "failed", "error": return "加载失败"
        case "pending", "loading": return "加载中"
        case "disposed", "inactive", "stopped": return "已停止"
        default: return fiberPhase
        }
    }

    public init(
        module: String,
        title: String,
        version: String,
        summary: String,
        enabled: Bool,
        fiberPhase: String = "",
        diagnostic: String = "",
        readOnlyReason: String = "",
        mobilePath: String?
    ) {
        self.module = module
        self.title = title
        self.version = version
        self.summary = summary
        self.enabled = enabled
        self.fiberPhase = fiberPhase
        self.diagnostic = diagnostic
        self.readOnlyReason = readOnlyReason
        self.mobilePath = mobilePath
    }
}

/// `/dsh-pocket/plugins/installed` 的响应。
public struct PluginInstalledCatalog: Equatable, Sendable {
    public let plugins: [PluginInstalledEntry]

    public var isEmpty: Bool { plugins.isEmpty }

    /// 有手机页面的那些——用来回答「这台电脑上能用手机打开几个插件」。
    public var openablePlugins: [PluginInstalledEntry] { plugins.filter(\.canOpen) }

    public init(plugins: [PluginInstalledEntry]) {
        self.plugins = plugins
    }

    /// 解析。字段缺失按「安全默认」处理，不整条丢弃——
    /// 少一个字段就丢掉整个插件，用户会以为插件没装。
    public static func parse(_ raw: Any?) -> PluginInstalledCatalog {
        guard let object = raw as? [String: Any],
              let rows = object["plugins"] as? [[String: Any]] else {
            return PluginInstalledCatalog(plugins: [])
        }
        let plugins = rows.compactMap { row -> PluginInstalledEntry? in
            guard let module = (row["module"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !module.isEmpty else { return nil }
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let version = (row["version"] as? String) ?? ""
            let summary = (row["description"] as? String) ?? ""
            // enabled 缺省当 true：宁可让用户看到「已启用」，也不要误显示成关闭。
            let enabled = (row["enabled"] as? Bool) ?? true
            // 运行状态与只读标记：老服务端不返回，缺省空串 = 不显示。
            let fiberPhase = (row["fiberPhase"] as? String) ?? ""
            let diagnostic = (row["diagnostic"] as? String) ?? ""
            let readOnly = (row["readOnlyReason"] as? String) ?? ""
            let path = (row["mobilePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PluginInstalledEntry(
                module: module,
                title: title.isEmpty ? module : title,
                version: version,
                summary: summary,
                enabled: enabled,
                fiberPhase: fiberPhase,
                diagnostic: diagnostic,
                readOnlyReason: readOnly,
                mobilePath: (path?.isEmpty == false) ? path : nil
            )
        }
        return PluginInstalledCatalog(plugins: plugins)
    }
}
