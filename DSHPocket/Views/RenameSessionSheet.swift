// RenameSessionSheet

import SwiftUI

/// 重命名会话。
///
/// 为什么不用系统 `.alert` + `TextField`：在 iOS 27.3 真机上，alert 里的输入框
/// 只显示光标但**键盘不弹**，用户打不了字（实测；延迟弹窗也无效）。
/// 换成 sheet + `@FocusState` 显式聚焦，键盘弹出由我们控制。
struct RenameSessionSheet: View {
    let originalTitle: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @FocusState private var focused: Bool

    init(originalTitle: String,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.originalTitle = originalTitle
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: originalTitle)
    }

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("会话名称"), text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } footer: {
                    Text(L10n.t("会同步到电脑端的会话标题。"))
                }
            }
            .navigationTitle(L10n.t("重命名会话"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) { save() }
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .onAppear {
            // sheet 的转场动画结束后再聚焦，否则键盘会立刻被收起。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                focused = true
            }
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
