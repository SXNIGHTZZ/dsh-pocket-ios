# 长 Markdown 折叠：表格 30 行 / 代码 200 行

> **Status**: Draft
> **起始日期**：2026-11-14
> **预估工时**：150 分钟（单元累加）
> **文件名**：`spec/2026-11-14-1700-markdown-truncation.md`

## 背景 / 问题

真机会话「iOS内存测试开源工具」占 **368 MB footprint**，明显卡顿。

用 `ios_mem_*` 在模拟器复现（footprint 口径）：

| 场景 | footprint | CoreAnimation | regions |
| --- | --- | --- | --- |
| 28 消息 + 134 步骤 | 56.2 MB | 4.3 MB | — |
| 28 消息 + 134 步骤 + **100 行表格** | **166.5 MB** | **16.7 MB** | **937** |
| 用户真机会话 | **368 MB** | — | — |

**结论**：
- 消息数、步骤数**都不是主因**（56 MB）。
- **大表格是主因**：加一张 100 行 × 8 列表格 → +110 MB。
- 机制：**表格每个单元格是独立图层**（937 regions / 16.7 MB CoreAnimation）。
- 之前记录的 `code:950`（100 MB，其中 43.3 MB CoreAnimation）同理：整段代码绘成一个巨大 `Text`。

368 MB ≈ 两个极端场景（`markdown:extreme` = 181 MB）叠加，与用户会话里贴了压测数据吻合。

## 目标与非目标

**目标**
1. 表格超过 **30 行**时只渲染前 30 行，正文里标注省略行数。
2. 代码块超过 **200 行**时只渲染前 200 行，同样标注。
3. 被截断的消息下方出现「展开全部」按钮，点击后渲染完整内容。
4. 正常对话（表格 < 30 行、代码 < 200 行）**行为完全不变**。

**非目标**
- 不做逐块展开（只做整条消息级别）——`StructuredText` 是整体渲染，中间插不了按钮。
- 不改 Textual 内部。
- 不动代码块的语言标识（那是防崩溃的既有逻辑，见 `strippingCodeLanguage`）。

## 参考实现（Prior art）

- **`MarkdownBody.strippingCodeLanguage`**（本项目）：已经会扫描 ` ``` ` 围栏并做字符串改写
  → **采用**：沿用同一套「按行扫描 + 改写」的思路，不引入 Markdown AST 解析器。
- **`TimelineSpacing`**（本项目）：纯逻辑放 DSHKit、可单测
  → **采用**：截断规则也放 DSHKit。

## 方案

### 第 1 步：DSHKit 加 `MarkdownTruncation`（纯逻辑，可测）

```swift
public enum MarkdownTruncation {
    public struct Result: Equatable {
        public let markdown: String
        public let omittedTableRows: Int
        public let omittedCodeLines: Int
        public var didTruncate: Bool { omittedTableRows > 0 || omittedCodeLines > 0 }
    }

    public static func apply(to markdown: String,
                             maxTableRows: Int = 30,
                             maxCodeLines: Int = 200) -> Result
}
```

**规则**：
- 代码块：` ``` ` 围栏内的行数超限 → 保留前 N 行，插入 `… 省略 N 行 …`（作为代码块内的一行，不进渲染层）
- 表格：以 `|` 开头的**连续行**超过 N 行（含表头 + 分隔行）→ 保留前 N 行
- 不计入省略的行，**原样保留**

### 第 2 步：`MarkdownBody` 接入

```swift
struct MarkdownBody: View {
    let text: String
    @State private var expandAll = false

    var body: some View {
        let result = expandAll ? rawResult : MarkdownTruncation.apply(to: text)
        VStack(alignment: .leading, spacing: 6) {
            StructuredText(markdown: result.markdown)...
            if result.didTruncate && !expandAll {
                Button("展开全部（省略 \(省略行数) 行）") { expandAll = true }
            }
        }
    }
}
```

**注意**：`@State` 在 `MessageRow` 复用时会重置——但消息一旦滚出屏幕重建，折叠回默认状态是**可接受**的（比崩溃和卡顿好）。

### 第 3 步：测试

pure-logic 层覆盖：表格超/不超限、代码超/不超限、混合、空输入、围栏未闭合。

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| 逐块插入「展开」按钮 | `StructuredText` 整体渲染，中间插不了 View；要拆就得放弃 Textual |
| 用 Markdown AST 库解析后再拼 | 引入新依赖 + 重写渲染路径，收益不抵风险 |
| 表格改用 `LazyVStack` 自定义渲染 | Textual 的表格样式（横滚、列宽）要全部重写，1-2 天 |
| 不折叠，接受 368 MB | 用户实际体感「卡」，不能接受 |

## 代价与风险

**代价**
- 超限内容默认不可见（要手点展开）
- 约 120 行新代码 + 6 条测试

**风险**
| 风险 | 缓解 |
| --- | --- |
| 截断逻辑误伤正常内容（比如表格识别错） | 阈值远高于日常（30 行 / 200 行），且单测覆盖边界 |
| `@State` 在滚动时重置，用户展开后滚走再回来又折叠 | 可接受；若体感差，后续把展开状态提到 `ConversationView` 的 `@State` |
| 代码块截断破坏了「复制代码」的完整性 | 折叠时正文明确标注「省略 N 行」，不误导 |

## 未决问题

- 展开状态是否要跨消息保留？（当前放在 `MarkdownBody` 的 `@State`，滚出屏幕即丢）

## 测试计划（先红后绿）

| 用例 | target | 断言 |
| --- | --- | --- |
| 表格不超限 | `DSHKitTests/MarkdownTruncationTests` | 原样返回，`didTruncate == false` |
| 表格超限 | 同上 | 只留前 30 行，`omittedTableRows == 70` |
| 代码块不超限 | 同上 | 原样返回 |
| 代码块超限 | 同上 | 只留前 200 行，`omittedCodeLines == 750` |
| 混合超限 | 同上 | 两者都截，两个计数都对 |
| 围栏未闭合 | 同上 | 不崩，按普通文本处理 |
| 回归 | `swift test` | 404+ 绿 |
| 实测 | `ios_mem_start` | 100 行表格场景 footprint 从 166 MB 降到 < 100 MB |

## 预估工时

| 单元 | 数量 | 单耗依据 | 小计 |
| --- | --- | --- | --- |
| spec | 1 | 约 25 | 25 分钟 |
| `MarkdownTruncation` + 6 条测试 | 1 | 同类约 45 | 45 分钟 |
| `MarkdownBody` 接入（含展开按钮） | 1 | 约 30 | 30 分钟 |
| 模拟器实测对比 | 1 | 约 25 | 25 分钟 |
| 真机验证（待设备可达） | 1 | 约 25 | 25 分钟 |
| **合计** | | | **150 分钟** |
