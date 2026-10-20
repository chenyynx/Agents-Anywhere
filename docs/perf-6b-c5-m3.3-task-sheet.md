# C5 / M3.3 任务单：官方粒度（per-block cells）

> 前置：M3.2 的滚动 gate 已定位问题——一条消息一个 cell 时，cellBuild 平均 27ms，其中 list 10.8ms、text 5.4ms（2×2.7）、code 3.3ms、table 1.5ms。
> 官方 Code 页的 `MarkdownTextCellContent.Body` 是 `prose(blocks) | code | table`，即**一个块（或一段连续 prose）一个 cell**。
> 本轮把我们的时间线粒度改成官方形状；视觉尺寸先保持不变，官方像素对齐留到后续。
> 分支：`feat/textkit2-assistant-body`。不合并、不发包、不碰 dev。

## 0. 目标

把**可接入的静态助手消息**从“一条消息一个 cell”改成：

- 连续的 prose 块（paragraph/header/list/quote）→ 一个 `.prose` segment cell
- 每个 code 块 → 一个 `.code` segment cell
- 每个 table 块 → 一个 `.table` segment cell

每个 segment 是一个独立的 `TimelineListItem`，独立测高、独立复用、独立渲染。

**验收的不变量**：拆分前后，同一条消息的视觉总高度不变——各 segment 高度之和 + 段间 12pt = 原整条消息高度（±1pt）。

## 1. 不做

- 不改字号/颜色/列表 marker/引用条/代码卡/表格列宽等视觉常量（官方 `padV=8`、`TableOverflowPolicy`、`+1pt` 等留到“官方像素对齐”专项）
- 不做表格单 surface、代码 `FramedCodeView`、流式增量、选择/链接（后续里程碑）
- 不改非助手行（hosting 路径保持原样）
- 不改 C3 gate 的默认行为（C3 模型仍一个 group 一个 item）

## 2. 模型

```swift
enum AssistantMarkdownSegment {
    case prose([AssistantMarkdownBlock])   // 连续 text/list/quote
    case code(AssistantCodeBlock)
    case table(AssistantTableBlock)
}
```

分段规则：按文档顺序扫描 `AssistantMarkdownDocument.blocks`：

- `.text/.list/.quote` 追加到当前 prose；遇到 code/table 先 flush prose
- `.code` / `.table` 各自成段
- 空 prose 不生成 segment

segment 身份：

- `TimelineListItem.segment(groupID: String, rowID: String, index: Int)`
- `itemID = "sg:\(rowID):\(index)"`
- revision 用 row revision + segment index；静态行足够。流式阶段再换成块级稳定身份（记为后续项）

## 3. 时间线接线

### 3.1 条目身份

- `TimelineItemIdentity.build` 增加一个 `items(forGroup: (String) -> [TimelineListItem])` 参数，默认返回 `.group(id)`。
- 适配器对可接入组返回 segment items；不可接入组仍返回一个 `.group` item。
- C3 合成模型不传该参数，行为不变。
- segment 去重：同一 `itemID` 只保留第一个；记录到 duplicate 列表（或至少日志）。

### 3.2 适配器

- `assistantMarkdown(for:)` 保留（用于整条文档/缓存）；新增 `assistantSegment(for:)`。
- `refresh()` 时对可接入组解析文档并分段，缓存 `segmentsByGroup`；同一 row revision/text/typography 只分一次。
- `contentSignature(for: .segment)` 返回合成的 `.group` signature：
  - `rows: [TimelineRowContentSignature(id: itemID, revision: rowRevision, updatedSeq: ...)]`
  - `turnAction` 只在**最后一个 segment**上带（footer 归属）；其余为 nil
- `assistantTurnFooter(for:)` 只在最后一个 segment 返回。
- `rowIDs(in: .segment)` 返回 `[rowID]`；`rowToItem` 首个 segment 作为该 row 的锚点（开屏/回顶到消息起点）。
- `measurementContent`: prose/code/table 都 `.markdown`。

### 3.3 Controller / layout

- `measureSynchronously`：对每个 `.segment` 测该段高度；写入 `documentHeights[itemID]`。
- cellProvider：`.segment` 且有 measured 高度 → `AssistantMarkdownSegmentCell`；否则 hosting。
- 失去准入时清理 `documentHeights`（沿用 M3.1 的清理逻辑）。
- segment 之间的间距：
  - 同一条消息内相邻 segment：**12pt**（与当前块间距一致）
  - 最后一个 segment 到下一个 group/其他 item：**20pt**（当前 `TimelineListMetrics.itemSpacing`）
  - 给 `TimelineListLayoutHost` 增加 `layoutSpacing(after:before:)`（默认 20）；layout 的前缀复用条件和 y 游标使用这个值
- 现有 `documentHeights` / `pendingMeasurements` / `settleVisibleCellHeightsOnce` 都按 segment itemID 工作。

## 4. Cell

`AssistantMarkdownSegmentCell`（或把现有 `AssistantMarkdownCell` 改成接收 segment）：

- `.prose(blocks)`：vertical stack，block 间 12pt；每块沿用现有 block view
- `.code` / `.table`：单个 block view
- footer：只由最后一个 segment 传入，4pt + 39.5pt（沿用 M3.1）
- 高度约束仍用 `AssistantMarkdownTextLayout` 的同一条测量公式

## 5. Gate（扩展 `aa-textkit-m3`）

合成模型同样按 segment 生成 items；断言：

1. 每个 segment：`stored == measured`（0.5pt），cell content 与 stored 差 ≤1pt，不进入 pending/estimate
2. 相邻 frame 不相交
3. **总高不变量**：`Σ(segment stored) + 12×(n−1) == AssistantMarkdownTextLayout.measure(document, width)` ±1pt
4. footer 只在最后一个 segment；footerDelta 仍为 43.5±1
5. 解析契约与块统计不变
6. 报告 `segmentCount`、每个 segment 的 kind/height

## 6. 风险

- **item 身份/ diffing**：segment index 在内容变化时可能移动；静态行可接受，流式阶段要换稳定身份。
- **间距**：全局 `itemSpacing=20` 与段间 12 冲突；必须按 item pair 取值，并纳入 layout 前缀复用。
- **footer 归属**：只挂最后一个 segment；不要在每个 segment 重复。
- **锚点**：`rowToItem` 取首个 segment；开屏/回跳落到消息开头。
- **C3**：默认路径必须保持一个 group item；C3 gate 不能回归。
- **性能**：segment 变多，layout 的 item 数增加；以滚动 gate 和真机为准。

## 7. 交付顺序

1. 纯分段模型 + 单测/gate 可读的 segment 统计
2. item 身份 + adapter/controller + 间距
3. segment cell + footer
4. gate 总装
5. 绿后再做表格单 surface（M3.4）与官方像素对齐

## 8. 验收

- 全流程 CI 绿（M3 gate；C3 既有 flake 单独记录）
- 每 segment 高度、总高不变量、footer、块统计均通过
- 未覆盖：真机视觉、滚动真机、流式、选择/附件
