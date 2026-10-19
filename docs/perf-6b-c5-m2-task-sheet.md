# C5 / M2 任务单：静态助手正文接入 TextKit 2

> 前置：M1 spike 完成（`docs/perf-6b-c5-m1-spike-report.md`）。测量引擎 = 自建 TextKit 2（官方同形），不 vendor CDMarkdownKit。
> 分支：`feat/textkit2-assistant-body`（继续使用；不合并、不发包、不碰 dev）。
> 默认开关仍为 off（`aa.timeline.collectionView`），M2 只在开关打开时生效。

## 0. 目标

让**静态助手正文**在 collection timeline 里由 UIKit + TextKit 2 渲染，并在 apply 前用同一台引擎同步测高：

- 新增 `AssistantMarkdownTextLayout`（测量）与 `AssistantMarkdownCell`（渲染）。
- 该行不再走 `UIHostingConfiguration`、不再用 estimate、不再依赖可见 cell 拟合。
- Gate：一条长助手的 `firstStored == 同步测量值`，cell 内容与 stored 差 ≤1pt；无 estimate 写入；相邻行不相交。

## 1. 范围（M2 只做这些）

**接入的行**：`.group` 且满足全部条件——
- `group.kind == .single`、`group.rows.count == 1`
- row 是 `.message`、`role != .user`
- `!isStreamingText`、`!isRevealing`
- `status` 不是 `interrupted/cancelled/failed`（这些会多一行 caption）
- 无附件、无 inline notice、无 turnAction footer
- 解析后的 blocks **全部是 paragraph / header**，且不含 attachment（Git badge、图片、math 等）

**块内允许**：普通文本、粗体、斜体、inline code、链接（M2 只上色，不接点击）。
**回退 hosting（M2 不做）**：列表、引用、代码块、表格、图片、附件、Git badge、math、fold、流式。

**不做**：流式尾部重排、选择、链接交互、无障碍细节、Dynamic Type 中途变化、RTL 真机、宽度变化的真机验证、非助手行。以上按计划留给 M3/M4。

## 2. 架构

```
TimelineChatContentAdapter.refresh()
  └─ assistantMarkdown(for: item)          // 只对符合条件的行解析
       ├─ 复用 Textual 的 AttributedStringMarkdownParser + Git/file enrich
       ├─ MarkdownBlockSnapshot.split
       ├─ 只接受 paragraph/header block；任一不支持 → nil（回退）
       └─ AssistantMarkdownDocument（blocks 的 NSAttributedString + 排版快照 + revision）

TimelineCollectionController.apply(items:)
  └─ measureSynchronously()
       ├─ 有 document 的 item → AssistantMarkdownTextLayout.measure(blocks,width)（TextKit 2 独立 stack）→ layout.heights.set(.measured)
       └─ 其余路径不变（plainText 同步 hosting / markdown 走 estimate+可见 cell）

dataSource cellProvider
  ├─ 有 document 且有 measured 高度 → AssistantMarkdownCell(document)
  └─ 否则 → TimelineHostingCell（现状）
```

- **同一份 attributed string** 同时用于测量与渲染；`AssistantMarkdownTextLayout` 的测量 stack 与 block `UITextView` 都是 TextKit 2。
- 块间距沿用产品：block 之间 12pt（`MarkdownBlockSnapshot` 的 VStack spacing）。
- 字体/行距按 Textual 的解析口径：`lineSpacing = 设计值 / 14 × body`；标题 18/16/14 semibold；inline code 按 `inlineCodeRatio/pin`。
- 高度取整：每块按 displayScale 向上取整（与 `MarkdownBlockSizing` 同口径），总和再 `ceil` 到整点（与 controller 的 `validatedHeight` 一致）。
- 该行 `heightPolicy = .measured`；不进入 `pendingMeasurements`；可见 cell settle 跳过它。
- 数据源选择与测量结果共用一份 `documentHeights[itemID]`，避免“cell 是 TextKit、高度却是 estimate”的错配。

## 3. 数据层

- `AssistantMarkdownDocument`（Models/Chat）：`blocks: [AssistantMarkdownBlock]`、`measuredRevision`（row revision + typography revision + width）、`plainTextLength`。
- `AssistantMarkdownBlock`（M2）：`.text(NSAttributedString)`；M3 扩展 `.code/.table/.attachment`。
- 解析器复用现有管线，不新造 Markdown 解析：
  - `AttributedStringMarkdownParser.parse(text, syntaxExtensions: [.math])`
  - `GitDirectiveParser.enrich`（产生 attachment → M2 回退）
  - inline file reference 的 link 处理（与 `ChatMarkdownView.parse` 相同）
  - `MarkdownBlockSnapshot.split(document, startingAt: 0)`
- 缓存：adapter 内 `[rowID: (revision, document?)]`；revision 变化才重解析。空文档（nil）也缓存，避免反复解析不可接入的长回复。
- 线程：M2 在 adapter 的 `refresh()`（主 actor）同步解析；首次打开长历史的成本由 gate 记录，超预算在 M3 外置到后台。

## 4. 渲染

- `AssistantMarkdownTextLayout`：
  - `static func measure(blocks:width:) -> CGFloat`：每块独立 `NSTextContentStorage + NSTextLayoutManager + NSTextContainer`，`ensureLayout` + `usageBoundsForTextContainer.maxY`，按 displayScale 取整后求和 + 12×间隔。
  - `static func height(of: NSAttributedString, width:) -> CGFloat`：单块测量，供 cell 复用。
- `AssistantMarkdownBlockTextView: UITextView`：
  - TextKit 2 默认栈；`isEditable=false`、`isScrollEnabled=false`、`isSelectable=false`（M3 再开）、`textContainerInset=.zero`、`lineFragmentPadding=0`、`backgroundColor=.clear`。
  - `attributedText` 由 document 提供，与测量同一份。
- `AssistantMarkdownCell: UICollectionViewCell`：
  - `contentView` 内 vertical `UIStackView`（spacing 12，alignment .fill），逐块 `AssistantMarkdownBlockTextView`。
  - `configure(document:)` 重建块；`prepareForReuse` 清空。
  - 不实现 `preferredLayoutAttributesFitting` 的接受分支（`.measured` 行由 layout 定高）。
  - `contentView.clipsToBounds = true`（与其他 cell 一致）。

## 5. 数据源与测量接线

- `TimelineCollectionContentProviding` 新增：
  ```swift
  func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument?
  ```
  默认实现返回 nil（C3 合成模型不接入）。适配器实现真实逻辑。
- controller：
  - `measureSynchronously`：先处理 document（测量并写 `.measured`），再走原有 plainText 分支。
  - 记录 `documentHeights: [String: CGFloat]`；`documentHeights[itemID] != nil` 时 cellProvider 用 `AssistantMarkdownCell`。
  - `settleVisibleCellHeightsOnce` / `schedulePendingMeasurements` 跳过 document 行（测量已是真值）。
  - `heightPolicy` 仍由 provider 给出 `.measured`（适配器保证符合条件）。
- adapter：
  - `refresh()` 里保持现有 groups 构建不变；新增 document 缓存与 `assistantMarkdown(for:)`。
  - 解析失败/不支持 → nil，回退现有 hosting 路径，不改任何现有行为。

## 6. Gate（CI `timeline-autorun`）

在 `TimelineAutoRunModel` 增加一条 `assistantTextKit` 合成行（长静态正文，**只含段落与标题**，含粗体/inline code/链接），实现 `assistantMarkdown(for:)`，并断言：

1. `firstStoredHeight == documentMeasuredHeight`（同步测量值，精确到 0.5pt）。
2. `|cellContentHeight − firstStoredHeight| ≤ 1pt`（文本容差）。
3. 该行不进入 `pendingMeasurements`，且 `firstStoredHeight != estimateKind.height`（证明没有 estimate 写入）。
4. 相邻 item frame 不相交（全表检查）。
5. 现有 C3 gate 全部保持 PASS。

## 7. 风险与处置

- **解析成本**：首次打开长历史会同步解析可接入行；gate 记录解析耗时。超 50ms/行或开屏卡顿 → M3 后台解析，不阻塞合并（M2 只在实验开关内）。
- **视觉差异**：M2 只接段落/标题/inline；列表/引用等仍走原路径，不会出现“半套视觉”。标题/段落与 Textual 的对齐由 M1 的 ≤1pt 结论背书。
- **行高取整**：per-block 像素取整 + 总高整点取整；gate 容忍 1pt。
- **RTL/Dynamic Type/宽度变化**：M2 用 typography snapshot 的 body/lineSpacing/headings；宽度变化会生成新 key 并重测。RTL 仅设置 baseWritingDirection，真机验证留 M4。

## 8. 验证与交付

- CI：`test` + `timeline-autorun` 必过；新增断言红→绿（先在 gate 里加断言，确认未接入时红，再接入转绿）。
- 不合并、不发包、不碰 dev。
- 交付：代码 + gate 输出 + 更新本任务单的“验证状态”与 M1 报告的执行记录。
