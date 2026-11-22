import XCTest
@testable import DSHKit

final class ReasoningFoldTests: XCTestCase {
    private func msg(_ id: String, _ seq: Int, user: Bool = false, _ reasoning: String) -> ReasoningFold.Message {
        ReasoningFold.Message(id: id, sequence: seq, isUser: user, reasoning: reasoning)
    }

    func testSameTurnFoldsIntoFirstOwner() {
        // 一轮里被工具打断两次：三条助手消息，各自带一段思考
        let messages = [
            msg("u1", 1, user: true, ""),
            msg("a1", 3, "先看目录。"),
            msg("a2", 7, "再改文件。"),
            msg("a3", 11, "跑测试。")
        ]
        let result = ReasoningFold.fold(messages, turnStartSeqs: [2])
        XCTAssertEqual(result["a1"], "先看目录。\n\n再改文件。\n\n跑测试。")
        // 同轮后续消息不再单独显示思考：字典里干脆没有它们（视图侧 `?? ""` 会隐藏）
        XCTAssertNil(result["a2"], "同轮第二条不该再有一份思考")
        XCTAssertNil(result["a3"], "同轮第三条不该再有一份思考")
        XCTAssertNil(result["u1"], "用户消息不参与合并")
    }

    func testTwoTurnsStaySeparate() {
        let messages = [
            msg("u1", 1, user: true, ""),
            msg("a1", 3, "第一轮想法。"),
            msg("u2", 5, user: true, ""),
            msg("a2", 7, "第二轮想法。")
        ]
        let result = ReasoningFold.fold(messages, turnStartSeqs: [2, 6])
        XCTAssertEqual(result["a1"], "第一轮想法。")
        XCTAssertEqual(result["a2"], "第二轮想法。")
    }

    func testEmptyReasoningIsSkipped() {
        let messages = [
            msg("a1", 3, ""),
            msg("a2", 7, "有内容。")
        ]
        let result = ReasoningFold.fold(messages, turnStartSeqs: [2])
        XCTAssertNil(result["a1"], "没思考的那条不占位置")
        XCTAssertEqual(result["a2"], "有内容。")
    }

    func testNoTurnBoundariesKeepsPerMessage() {
        // 拿不到轮次边界时不能把所有轮并成一段（那会把整段历史揉成一坨）
        let messages = [
            msg("a1", 3, "甲"),
            msg("a2", 7, "乙")
        ]
        let result = ReasoningFold.fold(messages, turnStartSeqs: [])
        XCTAssertEqual(result["a1"], "甲")
        XCTAssertEqual(result["a2"], "乙")
    }

    func testWhitespaceOnlyReasoningIgnored() {
        let messages = [
            msg("a1", 3, "   \n  "),
            msg("a2", 7, "真内容")
        ]
        let result = ReasoningFold.fold(messages, turnStartSeqs: [2])
        XCTAssertNil(result["a1"])
        XCTAssertEqual(result["a2"], "真内容")
    }

    // 回归：快照窗口从中间截断时，早于窗口里第一个 turn/start 的消息不能被揉成一组
    func testMessagesBeforeFirstTurnStartKeepOwn() {
        let messages = [
            msg("old1", 1, "老轮次甲"),
            msg("old2", 4, "老轮次乙"),
            msg("u1", 10, user: true, ""),
            msg("a1", 12, "本窗口第一轮"),
            msg("a2", 14, "本窗口第一轮-续")
        ]
        let result = ReasoningFold.fold(messages, turnStartSeqs: [11])
        XCTAssertEqual(result["old1"], "老轮次甲", "窗口外的消息各显各的")
        XCTAssertEqual(result["old2"], "老轮次乙")
        XCTAssertEqual(result["a1"], "本窗口第一轮\n\n本窗口第一轮-续", "窗口内仍然按轮合并")
        XCTAssertNil(result["a2"])
    }
}
