import Foundation

/// 插件移动端「聚合通道」的选择策略。
///
/// 背景：手机要打开插件面板，先得从电脑换一个 5 分钟 token 并拉插件清单。
/// 这个能力有过两个提供者：
///
/// - `dsh-plugin-panel`（选装插件，1.0.9 及更早只认它）
/// - `dsh-pocket-ios`（必装插件，0.7.0 起自己提供）
///
/// 放在 DSHKit 而不是 App 里，是为了能单测——App target 没有测试 target。
public enum PluginMobileChannelPolicy {

    /// 按优先级排列的通道前缀（不含尾斜杠）。
    ///
    /// 新通道在前：它来自必装插件，用户不会缺；老通道在后兜底，
    /// 让「电脑端插件还没升级」的用户不退化。
    public static let channels: [String] = [
        "/dsh-pocket/plugins",
        "/dsh-plugin-panel/mobile",
    ]

    /// 该不该换下一个通道重试。
    ///
    /// **只在「端点根本不存在」时回退**：
    /// - 404：这台电脑上的插件版本旧，没有新通道
    /// - 405：路径存在但方法不对（同样说明版本不匹配）
    ///
    /// **401/403 不回退**：那是认证问题，换通道一样失败，
    /// 换过去只会把「需要重新连接」误报成「插件版本旧」。
    /// 5xx 也不回退：那是电脑端出错，报出来才有排查价值。
    public static func shouldFallBack(statusCode: Int) -> Bool {
        statusCode == 404 || statusCode == 405
    }

    /// 所有通道都不支持时，给用户一句能照着做的提示。
    ///
    /// 这个文案是「可操作性」的唯一保障：早先这里直接抛 HTTP 404，
    /// 用户看不出该装什么、该更新什么。
    public static let missingAggregatorMessage =
        "电脑上的 DSH 需要更新：运行 dsh plugin add dsh-pocket-ios 后重启 DSH。"
}
