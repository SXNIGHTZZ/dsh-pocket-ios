import XCTest
@testable import DSHKit

/// 长 Markdown 折叠：表格 30 行、代码 200 行。
/// 依据实测：100 行 × 8 列表格会把 footprint 从 56 MB 推到 166 MB。
final class MarkdownTruncationTests: XCTestCase {
    private func table(rows: Int) -> String {
        var lines = ["| 列1 | 列2 |", "| --- | --- |"]
        for i in 0..<rows { lines.append("| \(i) | v\(i) |") }
        return lines.joined(separator: "\n")
    }

    private func code(lines count: Int, closed: Bool = true) -> String {
        var lines = ["```swift"]
        for i in 0..<count { lines.append("let x\(i) = \(i)") }
        if closed { lines.append("```") }
        return lines.joined(separator: "\n")
    }

    func testShortTableIsUntouched() {
        let input = table(rows: 5)
        let result = MarkdownTruncation.apply(to: input)
        XCTAssertEqual(result.markdown, input)
        XCTAssertFalse(result.didTruncate)
        XCTAssertEqual(result.omittedTableRows, 0)
    }

    func testLongTableIsTruncated() {
        let input = table(rows: 40)   // 2 行表头 + 40 行 = 42 行
        let result = MarkdownTruncation.apply(to: input)
        XCTAssertTrue(result.didTruncate)
        // 42 行超过 30 → 省略 12 行
        XCTAssertEqual(result.omittedTableRows, 12)
        XCTAssertTrue(result.markdown.contains("省略 12 行表格"))
    }

    func testShortCodeIsUntouched() {
        let input = code(lines: 10)
        let result = MarkdownTruncation.apply(to: input)
        XCTAssertEqual(result.markdown, input)
        XCTAssertFalse(result.didTruncate)
    }

    func testLongCodeIsTruncated() {
        let input = code(lines: 300)
        let result = MarkdownTruncation.apply(to: input)
        XCTAssertTrue(result.didTruncate)
        XCTAssertEqual(result.omittedCodeLines, 100)
        XCTAssertTrue(result.markdown.contains("省略 100 行"))
        // 围栏必须还在（否则后面的内容会被当成代码）
        XCTAssertTrue(result.markdown.hasPrefix("```swift"))
        XCTAssertTrue(result.markdown.hasSuffix("```"))
    }

    func testMixedTruncationCountsBoth() {
        let input = table(rows: 40) + "\n\n" + code(lines: 300)
        let result = MarkdownTruncation.apply(to: input)
        XCTAssertEqual(result.omittedTableRows, 12)
        XCTAssertEqual(result.omittedCodeLines, 100)
        XCTAssertEqual(result.omittedTotal, 112)
    }

    func testUnclosedFenceDoesNotCrash() {
        let input = code(lines: 300, closed: false)
        let result = MarkdownTruncation.apply(to: input)
        XCTAssertTrue(result.didTruncate)
        XCTAssertEqual(result.omittedCodeLines, 100)
    }

    func testEmptyInput() {
        let result = MarkdownTruncation.apply(to: "")
        XCTAssertEqual(result.markdown, "")
        XCTAssertFalse(result.didTruncate)
    }

    func testNormalMarkdownPassesThroughUnchanged() {
        let input = """
        # 标题

        普通段落，带 `行内代码`、**加粗**。

        - 列表项 A
        - 列表项 B
        """
        let result = MarkdownTruncation.apply(to: input)
        XCTAssertEqual(result.markdown, input)
        XCTAssertFalse(result.didTruncate)
    }
}
