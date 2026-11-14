// QuestionInbox

import Foundation
import Observation
import DSHKit

/// `ask_user_question` 卡片的状态机：什么时候该弹出、什么时候收起、怎么提交回答。
///
/// 边界（spec/12）：
/// - 只读写「当前会话的 pendingQuestion」，不持有会话本身；
/// - 不发别的请求，只发 `userQuestions/answer`；
/// - 会话与诊断通过闭包注入，避免反向依赖 ConnectionModel。
@Observable
final class QuestionInbox {
    struct Providers {
        /// 当前打开的会话（用于提交回答时的 sessionId）。
        var sessionId: () -> String?
        /// 当前会话状态（读写 pendingQuestion / answeredQuestionCallIds）。
        var conversation: () -> ConversationState?
        /// 发请求用的客户端。
        var client: () throws -> DSHClient
        /// 写诊断。
        var record: (String) -> Void
        /// 回答失败时把错误展示给用户。
        var reportError: (String) -> Void
    }

    var providers: Providers?

    /// 历史重放不能把答过的问题再抬出来：只有「还没结果且这一轮没结束」才占输入区。
    @MainActor
    func noteAsked(callId: String, turn: Int, arguments: String) {
        guard let conversation = providers?.conversation() else { return }
        let answered = conversation.answeredQuestionCallIds.contains(callId)
        let turnEnded = conversation.endedTurnNumbers.contains(turn)
        guard PendingQuestionPolicy.shouldShow(hasResult: answered, turnEnded: turnEnded),
              let payload = PendingQuestionPayload.decode(callId: callId, arguments: arguments) else { return }
        conversation.pendingQuestion = PendingUserQuestion(payload: payload)
        conversation.pendingQuestionTurn = turn
    }

    /// 电脑端已经给出结果，或本机刚提交了回答。
    @MainActor
    func noteSettled(callId: String) {
        guard !callId.isEmpty, let conversation = providers?.conversation() else { return }
        conversation.answeredQuestionCallIds.insert(callId)
        if conversation.pendingQuestion?.callId == callId {
            clear()
        }
    }

    @MainActor
    func clear() {
        providers?.conversation()?.pendingQuestion = nil
        providers?.conversation()?.pendingQuestionTurn = nil
    }

    /// 提交回答：选中项与自定义文本一起发回。
    @MainActor
    func answer(_ request: PendingUserQuestion,
                selected: [String: Set<String>],
                custom: [String: String]) {
        guard let providers, let sessionId = providers.sessionId() else { return }
        let answers: [[String: Any]] = request.questions.map { item in
            var answer: [String: Any] = [
                "id": item.id,
                "selected": Array(selected[item.id] ?? [])
            ]
            let text = (custom[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { answer["custom"] = text }
            return answer
        }
        let args: [String: Any] = [
            "agentId": sessionId,
            "callId": request.callId,
            "answer": ["answers": answers]
        ]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 用 rpcVoidRawAdapted：只看 result.ok，同时把原始响应体记进诊断。
                // 之前踩过两个坑：①严格解析 value 会误报「响应格式无效」；
                // ②回显太简略，真出问题时看不出服务端到底回了什么。
                let raw = try await providers.client().rpcVoidRawAdapted("userQuestions/answer", args: args)
                providers.record("回答用户问题：\(request.callId)  raw=\(raw.prefix(200))")
                // userQuestions/answer 返回 boolean：true = 服务端接受了并排队给 agent；
                // false = 问题当前不是 continued（已经结束，或没有客户端认领过它）。
                // 以前这里不检查——宽松解析把 false 吞成空字典，界面假装成功、卡片收起，
                // 但 agent 永远收不到答案，步骤就一直停在「正在等待你的选择」。
                if let value = Self.booleanResult(in: raw), value == false {
                    providers.reportError("回答没被接受：这个问题当前不是等待状态（可能已结束，或需要电脑端 DSH 页面同时打开）")
                    providers.record("回答被服务端拒绝：\(request.callId)")
                    return
                }
                self.noteSettled(callId: request.callId)
            } catch {
                providers.record("回答用户问题失败：callId=\(request.callId) err=\(error.localizedDescription)")
                providers.reportError("回答问题失败：\(error.localizedDescription)")
            }
        }
    }

    /// 从 `userQuestions/answer` 的原始响应里取 boolean 结果。
    private static func booleanResult(in raw: String) -> Bool? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return nil }
        return result["value"] as? Bool
    }
}
