import Foundation

/// `POST /api/<method>` 的请求封装（用例 P03）。
public struct RPCRequest {
    public let method: String
    public let rpcId: UUID
    public let args: [String: Any]

    public init(method: String, rpcId: UUID = UUID(), args: [String: Any] = [:]) {
        self.method = method
        self.rpcId = rpcId
        self.args = args
    }

    /// 编码为 DSH 的 client-request envelope：`{type, rpcId, method, payload:{args}}`。
    public func encoded() throws -> Data {
        let body: [String: Any] = [
            "type": "client-request",
            "rpcId": rpcId.uuidString,
            "method": method,
            "payload": ["args": args]
        ]
        guard JSONSerialization.isValidJSONObject(body) else { throw DSHError.invalidPayload }
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// 从响应体提取 `result.value`。
    ///
    /// 失败有两种形状，都要认：
    /// 1. 顶层 `error`（传输/鉴权层失败）；
    /// 2. `result.ok == false` + `result.error.message`（业务失败）。
    /// 只认第一种会把业务失败当成成功——这是收口两套 RPC 时最容易漏的一条。
    public static func value(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DSHError.invalidPayload
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String
            throw DSHError.server(status: (error["status"] as? NSNumber)?.intValue ?? 0, message: message)
        }
        guard let result = object["result"] as? [String: Any] else { throw DSHError.invalidPayload }
        if (result["ok"] as? Bool) == false {
            let detail = result["error"] as? [String: Any]
            let message = detail?["message"] as? String
            let status = (detail?["status"] as? NSNumber)?.intValue ?? 0
            throw DSHError.server(status: status, message: message)
        }
        guard let value = result["value"] as? [String: Any] else { throw DSHError.invalidPayload }
        return value
    }

    /// 只判断成功与否，**不要求** `result.value` 是字典。
    ///
    /// 有些接口（如 `userQuestions/answer`）只关心「答没答上」，返回体里
    /// `value` 可能是 null / 数组 / 整个字段缺失。用 `value(from:)` 会抛
    /// `invalidPayload`，界面就显示「服务器响应格式无效」——但服务端其实已经成功了。
    /// 这类「命令式」接口应该用这个宽松版。
    public static func ok(from data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DSHError.invalidPayload
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String
            throw DSHError.server(status: (error["status"] as? NSNumber)?.intValue ?? 0, message: message)
        }
        guard let result = object["result"] as? [String: Any] else { throw DSHError.invalidPayload }
        if (result["ok"] as? Bool) == false {
            let detail = result["error"] as? [String: Any]
            let message = detail?["message"] as? String
            let status = (detail?["status"] as? NSNumber)?.intValue ?? 0
            throw DSHError.server(status: status, message: message)
        }
    }
}
