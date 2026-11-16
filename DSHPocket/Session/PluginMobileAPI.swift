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

    /// 通道顺序与回退判定都下沉到 DSHKit（`PluginMobileChannelPolicy`），那里能单测。
    private static var channels: [String] { PluginMobileChannelPolicy.channels }

    /// 一次握手的结果。
    struct Session {
        let token: String
        let catalog: PluginMobileCatalog
        /// 实际走的通道，出错时能说清楚是哪条。
        let channel: String
    }

    enum APIError: LocalizedError {
        case notAuthenticated
        case badResponse(Int)
        case empty
        case noAggregator(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return L10n.t("需要先连接到电脑")
            case .badResponse(let code): return L10n.t("电脑没有响应（HTTP \(code)）")
            case .empty: return L10n.t("这台电脑上没有支持手机端的插件")
            case .noAggregator(let detail): return detail
            }
        }
    }

    /// 该不该换下一个通道——判定规则见 `PluginMobileChannelPolicy.shouldFallBack`。
    private static func shouldFallBack(_ error: Error) -> Bool {
        guard case APIError.badResponse(let code) = error else { return false }
        return PluginMobileChannelPolicy.shouldFallBack(statusCode: code)
    }

    /// 换一次性令牌。需要已登录的 cookie，所以走 `URLSession.shared`。
    static func fetchToken(baseURL: URL, channel: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "\(channel)/token"))
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

    /// 拉「哪些插件声明了移动端」。
    ///
    /// 解析放在 DSHKit 的 `PluginMobileCatalog`（App 层没有测试 target，
    /// 下沉才能单测——AGENTS.md 的约定）。
    ///
    /// **必须带 `mt` token**：这条路由和 `/mobile` 页面一样只认一次性令牌，
    /// 不认 cookie（因为手机侧走的是局域网/Tailscale 的 Host，过不了 DSH 的 Host 校验）。
    /// 之前这里漏传 token，直接 401，被映射成「需要先连接到电脑」（2026-11-16 踩到）。
    static func fetchList(baseURL: URL, channel: String, token: String) async throws -> PluginMobileCatalog {
        var components = URLComponents(
            url: baseURL.appending(path: "\(channel)/list"),
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

        return PluginMobileCatalog.parse(try? JSONSerialization.jsonObject(with: data))
    }

    /// 换 token + 拉列表，**按通道顺序尝试**。
    ///
    /// 两条都失败时给一句能照着做的提示，而不是一个裸 HTTP 码。
    static func fetchSession(baseURL: URL) async throws -> Session {
        var lastError: Error?
        for channel in channels {
            do {
                let token = try await fetchToken(baseURL: baseURL, channel: channel)
                let catalog = try await fetchList(baseURL: baseURL, channel: channel, token: token)
                return Session(token: token, catalog: catalog, channel: channel)
            } catch {
                lastError = error
                if shouldFallBack(error) { continue }
                throw error
            }
        }
        // 所有通道都是「端点不存在」：电脑端的插件太旧，或一个都没装。
        if lastError != nil {
            throw APIError.noAggregator(L10n.t(PluginMobileChannelPolicy.missingAggregatorMessage))
        }
        throw APIError.notAuthenticated
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
