# 手机端参与问答：走 `$events` provider 通道

> **Status**: Draft
> **起始日期**：2026-11-14
> **预估工时**：210 分钟（单元累加）
> **文件名**：`spec/2026-11-14-1500-question-answer-provider.md`

## 背景 / 问题

`ask_user_question` 的问答卡在**手机端点了没有效果**：界面显示「回答没被接受」，电脑端 agent 永远收不到答案，步骤停在「正在等待你的选择」。

实测证据（真机 `diagnostics.log`）：

```
回答用户问题：call_00_nzpVEbhFUIzvijUeeMRV9928
raw={"result":{"ok":true,"value":false}}
回答被服务端拒绝
```

请求**确实发出去了**（服务端回了 `server-response`），但服务端 `userQuestions/answer` 返回 `false`。

根因（读 DSH 0.2.2-rc.2 源码确认）：

```js
// dsh-user-questions/lib/index.js
answer(agent, callId, answer) {
    const question = this.continued(agent).find(item => item.callId === callId);
    if (question === void 0) return false;    // ← 这里返回 false
}
continued(agent) {
    return stateOf(agent.session).questions.active.filter(q => q.state === "continued");
}
```

问题状态机只有 `open` →（`tool/result` pending 或 `tool/ptc-dispatch` pending）→ `continued`。而 `ask_user_question` 在用户回答前不会产生 `tool/result`，所以**在等待期间 state 一直是 `open`**，`answer` 必然返回 `false`。

这个会话的实测：

```
ask_user_question 出现 1 次
ptc-dispatch      出现 0 次     ← 没走 PTC 分发
```

**对比：浏览器端为什么能答**

`dsh-client-ui-user-questions`（浏览器）**不走 `answer`**——它作为 provider 直接返回答案。它的处理在 `dsh-api-gateway/lib/client.browser.js`：

```js
// 打开 $events 流 → 第一帧拿到 clientId → 后续帧是请求 → 处理后回传
const response = await this.connection.rpc.call('/api', REMOTE_EVENT_RESULT_ENDPOINT, { args: result })
// REMOTE_EVENT_RESULT_ENDPOINT = '$events/result'
```

**App 只处理了 `type == "item"` 的流式消息，从来没有打开过 `$events` 流，所以服务端不会把问答请求推给它。**

用户诉求：**手机点完立刻生效，不用电脑端配合，也不用等 120 秒超时。**

## 目标与非目标

**目标**
1. App 打开 `$events` 流，成为服务端可推送的客户端。
2. 收到 `user-questions/request` 时，**用户的选择直接作为该请求的结果回传**，不调 `userQuestions/answer`。
3. 手机端选完立即生效（agent 当场收到答案）。
4. 保留 `answer` 作为兜底（`$events` 不可用时仍能尝试），但**失败要明确报错**。

**非目标**
- 不改电脑端（浏览器）行为。
- 不实现其他 `$events` 事件类型（只处理问答；其余记录日志后忽略）。
- 不做离线队列（问答是即时交互，离线时本来也不该显示卡片）。

## 参考实现（Prior art）

- **`dsh-api-gateway/lib/client.browser.js`**（浏览器端官方实现）：
  - 打开 `$events` 流，`payload = { args: {} }`
  - 第一帧 `parseRemoteEventReady` 拿 `clientId`
  - 后续帧 `parseRemoteEventFrame`：`type` 为 `cancel` / `emit` / 其余视为请求
  - 请求处理完调 `rpc.call('/api', '$events/result', { args: { clientId, eventId, outcome } })`
  - `outcome.kind`：`result`（带 `value`）/ `rejected`（带 `error`）/ `next`
  → **采用**：整套流程照搬。
- **`dsh-api-gateway/lib/types/stream-protocol.js`**：协议常量的唯一定义
  （`REMOTE_STREAM_MUX_PATH`、`REMOTE_EVENT_STREAM_ENDPOINT`、`REMOTE_EVENT_RESULT_ENDPOINT`）
  → **采用**：把这些常量放进 DSHKit，避免在 App 里散落魔法字符串。
- **本项目已有的 `session/follow` 流**（`LiveStreamRunner`）
  → **采用**：复用同一套 WebSocket 连接与 `open` 帧格式，只是多开一条流。

## 方案

### 第 1 步：先量出真实帧结构（不猜协议）

浏览器实现里，请求帧的字段（`eventId` 之外还有什么）没有文档。**先不写死**：

在 `LiveStreamRunner` 旁加一条**独立的 `$events` 流**，把收到的每一帧**原样写进诊断日志**（截断 500 字符），跑一次问答，看真实形状。

**为什么先做这步**：协议细节猜错的代价是把用户可见功能写坏，而记录原始帧只要 20 行代码。

### 第 2 步：DSHKit 加协议常量与帧解析（可单测）

新增 `RemoteEventProtocol`：

```swift
public enum RemoteEventProtocol {
    public static let streamEndpoint = "$events"
    public static let resultEndpoint = "$events/result"
    public static let streamPayload = ["args": [:] as [String: Any]]

    /// 第一帧就绪信息
    public struct Ready { public let clientId: String; public let host: String? }
    public static func ready(from value: [String: Any]) -> Ready?

    /// 后续帧分类
    public enum Frame {
        case cancel(eventId: String)
        case emit(eventId: String)
        case request(eventId: String, payload: [String: Any])
        case unknown(type: String?)
    }
    public static func frame(from value: [String: Any]) -> Frame

    /// 回传体
    public static func resultBody(clientId: String, eventId: String, value: Any?) -> [String: Any]
    public static func rejectionBody(clientId: String, eventId: String, message: String) -> [String: Any]
}
```

**纯逻辑、可单测**（帧分类、回传体构造）。

### 第 3 步：App 侧接线

1. `LiveStreamRunner` 增加 `runRemoteEvents()`：与 `session/follow` **并行**开一条流（同一个 `api/remote.mux`）。
2. 收帧 → `RemoteEventProtocol.frame` 分类：
   - `.request` 且 payload 的 method 是 `user-questions/request` → 交给 `QuestionInbox`
   - 其余 → 记录诊断后忽略（用 `rejected` 回传，避免服务端一直挂着）
3. `QuestionInbox` 收到 provider 请求时：**显示卡片 + 记住 `(clientId, eventId)`**
4. 用户点提交 → 构造 `outcome = {kind: "result", value: {answers: [...]}}`
   → `POST api/$events/result`
   **不再调 `userQuestions/answer`**
5. 若这条流不可用（连接失败/服务端没推 ready）→ 回退到旧的 `answer` 路径，并明确报错。

### 第 4 步：卡片状态与两条路径的关系

- provider 路径成功 → `noteSettled` → 卡片收起
- provider 路径失败 → 保留卡片 + 展示错误（不假装成功）
- 兜底 `answer` 路径 → 校验 `value`，`false` 明确报错（本次已实现，`d3e70ec`）

## 被否决的方案

| 方案 | 否决理由 | 依据 |
| --- | --- | --- |
| 等 120 秒超时后再提交 | 用户点完要等两分钟，等于不可用 | `ask_user_question` 默认 timeout 120s |
| 继续只用 `answer`，改参数 | `answer` 要求 `state == continued`，而等待期间永远是 `open`，参数怎么改都不成立 | `dsh-user-questions` 源码 |
| 让电脑端常开浏览器 | 手机独立可用是产品前提，不能要求用户开着电脑网页 | 用户明确要求 |
| 改 DSH 服务端让 `answer` 接受 `open` | 上游不属于本项目，改动无法随 App 发布 | 依赖边界 |
| 用轮询 `userQuestions` 状态代替 provider | 仍需提交路径；轮询只能看状态，不能回答 | 协议无此接口 |

## 代价与风险

**代价**（确定会付）
- 多一条常驻 WebSocket 流（与 `session/follow` 共用连接，内存增量小）
- 约 150 行新代码 + 测试
- 卡片状态机要同时兼顾 provider 与兜底两条路径

**风险**（可能发生）
| 风险 | 缓解 |
| --- | --- |
| `$events` 帧结构猜错 | 第 1 步先记录原始帧再实现 |
| 两条流同时存在导致重连逻辑混乱 | `$events` 独立生命周期，失败不影响 `session/follow` |
| `$events/result` 的 HTTP 路径不对（`/api/$events/result` vs `/api`） | 第 1 步同时记录浏览器请求路径；实现后实测 |
| 服务端把非问答请求也推过来（比如别的 waterfall） | 全部 `rejected` 回传并记录，避免挂死 |
| 手机和浏览器同时开着，出现双答 | 服务端 waterfall 先到先得；后到的返回 rejected，记录日志 |

## 未决问题（Unresolved Questions）

- `$events` 流的请求帧里，**方法名**放在哪个字段（`method`? `endpoint`? `payload.method`）？
  第 1 步记录原始帧后确定。
- `outcome.value` 的形状是否就是 `{ answers: [...] }`（和 `answer` 的 `answer` 参数一致）？
- 同一条 `remote.mux` 上能否稳定并行两条流（`session/follow` + `$events`）？需要实测。
- `$events` 流断开后是否需要重新 `open` 并重新拿 `clientId`？（推测需要，实现时按重连处理）

## 测试计划（先红后绿）

| 用例 | target | 断言 |
| --- | --- | --- |
| ready 帧解析 | `DSHKitTests/RemoteEventProtocolTests` | 缺 `clientId` 返回 nil；正常帧解析出 clientId |
| 帧分类：cancel | 同上 | `type == "cancel"` → `.cancel(eventId:)` |
| 帧分类：emit | 同上 | `type == "emit"` → `.emit` |
| 帧分类：请求 | 同上 | 带 `eventId` 且无已知 type → `.request` |
| 帧分类：未知 | 同上 | 无 `eventId` → `.unknown` |
| 回传体：成功 | 同上 | 含 `clientId`/`eventId`/`outcome.kind == "result"` |
| 回传体：拒绝 | 同上 | `outcome.kind == "rejected"` 带 message |
| 回归 | `swift test` | 386+ 绿 |
| 架构 | `check-architecture.sh` | 违规 0 |
| 真机 | 手工 | 手机选完 → agent 当场收到答案；卡片正常收起 |

## 预估工时

| 单元 | 数量 | 单耗依据 | 小计 |
| --- | --- | --- | --- |
| spec 定稿 | 1 | 约 30 | 30 分钟 |
| 第 1 步：开流 + 记录原始帧 | 1 | 同类约 30 | 30 分钟 |
| 实测并确定帧结构 | 1 | 约 15 | 15 分钟 |
| `RemoteEventProtocol` + 7 条测试 | 1 | 同类约 30 | 30 分钟 |
| App 接线（流 + 分类 + 回传） | 1 | 约 50 | 50 分钟 |
| `QuestionInbox` 双路径改造 | 1 | 约 30 | 30 分钟 |
| 真机验证与修正 | 1 | 约 25 | 25 分钟 |
| **合计** | | | **210 分钟** |
