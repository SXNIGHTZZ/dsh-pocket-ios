import Foundation

/// 发送模式：决定这条消息是「新开一轮」还是「插进当前轮」。
///
/// 为什么统一：这行三元表达式原先散在三处（发送、通知回复、断网补发），
/// 三处的判定条件已经不一致——补发要固定 queue，实时发送要「确认过 turn 事件」。
/// 收敛成一处之后，规则可以直接测，也不会再各写各的。
public enum PromptMode: String, Equatable, Sendable {
    case queue
    case steer
}

public enum PromptPolicy {
    /// 实时发送的默认行为：**在跑就打断**。
    ///
    /// 曾经要求「见过实时 turn 事件」才 steer，结果生成中发的消息全被排到当前轮之后，
    /// 电脑端显示「排队」——用户以为消息卡住了。排队带来的体感损失远大于误打断：
    /// 误打断最多让 AI 多问一句，排队则要等整轮跑完。
    /// `isRunning` 本身已由 turn 事件驱动（列表状态只用于首帧），足够可信。
    ///
    /// **这是没有远端设置时的默认值**。用户在电脑端把「繁忙时 Enter」设成排队时，
    /// 会通过 `BusyEnterSetting` 读出来覆盖它——见 `liveMode(isRunning:preference:)`。
    public static var defaultLiveMode: PromptMode { .steer }

    /// 实时发送：按用户偏好决定「在跑时」用哪种投递。
    ///
    /// - Parameters:
    ///   - isRunning: 当前会话是否正在生成。
    ///   - preference: 用户设置的繁忙态投递方式；`nil` 或读不到时用 [defaultLiveMode]。
    ///
    /// 注意：**只有在跑的时候偏好才生效**。空闲时发消息一定是新开一轮（queue），
    /// 这与 DSH 桌面端 `resolveSubmitMode` 的行为一致——空闲时 Steer 没有意义。
    public static func liveMode(isRunning: Bool, preference: PromptMode? = nil) -> PromptMode {
        guard isRunning else { return .queue }
        return preference ?? defaultLiveMode
    }

    /// 通知/手表回复：列表里的 running 可能滞后，统一排队，避免误打断。
    public static func replyMode(isRunning: Bool) -> PromptMode {
        .queue
    }

    /// 断网补发：积压是「排着说」，一律排队（见 OfflineDeliveryPolicy）。
    public static var backlogMode: PromptMode { .queue }
}

/// 「智能体运行时，Enter 键和发送按钮」的行为设置。
///
/// 存在 **DSH Host 的 user-settings 文档**里（命名空间 `ui-conversation`，字段 `busyEnter`），
/// 不是浏览器 localStorage——所以手机端能通过 `settings.describe` / `settings.mutate` 读写，
/// 和电脑端共享同一份偏好。
///
/// 字段是 `.volatile()`：改完立即生效，不需要重启 DSH。
public enum BusyEnterSetting {
    /// DSH 由 `dsh-client-ui-conversation` 注册的命名空间。
    public static let namespace = "ui-conversation"
    /// RPC 方法名。**必须用斜杠**：DSH 的方法是 `settings/describe`、`settings/mutate`，
    /// 点号写法（`settings.mutate`）在 TypeScript 里是客户端的命名空间访问，
    /// 直接当方法名打会得到 `not found`（已踩）。
    public static let describeMethod = "settings/describe"
    public static let mutateMethod = "settings/mutate"
    /// 承载投递方式的字段名。
    public static let field = "busyEnter"

    /// 从 `settings.describe` 的结果里取出用户当前的选择。
    ///
    /// - Parameter descriptors: `settings.describe` 返回的 descriptor 数组。
    /// - Returns: 读到就返回用户的选择；**没有这个命名空间、字段缺失或取值不认识时返回 nil**，
    ///   调用方据此回退到默认值（而不是把默认值当成用户的真实选择）。
    public static func read(fromDescriptors descriptors: [[String: Any]]) -> PromptMode? {
        for descriptor in descriptors {
            guard descriptor["ns"] as? String == namespace,
                  let value = descriptor["value"] as? [String: Any],
                  let raw = value[field] as? String else { continue }
            return PromptMode(rawValue: raw)
        }
        return nil
    }

    /// 生成写入用的 ops（`settings.mutate` 的第二个参数）。
    public static func writeOps(_ mode: PromptMode) -> [[String: Any]] {
        [["op": "set", "path": [field], "value": mode.rawValue]]
    }
}
