import XCTest
@testable import DSHKit

final class PromptPayloadTests: XCTestCase {
    private let image = PromptPayload.Image(mediaType: "image/jpeg", base64: "AAAA", name: "a.jpg")

    func testTextOnlyProducesOneBlock() throws {
        let blocks = PromptPayload.content(text: "你好", images: [])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        // 正文会带上不可见的客户端来源标记，助手据此判断这条是不是手机发的。
        XCTAssertEqual(blocks[0]["text"] as? String, "你好" + PromptPayload.clientMark)
    }

    func testTextCarriesClientMark() throws {
        let blocks = PromptPayload.content(text: "你好", images: [])
        let text = try XCTUnwrap(blocks[0]["text"] as? String)
        XCTAssertTrue(PromptPayload.isFromClient(text), "iOS 消息必须带来源标记")
        // 标记必须不可见：不能出现任何可见字符（否则会显示在用户消息里）。
        XCTAssertEqual(text.filter { !$0.unicodeScalars.allSatisfy { $0.properties.isDefaultIgnorableCodePoint } },
                       "你好")
    }

    func testClientMarkIsIdempotent() {
        // 断网补发会重入，不能加两遍。
        let once = PromptPayload.marked("你好")
        XCTAssertEqual(PromptPayload.marked(once), once)
    }

    func testEmptyTextGetsNoMark() {
        // 纯图片消息不加标记：否则会多出一条只有标记的丑气泡。
        XCTAssertEqual(PromptPayload.marked(""), "")
        XCTAssertTrue(PromptPayload.content(text: "", images: [image])
            .allSatisfy { ($0["type"] as? String) != "text" })
    }

    func testEmptyTextProducesNoTextBlock() {
        // 空文本不能产生空 block：服务端会当成空消息。
        XCTAssertTrue(PromptPayload.content(text: "", images: []).isEmpty)
    }

    func testImageOnlyStillSendsImage() throws {
        let blocks = PromptPayload.content(text: "", images: [image])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        XCTAssertEqual(blocks[0]["mediaType"] as? String, "image/jpeg")
        XCTAssertEqual(blocks[0]["data"] as? String, "AAAA")
        XCTAssertEqual(blocks[0]["name"] as? String, "a.jpg")
    }

    func testRequestCarriesAllFields() throws {
        let request = PromptPayload.request(requestId: "r1", sessionId: "s1", mode: .steer,
                                            text: "hi", images: [image], timeZone: "Asia/Shanghai")
        XCTAssertEqual(request["requestId"] as? String, "r1")
        XCTAssertEqual(request["sessionId"] as? String, "s1")
        XCTAssertEqual(request["mode"] as? String, "steer")
        XCTAssertEqual(request["clientTimeZone"] as? String, "Asia/Shanghai")
        let blocks = try XCTUnwrap(request["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2, "文本 + 图片应有 2 个块")
    }

    func testQueueModeSerializes() {
        let request = PromptPayload.request(requestId: "r", sessionId: "s", mode: .queue,
                                            text: "x", images: [], timeZone: "UTC")
        XCTAssertEqual(request["mode"] as? String, "queue")
    }
}
