// PluginPanelSheet

import SwiftUI
import WebKit
import DSHKit

/// 插件移动面板：把插件声明的移动页面装进一个和「后台任务」一致的外壳里。
///
/// 这一版是**协议 v1 的 Layer 1（WebView 兜底）**，目的不是最终形态，
/// 而是验证「手机上到底会不会用插件」。所以刻意保持薄：
/// 原生只负责外壳（标题、加载态、失败态），内容完全交给插件自己的页面。
struct PluginPanelSheet: View {
    let baseURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var entry: PluginMobileEntry?
    @State private var pageURL: URL?
    @State private var webError: String?
    /// 页面里是否已经打开了某个插件——只有这时导航栏才出现「返回」。
    @State private var viewerOpen = false
    /// 让导航栏的返回能回到插件列表。
    @StateObject private var webBox = PluginWebViewBox()

    private enum Phase: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView(L10n.t("正在准备插件页面…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .empty:
                    ContentUnavailableView(
                        L10n.t("这台电脑上没有支持手机端的插件"),
                        systemImage: "puzzlepiece.extension",
                        description: Text(L10n.t("插件可以在 package.json 里声明 dsh.mobile 来启用手机端页面。"))
                    )

                case .failed(let message):
                    ContentUnavailableView(
                        L10n.t("打不开插件面板"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )

                case .ready:
                    if let pageURL {
                        PluginWebView(url: pageURL, errorMessage: $webError, viewerOpen: $viewerOpen, box: webBox)
                            .ignoresSafeArea(edges: .bottom)
                            .overlay {
                                if let webError {
                                    ContentUnavailableView(
                                        L10n.t("页面加载失败"),
                                        systemImage: "wifi.exclamationmark",
                                        description: Text(webError)
                                    )
                                    .background(.background)
                                }
                            }
                    }
                }
            }
            .navigationTitle(entry?.title ?? L10n.t("插件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 进到插件页面后才出现，位置和返回手势一致（标题左侧）。
                // 为什么由页面告诉原生：插件页是加载在页面内部的，原生看不见这层导航。
                if viewerOpen {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            webBox.closeViewer()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.backward")
                                    .font(.body.weight(.semibold))
                                Text(L10n.t("插件列表"))
                            }
                        }
                        .accessibilityLabel(L10n.t("返回插件列表"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
        }
        .task { await prepare() }
    }

    /// 换 token → 拉列表 → 拼出要加载的地址。
    ///
    /// 为什么一次只加载**第一个**声明了移动端的插件：协议 v1 明确「一个按钮 → 一个面板」，
    /// 多插件选择列表留到后续。真出现多个时，取第一个并记录诊断，避免静默忽略。
    private func prepare() async {
        do {
            // 双通道握手：`dsh-pocket-ios`（必装）优先，失败回退 `dsh-plugin-panel`（选装）。
            // 早先只认后者，导致只装了必装插件的用户点「插件」只能看到 HTTP 404。
            let session = try await PluginMobileAPI.fetchSession(baseURL: baseURL)
            let result = session.catalog
            guard let first = result.entries.first else {
                // 有声明但不合格时把原因说出来——否则用户会以为是「没装插件」。
                // 这段判断逻辑在 DSHKit 里（PluginMobileCatalog.emptyStateMessage），有单测覆盖。
                if let message = result.emptyStateMessage {
                    phase = .failed(message.title + " — " + message.detail)
                } else {
                    phase = .empty
                }
                return
            }
            entry = first
            guard first.manifest.kind == .web, let path = first.manifest.path else {
                // kind == .native 需要 Layer 2 的 Schema 渲染器，本版还没实现
                phase = .failed(L10n.t("这个插件用了原生声明（schema），需要更新版本的 App。"))
                return
            }
            guard let url = PluginMobileAPI.pageURL(baseURL: baseURL, path: path, token: session.token) else {
                phase = .failed(L10n.t("插件声明的页面地址无效。"))
                return
            }
            pageURL = url
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// 让 SwiftUI 能操作底层 `WKWebView`：导航栏的「返回」要回到插件列表。
final class PluginWebViewBox: ObservableObject {
    weak var webView: WKWebView?

    /// 页面没暴露 `__dshCloseViewer` 时什么也不做，不报错。
    func closeViewer() {
        webView?.evaluateJavaScript("window.__dshCloseViewer && window.__dshCloseViewer();")
    }
}

/// 最薄的 `WKWebView` 包装：负责加载、上报失败，以及把「进/出插件页」告诉原生。
///
/// 为什么要有这条消息：插件页是加载在列表页内部的（同源 iframe），
/// `WKWebView` 自己不会产生导航记录，原生无从知道用户是不是已经进了某个插件。
/// 页面在打开/关闭时发一条消息，导航栏据此决定显不显示「返回插件列表」。
struct PluginWebView: UIViewRepresentable {
    let url: URL
    @Binding var errorMessage: String?
    @Binding var viewerOpen: Bool
    let box: PluginWebViewBox

    func makeCoordinator() -> Coordinator {
        Coordinator(errorMessage: $errorMessage, viewerOpen: $viewerOpen)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 告诉页面「原生已经有返回按钮了」，页面就不用再画一条自己的
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.__DSH_NATIVE_VIEWER__ = true;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.add(context.coordinator, name: Coordinator.viewerMessage)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        box.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        box.webView = webView
        // 地址没变就不重载，避免 SwiftUI 重绘时把页面刷掉、丢掉用户滚动位置
        if webView.url != url, webView.isLoading == false {
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.viewerMessage)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let viewerMessage = "viewerState"

        private let errorMessage: Binding<String?>
        private let viewerOpen: Binding<Bool>

        init(errorMessage: Binding<String?>, viewerOpen: Binding<Bool>) {
            self.errorMessage = errorMessage
            self.viewerOpen = viewerOpen
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Coordinator.viewerMessage,
                  let body = message.body as? [String: Any],
                  let open = body["open"] as? Bool else { return }
            viewerOpen.wrappedValue = open
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            errorMessage.wrappedValue = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            errorMessage.wrappedValue = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 收到 401 时 WKWebView 报的是通用加载失败，这里换成更可操作的文案
            if (error as NSError).code == NSURLErrorUserAuthenticationRequired {
                errorMessage.wrappedValue = L10n.t("插件页面拒绝了这次访问，请关掉面板重新打开。")
            } else {
                errorMessage.wrappedValue = error.localizedDescription
            }
        }
    }
}
