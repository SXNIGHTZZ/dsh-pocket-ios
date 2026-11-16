# 插件移动端聚合收归 dsh-pocket-ios（把「插件」按钮从可选依赖里救出来）

> **文件名**：`spec/2026-11-16-1420-mobile-plugin-aggregator.md`
> **Status**：Accepted（2026-11-16 实现并验证）
> **起始日期**：2026-11-16
> **预估工时**：150 分钟（按 `scripts/estimate-from-history.sh` 分单元查历史中位数，见下）
> **目标版本**：1.1.0（1.0.9 已过审并上架）
> **对应提交**：`3c10d15`
> **实际耗时**：约 30 分钟（预估 150，倍率 0.20——又高估了）

## 背景 / 问题

### 现状：App Store 用户的「插件」按钮默认是坏的

「插件」按钮的功能依赖三个端点，全部由 `dsh-plugin-panel` 提供：

```
POST /dsh-plugin-panel/mobile/token     换 token
GET  /dsh-plugin-panel/mobile/list      列出声明了 dsh.mobile 的插件
GET  /dsh-plugin-panel/mobile           HTML 列表页（WebView 加载）
```

但 `dsh-plugin-panel` 是**选装插件**：

| 插件 | npm | 是否必装 |
| --- | --- | --- |
| `dsh-pocket-ios` | 0.6.0 | **必装**（3091 代理、PIN、pair、refresh；没有它 App 连不上） |
| `dsh-plugin-panel` | 0.1.14 | 选装（插件管理） |

App 的连接页只给一个「使用说明」链接
（`ConnectHeaderCard.swift:11` → 飞书文档），文档教的是 `dsh plugin add dsh-pocket-ios`，
**没有提到 `dsh-plugin-panel`**。

### 实测证据

```bash
# App 实际调用链（PluginMobileAPI.swift:38 / 64）
POST /dsh-plugin-panel/mobile/token     → 3ms
GET  /dsh-plugin-panel/mobile/list      → 3ms，366 字节
WebView /dsh-plugin-panel/mobile        → 90-145ms，12.9 KB
```

没装 `dsh-plugin-panel` 时：`fetchToken` 得到 404 →
`APIError.badResponse(404)` → 用户看到「电脑没有响应（HTTP 404）」。

**后果**：默认用户点「插件」只得到一句 HTTP 错误码，且**所有插件的移动端页面都换不到 token**
（`dsh-audio-parse` 的 `/token` 也依赖 App 统一签发）。

### DSH 内核没有这个能力

查 `app.asar` 确认：内核只有 `/plugins/<pkg>/assets/<path>`（client 资源路由），
`pluginManager.listPlugins()` 是 host 侧 service，**没有对外 HTTP**。

**所以必须由某个插件提供**——问题只是放在哪个插件里。

### 结论

**能力放错包了。** 它应该跟着「用户必然会装的那个插件」走。

## 目标

1. `dsh-pocket-ios` 自己提供移动端插件聚合（列表 + token），**不依赖 `dsh-plugin-panel`**
2. App 优先走新端点，失败时回退到旧端点（不破坏已装 `dsh-plugin-panel` 的用户）
3. `dsh-plugin-panel` 的对应端点保留，标记兼容，不删除

**非目标**：

- 不改 DSH 内核（`app.asar` 不动）
- 不改协议版本（仍是 `dsh.mobile` version 1）
- 不做插件页面的原生渲染（Layer 2 仍不做）

## 方案

### 一、`dsh-pocket-ios` 新增聚合端点

新通道 `/dsh-pocket/plugins`（和现有 `CHANNEL` 并列，不改动现有路由）：

```
POST /dsh-pocket/plugins/token    换 token（走 DSH 认证：connection.requestRejection）
GET  /dsh-pocket/plugins/list     列出声明了 dsh.mobile 的插件（token）
GET  /dsh-pocket/plugins          插件列表页 HTML（token）—— 可选，WebView 直接用它
```

**判定逻辑**：扫 `ctx.pluginManager.listBundles()` 拿到的每个包目录，读 `package.json` 的
`dsh.mobile`，按协议 v1 校验（`version`/`kind`/`title`/`path|schema`）。

**token 规则**（与协议 v1 一致）：

- 由这里签发，32 位 base64url，5 分钟有效
- **插件的页面只验格式**（`/^[A-Za-z0-9_-]{32}$/`），不自建表
- 这里维护一个短期 Set，仅用于「自己签发的能校验」，同时接受任意格式正确的 token

**为什么 token 放这里**：`dsh-pocket-ios` 已经在管移动端认证（PIN / pair / refresh），
token 签发是同一类事，收归一处。

### 二、App 双路径 + 回退

`PluginMobileAPI` 改成按顺序尝试：

```
1. POST /dsh-pocket/plugins/token      → 成功则用 GET /dsh-pocket/plugins/list
2. 失败（404/405）则回退：
   POST /dsh-plugin-panel/mobile/token → GET /dsh-plugin-panel/mobile/list
3. 都失败 → 报错文案说明「需要更新电脑端的 dsh-pocket-ios 插件，
   或安装插件管理插件」
```

**为什么要回退而不是直接切换**：已装 `dsh-plugin-panel` 但 `dsh-pocket-ios` 版本较旧
（< 0.7.0）的用户会同时存在，回退保证他们不退化。

### 三、错误文案可操作

失败态从「电脑没有响应（HTTP 404）」改成：

```
打不开插件面板
电脑上的 DSH 需要更新：在电脑上运行
  dsh plugin add dsh-pocket-ios
（如果只想用插件面板，也可以装 dsh-plugin-panel）
```

## 影响面

| 文件 | 改动 |
| --- | --- |
| `plugin/lib/index.js` | 新增 `registerPluginAggregator()`，约 130 行 |
| `plugin/package.json` | 版本 0.6.2 → 0.7.0 |
| `DSHPocket/Session/PluginMobileAPI.swift` | 双路径 + 回退，约 45 行 |
| `DSHKit/.../PluginMobileManifest.swift` | 不动（解析逻辑复用） |
| `DSHKit/Tests/...` | 新增聚合端点响应解析的测试 |

**协议文档**：`spec/2026-11-16-0600-plugin-mobile-protocol.md` 增加一节
「聚合端点由 dsh-pocket-ios 提供」，说明 `dsh-plugin-panel` 的对应端点降级为兼容。

## 测试计划

| # | 用例 | target | 预期 |
| --- | --- | --- | --- |
| 1 | 新端点换 token | 集成（curl） | 200 + 32 位 token |
| 2 | 新端点列表 | 集成 | 含 `dsh-audio-parse` 等声明了 `dsh.mobile` 的插件 |
| 3 | 无 token 访问列表 | 集成 | 401 |
| 4 | 插件页用新 token | 集成 | 200，页面正常 |
| 5 | 旧端点仍可用 | 集成 | 200（不退化） |
| 6 | App 回退逻辑 | `DSHKit` 单测 | 新端点 404 → 走旧端点 |
| 7 | 双端点都失败 | `DSHKit` 单测 | 返回可操作文案 |
| 8 | 声明不合法的插件被过滤 | `DSHKit` 单测 | `invalid` 里有原因 |

**验收口径**：把 `dsh-plugin-panel` 停用（或改名目录），App 仍能打开「插件」并看到
`dsh-audio-parse` 的页面。

## 参考实现

- **token 签发与校验**：`dsh-plugin-panel/index.js` 的 `mintMobileToken` / `mobileTokenValid`
  （照抄逻辑，换成独立通道）
- **`dsh.mobile` 声明解析**：`dsh-plugin-panel/index.js` 的 `readMobileManifests`
- **协议校验**：`DSHKit/Sources/DSHKit/Protocol/PluginMobileManifest.swift`（已存在，复用）
- **认证**：`plugin/lib/index.js` 现有 `connection.requestRejection` 用法（同文件已有）

## 风险

| 风险 | 缓解 |
| --- | --- |
| 老用户 `dsh-pocket-ios` 版本旧，新端点 404 | App 回退到旧端点 |
| 新端点扫描 48 个包，可能慢 | 实测 `listBundles()` 1ms、读 82 个文件 12ms；必要时按 mtime 缓存 |
| token 有两处签发，规则漂移 | 只校验格式、不自建表；两侧共用同一个正则 |
| 插件数量多时 HTML 页慢（现有 90-145ms） | 本次不改 HTML，只做 JSON 列表；HTML 页后续单独优化 |

## 预估依据

**不是凭直觉加总**。仓库有 `scripts/estimate-from-history.sh`（61 个样本），
按类型查历史实际中位数：

| # | 单元 | 类型 | 历史实际中位（分钟） |
| --- | --- | --- | --- |
| ① | 插件侧聚合端点 + token | 新功能 | 35 |
| ② | App 侧双路径 + 回退 | 新功能 | 35 |
| ③ | 失败文案 + 本地化 | 其它 | 18 |
| ④ | DSHKit 单测 | 其它 | 18 |
| ⑤ | 停用 panel 的联动验证 | 其它 | 18 |
| ⑥ | spec 回填 + 提交 | 文档 | 24 |
| | **合计** | | **148 ≈ 150** |

**为什么不用「行数 × 系数」**：脚本注释给的数据是机械搬迁 1.6 分/百行、
逐点重构 25–67 分/百行——成本驱动是**需要判断的地方**，不是行数。

**本次真正贵的两处判断**（不是写代码）：

1. 双路径回退的判定：哪些 HTTP 状态该回退、哪些该直接报错
2. 停用 `dsh-plugin-panel` 后能否真走通——这是本 spec 的核心验收

**历史偏差警示**：整体倍率中位数 0.60×（预估普遍高估 1.67 倍），
离散度大（0.29–1.20），说明按类型分单元比估总量可靠。
