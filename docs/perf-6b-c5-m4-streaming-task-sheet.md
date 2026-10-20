# C5 / M4 任务单：流式助手正文接入 TextKit 2（2026-10-21）

> 分支：`feat/textkit2-assistant-body`（基于 `18f77b4f`）
> 约束：**不合并 dev、不出包、不动部署；视觉冻结；先验证再动手。**
> 级别：**L**（流式核心链路、主线程预算、行高/滚动锚点、逐字动画），走全流程 + 独立审查。
> 前置：`docs/perf-6b-c5-m4-handoff.md`（静态正文收口；图标修复已验证：CI `39451773950`，旧 608.33pt / 新 610.00pt）。

## 0. 一句话

把流式助手正文从「旧 SwiftUI/Textual hosting 行 + 估算高度」换成「TextKit 2 实际测量 + 按块增量更新」；为不改视觉，**揭示中的尾部继续用现有 `ChatMarkdownView`（逐字动画），稳定块用 TextKit**，消息完成时同一行平滑转为静态 TextKit。现有 TextKit cell 的「每次 configure 全量重建」必须同时改成按块更新，否则接入流式后每批都会重建整条消息。

## 1. 已核实的事实

### 1.1 AA 现状（代码为准）

1. **流式行被 TextKit 路径明确排除**：`TimelineChatContentAdapter.swift:239` 要求 `!row.value.isStreamingText && !row.isRevealing`，且 `:240` 要求 `status == .done`。流式期完全走旧 hosting 路径。
2. **流式行是 `.measured` 策略，但没有 engine 测量**：流式正文属于 `.single` group，`groupHasInteractiveContent` 只对 reasoning/tool/marker/notice 返回 true（`:586-600`），因此 `heightPolicy` 返回 `.measured`（`:211`）；而 `measureSynchronously` 只同步测 `.plainText`，markdown 一律跳过（`TimelineCollectionController.swift:413-427`），可见 cell 的 preferred-height 校正只对 `.interactive` 生效（`TimelinePreferredAttributesDecision.swift:13`、`TimelineCollectionController.swift:309`）。
3. **所以流式行高度来自估算**：布局用 `heights.resolvedHeight(..., fallback: estimate)`（`TimelineListLayout.swift:103-104`）。完成时才换成 TextKit 精确测量，存在「估算 → 精确」的完成跳动风险。
4. **TextKit 路径每批都是全量解析**：文档缓存只按 `row.id + revision + text` 命中（`TimelineChatContentAdapter.swift:244-259`），未命中就 `AssistantMarkdownDocumentParser.make` 全量解析（`AssistantMarkdownDocument.swift:176-200`）。
5. **cell 每次 configure 全量重建**：`AssistantMarkdownCell.swift:132-165` 先 `removeBlockViews()` 再逐块新建；流式每批 reconfigure 都会重建整条消息的块视图。
6. **流式更新节流在 0.24s 批次**：`ReplyPresentation.revealSeconds = 0.24`、`batchInterval = revealSeconds + 1/60`（`ReplyPresentation.swift:7-11`）；`ChatTimelineRowModel.flush` 按批次显示（`SessionTimelinePresentation.swift:26-50`），未上屏文本在 `pending` 等待。
7. **动画是逐字 reveal**：`StreamingGlyphReveal` 用 `GlyphRevealRenderer` 对每个 batch 的新增 glyph 做 opacity/rise/blur（`StreamingGlyphReveal.swift:40-83`、`GlyphRevealLedger.swift:5-78`），只改绘制、不改排版。
8. **增量解析能力已经存在，但只有 SwiftUI 路径在用**：`MarkdownStreamSplit.safeSplitIndex`（`MarkdownStreamSplit.swift:6-43`）+ `MarkdownParseState`（`:83-96`）让 `ChatMarkdownView` 只重解析开放尾部（`ChatMarkdownView.swift:71-86`）。TextKit 路径尚未复用。
9. **官方证据**：流式正文是独立 `.streamingText` 行（固定 ID），完成后转 `.message(id)` 行；数据每 0.1s 发布整段 `StreamingAssistantText`；视图按 block（`Block.index`）逐块 `EquatableView` diff；正文 leaf 只失效「上一段起点到文末」；代码按前缀追加 + 增量高亮；tool call 不在流式行。见 `/home/ubuntu/aa-test/part-ab-code-page-granularity.md` §1.3、§5；`/home/ubuntu/aa-test/part-ac-code-page-parity.md` M5（本地报告，不进 public 仓库）。

### 1.2 由事实推出的判断

- 当前体感缺口的直接原因**不只是解析**（SwiftUI 路径已做尾部分解析），而是：
  1. 流式行没有 engine 测量，高度靠估算；
  2. 现有 `AssistantMarkdownCell` 每次 configure 都全量重建块视图；若不做增量更新就直接接入流式，每批都会重建整条消息；
  3. 完成时「估算 → 精确测量」切换。
- 因此 M4 的收益必须先用 **M4.0 埋点**证明；若数据显示瓶颈不在这三处，停下汇报，不进入实现。

## 2. 范围

**做**：流式正文的文档模型、增量解析与按块高度缓存、TextKit cell 增量更新、尾部动画保持、流式 gate、完成切换与滚动锚点验证。

**不做**（明确留给后续）：
- 附件/图片/Git badge/公式：解析遇到即整行回退旧路径，并**保持到本轮完成**（见 §3.3）。
- 选择/链接/复制、Dynamic Type/RTL、真机验收、出包、合并 dev。
- tool call 形态：保持 AA 现有 A 形态（工具胶囊聚合），不改 `.tools` 分组。
- `ChatMetrics` / `ChatPalette` / 任何视觉常数。

## 3. 设计

### 3.1 行身份：保持同一行（与官方差异，需 pp 确认）

- 官方：`.streamingText`（固定 ID）→ 完成后换成 `.message(DisplayMessage.ID)`，是 remove + insert 两行。
- AA：保持同一个 `V2TimelineItem.id` 贯穿流式 → 完成。
  - 依据：AA 的数据模型是一条消息一个 item，`revision` 随内容递增（`V2TimelineItem.swift:73`）；没有官方的 `SessionTranscriptEntry` 双 ID 结构。
  - 收益：避免 diffable snapshot 的 remove+insert 动画、避免完成时滚动锚点重算；可观察行为与官方一致（内容续写，最终静止）。
  - 备用：若 pp 要求严格同形，可引入合成 streaming item ID；代价是完成时的插入/删除动画与锚点处理，需要单独的 gate。
- **推荐前者**；本单按前者写 gate。

### 3.2 流式文档模型与缓存

新增 `AssistantStreamingDocument`（或给 `AssistantMarkdownDocument` 增加流式元数据）：

- `blocks: [AssistantMarkdownBlock]`、`blockIDs: [Int]`、`blockGroups: [Int]`、`digests: [Int]`、`tailRange`。
- 复用 `MarkdownStreamSplit` + `MarkdownParseState`：
  - 已过安全边界的 snapshot 只解析一次，块 ID 沿用 `MarkdownParseState.nextID`；
  - 每批只解析开放尾部；未变化块不重新转换、不重新测量。
- 每块高度缓存：key = `(blockID, digest, width, displayScale, typographyRevision)`；存在 adapter 的 per-row 状态里。
- 文本不再是前缀（服务端修正/快照替换）→ 丢弃该行 cache，整行重建（对应 `ChatTimelineRowModel.layoutGeneration` 的语义，`SessionTimelinePresentation.swift:33`）。
- 解析线程：`parseBlocks` 已 `nonisolated`（`AssistantMarkdownDocument.swift:204`）。第一版保持主线程，M4.0 量预算；若单批 parse+convert > 2ms，再把 `parseBlocks` 移到 detached，只在主线程做 `NSAttributedString`/UIKit 转换。

### 3.3 准入与回退

`assistantStreamingDocument(for:)` 的准入条件（与静态同源）：

- `.group` 且 `kind == .single`、恰好 1 行；
- `role == .assistant`、`content == .message`、`isStreamingText == true`；
- 无 inline notice、无附件、文本非空；
- turn action 为空或 text-only（沿用 `isTextOnlyTurnAction`）。

**Sticky fallback**：任一批解析出现未支持结构（图片/math 等，当前 `make` 返回 nil），该行从当批起固定走旧 hosting 路径，直到本轮完成；不允许「TextKit → hosting → TextKit」来回切换。完成后仍走现有静态准入；静态被拒绝时和今天一样回退 hosting。

### 3.4 Cell 增量更新

`AssistantMarkdownCell` 增加 `update(with:)`，与静态 `configure` 共用：

- 按 `blockIDs` diff：相同 ID 的块复用视图；只有 `digest` 变化的块更新内容与高度约束；
- 文本块前缀追加时用 `textStorage.replaceCharacters(in:with:)` 只改尾部（不做整段 `attributedText` 赋值）；非前缀替换才整段重建该块；
- 新增块追加视图，消失块移除（正常流式只追加；修正时整行重建）；
- 宽度变化 → 整行重建（现有行为）；
- footer 仅在静态路径传入，流式期无 footer。

### 3.5 渲染与动画（关键）

**Phase 1（本单）：混合块渲染**

- 稳定块（安全边界之前的块）用现有 TextKit 块视图；
- 开放尾部（`safeSplitIndex` 之后）用现有 `ChatMarkdownView(text: tailText, isStreaming: row.isRevealing, resolvesFileReferences: true)` 作为 host 放在 cell 内，**逐字 reveal 动画原样保留**（`isStreaming` 必须透传行的真实状态，不能写死 true）；
- 尾部高度用 TextKit 从同一份解析结果测量，host 约束到该高度；
- 当新安全边界把某个块推出尾部时，把它提升为 TextKit 块视图。提升发生在一个新的批次的布局变化中，容差 ≤1pt；gate 断言接缝高度差。
- 为什么不是直接全 TextKit：`StreamingGlyphReveal` 是 SwiftUI `TextRenderer` 的逐 run 绘制（opacity/rise/blur），普通 `UITextView` 无法复现；整块 alpha 淡入是视觉变化，不做。

**Phase 2（不在本单）**：TextKit 原生逐字渲染器（自建 `NSTextLayoutManager` 绘制视图，复用 `GlyphRevealLedger`）。只有 Phase 1 接缝不达标或 pp 要求全引擎同形时才单独立项。

### 3.6 测量与滚动

- `measureSynchronously` 接纳 streaming document：用 per-block 缓存求和 + 间距，写入 `.measured`；流式行不再落 estimate。
- 高度变化仍走 `TimelineListLayout` 现有的 bottom-pin / 锚点逻辑；`streamingItemIDs` 继续包含该行（`TimelineChatContentAdapter.swift:602-611`）。
- 高度约束：普通批次单调不减；文本修正批次允许受控重置，gate 断言不是抖动。

## 4. Gate

### 4.1 M4.0：先量基线（不改 UI）

DEBUG 埋点，跑同一段脚本化流：

- 每批记录：parse 耗时、convert 耗时、measure 耗时、cellBuild 耗时、当前高度来源（estimate/measured）；
- 同一 fixture 对比：现有路径 vs 新文档管线（只测量、不换视图）；
- 产出 `textkit-m4-baseline.json`。若新管线没有明显收益，停下汇报。

### 4.2 M4.1：流式 gate（新 autorun `aa-textkit-m4`）

脚本化流 fixture（模拟 AA 0.26s 批次）：段落 → 列表 → 未闭合代码围栏 → 表格 → 收尾段落 → 一次非前缀修正。每批断言：

1. `stored == measured`（±0.5）、`cellContent == stored`（±1）、无 pending/estimate；
2. 相邻行 frame 无重叠；
3. 高度单调不减（修正批次除外，且修正后与重新全量测量一致）；
4. 未变化块的 blockID 稳定；只有尾部块 digest 变化；
5. 代码高亮 token 与当前 code 前缀一致（现有 `tokens.joined() == source` guard 加 generation 检查）；
6. 完成切换：最终文本与静态 `AssistantMarkdownDocument` 一致；`|h_stream - h_static| ≤ 1pt`；底部 pinned 时 scroll offset 变化 ≤1pt；
7. 回退：含图片的 fixture 从首批起走 hosting，且全程不翻转；
8. 视觉：流式中段两帧 + 完成后一帧，与旧渲染并排/裁剪对比；完成后必须满足现有静态 parity（旧 608.33 / 新 610.00，差 1.67pt 基线）。
9. 报告新增：每批 parse/convert/measure/cellBuild 的 median/p95、块复用数、提升次数、接缝最大高度差。

### 4.3 CI

- 走 `.github/workflows/ios-build.yml` 的 `timeline_autorun` 派发（feature 分支不自动触发）；
- M4 结果单独判读；已知 C3 flake（`no cell for reasoning` / `longGroup`）只记录，不计入本单结论；
- 若 M3 gate 受流式改动影响（静态准入路径共用），必须同轮保持绿。

## 5. 风险

- **主线程预算**：每批 parse+convert 在 main actor；用 M4.0 数据决定是否移后台。
- **长未闭合代码围栏**：`safeSplitIndex` 在未闭合围栏时返回 nil，尾部等于全文；非常长的代码流式会每批全量解析。M4.0 必须量这个最坏情况；必要时对该形态降级（保留旧路径并记录）。
- **接缝/提升跳动**：TextKit 与 Textual 的逐块高度差；gate 用接缝高度差和视觉帧兜底；超过阈值就退回「尾部保持 SwiftUI 到消息完成」的更保守方案（此时稳定块仍 TextKit）。
- **代码高亮异步竞态**：`SyntaxHighlighting.tokenize` 是 async（`SyntaxHighlighting.swift`）；批次快速到达时旧 token 结果可能覆盖新文本，必须 generation guard。
- **缓存增长**：per-block cache 随行数增长，需在该行离开窗口/完成时清理。
- **高度单调性被打破**：Markdown 解析在补全语法时可能让同一段文字变矮（如列表收拢）；gate 允许受控下降但必须无重叠、无锚点跳动。

## 6. 交付顺序

1. `AssistantStreamingDocument` + 增量解析/块缓存 + 单测（纯模型，无 UI）
2. adapter 准入 + controller 测量 + 单测
3. cell 增量更新（先全 TextKit 路径，用 gate 单独驱动）
4. 尾部 SwiftUI host + 提升逻辑
5. `aa-textkit-m4` gate + CI 首跑
6. M4.0 基线数据与实现后数据对比，写交接

## 7. 需要 pp 决定

1. **行身份**：保持同一行（推荐，见 §3.1）还是严格按官方换行？
2. **尾部动画**：接受 Phase 1 混合渲染（推荐，视觉不变、性能收益集中在前面的稳定块），还是要求一次性做 Phase 2 的 TextKit 原生逐字渲染器？
3. **M4.0 先跑**：推荐先花半天量基线，再决定是否进入 M4.1 实现。

## 8. 验收

- M4 gate `passed: true`；CI 的 `test` + `timeline-autorun` 中 M4 步绿（已知 C3 flake 单列）。
- 每批 `stored == measured`、无重叠、完成切换 ≤1pt、无锚点跳动。
- 完成后视觉 parity 不低于静态基线（1.67pt）。
- M4.0 与 M4.1 数据对比证明收益（parse/convert/measure/cellBuild 至少一项显著下降，且总耗时下降）。
- 未覆盖：附件/选择/链接/DT/RTL/真机/出包/合并。
