// ConversationMoreMenu

import SwiftUI
import DSHKit

/// 对话页右上角「更多」菜单：复制会话地址/日志路径/诊断信息、选择模型。
///
/// 为什么单独成文件：这一块只依赖几个只读字符串、一个 sheet 开关和「已复制」提示，
/// 从 655 行的 ConversationView 里拆出来后，改菜单项不必读整套滚动逻辑。
struct ConversationMoreMenu: View {
    @Bindable var model: ConnectionModel
    @Binding var showingModelPicker: Bool
    /// 复制成功后把内容回传给父视图弹「已复制」。
    var onCopied: (String) -> Void
    /// 打开后台任务。原先它是工具栏上的独立按钮，移到「更多」里省一格位置。
    var onShowJobs: () -> Void

    private var modelMenuTitle: String {
        guard let name = model.selectedModelLabel else { return L10n.t("选择模型") }
        if let effort = model.selectedReasoningLabel {
            return L10n.t("模型") + "：" + name + " · " + effort
        }
        return L10n.t("选择模型") + "：" + name
    }

    var body: some View {
        Menu {
            // 导航类动作放最前面，和下面的复制/诊断分开。
            Button {
                onShowJobs()
            } label: {
                Label(L10n.t("后台任务"), systemImage: "checklist")
            }
            // 和设置页里的是**同一个全局偏好**，放这里只是省一次跳转。
            Button {
                let next: PromptMode = model.busyEnterPreference == .steer ? .queue : .steer
                Task { await model.setBusyEnterPreference(next) }
            } label: {
                Label(
                    model.busyEnterPreference == .steer
                        ? L10n.t("发送方式：插话")
                        : L10n.t("发送方式：排队"),
                    systemImage: model.busyEnterPreference == .steer ? "arrow.down.to.line" : "list.bullet"
                )
            }
            Divider()
            Button {
                UIPasteboard.general.string = model.sessionAddress
                onCopied(model.sessionAddress)
            } label: {
                Label(L10n.t("复制会话地址"), systemImage: "link")
            }
            Button {
                if let path = model.sessionLogPath {
                    UIPasteboard.general.string = path
                    onCopied(path)
                }
            } label: {
                Label(L10n.t("复制会话日志路径"), systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                showingModelPicker = true
            } label: {
                // 模型 + 推理强度写在同一行：只显示模型会让人以为强度没生效。
                Label(modelMenuTitle, systemImage: "cpu")
            }
            Button {
                let report = model.diagnosticReport()
                UIPasteboard.general.string = report
                onCopied(report)
            } label: {
                Label(L10n.t("复制诊断信息"), systemImage: "stethoscope")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(L10n.t("更多"))
    }
}
