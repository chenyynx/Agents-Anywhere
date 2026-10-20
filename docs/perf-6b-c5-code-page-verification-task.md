# C5 / Code 页助手正文核实任务单（2026-10-20）

> 目标：在继续改 AA 的助手正文之前，把官方 **Code 页**的行粒度和正文组合用证据钉死。
> 背景：第一版报告把 `MarkdownTextCellContent` / `MarkdownTextCellRow` 误归到 Code 页；第二版报告已修正为聊天页。当前 AA 分支 `feat/textkit2-assistant-body` 已按“Code 页一条消息一行”回退（`02c727bd`），但这一步仍基于 INFERENCE，**不是最终结论**。
> 输出要求：结论先行；每条标 `EVIDENCE` / `INFERENCE` / `UNKNOWN`；给地址（函数/符号/常量）；不要改 AA 代码。
> 参考：`/home/ubuntu/wiring/docs/part-aa-markdown-ui.md`（第二轮报告）。
> 状态：第一轮行粒度核实已由 Hark 完成（`part-ab-code-page-granularity.md`，结论见文末）；**本任务单现在作为 Muse 的补挖单，只做 §8 的 UNKNOWN，不重做已证实部分。**

## 0. 先给一句话结论

请先回答：

**Code 页里，一条 assistant 消息（可能包含多段正文、代码块、表格、tool call）在 `TranscriptListCell` / `UICollectionView` 里到底占几行？每行的 content 是什么？**

如果无法从现有证据唯一确定，直接写 UNKNOWN，并列出还差哪条指令/哪个调用点。

## 1. 行粒度（最关键）

- `TranscriptListCell` 的一次 data source 配置对应哪个模型对象？把配置闭包 / `UIHostingConfiguration` 的创建点追出来。
- `AssistantTextBlockView` 是一次配置的**整个 content**，还是其中一段？
- `AssistantTextBlockView.source.committed(String)` 的字符串是**整条 assistant 消息**，还是**单个 text block**？
- 一条 assistant 消息如果包含“正文 → tool call → 正文”，会产生几个 `AssistantTextBlockView` / hosting 行？
- `TranscriptListCell` 的 row 身份来自哪个字段（message id / block id / index）？

需要证据链：`AssistantTextBlockView` 创建点 → hosting configuration → `TranscriptListCell` 配置闭包；给地址。

## 2. `RichMarkdownView` 的块组合

- `RichMarkdownView` 的容器是什么（VStack / LazyVStack / 其他）？
- 块与块之间的 spacing 是多少？有没有外层 insets？代码块、表格、图片块是否同间距？
- `RichMarkdownView` 接收的是字符串还是 `MarkdownBlockCollection`？块如何枚举成 `MarkdownBlockView`？
- 列表 / 引用是一个 `MarkdownBlockView`，还是每个 item 一个？
- 如果 spacing/insets 只能反编译到常量，给常量地址和数值；拿不到就标 UNKNOWN。

## 3. 行高与测量

- Code 页 hosting 行的 SwiftUI 高度通过哪个闭包报给 `heightDidChange` / `rowMeasured`？给调用链。
- 是否存在 measured / estimate 两档？宽度变化时是否清高度？
- 展开代码块、表格横向滚动、流式增长时，行高如何变化？

## 4. 代码块与表格（Code 页路径）

- `CodeView(display: MarkdownCodeTextView)` 的卡片、header、滚动、复制按钮结构；`ExpandableCodeBlockView` 的展开逻辑。
- Code 页的 `MarkdownTableRepresentable` 是否复用聊天页的 `MarkdownTableLayout` / `MarkdownTableSurface`？表格的 padH/padV、列宽 policy、横向滚动、边缘渐隐是否同一套？
- 表格里单元格文字是 UITextView、TextKit leaf，还是自绘 tile？

## 5. 流式

- `AssistantTextBlockView` 的 `streaming((MarkdownBlockCollection, isComplete))` 每次更新时，是整条消息重建，还是按块 diff？
- `committed(String)` 切换时是否更换视图 identity？
- 正文/代码/表格各自的增量粒度（只追加尾部？只失效 y 以下？）。

## 6. 给 AA 的最小同形映射

基于以上证据，回答：

- AA 现有 UICollectionView 时间线，最小同形映射应该是：
  - A. 一条 assistant 正文一个 cell，内部块堆叠；
  - B. 每个 text/code/table 块一个 cell；
  - C. 其他。
- 选一个并给出证据；如果官方行为会根据内容/流式状态变化，分别说明。

## 7. 不要做的事

- 不要重新挖聊天页（`MarkdownTextCellContent` 路径）的细节，除非它和 Code 页共享。
- 不要改 AA 代码。
- 不要把 INFERENCE 写成 EVIDENCE；拿不到就写 UNKNOWN。

## 核实结果（2026-10-20，Hark `part-ab`）

> 报告：sbx `/home/ubuntu/wiring/docs/part-ab-code-page-granularity.md`；本地副本 `/home/ubuntu/aa-test/part-ab-code-page-granularity.md`。

**结论（EVIDENCE）**

- Code 页一个 `SessionTranscriptEntry` 占一行 `TranscriptListCell`；该行是 `UIHostingConfiguration`，content 为 `SessionCollectionRow → SessionTranscriptEntryView`。
- 已落库的 assistant 消息 `.message(DisplayMessage)` **整条一行**：`DisplayMessageView → TranscriptBlockStack`（`VStack(.leading, spacing: interBlockSpacing)` + `ForEach`）按 `DisplayMessage.blocks` 逐块排 `DisplayBlockView`。
- 每个 `.text(String)` 块是一个 `AssistantTextBlockView(.committed)` → `RichMarkdownView` → `ClaudeMarkdownView`（内层 `VStack` + `ForEach`，每个 Markdown 块一个 `MarkdownBlockView`）。
- `.toolCalls` 等非文本块也是同一 VStack 里的兄弟视图，**不单独占行**（前提是它们在同一个 `DisplayMessage` 里）。
- 流式正文是**另一行**：`.streamingText`（固定 ID）→ `StreamingAssistantTextView`，每个 API text block 一个 `AssistantTextBlockView(.streaming)`；完成后转为 `.message(id)` 行。

**仍是 INFERENCE / UNKNOWN**

- “正文 → tool call → 正文”是否落在**同一个** `DisplayMessage`（决定 1 行还是多行）：INFERENCE；`SessionMessageProcessor` 的合并/拆分指令未读完。
- `ClaudeMarkdownView` 内层 block spacing 的字段名和数值：UNKNOWN（字段名推断 `theme.blockSpacing`）。
- 外层 `SessionMessageStyle.interBlockSpacing` 默认 nil（SwiftUI 默认 spacing）；`rowMargins`、`interMessageSpacing` 实际值未读出。
- 列表/引用在解析器里是一个块还是每个 item 一个块：UNKNOWN。
- Code 页 `CodeView` 走 `CodeTextDisplay`（`MarkdownCodeTextView`）还是 `CodeTextView`：UNKNOWN；代码卡片圆角/颜色/header 高也 UNKNOWN。

---

# 8. Muse 补挖任务（2026-10-20，只做剩余 UNKNOWN）

> 前置：Hark `part-ab-code-page-granularity.md` 已证实行粒度；不要重做 §1–§7 的已证实部分。
> 目标：补出实现“严格同形”还缺的证据。每条都要 `EVIDENCE / INFERENCE / UNKNOWN` + 地址；拿不到就写 UNKNOWN，不要猜。
> 产物：与 `part-ab` 同目录的 `part-ac-code-page-parity.md`；不改 AA 代码。

## M1. DisplayMessage 合并/拆分（决定 tool call 是否与正文同一行）

Hark 已把行级视图链钉死；数据层还差“正文 → tool call → 正文”是否同一个 `DisplayMessage`。

请读完并给出规则表（输入事件 → 产生/追加哪个 `DisplayMessage`、哪个 block）：

- `SessionMessageProcessor` 候选：`0x10273255c`、`0x102737174`、`0x102735628`、`0x10272fa48`、`0x102731950`
- `SessionTranscript` 条目构建：`0x10253f794`、`0x102542cdc`、`0x1025415e4`
- `LiveTurn.Span.isOnlyRowOfItsMessage` 的语义

要回答：

1. 一条 API assistant message（含 text + tool_use）落成几个 `DisplayMessage`？
2. tool call 前后的两段 text 是否进同一个 `DisplayMessage.blocks`？
3. 若同一 API message 有多个 text content block，是否每个 block 一个 `.text` 元素、但仍在同一个 `DisplayMessage`？
4. AA 若把 tool 行独立成 `.tools` group，与官方差在哪一层的什么规则？

## M2. 间距 / insets 数值

1. `ClaudeMarkdownView` 内层 `VStack(spacing:)` 的字段（推断 `MarkdownThemeConfiguration.blockSpacing`）：字段名、默认值、`AssistantTextBlockView` 构造 theme 的三处（`0x10295b974` / `0x10295b9a8` / `0x10295ba3c`）实际传值。
2. `SessionMessageStyle`：`interBlockSpacing` 默认 nil 已证；补 `rowMargins`（`SessionCollectionRow` 字段 / hosting `.margins`）和 `.padding(.bottom, x)` 在 Code 页的实际数值；`interMessageSpacing=10.0`、`segmentVerticalPadding=4.0` 是否参与普通 Code 会话。
3. 给出可直接写进 AA 的数值（含单位/缩放），拿不到就 UNKNOWN。

## M3. 列表 / 引用

官方 `MarkdownBlock.Content` 没有 list/quote case，列表/引用是 `.text(AttributedString)`；AA 现在是自定义视图。请补：

1. `MarkdownTextRenderer` 如何把 `RunTraits{listLevel, listItemLevel, quoteLevel, quoteGutterDepth, tabStops}` 映射到 `NSParagraphStyle`（`headIndent` / `tailIndent` / `firstLineHeadIndent` / `tabStops` / `defaultTabInterval`）。
2. 列表 marker（bullet/ordered）和引用条/quote gutter 的绘制位置、宽度、颜色、圆角。
3. 解析器切块：一个列表是**一个** `.text` 块，还是每个 item / 每个段落一个块？引用同理。
4. 给出能复现一段“嵌套列表 + 引用”的公式/伪代码；拿不到就 UNKNOWN。

## M4. 代码块

1. `ClaudeComponents.CodeBlockView` 常量：圆角、背景色、header 高、divider 高/色、内容 insets、字体、行距。
2. Code 页 `CodeView` 的 `display` 环境是否被设为 `MarkdownCodeTextView`？找到环境写入点；若没有，走 `CodeTextView`（UITextView）。
3. `ExpandableCodeBlockView` 的展开是 sheet / 全屏 / 行内？复制按钮的格式（纯文本 / Markdown / HTML）。
4. `CodeTextView` 的行高/换行/横向滚动策略；`MarkdownCodeTextView` 的 `StreamingCodeColors` 更新粒度。

## M5. 流式行切换（P2）

1. `.streamingText` 行 → `.message(id)` 行的替换时序、锚点、动画；`rowsApplied` 前缀比较是否参与。
2. `TranscriptBlockStack` 的 `ForEach` id keypath：committed 侧是否 `offset`，streaming 侧是否 `Block.index`。
3. 流式期间 tool call 放哪一行（Hark 推断不在 `.streamingText`，需确认）。

## 环境与工具

- 二进制：`/home/ubuntu/swift-recover/unpacked/Payload/Claude.app/Claude`（thin arm64，base `0x100000000`；若分析机上路径不同，用等价副本）。
- Hark 用过的工具：`swift_types.csv` / `witness.csv`（`/home/ubuntu/wiring/out/`）、`q.py` / `calls.py` / `dis1.py` / `xrefs.py`、Ghidra `DecompileAt.java`（`-readOnly`）。
- 临时反编译输出放分析机 `/tmp`，不入库；报告按 `EVIDENCE / INFERENCE / UNKNOWN` 分档。
- **不要改 AA 仓库**；只写报告。
