import Foundation

/// 实时流的时序参数与假死判定。
///
/// 为什么要集中：这些数字散在 follow 循环里，改一个要读 130 行；
/// 而且「生成中 25 秒无帧就主动重连」是踩过的坑（公网隧道会假死），
/// 写在循环里无法测试，也就无法防止有人顺手把它调成 60 秒。
public enum LiveStreamPolicy {
    /// 心跳间隔：定期 ping，避免中间层回收空闲连接。
    public static let heartbeatInterval: Duration = .seconds(25)
    /// 生成中允许的最长静默：超过即认定假死，主动断开重连。
    public static let runningIdleTimeout: Duration = .seconds(25)
    /// **空闲时**允许的最长静默：超过也判定假死并重连。
    ///
    /// 为什么空闲也要判：公网隧道/中间层回收空闲连接后，TCP 往往不会立刻报错，
    /// 表现就是「Live: connected」但长时间收不到任何帧。真机实测出现过 **9 分钟无帧**
    /// 而界面一直显示已连接——这期间发消息会卡在「发送中」，问答卡片也收不到结果。
    /// 空闲时不该像生成中那样敏感（25 秒），所以用更宽的值。
    public static let idleTimeout: Duration = .seconds(120)
    /// 重连退避：从 1 秒开始翻倍，上限 20 秒。
    public static let initialReconnectDelay: Duration = .seconds(1)
    public static let maxReconnectDelay: Duration = .seconds(20)
    /// 断流兜底轮询：最多 30 次、每次间隔 500 毫秒（约 15 秒）。
    public static let historyPollAttempts = 30
    public static let historyPollInterval: Duration = .milliseconds(500)

    /// 下一次重连等待多久。
    public static func nextReconnectDelay(after current: Duration) -> Duration {
        let doubled = current * 2
        return doubled > maxReconnectDelay ? maxReconnectDelay : doubled
    }

    /// 是否需要因为「长时间没帧」而断开重连。
    ///
    /// 生成中用 25 秒阈值（模型输出应该持续有帧）；
    /// 空闲用 120 秒阈值（正常空闲不会有帧，但不能无限容忍假死）。
    public static func shouldReconnect(isRunning: Bool, idle: Duration) -> Bool {
        isRunning ? idle >= runningIdleTimeout : idle >= idleTimeout
    }
}
