# C5 / Code 页同形差距单（2026-10-20）

> 依据：Hark `part-ab-code-page-granularity.md`（EVIDENCE / INFERENCE / UNKNOWN 分档）。
> 当前分支：`feat/textkit2-assistant-body`，行粒度已按 EVIDENCE 回退到 `02c727bd`。
> 原则：只对 EVIDENCE 动手；INFERENCE/UNKNOWN 先列核实项，不猜。

## 0. 已确认并已对齐

| 项 | 官方 Code 页（EVIDENCE） | AA 当前 | 状态 |
|---|---|---|---|
| 行粒度 | 一个 `SessionTranscriptEntry` 一行；`.message(DisplayMessage)` 整条一行 | 一个 assistant group 一个 `AssistantMarkdownCell` | 已对齐 |
| 行内组合 | `TranscriptBlockStack` 的 `VStack(.leading, spacing: interBlockSpacing)` + `ForEach(DisplayMessage.blocks)` | `AssistantMarkdownCell` 的 `UIStackView` 纵向堆叠 block views | 形状对齐 |
| 正文块 | 每个 `.text(String)` → `AssistantTextBlockView(.committed)` → `RichMarkdownView` → `ClaudeMarkdownView` 的 `VStack` + 每 Markdown 块一个 `MarkdownBlockView` | 每个文本块一个 TextKit view；代码/表格/列表/引用各自 block view | 粒度对齐，内部实现不同 |
| 流式行 | 独立 `.streamingText` 行（固定 ID），内部每个 API text block 一个 `AssistantTextBlockView(.streaming)`；完成后转 `.message(id)` 行 | 流式时 TextKit 路径退出，走旧 SwiftUI/Textual hosting | **未对齐** |
| 表格 | `MarkdownTableRepresentable` → `MarkdownTableView`，单 surface、padH 12 / padV 8、`TableOverflowPolicy`、横向滚动、边缘渐隐 | 单 surface，padH 12 / padV 8；列宽 cap 260；无边缘渐隐 | 形状对齐，细节未对齐 |
| 代码块 | `ExpandableCodeBlockView` + `ClaudeComponents.CodeBlockView`（header/divider/横滚/圆角卡片）；`CodeView` 内部 `CodeTextDisplay` 或 `CodeTextView` 二选一（未确定） | 自绘 card + header + `UITextView`；无语法高亮 | 形状接近，实现不同 |

## 1. 剩余差距与证据状态

### A. 流式（优先）

- 官方：数据每 0.1s 整条 `StreamingAssistantText`；视图按 block id 逐块 `EquatableView` diff；`MarkdownTextView` 引擎只失效上一段起点到文末，`MarkdownUITextView` 引擎整段替换。
- AA：`TimelineChatContentAdapter` 明确排除 `isStreamingText` / `isRevealing`，流式走旧 Textual 路径。
- 状态：官方行结构与 diff 粒度 EVIDENCE；AA 改造方案未写。
- 需要：独立的 streaming 行模型 + 0.1s 块集合 + 逐块 diff + TextKit 尾部增量。工作量 M4 级。

### B. 列表 / 引用

- 官方：`MarkdownBlock.Content` 没有 list/quote case；列表和引用都是 `.text(AttributedString)`，靠 `RunTraits.listLevel/quoteLevel` 排版；一个列表/引用是几个 MarkdownBlock 仍 UNKNOWN。
- AA：自定义 `AssistantListBlockView` / `AssistantQuoteBlockView`，marker/缩进/quote bar 自绘。
- 状态：官方“用 text + RunTraits”是 EVIDENCE；切块粒度、`MarkdownTextRenderer` 的段落样式/tab stops/quote bar 映射仍是 UNKNOWN（part-aa Q2/Q8）。
- 需要：Hark 补 `RunTraits → paragraphStyle/tabStops/quoteGutterDepth` 的映射后，才能严格同形。

### C. 块间距 / insets

- 官方：内层 `ClaudeMarkdownView` 的 `VStack(spacing:)` 数值 UNKNOWN；外层 `SessionMessageStyle.interBlockSpacing` 默认 nil（SwiftUI 默认）；`rowMargins`、`interMessageSpacing` 实际值未读出。
- AA：块间固定 12pt（`AssistantMarkdownTextLayout.blockSpacing`），消息间 20pt。
- 状态：UNKNOWN，不能改数值。
- 需要：Hark 读常量或从参考截图量；拿到前保持 AA 现值。

### D. 代码块

- 官方：`ClaudeComponents.CodeBlockView` 的 header/divider/横滚/圆角结构 EVIDENCE；圆角、背景、header 高、字体、`CodeView` 走 `CodeTextDisplay` 还是 `CodeTextView` 均 UNKNOWN。
- AA：自绘 card，36pt header、14pt padding、`UITextView`、无高亮。
- 状态：结构接近，数值/引擎未证实。
- 需要：Hark 补常量与 `CodeView` 分支；拿到前不调尺寸。

### E. 表格

- 官方：同一 `MarkdownTableView`；`TableOverflowPolicy` 字段与常量对应仍是 INFERENCE；边缘渐隐 EVIDENCE。
- AA：单 surface、padH 12 / padV 8；列宽 max-content + 260 cap；无边缘渐隐；绘制用 `NSAttributedString.draw` 而非 TextKit fragment tile。
- 状态：形状对齐；列宽 policy、渐隐、tile 绘制未对齐。
- 需要：先确认是否照搬 `TableOverflowPolicy`（Hark 未完全解出）；渐隐可独立做。

### F. tool call 与正文同行

- 官方：视图层 EVIDENCE——同一 `DisplayMessage.blocks` 里的 `.text` 和 `.toolCalls` 在一个 VStack、同一行。
- 数据层：“正文 → tool → 正文”是否同一个 `DisplayMessage` 仍是 INFERENCE；`SessionMessageProcessor` 合并/拆分规则未读完。
- AA：tool/thinking 行聚成 `.tools` group，单独一行；assistant 正文 cell 只接受 `.single` group。
- 状态：官方数据层未证实；AA 改动会动分组模型，风险高。
- 需要：Hark 读完合并/拆分函数；再决定是否改 AA 分组。

## 2. 建议顺序

1. **先补核实**：B（列表/引用 RunTraits 映射）、C（spacing/insets 常量）、D（代码块常量与 CodeView 分支）、F（DisplayMessage 合并规则）。
2. **再做流式 A**：它是当前用户体感最大、且官方行结构已 EVIDENCE 的差距。
3. 表格 E：先做边缘渐隐（EVIDENCE），列宽 policy 等 Hark 解出后再动。
4. tool call 同行 F：最后做，涉及分组模型。

## 3. 本单不做

- 不调整块间距/消息间距（等 C 证据）。
- 不换列表/引用实现（等 B 证据）。
- 不改代码块尺寸/颜色（等 D 证据）。
- 不改 tool 分组（等 F 证据）。
- 不合并、不发包。

## 4. 决策（2026-10-20，pp）

**先保持 AA 现有形态（A：工具胶囊聚合），官方 B 形态（消息内平铺）后面再考虑。**

- 当前分支的视觉与交互冻结：不做 tool call 并回 cell，不做间距/代码卡视觉对齐。
- M1 的官方证据保留在 `part-ac` 报告与 `perf-6b-c5-muse-audit.md`，等 pp 以后决定是否切 B 时再启用。
- C5 的定位保持“dev 的视觉 + 换 TextKit 2 引擎的性能优化”，不引入视觉变化。
