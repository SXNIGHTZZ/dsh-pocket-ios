// 问答通道：$events

import Foundation
import DSHKit
import os

/// `$events` 通道：服务端把需要客户端处理的请求推过来，客户端处理完回传结果。
///
/// 为什么需要它（见 spec/2026-11-14-1500-question-answer-provider）：
/// `userQuestions/answer` 要求问题处于 `continued` 状态，而该状态只在工具超时后出现，
/// 所以手机点答案必然被拒。浏览器端走的是这条 `$events` 通道——收到请求后
/// **直接把答案作为请求结果回传**，点完立即生效。
extension ConnectionModel {
    /// 与 `session/follow` 共用同一个 `api/remote.mux`，只是多开一条 endpoint 为 `$events` 的流。
    ///
    /// 独立于 `runLiveStream`：这条流挂了不影响对话实时同步，反之亦然。
    @MainActor
    func runRemoteEvents() async {
        guard !isDemoMode else { return }
        guard let base = URL(string: connection.serverAddress),
              let socketURL = Self.webSocketURL(from: base, path: "api/remote.mux") else {
            recordDiagnostic("问答通道未启动：地址无效")
            return
        }
        var retryDelay: Duration = .seconds(1)
        while !Task.isCancelled {
            let socket = URLSession.shared.webSocketTask(with: socketURL)
            socket.resume()
            let streamId = UUID().uuidString
            do {
                let open = StreamOpen(type: "open", streamId: streamId,
                                      endpoint: RemoteEventProtocol.streamEndpoint,
                                      payload: RemoteEventProtocol.streamPayload)
                let data = try JSONEncoder().encode(open)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ConnectionError.invalidPayload
                }
                try await socket.send(.string(text))
                recordDiagnostic("问答通道：已发起连接")
                var clientId: String?
                var framesSeen = 0
                while !Task.isCancelled {
                    let frame = try await Self.receiveRemoteEventFrame(socket: socket)
                    // 前几帧原样记录：协议字段名没文档，先看真实形状（只记 5 帧，避免刷屏）。
                    if framesSeen < 5 {
                        framesSeen += 1
                        let text = String(data: frame, encoding: .utf8) ?? "<\(frame.count)B>"
                        recordDiagnostic("问答通道原始帧#\(framesSeen): \(text.prefix(400))")
                    }
                    guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                        continue
                    }
                    // `$events` 的帧包在 `{type:"item", streamId, value:{...}}` 里，
                    // 解包字段是 **value**（不是 item）。实测原始帧：
                    // {"type":"item","streamId":"...","value":{"type":"ready","clientId":"...","host":{"home":"..."}}}
                    let payload: [String: Any]
                    if object["type"] as? String == "item",
                       let item = object["value"] as? [String: Any] {
                        payload = item
                    } else {
                        payload = object
                    }
                    if let ready = RemoteEventProtocol.ready(from: payload) {
                        clientId = ready.clientId
                        recordDiagnostic("问答通道就绪 clientId=\(ready.clientId.prefix(8))")
                        continue
                    }
                    guard let clientId else { continue }
                    switch RemoteEventProtocol.frame(from: payload) {
                    case .cancel(let eventId):
                        questionInbox.cancelProviderRequest(eventId: eventId)
                        recordDiagnostic("问答通道：服务端撤销了请求 \(eventId.prefix(12))")
                    case .emit:
                        break
                    case .request(let eventId, let raw):
                        let method = RemoteEventProtocol.methodName(in: raw)
                        let args = RemoteEventProtocol.arguments(in: raw) ?? [:]
                        recordDiagnostic("问答通道收到请求 method=\(method ?? "nil") eventId=\(eventId.prefix(12)) args=\(String(describing: args).prefix(160))")
                        if method == "user-questions/request" {
                            questionInbox.receiveProviderRequest(clientId: clientId,
                                                                 eventId: eventId,
                                                                 args: args)
                        } else {
                            // 不是问答请求：也要回传 rejected，否则服务端那条 waterfall 会一直挂着。
                            await sendRemoteEventRejection(clientId: clientId, eventId: eventId,
                                                           message: "unsupported request: \(method ?? "unknown")")
                        }
                    case .unknown(let type):
                        recordDiagnostic("问答通道收到未知帧 type=\(type ?? "nil")")
                    }
                }
                retryDelay = .seconds(1)
            } catch {
                guard !Task.isCancelled else { break }
                recordDiagnostic("问答通道断开，\(Int(retryDelay.components.seconds)) 秒后重连：\(error.localizedDescription)")
                try? await Task.sleep(for: retryDelay)
                retryDelay = LiveStreamPolicy.nextReconnectDelay(after: retryDelay)
            }
        }
    }

    /// 收一帧，带超时——否则连接假死时会永久卡在这里（对话流踩过同样的坑）。
    private static func receiveRemoteEventFrame(socket: URLSessionWebSocketTask) async throws -> Data {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await socket.receive()
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw ConnectionError.remote("问答通道 180 秒无数据，主动重连")
            }
            guard let first = try await group.next() else {
                throw ConnectionError.remote("问答通道无数据")
            }
            group.cancelAll()
            return first
        }
        switch message {
        case .data(let bytes): return bytes
        case .string(let text): return Data(text.utf8)
        @unknown default: return Data()
        }
    }

    /// 回传处理结果。失败只记录——卡片状态由 QuestionInbox 自己维护。
    @MainActor
    func sendRemoteEventResult(clientId: String, eventId: String, value: Any?) async {
        let body = RemoteEventProtocol.resultBody(clientId: clientId, eventId: eventId, value: value)
        await sendRemoteEventBody(body, eventId: eventId, label: "结果")
    }

    @MainActor
    func sendRemoteEventRejection(clientId: String, eventId: String, message: String) async {
        let body = RemoteEventProtocol.rejectionBody(clientId: clientId, eventId: eventId, message: message)
        await sendRemoteEventBody(body, eventId: eventId, label: "拒绝")
    }

    @MainActor
    private func sendRemoteEventBody(_ body: [String: Any], eventId: String, label: String) async {
        do {
            let client = try rpcClient
            try await client.remoteEventResult(body)
            recordDiagnostic("问答通道已回传\(label)：eventId=\(eventId.prefix(12))")
        } catch {
            recordDiagnostic("问答通道回传\(label)失败：eventId=\(eventId.prefix(12)) err=\(error.localizedDescription)")
        }
    }
}
