import Foundation

/// 消息列表的垂直节奏与未读计数。
///
/// 抽出来的原因：这两个规则决定「同一个人连着说的话看起来是不是一伙的」，
/// 也和「离开底部后到底有几条新回复」直接相关——都是可判定的，不该写在视图里靠肉眼调。
public enum TimelineSpacing {
    /// 同人连续 5、换角色 12、过程行/失败卡相邻 7。
    ///
    /// 2026-11-14 整体收紧约 30%（原 8 / 18 / 10）：真机上看一屏只放得下三四条，
    /// 垂直留白比文字本身还占地方。收紧后层级仍然分得清——换角色的 12 明显大于
    /// 同人的 5，只是不再用 18 这种几乎等于一条空行的间隔。
    public static func between(previousIsGroup: Bool, currentIsGroup: Bool,
                               previousIsUser: Bool?, currentIsUser: Bool?) -> Int {
        if previousIsGroup || currentIsGroup { return groupSpacing }
        guard let previousIsUser, let currentIsUser else { return groupSpacing }
        return previousIsUser == currentIsUser ? sameSpeakerSpacing : speakerChangeSpacing
    }

    public static let groupSpacing = 7
    public static let sameSpeakerSpacing = 5
    public static let speakerChangeSpacing = 12
}

public enum UnreadCounter {
    /// 离开底部之后到达的**助手回复**条数：用户自己的消息和仍在待发的都不算。
    public static func replies(after mark: Int,
                               messages: [(isUser: Bool, isPending: Bool, sequence: Int)]) -> Int {
        messages.filter { !$0.isUser && !$0.isPending && $0.sequence > mark }.count
    }
}
