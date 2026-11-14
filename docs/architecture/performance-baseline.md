# 性能压测基线

> 用 `./scripts/stress-run.sh <场景>` 采集。
> **基线不是阈值**——只比数量级，不比绝对值。模拟器内存读数受宿主负载影响，实测波动可达 20%。
>
> 判断标准：**数量级变化**（如 400 → 1200 MB）= 有问题必须查；10–20% 波动 = 正常。

## 采集环境

| 项 | 值 |
| --- | --- |
| 日期 | 2026-11-14 |
| 设备 | 模拟器 DSH Pocket Max（iPhone 17 Pro Max, iOS 26.3） |
| 构建 | Debug |
| 测量 | 进会话后稳定值（RSS 用 `ps`；footprint 由 `dsh-ios-mem` 采样） |
| 空载基线 | 281 MB（RSS）/ 待补（footprint） |

## ⚠️ 口径说明：RSS 会虚高 3 倍，优先看 footprint

2026-11-14 用 `dsh-ios-mem` 对比过两种口径（同一批场景、同一台模拟器）：

| 场景 | RSS | footprint | 差值 |
| --- | --- | --- | --- |
| `sessions:800` | 277 MB | **37.8 MB** | 239 |
| `markdown:code:950` | 381 MB | **100.1 MB** | 281 |
| `messages:400` | 400 MB | **121.5 MB** | 279 |
| `markdown:extreme` | 466 MB | **180.9 MB** | 285 |
| `images:120` | 307 MB | **56.6 MB** | 250 |
| `steps:80` | 319 MB | **62.3 MB** | 257 |

**RSS 里那 240–280 MB 基本恒定，与场景无关**——是 dyld 共享缓存和框架干净页，
不是 App 自己的账。**按 RSS 排序会把场景间的真实差距稀释约 3 倍。**

下面的表保留 RSS 作为历史对照，但**新增 footprint 一列并以此为准**。

> footprint 数据来源：`/Users/ruska/projects/dsh-plugins/dsh-ios-mem/docs/measurements/dsh-pocket-ios/2026-11-14-1425-stress-footprint.md`
> （`dsh-ios-mem` 0.2.0，`ios_mem_start` 500ms，启动后 14–16 秒取稳定段）

## 当前基线

| 场景 | **footprint** | 稳定 RSS | footprint 口径下最贵的是 | 说明 |
| --- | --- | --- | --- | --- |
| 空载（连接页） | 待补 | 281 MB | — | 框架 + Debug 构建的基础开销 |
| `sessions:800` | **37.8 MB** | 277 MB | — | 列表页，800 个会话 |
| `images:120` | **56.6 MB** | 307 MB | 图片解码缓存 | 240 条消息全带图，裁到 24 条 |
| `steps:80` | **62.3 MB** | 319 MB | 富文本布局 | 每轮 80 个步骤，默认折叠 |
| `markdown:code:950` | **100.1 MB** | 381 MB | **CoreAnimation 43.3 MB** | 950 行代码块（不崩了）；Malloc 只有 18 MB |
| `messages:400` | **121.5 MB** | 400 MB | 富文本布局 | 800 条裁到 24 条后 |
| `markdown:extreme` | **180.9 MB** | 466 MB | 表格 + 代码块叠加 | 100 行 × 8 列表格 + 500 行代码块 |

**未复测的场景**（仍只有 RSS，下次用 `dsh-ios-mem` 补 footprint）：
`markdown:code:2000` 456 MB · `markdown:codeplain:950` 382 MB · `markdown:text:950` 593 MB · `markdown:singleline:950` 381 MB

## 结论

**最大风险是极端 Markdown**（footprint 180.9 MB）——大表格 + 长代码块的布局成本远高于消息数量本身。

**`code:950` 的成本结构值得单独记一笔**：100 MB 里 43.3 MB 是 CoreAnimation
（19 个 region），Malloc 只有 18 MB。原因是 Textual 把整段代码绘成**一个** `Text`，
950 行 ⇒ 一个巨大的图层 backing store。**压缩文本不会降这块内存**，要降只能
限制单块行数或分段渲染。

**更严重的是它有崩溃阈值**：代码块带语言标识（走 Textual 语法高亮）超过约 900 行时，
`ConcatenatedTextStorage` 递归解析会爆栈 → SIGSEGV。修复方式见 `MarkdownBody.strippingCodeLanguage`。

**图片和步骤的影响很小**（+26 / +38 MB），因为硬裁剪把消息数压到了 24 条，
图片全屏和步骤展开的峰值需要单独测（不在本基线内）。

## 已知未覆盖

| 场景 | 为什么不测 | 建议 |
| --- | --- | --- |
| 全屏图片翻页 | 需要 UI 交互，脚本采不到瞬时峰值 | 手工 + `ios_sim_*` 工具 |
| 步骤全部展开 | 需要点开每一组 | 用 `DSH_EXPAND_STEPS=1`（已有开关）单独跑 |
| 实时流高频更新 | 需要连真机或模拟流 | 真机上看 `[ Live Signal ]` 的帧率 |
| 冷启动时间 | 一次性指标，不属于稳态压测 | 单独记录一次 |

## 怎么更新这张表

1. 改完性能敏感代码（列表/图片/Markdown 渲染）
2. 跑对应场景：`./scripts/stress-run.sh messages:400`
3. 对比上表：
   - 数量级变化 → 查原因，不要提交
   - 20% 内波动 → 直接更新这行数字
4. 如果有新场景，加到脚本和这张表里
