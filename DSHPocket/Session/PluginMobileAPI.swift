// PluginMobileAPI

import Foundation
import DSHKit

/// 插件移动端的两步握手（协议见 spec/2026-11-16-0600）。
///
/// 为什么分两步而不是直接把 cookie 注入 WebView：
/// `WKWebsiteDataStore` 和 `URLSession` 的 cookie 域行为不一致，注入容易出边界问题；
/// 换成「App 用 cookie 换一个 5 分钟短令牌 → WebView 用令牌打开页面」，
/// 只需要插件做一件很简单的事（校验令牌），不碰 cookie。
///
/// 为什么要两个客户端：
/// - 换 token 必须由 App 的 `URLSession.shared` 发出（它有登录 cookie）
/// - 加载页面交给 WebView，App 不参与
enum PluginMobileAPI {

    /// 插件管理插件提供的聚合入口。协议里定死它是聚合点，因为它是唯一
    /// 「本来就持有全部插件元数据」的插件，不需要改 DSH 内核。
    private static let channel = "/dsh-plugin-panel/mobile"

    enum APIError: LocalizedError {
        case notAuthenticated
        case badResponse(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return L10n.t("需要先连接到电脑")
            case .badResponse(let code): return L10n.t("电脑没有响应（HTTP \(code)）")
            case .empty: return L10n.t("这台电脑上没有支持手机端的插件")
            }
        }
    }

    /// 换一次性令牌。需要已登录的 cookie，所以走 `URLSession.shared`。
    static func fetchToken(baseURL: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "dsh-plugin-panel/mobile/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badResponse(http.statusCode) }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let token = json?["token"] as? String, !token.isEmpty else { throw APIError.empty }
        return token
    }

    /// 聚合接口的响应：合法条目 + 声明不完整的插件（含原因）。
    ///
    /// 为什么要把 invalid 带出来：服务端以前把不合格的声明直接过滤掉，
    /// App 只看到空数组，就显示「没有支持手机端的插件」——像是没装，
    /// 实际只是少个字段（2026-11-16 因此浪费半小时）。
    struct ListResult: Sendable {
        var entries: [PluginMobileEntry]
        var invalid: [(module: String, problems: [String])]
    }

    /// 拉「哪些插件声明了移动端」。
    ///
    /// **必须带 `mt` token**：这条路由和 `/mobile` 页面一样只认一次性令牌，
    /// 不认 cookie（因为手机侧走的是局域网/Tailscale 的 Host，过不了 DSH 的 Host 校验）。
    /// 之前这里漏传 token，直接 401，被映射成「需要先连接到电脑」（2026-11-16 踩到）。
    static func fetchList(baseURL: URL, token: String) async throws -> ListResult {
        var components = URLComponents(
            url: baseURL.appending(path: "dsh-plugin-panel/mobile/list"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "mt", value: token)]
        guard let url = components?.url else { throw APIError.badResponse(-1) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badResponse(http.statusCode) }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let plugins = json?["plugins"] as? [[String: Any]] ?? []
        let invalid = (json?["invalid"] as? [[String: Any]] ?? []).compactMap { raw -> (String, [String])? in
            guard let module = raw["module"] as? String, !module.isEmpty else { return nil }
            return (module, raw["problems"] as? [String] ?? [])
        }
        return ListResult(entries: plugins.compactMap(PluginMobileEntry.parse),
                          invalid: invalid.map { (module: $0.0, problems: $0.1) })
    }

    /// 拼出给 WebView 的完整地址：`{address}{path}?mt={token}`。
    ///
    /// 注意 `path` 来自插件声明，可能是相对路径（`/dsh-plugin-panel/mobile`），
    /// 也可能带查询串——这里统一按「拼到 baseURL 后」处理，不做字符串切割。
    static func pageURL(baseURL: URL, path: String, token: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL.appending(path: trimmed), resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "mt", value: token))
        components.queryItems = items
        return components.url
    }
}
