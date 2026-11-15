# 插件移动端适配协议 v1（让手机端真正能用插件）

> **文件名**：`spec/2026-11-16-0600-plugin-mobile-protocol.md`
> **Status**：Draft
> **起始日期**：2026-11-16
> **预估工时**：480 分钟（本 spec 含协议定稿 + Layer 1 容器 + 聚合接口）
> **对应提交**：（Accepted 后回填）

## 背景 / 问题

**现状（2026-11-16 实测数据）**：

```
DSH 插件总数                      189
带 client 端 UI 的                 28   (15%)
其中挂在 sidebar.right.pane.tab    23   (占 28 的 82%)
```

**DSH Web 没有任何移动端断点**：

```
layout 里的 @media  → 只有 prefers-reduced-motion / prefers-reduced-transparency
全局搜 max-width    → 空
```

**所以**：桌面是「会话列表 + 对话 + 右侧插件面板」三栏并列，**手机单列放不下**；
且 **DSH Web 没有插件级路由**（SPA，插件靠 `ctx.slots.inject()` 挂载），
**没法深链到「只打开某个插件」**。

**用户诉求（原话）**：

> 「在现在对话页面的后台任务那个按钮的左侧增加一个叫插件的按钮，点击后拉起一个面板显示该插件在侧面板的内容。页面保持和后台任务的交互一致。」
>
> 「长期要考虑整个我们做这件事的核心目标，让移动端能真正用好插件……甚至在设计规范中增加移动端适配的提示词等帮助开发者开发带有移动端的插件。」

**三个核心目标**：

1. **能真正用**，不只是能看；
2. **生态化**：有协议、有规范、有工具，插件开发者照着写就行；
3. **分层**：简单的走 Web，复杂的能拿到原生体验。

## 目标与非目标

**目标**

- 定义 `dsh.mobile` 声明协议（v1），插件在 `package.json` 里声明自己支持移动端
- 定义聚合接口 `/dsh-plugin-panel/mobile/list`，App 一次拿到「哪些插件支持移动端」
- 定义 Schema v1 与 **10 个基础组件**，且**组件集合可扩展**（新增组件不需要改协议版本）
- App 侧：对话页加「插件」按钮 + Layer 1 WebView 容器（含一次性 token 认证）
- 协议**向后兼容**：App 遇到不认识的 `version` 或组件类型时降级，不崩溃

**非目标**（这次明确不做）

- **不实现 Layer 2 的 Schema 渲染器**（留给 P3，另开 spec）
- **不做多插件的插件选择列表 UI**（先支持「一个按钮 → 一个面板」）
- **不改 DSH 核心**（聚合接口由 `dsh-plugin-panel` 插件提供，不是内核）
- **不做插件市场里的移动端标记**（P5 的事）
- **不做 `dsh.mobile` 的自动校验工具**（P5 的脚手架再说）

## 参考实现（Prior art）

**未找到直接对标的开源实现。** 说明为什么：

- **Figma Plugin API**：插件用 TypeScript 调 API 构建 UI（`figma.createFrame()` 等命令式）。**不采用**——它要求 App 内嵌 JS 引擎，iOS 上不现实（App Store 禁止动态加载可执行代码）。
- **VS Code Webview**：插件提供 HTML，宿主用 webview 渲染。**采用它的分层思路**（Layer 1 = WebView），但**不采用「插件自己写完整 HTML」作为唯一方式**——那样每个插件都要重做一遍移动端样式。
- **GitHub Actions / Kubernetes CRD**：用声明式 schema 描述状态，宿主负责渲染/调和。**采用这个思路做 Layer 2**（插件给 JSON，App 渲染）。
- **JSON-RPC 2.0**：交互回传格式。**部分采用**——我们的 `action` 只借了「method + params」的形状，没引入完整 JSON-RPC envelope（对移动端交互过重）。

**结论**：自研协议，但三层分层（Web 兜底 / Schema 主推 / 内置原生组件）是从上述几个项目拼出来的，不是凭空设计。

## 方案

### 第 1 步：`dsh.mobile` 声明（协议核心）

**插件在 `package.json` 里加**：

```json
{
  "dsh": {
    "mobile": {
      "version": 1,
      "kind": "native",
      "title": "插件管理",
      "icon": "./icon.png",
      "schema": "/dsh-plugin-panel/mobile/schema"
    }
  }
}
```

`kind` 二选一：

| kind | 含义 | 插件要提供 | App 怎么渲染 |
| --- | --- | --- | --- |
| `native` | 声明式 UI | `schema` 指向一个返回 JSON 的路径 | 原生组件 |
| `web` | 网页兜底 | `path` 指向一个返回 HTML 的路径 | WebView |

**`web` 时的字段**：

```json
"mobile": { "version": 1, "kind": "web", "title": "...", "icon": "...", "path": "/dsh-plugin-panel/mobile" }
```

- **为什么用 `version`**：未来协议演进时，App 能识别旧插件并降级，而不是直接崩。
- **为什么 `title`/`icon` 放在插件声明里**：App 不该猜——按钮文案和图标必须由插件自己给。
- **为什么不复用 `locale/*.json` 的 title**：那套是「插件列表」的展示名，语义不同（移动端按钮可能想写得更短，如「插件」而不是「插件管理」）。

### 第 2 步：聚合接口

**由 `dsh-plugin-panel` 提供**（它是天然的插件聚合点，不依赖 DSH 内核改动）：

```
GET /dsh-plugin-panel/mobile/list
```

**响应**：

```json
{
  "version": 1,
  "plugins": [
    {
      "module": "dsh-plugin-panel",
      "title": "插件",
      "kind": "native",
      "icon": "data:image/png;base64,...",
      "schema": "/dsh-plugin-panel/mobile/schema"
    }
  ]
}
```

**为什么放 `dsh-plugin-panel` 而不是 DSH 核心**：

- 改内核意味着所有用户必须升级 DSH 才能用，推进慢；
- `dsh-plugin-panel` 已经在读全部插件的 `package.json`（它本来就是插件管理器），**天然有这个数据**；
- 代价是「不装 `dsh-plugin-panel` 就没有插件按钮」——可接受（它是标配）。

**认证**：复用 DSH 的 cookie（App 登录后已有）。不做额外 token，避免多一套凭证。

### 第 3 步：Schema v1

**`kind: "native"` 时，`schema` 路径返回**：

```json
{
  "version": 1,
  "title": "插件管理",
  "body": [
    {
      "type": "section",
      "title": "已安装",
      "children": [
        {
          "type": "row",
          "id": "dsh-chat-lens",
          "title": "dsh-chat-lens",
          "subtitle": "对话透镜 v0.3.1",
          "icon": "https://.../icon.png",
          "trailing": { "type": "tag", "text": "运行中", "tone": "success" },
          "action": { "kind": "rpc", "method": "pluginManager/detail", "args": { "name": "dsh-chat-lens" } }
        }
      ]
    }
  ]
}
```

**顶层字段**：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `version` | ✅ | Schema 版本，当前 `1` |
| `title` | ✅ | 面板标题 |
| `body` | ✅ | 组件数组 |
| `refreshable` | ❌ | 是否支持下拉刷新（默认 `true`） |

### 第 4 步：组件清单 v1（10 个，可扩展）

**扩展规则**：新增组件类型**不需要**升 `version`；App 遇到不认识的 `type` **跳过并记录**，不崩溃。

| type | 关键字段 | 覆盖 |
| --- | --- | --- |
| `section` | `title?`, `children` | 分组容器 |
| `row` | `title`, `subtitle?`, `icon?`, `trailing?`, `action?` | 列表项（**最常用**） |
| `button` | `title`, `style?`(default/destructive), `action` | 操作 |
| `toggle` | `title`, `value`, `action` | 开关 |
| `picker` | `title`, `options[]`, `value`, `action` | 单选 |
| `input` | `title`, `placeholder?`, `value`, `action` | 文本输入 |
| `tag` | `text`, `tone?`(neutral/info/success/warning/danger) | 状态标记（也用于 `trailing`） |
| `chart` | `kind`(line/bar), `series[]`, `labels[]` | 图表 |
| `code` | `text`, `language?` | 代码块 |
| `markdown` | `text` | 富文本 |

**每层都能带 `children` 的**：`section`（其他是叶子节点）。

### 第 5 步：交互回传（`action`）

**统一形状**：

```json
"action": {
  "kind": "rpc",
  "method": "pluginManager/list",
  "args": {},
  "confirm": "确定要卸载吗？"
}
```

`kind` 四种：

| kind | 含义 | App 行为 |
| --- | --- | --- |
| `rpc` | 调 DSH RPC | POST `/api/{method}`，成功后**重新拉 schema** |
| `refresh` | 刷新当前界面 | 重新拉 schema |
| `dismiss` | 关闭面板 | 关 sheet |
| `openURL` | 打开链接 | `openURL`（外部浏览器） |

**为什么「成功后重新拉 schema」而不是让插件推送 UI 增量**：

- 增量更新需要维护一份 UI 状态机（App 和插件都要），复杂且易错；
- 全量重拉在移动端面板这个量级（< 200 个节点）完全可接受；
- **声明式 + 全量重建**是 Web 框架验证过的模式（React/Vue），照抄即可。

### 第 6 步：App 侧 Layer 1 容器

**对话页，后台任务按钮左侧加一个「插件」按钮**：

```
[插件] [后台任务] [更多]
```

- 点击 → `.sheet` + `NavigationStack`，**和后台任务完全一致的呈现方式**；
- 读 `/dsh-plugin-panel/mobile/list`：
  - `kind: "web"` → `WKWebView` 加载 `{address}{path}?mt=<token>`
  - `kind: "native"` → **本 spec 不实现**，先显示「该插件需要新版 App」占位
- **一次性 token**：App 生成 32 位随机串，`?mt=` 传入；插件校验后 5 分钟内有效
  - 为什么不共享 cookie：`WKWebView` 的 cookie 域和 App 的 `URLSession` 不共享，注入 `WKWebsiteDataStore` 容易出边界问题；一次性 token 更简单可控。

### 第 7 步：认证（`mt` token）

**App 侧**：每次打开面板时生成 `mt`（内存中，5 分钟内有效，用完即弃）。

**插件侧**：`/mobile` 路由校验 `mt`：
- 校验通过 → 返回 HTML
- 校验失败 → 401 + 「请从 App 内打开」

**为什么不用 `cli.*` 那套「只允许 127.0.0.1」**：手机不是 127.0.0.1，走不通。

**为什么不用 PIN**：用户已经登录 App，不该再输一次密码。

## 被否决的方案（Rationale & Alternatives）

| 方案 | 否决理由 | 否决依据 |
| --- | --- | --- |
| **App 内嵌 WebView 加载整个 DSH Web** | DSH Web 无移动端断点，三栏布局在 390px 上不可用 | 实测：layout 只有 `prefers-reduced-*` 断点，无 `max-width` |
| **DSH 内核提供聚合接口** | 要求所有用户升级 DSH 内核才能用，推进慢；而 `dsh-plugin-panel` 本来就持有全部插件元数据 | 已有 `pluginManager` 服务，数据就在那 |
| **插件动态加载 Swift 代码** | App Store 禁止动态加载可执行代码，技术上不可行 | App Store Review 2.5.2 + iOS 沙盒限制 |
| **让每个插件写独立 HTML（只用 Layer 1）** | 每个插件都要重做移动端样式，生态化成本高，且视觉风格无法统一 | 28 个插件 × 各写一遍 HTML |
| **App 为每个插件硬编码 SwiftUI** | 与插件解耦背道而驰，插件升级要跟着发 App | 已知 28 个插件，未来还会增加 |
| **共享 cookie 给 WebView** | `WKWebsiteDataStore` 与 `URLSession` cookie 域行为有差异，边界情况多 | 一次性 token 更简单 |
| **什么都不做** | 手机端永远无法用插件，DSH 最强的插件系统在移动端等于不存在；28 个带 UI 的插件（可视化类尤其）全部浪费 | 用户明确诉求 + 数据：15% 插件有 UI，其中只读可视化类价值最高 |

## 代价与风险（Drawbacks & Risks）

**代价**（确定发生）

- 插件侧：每个想上手机的插件要加一个路由 + 一段 HTML/JSON（约 100–300 行）
- App 侧：多一个 WebView sheet（约 150 行）+ token 生成逻辑
- 协议维护：`version` 演进要保证向后兼容，未来改协议有约束

**风险**

| 风险 | 缓解措施 |
| --- | --- |
| WebView 体验被用户判定「不可接受」 | 先做 Layer 1 跑 2 周；若真被否决，Layer 2 的 schema 设计已经沉淀，不会白做 |
| 插件作者不跟进（生态起不来） | 自己做第一个样板（`dsh-plugin-panel`），并写规范 + 脚手架降低门槛 |
| `dsh-plugin-panel` 停更导致聚合接口没了 | 接口实现很简单（读 `package.json` 过滤），实在不行可迁到独立小插件 |
| 一次性 token 泄漏 | 5 分钟有效 + 用完即弃 + 只在内存 |
| 组件清单不够用（自定义 UI 无法表达） | 扩展规则允许加组件；极端情况可退回 `kind: "web"` 自己画 |

**为什么不该做这件事**（诚实）

- **手机屏幕太小，很多插件本来就该在电脑上用**（比如行业本体编辑器、插件市场的批量操作）；
- **插件生态是「桌面优先」的**，做移动端可能只服务极少数场景；
- **协议一旦定了就有维护成本**，哪怕没人用也要保证不破坏。

**但我认为值得做**：因为**只读可视化**（知识树、对话透镜、波形、图表）在手机上「看一眼」的需求是真实且高频的，而这恰恰是 Schema 最擅长覆盖的形态。

## 未决问题（Unresolved Questions）

- **`icon` 的传输形式**：`data:` base64 还是 URL？base64 让 App 少一次请求，但会让聚合接口响应变大（28 个插件 × 几十 KB）。**倾向**：App 端按需请求 URL，聚合接口只给相对路径。
- **Schema 的分页**：插件列表可能上百项，是否需要 `hasMore` / `cursor`？**倾向**：v1 不做，插件自己做「加载更多」按钮（用 `action: refresh` 带参数）。
- **`row` 的右侧展开指示**：有些 `row` 点进去是子页面，有些是直接执行 action。**倾向**：v1 只支持「点 row 执行 action」，子页面用「新的 schema 替换当前 body」实现（App 维护一个栈）。
- **离线缓存**：断网时是否展示上次的 schema？**倾向**：v1 不做。

## 测试计划（先红后绿）

| 用例 | target | 断言 |
| --- | --- | --- |
| 解析 `dsh.mobile` 声明 | `DSHKit` `PluginMobileManifestTests` | 缺 `version`/`kind`/`title` 时返回 nil 而非崩溃 |
| `kind=web` 时 `path` 必填 | `DSHKit` `PluginMobileManifestTests` | 缺 `path` 判为无效 |
| `kind=native` 时 `schema` 必填 | `DSHKit` `PluginMobileManifestTests` | 缺 `schema` 判为无效 |
| 未知 `version` 降级 | `DSHKit` `PluginMobileManifestTests` | `version: 99` 判为 `.unsupported`，不抛异常 |
| Schema 解析：未知组件跳过 | `DSHKit` `PluginMobileSchemaTests` | 含 `type: "unknown"` 时不崩，返回已知组件 |
| Schema 解析：`section.children` 递归 | `DSHKit` `PluginMobileSchemaTests` | 两层嵌套正确展开 |
| token 生成与校验 | `DSHKit` `PluginMobileTokenTests` | 5 分钟内有效、过期拒绝、用完即弃 |
| 聚合接口空场景 | 手工走查 | 没有插件声明 mobile 时返回 `plugins: []`，App 显示「暂无支持手机端的插件」 |

## 预估工时

| 单元 | 数量 | 单耗依据 | 小计 |
| --- | --- | --- | --- |
| 协议字段定义 + spec（本文件） | 1 | 设计类，约 60 分 | 60 |
| `dsh.mobile` 解析 + 校验（DSHKit） | 1 | 纯逻辑约 40 行，含测试 | 60 |
| Schema v1 解析器（DSHKit，10 个组件） | 1 | 纯逻辑约 200 行 + 8 个测试 | 120 |
| 聚合接口（`dsh-plugin-panel`） | 1 | 读 package.json + 过滤，约 60 行 | 50 |
| 插件侧 `/mobile` + token 校验 | 1 | 约 80 行 | 50 |
| App 按钮 + WebView sheet | 1 | 约 150 行（含认证注入、加载态） | 100 |
| 手工验证（真机走一遍） | 1 | 装机 + 走查 | 40 |
| **合计** | | | **480 分钟** |

## 验收记录（实现后回填）

| 用例 | 结果 | 证据 |
| --- | --- | --- |
| （待实现后回填） | | |
