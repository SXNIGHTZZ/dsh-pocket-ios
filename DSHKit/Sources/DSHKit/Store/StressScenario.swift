import Foundation

/// 性能压测场景。用环境变量 `DSH_STRESS` 传入，逗号分隔可叠加多个。
///
/// 语法：`messages:400,images:120,steps:80,sessions:800,markdown:extreme`
///
/// 为什么放 DSHKit：解析是纯逻辑，能单测。真正的数据生成在 App 的 Debug 数据源里
/// （依赖 `PocketMessage` 等 App 类型）。
public enum StressScenario: Equatable, Sendable {
    /// N 轮「用户提问 + 助手 Markdown 回复」。
    case messages(Int)
    /// N 条消息，每条带图片。
    case images(Int)
    /// 每轮附带 N 个过程步骤。
    case steps(Int)
    /// N 个演示会话（测列表规模与分组计算）。
    case sessions(Int)
    /// 极端 Markdown：超宽表格 + 超长代码块。
    case markdownExtreme

    /// 单场景的数量上限。防止传错（比如 999999）把模拟器直接撑爆，
    /// 压测是要定位问题，不是制造 OOM 崩溃。
    public static let maxCount = 2000

    /// 解析一个或多个场景。无法识别的条目直接丢弃（不抛错——压测入口不该因为
    /// 一个拼写错误就整个跑不起来，静默跳过更容易排查）。
    public static func parse(_ raw: String?) -> [StressScenario] {
        guard let raw, !raw.isEmpty else { return [] }
        var result: [StressScenario] = []
        for piece in raw.split(separator: ",") {
            let token = piece.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if token == "markdown:extreme" {
                result.append(.markdownExtreme)
                continue
            }
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            let count = min(max(value, 0), maxCount)
            guard count > 0 else { continue }
            switch parts[0] {
            case "messages": result.append(.messages(count))
            case "images": result.append(.images(count))
            case "steps": result.append(.steps(count))
            case "sessions": result.append(.sessions(count))
            default: continue
            }
        }
        return result
    }

    /// 该场景要生成的消息轮数（`sessions` 不生成消息，返回 0）。
    public var messageRounds: Int {
        switch self {
        case .messages(let n): return n
        case .images(let n): return n
        case .steps(let n): return n
        case .markdownExtreme: return 1
        case .sessions: return 0
        }
    }
}
