import XCTest
@testable import DSHKit

final class DecodingExtraTests: XCTestCase {
    func testStreamStartEndAndOther() throws {
        let start: [String: Any] = [
            "type": "assistant-stream",
            "frame": ["type": "start", "attemptId": "a1", "turn": 3, "step": 2]
        ]
        guard case .start(let attemptId, let turn, let step)? = DSHDecoding.streamFrame(fromJSON: start) else {
            return XCTFail("expected start")
        }
        XCTAssertEqual(attemptId, "a1")
        XCTAssertEqual(turn, 3)
        XCTAssertEqual(step, 2)

        let end: [String: Any] = [
            "type": "assistant-stream",
            "frame": ["type": "end", "attemptId": "a1", "outcome": ["kind": "committed"]]
        ]
        guard case .end(let endId, let outcome)? = DSHDecoding.streamFrame(fromJSON: end) else {
            return XCTFail("expected end")
        }
        XCTAssertEqual(endId, "a1")
        XCTAssertEqual(outcome, "committed")

        let reasoning: [String: Any] = [
            "type": "assistant-stream",
            "frame": ["type": "chunk", "attemptId": "a1", "index": 0,
                      "chunk": ["type": "reasoning-delta", "text": "thinking"]]
        ]
        // 2026-11-22 改：以前这里断言「等于 .other」，等于把「思考不显示」写成契约。
        // 现在 reasoning-delta 必须解出独立的帧，否则手机上永远看不到思考过程。
        guard case .reasoningDelta(let reasoningId, let reasoningIndex, let reasoningText)? =
                DSHDecoding.streamFrame(fromJSON: reasoning) else {
            return XCTFail("expected reasoningDelta")
        }
        XCTAssertEqual(reasoningId, "a1")
        XCTAssertEqual(reasoningIndex, 0)
        XCTAssertEqual(reasoningText, "thinking")
        XCTAssertNil(DSHDecoding.streamFrame(fromJSON: ["type": "assistant-stream"]))
        XCTAssertNil(DSHDecoding.streamFrame(fromJSON: ["type": "event"]))
    }

    // 回归：assistant/message 的 content 里 reasoning 块不能丢（2026-11-22）
    func testAssistantMessageReasoningBlockDecoded() {
        let event: [String: Any] = [
            "type": "assistant/message",
            "seq": 42,
            "data": ["message": ["role": "assistant", "content": [
                ["type": "reasoning", "text": "先看目录，再决定改哪个文件。"],
                ["type": "text", "text": "改好了。"]
            ]]]
        ]
        guard let message = DSHDecoding.message(fromEvent: event) else {
            return XCTFail("expected message")
        }
        XCTAssertEqual(message.text, "改好了。")
        XCTAssertEqual(message.reasoning, "先看目录，再决定改哪个文件。")
    }

    // 只有思考、没有正文的一轮也要留下（桌面端就是「只有 reasoning 的 step」）
    func testReasoningOnlyMessageSurvives() {
        let event: [String: Any] = [
            "type": "assistant/message",
            "seq": 43,
            "data": ["message": ["role": "assistant", "content": [
                ["type": "reasoning", "text": "这一步不需要输出正文。"]
            ]]]
        ]
        guard let message = DSHDecoding.message(fromEvent: event) else {
            return XCTFail("expected reasoning-only message")
        }
        XCTAssertEqual(message.text, "")
        XCTAssertEqual(message.reasoning, "这一步不需要输出正文。")
    }

    func testToolResultErrorFlag() {
        let event: [String: Any] = [
            "type": "tool/result",
            "seq": 11,
            "data": [
                "turn": 2,
                "toolCallId": "call-x",
                "isError": true,
                "message": ["content": [["type": "text", "text": "boom"]]]
            ]
        ]
        guard case .toolResult(let seq, let turn, let callId, let text, let isError, _)? = DSHDecoding.stepEvent(fromEvent: event) else {
            return XCTFail("expected toolResult")
        }
        XCTAssertEqual(seq, 11)
        XCTAssertEqual(turn, 2)
        XCTAssertEqual(callId, "call-x")
        XCTAssertEqual(text, "boom")
        XCTAssertTrue(isError)
    }


    // 回归：tool/result 里的截图（type=image + attachment）必须被解码出来
    func testToolResultImagesDecoded() {
        let event: [String: Any] = [
            "type": "tool/result", "seq": 2783,
            "data": [
                "turn": 28, "toolCallId": "call-x",
                "message": ["role": "tool", "content": [
                    ["type": "text", "text": "screenshot saved"],
                    ["type": "image", "attachment": [
                        "attachmentId": "sha256:1b65b320",
                        "mediaType": "image/png", "bytes": 343367,
                        "width": 2160, "height": 1350, "name": "shot.png"
                    ]]
                ]]
            ]
        ]
        guard case .toolResult(_, _, _, _, _, let images)? = DSHDecoding.stepEvent(fromEvent: event) else {
            return XCTFail("expected toolResult")
        }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.attachmentId, "sha256:1b65b320")
        XCTAssertEqual(images.first?.mediaType, "image/png")
        XCTAssertEqual(images.first?.width, 2160)
        XCTAssertEqual(images.first?.name, "shot.png")
    }

    func testArgumentDetailFallsBackToPathAndRawArguments() {
        XCTAssertEqual(DSHDecoding.argumentDetail(name: "read", arguments: #"{"path":"/tmp/a.ts"}"#), "/tmp/a.ts")
        XCTAssertEqual(DSHDecoding.argumentDetail(name: "web_search", arguments: #"{"queries":["a","b"]}"#), "a / b")
        XCTAssertEqual(DSHDecoding.argumentDetail(name: "read", arguments: "not-json"), "not-json")
        XCTAssertEqual(DSHDecoding.argumentDetail(name: "custom", arguments: #"{"other":1}"#), "custom")
        XCTAssertEqual(DSHDecoding.argumentDetail(name: "bash", arguments: #"{"cmd":"echo hi"}"#), "echo hi")
    }

    func testMessageWithoutContentReturnsNil() {
        let empty: [String: Any] = [
            "type": "assistant/message", "seq": 1,
            "data": ["message": ["content": []]]
        ]
        XCTAssertNil(DSHDecoding.message(fromEvent: empty))
    }

    func testSessionMissingIDReturnsNil() {
        XCTAssertNil(DSHDecoding.session(fromJSON: ["updatedAt": 1]))
    }

    func testSessionWithWhitespaceTitleIsInvisible() {
        let session = DSHSession(sessionId: "s", updatedAt: 0, running: false, blank: false, title: "   ")
        XCTAssertFalse(session.isVisibleInList)
        XCTAssertNil(DSHDecoding.session(fromJSON: ["sessionId": "s", "projections": ["values": ["title": "   "]]])?.title?.isEmpty == false ? nil : session)
    }

    func testRPCValueRejectsInvalidJSON() {
        XCTAssertThrowsError(try RPCRequest.value(from: Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? DSHError, .invalidPayload)
        }
        XCTAssertThrowsError(try RPCRequest.value(from: Data(#"{"result":{}}"#.utf8)))
    }

    // 回归：tool/result 的 callId/isError 可能在 message/source 里（字段位置兜底）
    func testToolResultCallIdAndIsErrorFallbacks() {
        let event: [String: Any] = [
            "type": "tool/result", "seq": 9,
            "data": [
                "turn": 2,
                "message": [
                    "role": "tool",
                    "isError": true,
                    "toolCallId": "call-from-message",
                    "source": ["kind": "tool", "callId": "call-from-message"],
                    "content": [["type": "text", "text": "boom"]]
                ]
            ]
        ]
        guard case .toolResult(_, _, let callId, let text, let isError, _)? = DSHDecoding.stepEvent(fromEvent: event) else {
            return XCTFail("expected toolResult")
        }
        XCTAssertEqual(callId, "call-from-message")
        XCTAssertEqual(text, "boom")
        XCTAssertTrue(isError)
    }

    // 回归：session/list 的标题在 projections.values.title
    func testSessionTitleReadsProjectionValues() {
        let json: [String: Any] = [
            "sessionId": "s1", "updatedAt": 1, "running": false, "blank": false,
            "projections": ["values": ["title": "嵌套标题"]]
        ]
        XCTAssertEqual(DSHDecoding.session(fromJSON: json)?.title, "嵌套标题")
    }
}
