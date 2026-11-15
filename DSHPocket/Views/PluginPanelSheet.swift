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
                        PluginWebView(url: pageURL, errorMessage: $webError)
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
            let token = try await PluginMobileAPI.fetchToken(baseURL: baseURL)
            let entries = try await PluginMobileAPI.fetchList(baseURL: baseURL)
            guard let first = entries.first else {
                phase = .empty
                return
            }
            entry = first
            guard first.manifest.kind == .web, let path = first.manifest.path else {
                // kind == .native 需要 Layer 2 的 Schema 渲染器，本版还没实现
                phase = .failed(L10n.t("这个插件用了原生声明（schema），需要更新版本的 App。"))
                return
            }
            guard let url = PluginMobileAPI.pageURL(baseURL: baseURL, path: path, token: token) else {
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

/// 最薄的 `WKWebView` 包装：只负责加载和上报失败。
///
/// 不做 cookie 注入、不做 JS 桥——协议 v1 的定位就是「插件自己的页面自己管」。
struct PluginWebView: UIViewRepresentable {
    let url: URL
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator { Coordinator(errorMessage: $errorMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 地址没变就不重载，避免 SwiftUI 重绘时把页面刷掉、丢掉用户滚动位置
        if webView.url != url, webView.isLoading == false {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let errorMessage: Binding<String?>

        init(errorMessage: Binding<String?>) {
            self.errorMessage = errorMessage
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
