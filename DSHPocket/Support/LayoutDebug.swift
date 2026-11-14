// 布局调试模式

import SwiftUI

/// 布局调试：给关键组件画细红框 + 小字编号，方便双方用「L2 太紧」这种说法对齐。
///
/// 为什么需要：调间距时只能靠「上面那行」「过程行和 DSH 那行之间」描述，
/// 而 `groupSpacing = 7` 和 `MessageRow` 内部的 `spacing: 8` 这类相邻数字很容易混，
/// 每次都要来回确认是哪一个。
///
/// 编号固定，不要随意改——用户会记住编号。
enum LayoutDebug {
    /// 开关。默认关；正式包里也保留，用户要在真机上用它反馈布局问题。
    @AppStorage("dsh-pocket.layout-debug") static var enabled = false

    /// 编号表（设置页展示，也是给用户的说明书）。
    struct Entry: Identifiable {
        let id: String
        let name: String
        let spacing: String
    }

    static let entries: [Entry] = [
        Entry(id: "L1", name: "过程行（ProcessRow）", spacing: "与下方 7pt"),
        Entry(id: "L2", name: "消息头（✦ DSH + 按钮）", spacing: "与气泡 8pt"),
        Entry(id: "L3", name: "消息气泡", spacing: "行间 5 / 12pt"),
        Entry(id: "L4", name: "输入栏", spacing: "—"),
        Entry(id: "L5", name: "生成状态条", spacing: "—"),
        Entry(id: "L6", name: "顶部导航", spacing: "—")
    ]
}

private struct LayoutDebugModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if LayoutDebug.enabled {
            content
                .overlay {
                    Rectangle()
                        .strokeBorder(Color.red.opacity(0.75), lineWidth: 0.5)
                }
                .overlay(alignment: .topLeading) {
                    Text(id)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 2)
                        .background(Color.white.opacity(0.85))
                        .fixedSize()
                }
                // 描边和信息层绝对不能吃掉点击：开着调试模式时仍要能点复制、展开过程。
                .allowsHitTesting(false)
        } else {
            content
        }
    }
}

extension View {
    /// 标记一个需要被「调试模式」标出来的布局组件。
    func layoutDebug(_ id: String) -> some View {
        modifier(LayoutDebugModifier(id: id))
    }
}
