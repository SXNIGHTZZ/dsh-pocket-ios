// 布局调试模式

import SwiftUI

/// 布局调试：给关键组件画细红框 + 小字编号 + 间距数字，方便用「C2 太紧」这种说法对齐。
///
/// 为什么需要：调间距时只能靠「上面那行」「过程行和 DSH 那行之间」描述，
/// 而相邻的两处间距（`TimelineSpacing.groupSpacing = 7` 和 `MessageRow` 内部的 `8`）
/// 很容易混，每次都要来回确认是哪一个。
///
/// **编号按页分组，稳定不变，用户会记住**：
/// - `S*` = 列表页（Sessions）
/// - `C*` = 对话页（Conversation）
/// - `G*` = 全局（导航栏、提示条）
enum LayoutDebug {
    /// 开关。默认关；正式包里也保留，用户要在真机上用它反馈布局问题。
    @AppStorage("dsh-pocket.layout-debug") static var enabled = false

    struct Entry: Identifiable {
        let id: String
        let name: String
        let spacing: String
        /// 分组标题（设置页按这个分 Section）
        let group: String
    }

    /// **编号表的唯一真源**：设置页直接遍历这个数组，不另写一份。
    static let entries: [Entry] = [
        // ── 列表页 ──
        Entry(id: "S1", name: "工作区块（卡片）", spacing: "—", group: "列表页"),
        Entry(id: "S2", name: "工作区图标", spacing: "—", group: "列表页"),
        Entry(id: "S3", name: "工作区名称", spacing: "—", group: "列表页"),
        Entry(id: "S4", name: "展开/收起箭头", spacing: "—", group: "列表页"),
        Entry(id: "S5", name: "会话数量徽标", spacing: "—", group: "列表页"),
        Entry(id: "S6", name: "会话行（单条）", spacing: "行间 —", group: "列表页"),
        Entry(id: "S7", name: "会话标题", spacing: "—", group: "列表页"),
        Entry(id: "S8", name: "会话元信息", spacing: "—", group: "列表页"),
        Entry(id: "S9", name: "搜索框", spacing: "—", group: "列表页"),
        Entry(id: "S10", name: "空态提示", spacing: "—", group: "列表页"),

        // ── 对话页 ──
        Entry(id: "C1", name: "过程行（ProcessRow）", spacing: "与下方 7pt", group: "对话页"),
        Entry(id: "C2", name: "消息头容器（✦ DSH + 按钮）", spacing: "与气泡 8pt", group: "对话页"),
        Entry(id: "C3", name: "消息气泡", spacing: "行间 5 / 12pt", group: "对话页"),
        Entry(id: "C4", name: "气泡内 Markdown 正文", spacing: "—", group: "对话页"),
        Entry(id: "C5", name: "气泡内插图", spacing: "—", group: "对话页"),
        Entry(id: "C6", name: "发送者星标图标", spacing: "与文字 8pt", group: "对话页"),
        Entry(id: "C7", name: "发送者文字（DSH/你）", spacing: "—", group: "对话页"),
        Entry(id: "C8", name: "复制按钮", spacing: "图标 14 / 可点 44pt", group: "对话页"),
        Entry(id: "C9", name: "引用按钮", spacing: "图标 14 / 可点 44pt", group: "对话页"),
        Entry(id: "C10", name: "输入栏", spacing: "—", group: "对话页"),
        Entry(id: "C11", name: "生成状态条", spacing: "—", group: "对话页"),
        Entry(id: "C12", name: "失败卡", spacing: "—", group: "对话页"),

        // ── 全局 ──
        Entry(id: "G1", name: "顶部导航栏", spacing: "—", group: "全局"),
        Entry(id: "G2", name: "演示模式提示条", spacing: "—", group: "全局")
    ]

    /// 把语义字号换算成「实际 pt」，用于标注。
    ///
    /// 为什么不直接写数字：代码里用的是 `.footnote` 这类**语义样式**（规范禁止硬编码字号），
    /// 实际像素取决于用户的字号设置。这里问系统要真实值，标注才准。
    static func font(_ style: Font.TextStyle) -> String {
        let uiStyle: UIFont.TextStyle
        switch style {
        case .largeTitle: uiStyle = .largeTitle
        case .title: uiStyle = .title1
        case .title2: uiStyle = .title2
        case .title3: uiStyle = .title3
        case .headline: uiStyle = .headline
        case .subheadline: uiStyle = .subheadline
        case .body: uiStyle = .body
        case .callout: uiStyle = .callout
        case .footnote: uiStyle = .footnote
        case .caption: uiStyle = .caption1
        case .caption2: uiStyle = .caption2
        @unknown default: uiStyle = .body
        }
        let size = UIFont.preferredFont(forTextStyle: uiStyle).pointSize
        return "\(name(style)) \(Int(size.rounded()))pt"
    }

    private static func name(_ style: Font.TextStyle) -> String {
        switch style {
        case .largeTitle: return "largeTitle"
        case .title: return "title"
        case .title2: return "title2"
        case .title3: return "title3"
        case .headline: return "headline"
        case .subheadline: return "subheadline"
        case .body: return "body"
        case .callout: return "callout"
        case .footnote: return "footnote"
        case .caption: return "caption"
        case .caption2: return "caption2"
        @unknown default: return "body"
        }
    }

    /// 按分组聚合（设置页用）。保持 entries 里的原始顺序。
    static var grouped: [(group: String, entries: [Entry])] {
        var order: [String] = []
        var map: [String: [Entry]] = [:]
        for entry in entries {
            if map[entry.group] == nil { order.append(entry.group) }
            map[entry.group, default: []].append(entry)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

private struct LayoutDebugModifier: ViewModifier {
    let id: String
    let gap: String?
    let text: String?

    func body(content: Content) -> some View {
        if LayoutDebug.enabled {
            content
                .overlay {
                    Rectangle()
                        .strokeBorder(Color.red.opacity(0.75), lineWidth: 0.5)
                }
                .overlay(alignment: .topLeading) { badge(id) }
                .overlay(alignment: .topTrailing) {
                    if let text { badge(text) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let gap { badge(gap) }
                }
                // 描边和信息层绝对不能吃掉点击：开着调试模式时仍要能点复制、展开过程。
                .allowsHitTesting(false)
        } else {
            content
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(.red)
            .padding(.horizontal, 2)
            .background(Color.white.opacity(0.85))
            .fixedSize()
    }
}

extension View {
    /// 标记一个需要被「调试模式」标出来的布局组件。
    /// - Parameters:
    ///   - id: 编号（见 `LayoutDebug.entries`）。
    ///   - gap: 这个组件与其下方元素之间的间距，**填代码里的常量值**（如 "7pt"）。
    ///   - text: 字号，用 `LayoutDebug.font(.footnote)` 生成（会换算成实际 pt）。
    func layoutDebug(_ id: String, gap: String? = nil, text: String? = nil) -> some View {
        modifier(LayoutDebugModifier(id: id, gap: gap, text: text))
    }
}
