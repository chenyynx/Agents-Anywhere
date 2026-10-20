# C5 / Code 页助手正文核实任务单（2026-10-20）

> 目标：在继续改 AA 的助手正文之前，把官方 **Code 页**的行粒度和正文组合用证据钉死。
> 背景：第一版报告把 `MarkdownTextCellContent` / `MarkdownTextCellRow` 误归到 Code 页；第二版报告已修正为聊天页。当前 AA 分支 `feat/textkit2-assistant-body` 已按“Code 页一条消息一行”回退（`02c727bd`），但这一步仍基于 INFERENCE，**不是最终结论**。
> 输出要求：结论先行；每条标 `EVIDENCE` / `INFERENCE` / `UNKNOWN`；给地址（函数/符号/常量）；不要改 AA 代码。
> 参考：`/home/ubuntu/wiring/docs/part-aa-markdown-ui.md`（第二轮报告）。

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
