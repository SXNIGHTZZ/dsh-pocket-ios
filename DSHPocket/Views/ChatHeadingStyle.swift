// ChatHeadingStyle

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


/// 聊天气泡里的标题：比默认更克制（默认 H1/H2 太大）。
struct ChatHeadingStyle: StructuredText.HeadingStyle {
    // 以 Textual 基准字号 17pt（iOS .body）计算：
    // H1 17 / H2 16.5 / H3 16 / H4 15.5 / H5 15 / H6 14.5。移动端与正文接近。
    // 移动端：标题贴近正文大小，避免在气泡里过于抢眼。
    // 注意：Textual 的 fontScale 会叠加在 .gitHub 默认大标题之上（实测 H1 ≈ 1.4 倍正文），
    // 所以这里直接用显式字号覆盖，保证移动端标题与正文接近。
    // fontScale 是乘在 .gitHub 默认标题字号上的（H1≈24pt），因此用 ~0.7 压到正文附近。
    private static let fontScales: [CGFloat] = [0.72, 0.78, 0.84, 0.90, 0.93, 0.96]

    func makeBody(configuration: Configuration) -> some View {
        let index = min(max(configuration.headingLevel - 1, 0), Self.fontScales.count - 1)
        configuration.label
            .textual.fontScale(Self.fontScales[index])
            .fontWeight(.semibold)
            .textual.blockSpacing(.fontScaled(top: 0.8, bottom: 0.3))
    }
}

/// 在 GitHub 风格基础上只覆盖「行内代码」与已自定义的标题/表格样式。
///
/// 为什么不能直接用 `.textual.inlineStyle(...)`：那个 modifier 作用于 `InlineText`，
/// 而 `StructuredText` 的行内样式由 `StructuredTextStyle.inlineStyle` 决定——它是 `let`
/// （见 Textual 的 `GitHubStyle.swift`），只能整体替换这个 style 结构体。
///
/// 为什么要去掉行内代码的背景：`.gitHub` 给它加了 `githubSecondaryBackground`，
/// 在用户消息的深绿气泡上会变成白底白字——真机截图里 `markdown:code:950`、`MarkdownBody`
/// 这些行内代码只剩白块，完全读不出来。等宽 + 略小字号已经足够区分，不需要底色。
struct ChatStructuredStyle: StructuredText.Style {
    let inlineStyle = InlineStyle().code(.monospaced, .fontScale(0.94))
    let headingStyle = ChatHeadingStyle()
    let paragraphStyle = StructuredText.GitHubParagraphStyle.gitHub
    let blockQuoteStyle = StructuredText.GitHubBlockQuoteStyle.gitHub
    let codeBlockStyle = StructuredText.GitHubCodeBlockStyle.gitHub
    let listItemStyle = StructuredText.DefaultListItemStyle.default
    let unorderedListMarker = StructuredText.HierarchicalSymbolListMarker.hierarchical(
        .disc, .circle, .square)
    let orderedListMarker = StructuredText.DecimalListMarker.decimal
    let tableStyle = PhoneTableStyle()
    let tableCellStyle = StructuredText.GitHubTableCellStyle.gitHub
    let thematicBreakStyle = StructuredText.GitHubThematicBreakStyle.gitHub
}
