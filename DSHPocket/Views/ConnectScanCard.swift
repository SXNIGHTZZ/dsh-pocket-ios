// ConnectScanCard

import SwiftUI

/// 连接页的「扫码连接电脑」卡片：准备条件 + 三步引导 + 扫码按钮。
///
/// 为什么单独成文件：这一块是纯展示，只依赖品牌色与「扫码页是否展开」一个绑定，
/// 从 ConnectView（原本 505 行）里拆出来既能降行数，也让修改文案时不必读整页。
struct ConnectScanCard: View {
    @Binding var showingScanner: Bool

    private var brand: Color { Color(red: 0.08, green: 0.48, blue: 0.37) }
    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(brand)
                Text(L10n.t("扫码连接电脑"))
                    .font(.headline)
                Spacer()
                Text(L10n.t("推荐"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(brand.opacity(0.12), in: Capsule())
                    .foregroundStyle(brand)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("准备（任选一种，都在电脑的「手机访问（iOS）」里切换）"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                prereqRow(
                    icon: "wifi",
                    title: L10n.t("局域网"),
                    detail: L10n.t("手机和电脑连同一个 Wi-Fi 就行，最快，手机不用装任何东西")
                )
                prereqRow(
                    icon: "cloud",
                    title: L10n.t("Cloudflare"),
                    detail: L10n.t("手机不用装东西，人在外面也能连（走公网，稍慢；首次电脑会自动下载约 20MB）")
                )
                prereqRow(
                    icon: "network",
                    title: L10n.t("Tailscale"),
                    detail: L10n.t("电脑和手机都装 Tailscale 并登录同一账号，地址固定，长期更稳")
                )
                prereqRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: L10n.t("EasyTier"),
                    detail: L10n.t("电脑跑 EasyTier 组网，手机用 Shadowrocket 等加载订阅配置；需先配好代理规则")
                )
                Divider().padding(.vertical, 2)
                Text(L10n.t("然后"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                guideStep("1", L10n.t("电脑装 dsh-pocket-ios 连接器（DSH → 设置 → 内置插件，只需这一个插件）"))
                guideStep("2", L10n.t("打开电脑 DSH → 设置 → 手机访问（iOS），选一种连接方式"))
                guideStep("3", L10n.t("用本 App 扫二维码：多数方式扫码即连；EasyTier 需先在手机上配好代理规则"))
            }
            Button {
                showingScanner = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                    Text(L10n.t("扫一扫，连接电脑"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(.white)
                .background(brand, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scan-connect-button")
        }
        .padding(14)
        .background(card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func prereqRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(brand)
                .frame(width: 22, height: 22)
                .background(brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func guideStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(brand, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
