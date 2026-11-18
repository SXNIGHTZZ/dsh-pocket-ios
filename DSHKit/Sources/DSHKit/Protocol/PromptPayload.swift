import Foundation

/// 构造 `session/prompt` 的请求体。
///
/// 为什么抽出来：这段结构原先在 performSend 里手拼，其中两条容易写错：
/// - 文本为空时**不能**塞一个空 text block（服务端会当成空消息）；
/// - 图片是 base64 内联在 content 里，字段名 mediaType/data/name 一个都不能差。
/// 放在 DSHKit 之后可以直接断言结构，不必等发到服务端才发现。
public enum PromptPayload {
    public struct Image: Equatable, Sendable {
        public let mediaType: String
        public let base64: String
        public let name: String
        public init(mediaType: String, base64: String, name: String) {
            self.mediaType = mediaType
            self.base64 = base64
            self.name = name
        }
    }

    /// 客户端来源标记（不可见）。
    ///
    /// 为什么需要：DSH 的 `user/message` 只记录 `source.kind`（user/system/subagent）、
    /// `rpcId` 和 `clientTimeZone`，**没有「哪个客户端发的」**。而 Mac 端（DSH Web）
    /// 我们改不了，所以约定：**iOS 发的消息带这个后缀，Mac 发的不带**——
    /// 助手靠「有没有」判断来源，同一条会话里混着两端时也分得清。
    ///
    /// 用 **U+2063 INVISIBLE SEPARATOR ×2**：
    /// - 零宽，界面上完全看不见（`⟦iOS⟧` 那种可见标记会显示在用户的每条消息里，难看）；
    /// - 实测 JS 的 `\s` 不匹配它、`trim()` 不删它、`\S` 匹配它，
    ///   所以不会被服务端的「非空白文本」校验判成空消息；
    /// - 它比 ZWSP(U+200B) 罕见得多，几乎不会被复制粘贴意外带进来造成误判。
    public static let clientMark = "\u{2063}\u{2063}"

    /// 判断这段文本是否带 iOS 来源标记（助手侧/诊断用）。
    public static func isFromClient(_ text: String) -> Bool {
        text.hasSuffix(clientMark)
    }

    /// 给正文加上来源标记。已经有标记就不重复加（断网补发可能重入）。
    public static func marked(_ text: String) -> String {
        guard !text.isEmpty, !text.hasSuffix(clientMark) else { return text }
        return text + clientMark
    }

    /// 消息内容块：文本在前、图片按顺序在后，空内容不产生块。
    ///
    /// 纯图片消息（text 为空）**不加标记**：那会多出一条只有标记的气泡，很难看。
    public static func content(text: String, images: [Image]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !text.isEmpty {
            blocks.append(["type": "text", "text": marked(text)])
        }
        for image in images {
            blocks.append([
                "type": "image",
                "mediaType": image.mediaType,
                "data": image.base64,
                "name": image.name
            ])
        }
        return blocks
    }

    /// 完整请求体。
    public static func request(requestId: String,
                               sessionId: String,
                               mode: PromptMode,
                               text: String,
                               images: [Image],
                               timeZone: String) -> [String: Any] {
        [
            "requestId": requestId,
            "sessionId": sessionId,
            "mode": mode.rawValue,
            "content": content(text: text, images: images),
            "clientTimeZone": timeZone
        ]
    }
}
