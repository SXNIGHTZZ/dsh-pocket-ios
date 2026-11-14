import XCTest
@testable import DSHKit

/// `$events` 协议解析：手机端要走 provider 路径，必须先能正确识别服务端推来的帧。
final class RemoteEventProtocolTests: XCTestCase {
    // MARK: - ready

    func testReadyParsesClientId() {
        let ready = RemoteEventProtocol.ready(from: ["type": "ready", "clientId": "c-1", "host": "mac"])
        XCTAssertEqual(ready?.clientId, "c-1")
        XCTAssertEqual(ready?.host, "mac")
    }

    func testReadyRequiresClientId() {
        XCTAssertNil(RemoteEventProtocol.ready(from: ["type": "ready"]))
        XCTAssertNil(RemoteEventProtocol.ready(from: ["type": "ready", "clientId": ""]))
        // 不是 ready 类型也不能当就绪帧
        XCTAssertNil(RemoteEventProtocol.ready(from: ["type": "event", "clientId": "c-1"]))
    }

    // MARK: - 帧分类

    func testCancelFrame() {
        XCTAssertEqual(RemoteEventProtocol.frame(from: ["type": "cancel", "eventId": "e1"]),
                       .cancel(eventId: "e1"))
    }

    func testEmitFrame() {
        XCTAssertEqual(RemoteEventProtocol.frame(from: ["type": "emit", "eventId": "e2"]),
                       .emit(eventId: "e2"))
    }

    func testRequestFrameIsDefaultForUnknownTypeWithEventId() {
        let raw: [String: Any] = ["eventId": "e3", "method": "user-questions/request"]
        guard case .request(let eventId, let payload) = RemoteEventProtocol.frame(from: raw) else {
            return XCTFail("带 eventId 且非 cancel/emit 应视为请求")
        }
        XCTAssertEqual(eventId, "e3")
        XCTAssertEqual(payload["method"] as? String, "user-questions/request")
    }

    func testUnknownFrameWithoutEventId() {
        guard case .unknown = RemoteEventProtocol.frame(from: ["type": "weird"]) else {
            return XCTFail("没有 eventId 的帧应归为 unknown")
        }
    }

    // MARK: - 回传体

    func testResultBodyShape() {
        let body = RemoteEventProtocol.resultBody(clientId: "c-1", eventId: "e1",
                                                  value: ["answers": [["id": "q1", "selected": ["A"]]]])
        XCTAssertEqual(body["clientId"] as? String, "c-1")
        XCTAssertEqual(body["eventId"] as? String, "e1")
        let outcome = body["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["kind"] as? String, "result")
        let value = outcome?["value"] as? [String: Any]
        XCTAssertEqual((value?["answers"] as? [[String: Any]])?.count, 1)
    }

    func testResultBodyWithoutValueOmitsKey() {
        let body = RemoteEventProtocol.resultBody(clientId: "c", eventId: "e", value: nil)
        let outcome = body["outcome"] as? [String: Any]
        XCTAssertNil(outcome?["value"])
    }

    func testRejectionBodyShape() {
        let body = RemoteEventProtocol.rejectionBody(clientId: "c-1", eventId: "e1", message: "boom")
        let outcome = body["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["kind"] as? String, "rejected")
        let error = outcome?["error"] as? [String: Any]
        XCTAssertEqual(error?["message"] as? String, "boom")
    }

    // MARK: - 字段提取（实测前按多个位置容错）

    func testMethodNameFindsTopLevelAndPayload() {
        XCTAssertEqual(RemoteEventProtocol.methodName(in: ["method": "a/b"]), "a/b")
        XCTAssertEqual(RemoteEventProtocol.methodName(in: ["endpoint": "a/c"]), "a/c")
        XCTAssertEqual(RemoteEventProtocol.methodName(in: ["payload": ["method": "a/d"]]), "a/d")
        XCTAssertNil(RemoteEventProtocol.methodName(in: ["foo": "bar"]))
    }

    func testMethodNameFallsBackToKnownString() {
        let raw: [String: Any] = ["nested": ["text": "user-questions/request"]]
        XCTAssertEqual(RemoteEventProtocol.methodName(in: raw), "user-questions/request")
    }

    func testArgumentsExtraction() {
        XCTAssertEqual(RemoteEventProtocol.arguments(in: ["args": ["q": "v"]])?["q"] as? String, "v")
        XCTAssertEqual(RemoteEventProtocol.arguments(in: ["payload": ["args": ["q": "w"]]])?["q"] as? String,
                       "w")
        XCTAssertNil(RemoteEventProtocol.arguments(in: ["nothing": 1]))
    }
}
