import Foundation

/// 把「一轮里的思考」合成一段。
///
/// 为什么要这个：DSH 一轮（turn）里模型可能被工具调用打断好几次，每次产出一条
/// `assistant/message`，每条都带自己的 `reasoning` 块。手机端如果逐条渲染，
/// 同一条回答上方会出现好几段「思考」，看着像碎的——桌面端是按轮收拢成一段的。
///
/// 规则：
/// - 一条消息属于「它之前最近的那个 turn/start」；
/// - 同一轮里所有非空思考按 seq 升序拼成一段（用空行分隔）；
/// - 这段只挂在**该轮第一条带思考的助手消息**上，其余消息返回空串（不显示思考块）。
///
/// 放在 DSHKit 是因为它纯逻辑、可单测；视图只负责把结果传给行。
public enum ReasoningFold {
    /// 输入：已按 seq 升序的消息。
    /// 输出：messageId → 该条应显示的思考文本（空串 = 不显示）。
    public static func fold(_ messages: [Message],
                            turnStartSeqs: [Int]) -> [String: String] {
        var result: [String: String] = [:]
        let starts = turnStartSeqs.sorted()
        // 没有轮次边界就各显各的：千万别退化成「全部并成一段」，那会把整段历史揉成一坨。
        guard !starts.isEmpty else {
            for message in messages where !message.isUser {
                let text = message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result[message.id] = text }
            }
            return result
        }
        var turnKey = Int.min
        var startIndex = 0
        var currentChunk: [String] = []
        var currentOwner: String?

        func flush() {
            if let owner = currentOwner {
                result[owner] = currentChunk.joined(separator: "\n\n")
            }
            currentOwner = nil
            currentChunk = []
        }

        for message in messages {
            // 这条消息之前最近的一个 turn/start 就是它所属的轮
            var nextTurn = turnKey
            while startIndex < starts.count && starts[startIndex] <= message.sequence {
                nextTurn = starts[startIndex]
                startIndex += 1
            }
            if nextTurn != turnKey {
                flush()
                turnKey = nextTurn
            }
            if message.isUser { continue }
            let text = message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if currentOwner == nil { currentOwner = message.id }
            currentChunk.append(text)
        }
        flush()
        return result
    }

    public struct Message: Equatable, Sendable {
        public let id: String
        public let sequence: Int
        public let isUser: Bool
        public let reasoning: String

        public init(id: String, sequence: Int, isUser: Bool, reasoning: String) {
            self.id = id
            self.sequence = sequence
            self.isUser = isUser
            self.reasoning = reasoning
        }
    }
}
