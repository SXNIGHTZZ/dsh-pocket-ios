import Foundation

/// 长 Markdown 的折叠规则：表格只留前 N 行、代码块只留前 N 行。
///
/// 为什么需要（实测，footprint 口径）：
/// - 28 条消息 + 134 个步骤 → 56 MB
/// - 再加一张 100 行 × 8 列表格 → **166 MB**（CoreAnimation 16.7 MB / 937 regions）
///
/// 表格每个单元格都是独立图层；代码块整段绘成一个 `Text`（`code:950` 有 43 MB CoreAnimation）。
/// 正常对话碰不到这些量级，只有贴压测数据时才会——所以阈值取高，靠折叠兜底。
public enum MarkdownTruncation {
    public struct Result: Equatable {
        public let markdown: String
        public let omittedTableRows: Int
        public let omittedCodeLines: Int

        public var didTruncate: Bool { omittedTableRows > 0 || omittedCodeLines > 0 }
        public var omittedTotal: Int { omittedTableRows + omittedCodeLines }

        public init(markdown: String, omittedTableRows: Int, omittedCodeLines: Int) {
            self.markdown = markdown
            self.omittedTableRows = omittedTableRows
            self.omittedCodeLines = omittedCodeLines
        }
    }

    /// 默认阈值：表格 30 行、代码 200 行。
    /// 远高于日常内容，只拦压测/日志粘贴这类异常长的块。
    public static let defaultMaxTableRows = 30
    public static let defaultMaxCodeLines = 200

    /// 按阈值截断，返回改写后的 Markdown 与省略量。
    ///
    /// 实现方式是按行扫描改写，不解析 Markdown AST——和 `MarkdownBody.strippingCodeLanguage`
    /// 一致。宁可简单，也不要为了折叠引入一套解析器。
    public static func apply(to markdown: String,
                             maxTableRows: Int = defaultMaxTableRows,
                             maxCodeLines: Int = defaultMaxCodeLines) -> Result {
        guard !markdown.isEmpty else {
            return Result(markdown: markdown, omittedTableRows: 0, omittedCodeLines: 0)
        }
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)

        var omittedRows = 0
        var omittedCode = 0
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // ① 代码块：围栏开始的 ``` 之后，直到下一个 ``` 或结尾
            if let fence = fenceMarker(in: line) {
                let start = index
                var end = lines.count
                var closed = false
                var scan = index + 1
                while scan < lines.count {
                    if lines[scan].hasPrefix(fence) { end = scan; closed = true; break }
                    scan += 1
                }
                let bodyCount = (closed ? end : lines.count) - (start + 1)
                if bodyCount > maxCodeLines {
                    out.append(lines[start])                      // 开围栏（保留语言标识的剥离由外部处理）
                    out.append(contentsOf: lines[(start + 1)..<(start + 1 + maxCodeLines)])
                    omittedCode += bodyCount - maxCodeLines
                    out.append("… 省略 \(bodyCount - maxCodeLines) 行 …")
                    if closed { out.append(lines[end]) }
                    index = closed ? end + 1 : lines.count
                } else {
                    let stop = closed ? end : lines.count - 1
                    out.append(contentsOf: lines[start...stop])
                    index = stop + 1
                }
                continue
            }

            // ② 表格：连续以 | 开头的行
            if isTableLine(line) {
                let start = index
                var end = index
                while end + 1 < lines.count, isTableLine(lines[end + 1]) { end += 1 }
                let rowCount = end - start + 1
                if rowCount > maxTableRows {
                    out.append(contentsOf: lines[start..<(start + maxTableRows)])
                    omittedRows += rowCount - maxTableRows
                    out.append("")
                    out.append("… 省略 \(rowCount - maxTableRows) 行表格 …")
                    out.append("")
                    index = end + 1
                } else {
                    out.append(contentsOf: lines[start...end])
                    index = end + 1
                }
                continue
            }

            out.append(line)
            index += 1
        }

        return Result(markdown: out.joined(separator: "\n"),
                      omittedTableRows: omittedRows,
                      omittedCodeLines: omittedCode)
    }

    // MARK: - 识别

    /// 行首的代码围栏（``` 或 ~~~），返回围栏标记；不是围栏行返回 nil。
    static func fenceMarker(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return marker
        }
        return nil
    }

    /// 表格行：去掉前导空白后以 `|` 开头。
    static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        return trimmed.hasPrefix("|")
    }
}
