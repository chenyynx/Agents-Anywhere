# C5 / M3.1 任务单：最终助手回复接入 TextKit 2（turn action footer）

> 前置：M3 已完成并通过全流程 CI（`docs/perf-6b-c5-m3-task-sheet.md`，run `39364614409`）。
> 分支：`feat/textkit2-assistant-body`。不合并、不发包、不碰 dev。

## 0. 问题

M3 的接入条件沿用了 M2：`turnActions[group.id] == nil`。但一轮对话的**最终助手回复**通常带复制/重试 footer，因此被整行排除：

- 简单一问一答 → 最终回复永远走旧 hosting 渲染，M3 实际不可见
- 只有工具调用前的中间助手消息（无 footer）可能看到 M3
- M3 gate 的合成 fixture 没有 footer，所以 CI 没暴露这个缺口

## 1. 目标

让**文本型 turn action footer** 的最终助手回复也走 TextKit 2，同时保持：

- 先同步测高再 apply，stored == measured
- footer 高度是确定值，不依赖可见 cell 拟合
- 带文件变更摘要的 turn 继续整行回退 hosting（`SessionTurnReviewFooter` 高度不定）

## 2. 范围

**接入**：`turnAction != nil` 且满足：

- `action.changes.isEmpty`（没有文件变更摘要）
- `!action.replies.isEmpty`（footer 的动作行会显示）

**继续回退**：

- `action.changes` 非空（含文件变更的 `SessionTurnReviewFooter`）
- 其它 M3 已有的排除条件（流式、附件、notice、多行 group 等）不变

**footer 视觉与行为**：

- 复用 `SessionTurnActions` 的既有布局：复制、赞、踩、重新生成、时间戳
- 复制行为保持可用；赞/踩/重生成在产品里目前就是空动作，保持一致
- 高度：4pt 间距 + 24pt 动作行 + 15.5pt 底距 = 43.5pt

**不做**：流式、选择、链接点击、图片/Git/math 附件、文件变更 footer 的 TextKit 化。

## 3. 架构

```
AssistantTurnFooter { copyText, timestampText }
  static topSpacing = 4
  static rowHeight = ChatMetrics.actionRowHeight + ChatMetrics.actionRowBottomGap
  static height = topSpacing + rowHeight

TimelineCollectionContentProviding
  + assistantTurnFooter(for:) -> AssistantTurnFooter?   // 默认 nil

TimelineChatContentAdapter
  - assistantMarkdown: turnAction 为 nil 或 text-only footer 才通过
  - assistantTurnFooter: changes.isEmpty && !replies.isEmpty 时返回 payload

TimelineCollectionController.measureSynchronously
  - document 高度 + footer 高度 → validatedHeight
  - 文档不再可接入时移除该 item 的 documentHeights（避免陈旧条目卡住宿主测量）
  - cellProvider 把 footer 传给 AssistantMarkdownCell

AssistantMarkdownCell
  - body blocks 后追加固定高度的 UIHostingController(SessionTurnActionsRow)
  - UIStackView.setCustomSpacing(4, after: lastBodyView)
```

**footer 复用**：把 `SessionTurnActions` 的绘制拆成 `SessionTurnActionsRow(copyText:timestampText:)`；`SessionTurnActions` 保持原 API，内部转发到 row view。这样 TextKit cell 不必复制一套图标与复制逻辑。

## 4. Gate

扩展 `aa-textkit-m3`：

- 给合成助手行返回一个 `AssistantTurnFooter`，并在 `contentSignature` 里带上 `turnAction`，让高度 key 反映 footer 的出现。
- 断言：
  1. `stored == measured`（0.5pt）
  2. `|cellContent − stored| ≤ 1pt`
  3. 不进入 pending、不写 estimate、无相邻重叠
  4. footer 高度已计入：`stored` 大于同文档无 footer 时的高度，差值为 43.5pt
  5. 解析契约与 M3 一致
- 报告增加 `footerApplied` / `footerHeight` 字段。

## 5. 风险与处置

- **footer 高度漂移**：把 4 / 24 / 15.5 定为 `AssistantTurnFooter` 的常量，view 与测量共用；改产品 footer 时必须同时改这里（注释标明来源）。
- **hosting 子视图**：每个接入行多一个小的 SwiftUI hosting view；滚动开销待 scroll gate/真机验证。
- **eligibility 切换**：流式结束、footer 出现、文件变更出现都会改变可接入性；在 `measureSynchronously` 清理不再可接入的 `documentHeights`，防止陈旧高度卡住宿主测量。
- **复制行为**：hosting 的 `SessionTurnActionsRow` 直接调用 `UIPasteboard`，不依赖父控制器；真机验证复制成功与 2 秒确认态。

## 6. 验证状态（2026-10-20）

- 提交 `9a332bc9`，编译修复 `dafd9226`（`UIHostingController` 需要 `import SwiftUI`）。
- **全流程绿**：run `39370349234` 的 rerun（commit `dafd9226`）— `test` success、`timeline-autorun` success（C3 与 M3.1 同时绿）。
- M3 gate（iPhone Air / iOS 26.5）：
  - `stored 640 == measured 640`
  - `cellContent 639.67`，`cellFrame 640`
  - `footerDelta 44.0` vs `footerHeight 43.5`（整点取整差 0.5pt）
  - `pending false`，`estimate 200` 未写入，`overlaps 0`
  - 块统计与解析契约同 M3
- 同轮 C3 曾连续两次报既有 flake（`no cell for reasoning` / `longGroup cell 200 clips content 1471`），第三次 rerun 绿；M3.1 不触碰 C3 路径。
- 未覆盖：真机、复制交互、文件变更 footer、流式/选择/链接。

## 7. 滚动 gate（M3.2）

- 在 M3 gate 的合成时间线底部追加 12 条「表格 + 代码 + 列表」压力行，从顶到底 24 步 `setContentOffset` + `layoutIfNeeded`，只计同步 scroll+layout 时间。
- 首轮（run `39375282261`，commit `cc9a63bb`）：median 162.75ms / p95 297.36ms / max 307.67ms，触发 150/300ms 冒烟上限。根因：表格每个单元格一个 `UITextView`，一张 4×6 表 24 个 TextKit 2 栈。
- 修复（`b44b423e`）：表格单元格改用顶对齐 `UILabel`，同一份 attributed string，行高仍由 TextKit 2 测量。
- 复测（run `39377592341`，M3 gate pass）：median 27.31ms / p95 37.71ms / max 40.85ms；正确性 stored 640 / cellContent 639.67 不变。
- 这是模拟器 Debug 的同步冒烟指标，不是产品帧预算；真机滚动/120Hz 仍待验证。UILabel 与 TextKit 2 的换行差、是否裁切也未真机确认。
- 同轮 C3 仍是既有 flake，M3 gate 独立绿。
