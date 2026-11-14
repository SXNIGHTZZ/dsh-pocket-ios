import XCTest
@testable import DSHKit

final class StressScenarioTests: XCTestCase {
    func testParsesMultipleScenarios() {
        let result = StressScenario.parse("messages:400,images:120,steps:80")
        XCTAssertEqual(result, [.messages(400), .images(120), .steps(80)])
    }

    func testParsesExtremeMarkdown() {
        XCTAssertEqual(StressScenario.parse("markdown:extreme"), [.markdownExtreme])
    }

    func testIgnoresUnknownAndMalformed() {
        // 压测入口不该因为一个拼写错误就整个跑不起来。
        XCTAssertEqual(StressScenario.parse("messages:10,bogus:5,wat,steps:x"), [.messages(10)])
        XCTAssertEqual(StressScenario.parse(""), [])
        XCTAssertEqual(StressScenario.parse(nil), [])
    }

    func testClampsToSafeRange() {
        // 传错数量不能把模拟器直接撑爆——压测是定位问题，不是制造 OOM。
        XCTAssertEqual(StressScenario.parse("messages:999999"), [.messages(StressScenario.maxCount)])
        XCTAssertEqual(StressScenario.parse("messages:0"), [])
        XCTAssertEqual(StressScenario.parse("messages:-5"), [])
    }

    func testMessageRounds() {
        XCTAssertEqual(StressScenario.messages(10).messageRounds, 10)
        XCTAssertEqual(StressScenario.sessions(800).messageRounds, 0)
        XCTAssertEqual(StressScenario.markdownExtreme.messageRounds, 1)
    }
}

final class MarkdownScenarioTests: XCTestCase {
    func testParsesMarkdownSubScenarios() {
        XCTAssertEqual(StressScenario.parse("markdown:table:100"), [.markdownTable(100)])
        XCTAssertEqual(StressScenario.parse("markdown:code:500"), [.markdownCode(500)])
        XCTAssertEqual(StressScenario.parse("markdown:text:200"), [.markdownText(200)])
    }

    func testMarkdownSubScenariosClampAndReject() {
        XCTAssertEqual(StressScenario.parse("markdown:table:99999"), [.markdownTable(StressScenario.maxCount)])
        XCTAssertEqual(StressScenario.parse("markdown:table:0"), [])
        XCTAssertEqual(StressScenario.parse("markdown:bogus:10"), [])
    }
}

final class SingleLineScenarioTests: XCTestCase {
    func testParsesSingleLine() {
        XCTAssertEqual(StressScenario.parse("markdown:singleline:950"), [.markdownSingleLine(950)])
    }
}

final class CodePlainScenarioTests: XCTestCase {
    func testParsesCodePlain() {
        XCTAssertEqual(StressScenario.parse("markdown:codeplain:950"), [.markdownCodePlain(950)])
    }
}
