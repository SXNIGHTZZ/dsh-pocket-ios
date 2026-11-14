// MarkdownBody

import SwiftUI
import Security
import Textual
import DSHKit
import VisionKit
import AVFoundation
import Observation
import PhotosUI
import UIKit
import Photos
import os
import AudioToolbox
import ImageIO
import UserNotifications


/// Markdown 渲染体。
///
/// **为什么要 Equatable**：这是个值类型，SwiftUI 每次给父视图求值都会重新创建它。
/// 而 `StructuredText(markdown:)` 是「解析 + 布局」的重活——会话里有 28 条消息时，
/// 任何一次状态变化（滚动位置、计时器、实时帧）都可能触发 28 次重新解析。
/// 声明 Equatable 后，只要 `text` 和 `foreground` 没变，SwiftUI 会跳过重建。
///
/// 真机现象：28 条消息 / 134 个步骤的会话占 368 MB footprint，内存曲线
/// 在 237–472 MB 之间反复波动——符合「大对象反复创建又释放」的特征
/// （数据层只有 38.7 KB 文本，撑不起这个量）。
struct MarkdownBody: View, Equatable {
    let text: String
    var foreground: Color = .primary

    static func == (lhs: MarkdownBody, rhs: MarkdownBody) -> Bool {
        lhs.text == rhs.text && lhs.foreground == rhs.foreground
    }

    var body: some View {
        StructuredText(markdown: Self.strippingCodeLanguage(text))
            .textual.textSelection(.enabled)
            // 标题、表格、行内代码统一在 ChatStructuredStyle 里配置。
            //
            // 以前这里是「.textual.headingStyle / .textual.tableStyle 放在 .gitHub 之前」的写法，
            // 靠 modifier 顺序抢优先级；行内代码没法这么抢——`inlineStyle` 在
            // `StructuredTextStyle` 里是 `let`，`.textual.inlineStyle(...)` 只作用于 `InlineText`。
            // 所以整体换成一个自定义 style，顺序问题一次性消掉。
            .textual.structuredTextStyle(ChatStructuredStyle())
            // 行内代码**不要背景色**。
            // `.gitHub` 的内置样式给行内代码加了 `githubSecondaryBackground`，在深色模式下
            // 是浅色块——而我们把它渲染在深绿气泡上，白底 + 白字直接糊成一片（真机截图可见：
            // `markdown:code:950`、`MarkdownBody` 这些行内代码只剩白块）。
            // 等宽 + 略小字号已经足够区分，背景色在彩色气泡上只会降低可读性。
            // 必须放在 `structuredTextStyle(.gitHub)` 之后，否则被它内置的 inlineStyle 覆盖。
            .textual.inlineStyle(InlineStyle().code(.monospaced, .fontScale(0.94)))
            .foregroundStyle(foreground)
    }
}

extension MarkdownBody {
    /// 去掉代码围栏的语言标识（```swift → ```）。
    ///
    /// 为什么：Textual 的语法高亮走 `HighlightedTextFragment` —— 用 JavaScriptCore + Prism
    /// 把代码 tokenize，再把每个 token 拼成 `AttributedString` 交给 SwiftUI 的 `Text`。
    /// token 一多，`ConcatenatedTextStorage` 会递归解析到爆栈。
    ///
    /// 压测实测（模拟器，同一条消息、同样的代码内容）：
    ///   ```swift 950 行 → SIGSEGV（主线程栈里全是 ConcatenatedTextStorage.resolve）
    ///   ```   950 行 → 382 MB，稳
    ///   ```   2000 行 → 354 MB，稳
    ///
    /// 没有语言标识时 Textual 不 tokenize（`languageHint == nil` 直接跳过），
    /// 也就不会走高亮路径。代价：代码块没有配色，复制时也少一个语言标识——
    /// 对话场景里这个损失可以接受，崩溃不可接受。
    static func strippingCodeLanguage(_ markdown: String) -> String {
        // 只处理「以反引号开头、后面还跟着语言名」的行。
        var result = markdown
        var searchStart = result.startIndex
        while let fence = result.range(of: "```", range: searchStart..<result.endIndex) {
            // 围栏必须在行首（允许前导空白）
            let lineStart = result[result.startIndex..<fence.lowerBound]
            let isLineStart = lineStart.isEmpty || lineStart.hasSuffix("\n")
            guard isLineStart else {
                searchStart = fence.upperBound
                continue
            }
            // 找这一行结尾
            let lineEnd = result[fence.upperBound...].firstIndex(of: "\n") ?? result.endIndex
            let info = result[fence.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces)
            // 有语言标识 → 删掉；空（纯围栏）→ 不动
            if !info.isEmpty {
                result.removeSubrange(fence.upperBound..<lineEnd)
            }
            searchStart = result.index(fence.upperBound, offsetBy: 0)
            if searchStart >= result.endIndex { break }
        }
        return result
    }
}


/// 手机上的 Markdown 表格。
///
/// 只画 1 像素的线与外框，不铺隔行底色：Textual 的 dividers 给的是整段间隙，
/// 直接填会变成粗灰带（踩过）。
struct PhoneTableStyle: StructuredText.TableStyle {
    private static let hairline: CGFloat = 1
    private static let maxWidthRatio: CGFloat = 2.2
    private static let line = Color.primary.opacity(0.16)

    func makeBody(configuration: StructuredText.TableStyleConfiguration) -> some View {
        Overflow { state in
            let maxWidth = state.containerWidth.map { $0 * Self.maxWidthRatio }
            configuration.label
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .textual.tableCellSpacing(horizontal: 0, vertical: 0)
                .textual.tableOverlay { layout in
                    Canvas { context, _ in
                        // 行线：每行顶部一条 1 点
                        for row in layout.rowIndices.dropFirst() {
                            let bounds = layout.rowBounds(row)
                            let rect = CGRect(x: bounds.minX, y: bounds.minY - Self.hairline / 2,
                                              width: bounds.width, height: Self.hairline)
                            context.fill(Path(rect), with: .style(Self.line))
                        }
                        // 列线：只取竖直方向的分隔，压成 1 点宽
                        for divider in layout.dividers() where divider.height > divider.width {
                            let rect = CGRect(x: divider.midX - Self.hairline / 2, y: divider.minY,
                                              width: Self.hairline, height: divider.height)
                            context.fill(Path(rect), with: .style(Self.line))
                        }
                    }
                }
                .padding(Self.hairline)
                .border(Self.line, width: Self.hairline)
        }
        .textual.blockSpacing(.fontScaled(top: 1.4, bottom: 1.4))
    }
}
