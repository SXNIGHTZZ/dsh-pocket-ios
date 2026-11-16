# CONTEXT.md — dsh-pocket-ios 术语表

> **探索这个仓库前先读这份。** 用里面的词汇描述一切；与 ADR 冲突时**显式说明**，不要悄悄按自己的想法做。
>
> 只写定义，不写流程（流程在 `AGENTS.md`）、不写决策理由（在 `docs/adr/`）、不写本次任务（在 `spec/`）。
>
> 最后更新：2026-11-16

## 产品

**DSH（DeepSeek Harness）**: 电脑上运行的 Agent 宿主，本项目是它的移动端。DSH 本体开源（MIT），
通过 `packages/**/README.zh.md` 查它的行为，**不要读打包产物猜**。

**插件（plugin）**: DSH 里提供能力的模块。它可以声明 `dsh.mobile` 让自己在手机上有一个入口——
这是整个产品的理由：**插件才是 DSH 的核心，手机端只是让插件多一个出口**。

**插件移动端分级**: 插件在手机上能提供什么，分五档。见 `docs/插件移动端分级.md`。

| 级别 | 作者要做的 | 手机上 |
| --- | --- | --- |
| **L0** | 不声明 `dsh.mobile` | 列表可见，无「打开」 |
| **L1** | `kind: "web"` + HTML | WebView 打开 |
| **L1.5** | L1 + 调 JS Bridge | 同上 + 分享/相册/震动 |
| **L2a** | 声明 volatile config（本来就要写） | 原生配置表单 |
| **L2b** | `kind: "native"` + 内容 DSL | 原生渲染内容 |

**L2 拆 a/b 是关键**：L2a 复用 DSH 已有的 `settings` schema，作者零投入；L2b 要自建 UI DSL，是重工程。

**宿主（Host）**: 本项目里的 `plugin/`（npm 包 `dsh-pocket-ios`）。
它是**装在 DSH 里的插件**，不是独立应用。职责四件：反向代理、PIN 配对、长期凭证、插件聚合端点。

---

## 架构分层

**pure-logic**: `DSHKit/Sources`。无 UI 依赖的策略/解析/传输。**上限 400 行**，100% 可单测。

**app**: `DSHPocket/`（尤其 `Session/`）。编排层：持有 `@Published` 状态、串联调用、把错误映射成 UI。
**上限 600 行**。

**ui-tests**: `DSHPocketUITests/`。端到端。

三层由 `scripts/check-architecture.sh` 检查，退出码 1。

**DSHKit**: 纯逻辑的 Swift Package。**能测的代码都该在这里**。
它的测试密度是 74 个测试文件 / 64 个源文件——这是刻意维持的。

**Session 层**: `DSHPocket/Session/`，30 个文件 6525 行。**它是当前的架构债**：
里面混了纯逻辑（Outbox 状态机、分页边界、失败分类）、平台能力（图片、剪贴板）、接线代码。
**2101 行本该可测却因为落在 App target 而测不了。** 见 `docs/adr/0002`。

**`ConnectionModel`**: `DSHPocket/Session/ConnectionModel.swift` 及其 10 个 extension。
它是**唯一的状态容器 + 编排入口**，被约 140 处引用。改动它要预期连锁反应。

---

## 协议与认证

**通道（channel）**: 插件暴露给手机的 URL 前缀。本项目有两个：

| 通道 | 提供方 | 用途 |
| --- | --- | --- |
| `/dsh-pocket/plugins` | 本项目的聚合端点 | 插件列表 / 开关 / token（**首选**） |
| `/dsh-plugin-panel/mobile` | `dsh-plugin-panel` 插件 | 旧通道，作为回退 |

**回退策略**：只对 404/405 回退（`PluginMobileChannelPolicy.shouldFallBack`）。
其他错误不回退——否则真故障会被当成"通道不存在"。

**移动 token（`mt`）**: 手机调插件端点时携带的短期凭证。
**规则：页面只验格式（`/^[A-Za-z0-9_-]{32}$/`），签发方严格校验自己的 Map。**
这条规则是为了让任意插件都能接收 token 而不用共享密钥。

**PIN**: 用户首次连接时输入的一次性口令，用于把手机和设备绑定。

**长期设备凭证**: 存在宿主 `devices.json`（权限 0600），以 `Set-Cookie` 下发；App 存 Keychain。
**DSH 重启后能用它自动换票，不需要重新扫码。** 见 `docs/adr/0004`。

**Host 改写**: 代理转发给 DSH 时把 `Host` 改成 `127.0.0.1:<dshPort>`。
DSH 只接受 loopback 的请求，不改写会被它拒。

---

## 状态与缓存

**Outbox**: 未发送成功的消息队列。**要落盘**——用户点了发送就该记住，不能因为断网丢失。

**`HeldOfflineDelivery`**: 发送结果的四态。

| 态 | 含义 | 处理 |
| --- | --- | --- |
| `acked` | 服务端确认 | 从队列移除 |
| `stillOffline` | 仍离线 | **保留**，稍后重试 |
| `auth` | 认证失效 | 提示重新配对 |
| `failed` | 永久失败 | 标记失败，给重试入口 |

**`inSessionMessageLimit`**: 会话内保留 30 条（约 15 轮）。
不是产品设计，是**内存约束**：压测 400 轮吃到 1682 MB 会 OOM。见 `docs/adr/0007`。

**`ConversationCachePolicy`**: 切走的会话最多留 3 份，按 `lastOpenedAt` LRU 淘汰；当前会话 `pinned` 不淘汰。

**`SessionOpenPolicy`**: 有缓存就不拉 HTTP 基线（`shouldFetchHTTPBaseline == (cachedCount == 0)`）。

---

## 插件页

**WebView 通道**: 插件页面在 `WKWebView` 里打开。这是 L1。
**注意**：`allowsInlineMediaPlayback` 目前是 false，视频会全屏——待修。

**JS Bridge**: L1.5 的能力出口（分享/保存图片/震动/打开链接）。**尚未实现。**

**聚合端点**:  `/dsh-pocket/plugins/*`。列出所有声明了 `dsh.mobile` 的插件，让手机不依赖某个特定插件面板。

---

## 安全

**暴露面**: 代理监听 `0.0.0.0`，**除 `/dsh-pocket-ios/*` 外全部转发给 DSH WebUI**。
所以手机持有效 cookie 时，等于能访问整个 WebUI。这是已知的架构取舍，见 `docs/adr/0006`。

**路径白名单**: 收窄暴露面的方案（只放行手机实际用到的路径）。**尚未实现**，
因为需要先统计「手机真实请求过哪些路径」，否则漏一条会静默失效。

---

## 不在本项目范围

| 概念 | 为什么不在 |
| --- | --- |
| Android 客户端 | 当前只做 iOS。**若要支持 Android，逻辑必须上移到共享层**（见 `docs/adr/0009`） |
| 通用客户端功能（Agent traces、teams、折叠屏） | 产品定位是「让插件在手机上更好用」 |
| 自建中继服务 | 远程访问目前依赖 Tailscale / Cloudflare |

---

## 相关文档

| 文档 | 内容 |
| --- | --- |
| `AGENTS.md` | 协作入口 + 硬性禁止 + 现状 |
| `docs/adr/` | 架构决策（**只追加 Update**） |
| `docs/architecture/fact.json` | 脚本生成的模块与依赖图谱（**禁止手写**） |
| `docs/architecture/journey.jsonl` | 决策注册表（`id` 指向 ADR 编号） |
| `docs/插件移动端分级.md` | 插件分级的完整说明 |
| `spec/` | 每份改动的 spec |
