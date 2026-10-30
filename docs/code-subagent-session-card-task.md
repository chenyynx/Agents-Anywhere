# Code + Chat：SubAgent 会话卡（官方 ChildSessionCard）任务单

> 级别：**L**（两个渲染 profile、分组模型、视觉组件、行高）
> 基线：`feat/code-profile-beta @ bae413aa`（2026-10-30）
> 分支：`feat/subagent-session-card`（本任务单所在分支）
> 官方依据：Claude iOS **1.261023.20** 静态反编译；报告 `/home/ubuntu/aa-test/sbx-re-harvest/reports-subagent/R-SA1.md`、`R-SA4.md`（辅助证据，不在仓库内）
> pp 2026-10-30 定：**Code + Chat 一起做**；Chat 现有 Agent 卡/胶囊按官方样式重做，之后再做老 Chat 遗留清理（清理另开单）

---

## 1. 目标 / 非目标

### 1.1 目标

1. Code 与 Chat 两个 profile 的**顶层 Agent 调用**（connector `content.kind == "agent_call"`）渲染为官方 `ChildSessionCard` 形态的独立卡片，不再混在普通工具行/步骤组里。
2. 卡片整卡可点，打开现有 `SubAgentPanelSheet`（AA 的子代理详情面）。
3. Chat 的悬浮 SubAgent 胶囊按同一视觉重做（形态见 §7 待定项）。
4. 为步骤组任务单 §10「删除老 Chat 遗留」提供统一渲染面；本单不删旧容器。

### 1.2 非目标

- 不改 connector / server wire；不新增字段。
- 不做官方 `PullRequestCountPills`（AA 的 agent_call 没有 PR 数据）。
- 不做官方 `ThreadSessionCardContext.childSession/prRows` 的跨会话加载；AA 用现有面板。
- 不做卡内展开、停止按钮、描边/`ToolCallCardShell`（官方都没有）。
- 不删除 `ChatTimelineView` / `SessionTimelineGroupView` / 思考球等旧 Chat 遗留（§10 独立任务）。

---

## 2. 官方证据（1023 build）

### 2.1 类型链

`ToolCallSegment.threadSessionCard`（tag 3）→ `InlineThreadSessionCard` → `ChildSessionCard`。

- `ToolCallSegment` 6 例：`brief=0, workflow=1, writingDraft=2, threadSessionCard=3, span=4, artifactCard=5`；fieldmd `0x1069752b0`，case3 名字指针 `0x10683a680`。
- 1023 构造点：`0x1034524b0` 内 `0x103452b28..0x103452b34`（`mov w2,#3` + `swift_storeEnumTagMultiPayload`）。
- `InlineThreadSessionCard`（dump 110404）：
  ```swift
  struct InlineThreadSessionCard {
      let task: DispatchTaskInfo
      var _context: Environment<ThreadSessionCardContext>
  }
  ```
  size `0x99`/stride `0xA0`；Body = `ChildSessionCard` + `.task(id: task.sessionId, priority: .userInitiated)`（witness `0x1034a0d48` → `0x1034a0378`）。
- `ChildSessionCard`（dump 108537）：
  ```swift
  struct ChildSessionCard {
      let title: String
      let status: ActivityStatus
      let prStateCounts: [PullRequestState: Int]
      let updatedAt: Date?
      let onTap: () -> Void
  }
  ```
- `ThreadSessionCardContext`（dump 110395）：`childSession`、`prRows`、`onShown`、`onTap` 四个按 `SessionTag` 的回调；size 64。
- `ActivityStatus`（dump 20301）：`needsInput=0, working=1, failed=2, unread=3, idle=4`。

### 2.2 卡片视觉（R-SA4 C1–C4，地址可复查）

```
Button(action: onTap) {
    VStack(alignment: .leading, spacing: 8) {
        SessionCardTitleRow(title, updatedAt, status)
        PullRequestCountPills(prStateCounts)   // 空字典不渲染
    }
    .padding(.all, 16)
    .background(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(surface3)
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 2)
    )
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
.accessibilityInputLabels([Text(title)])
```

- 圆角 24 / continuous：`0x105a68270 = 24.0`，`0x10748b248 = continuous`（`0x1032db4d4`）。
- 内边距 16：`0x105a68228 = 16.0`（`0x1032db200`）。
- VStack 间距 8：`0x105a68218 = 8.0`。
- 背景色 `surface3`：light `#FFFFFF`，dark `#201F1F`（`0x108151bc8`）。
- 阴影：`black.opacity(0.1)`、radius 2、x 0、y 2（`0x105a68290 = [0.1, 2.0, 2.0]`）。
- 无描边、无 `ToolCallCardShell`、无展开区域；整卡 = 一个 PlainButtonStyle Button。
- 外层 transcript 的 `segmentVerticalPadding = 4 pt` 由段容器施加，不进入卡片内部。

### 2.3 标题行（R-SA4 C5–C7）

```
HStack(spacing: 8) {
    ActivityStatusGlyph(status, size: 0)          // 16 x 16
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(ClaudeFonts.Typography 15 / weight 400 / lineHeight 21, relative)
            .foregroundStyle(textPrimary)          // light #0B0B0B / dark #F0EFEC
        Text(statusText + optionalRelativeTime)
            .font(ClaudeFonts.Typography 13 / weight 400 / lineHeight 18.2, relative)
            .foregroundStyle(textSecondary)        // light #52514E / dark #C3C2B7
            .lineLimit(1)
    }
}
```

- 标题/副标题容器间距 4；glyph 与文本间距 8（R-SA4 C5：`0x100b5beb0 = 4.0`、`0x10313aa04 = 8.0`）。
- 副标题 = 状态文案 +（有 `updatedAt` 时）短相对时间，同一 Text 流（`0x100d2f39c`；`ShortRelativeFormatStyle` `0x100f80c00`）。
- 状态文案（ClaudeCoreUI `row_status_*`）：
  | status | key | EN | ZH |
  |---|---|---|---|
  | needsInput | `row_status_needs_input` | Waiting for you | 等待您的操作 |
  | working | `row_status_working` | Working | 处理中 |
  | failed | `row_status_failed` | Stopped | 已停止 |
  | unread | `row_status_unread` | New | 有新内容 |
  | idle | — | （无文案） | — |
- 状态图标 16×16（size=0；`0x100d2e650`）：
  - working → `RotatingSpinnerIcon`，`textSecondary`；
  - failed → `anthropicon.warning`，`textSecondary`（官方失败态是低饱和，不是红色）；
  - idle → `textDisabled`（token 名 U6，推断）；
  - needsInput/unread → `UnreadDot`/占位（AA 不使用）。
- 标题来源：childSession.title → task.title → 「Untitled thread / 无标题讨论串」（`2c67.code_project_thread_untitled`）。
- 相对时间分隔符 U4（未解出字面量）；AA 用 `" · "`（官方已有 `working_row_segment_separator`）。

### 2.4 点击 / 生命周期（R-SA1 §4、R-SA3 §1）

- 整卡点击 → `context.onTap(task.sessionId)`；无展开、无就地详情。
- `.task(id: task.sessionId)`（userInitiated）加载 childSession / PR rows；`onShown(sessionId)` 在 task 体内（U1）。
- AA 无 childSession 跨会话加载：点击直接打开 `SubAgentPanelSheet`。

### 2.5 与 AA 的关系（诚实标注）

- 官方这张卡是 **child session / thread session 卡**，数据源是 `DispatchTaskInfo`（dispatch/线程派发），不是 AA 的 `agent_call` 字段。
- AA 的 `agent_call` 同样是“子代理子会话”，因此本单把它**映射**到同一张官方卡；这是产品映射，不是声称官方 `Task` 调用逐字节等价于 `threadSessionCard`。

---

## 3. AA 现状（基线 `bae413aa`）

### 3.1 数据

- `agent_call` 由 connector 铸造：`toolName == "Agent"` → `AgentCallToolContent{title, description, agentType, prompt, runInBackground, parentItemId, agentId, targetIds, agents, usage}`（`connector/runtime_protocol/timeline.py:211`、`connector/runtimes/claude/timeline/agent_calls.py`）。
- `SubAgentCard` 已有：`taskName/agentType/prompt/phase/toolCalls/tokens/usage/summary/parentItemID/liveTasks/updatedAt`（`Models/Chat/SubAgentProgress.swift:99`）。
- 子代理子行（`parentItemId != nil`）不进主时间线。

### 3.2 Code profile

- 顶层 agent_call 已从 span 拆出：`isAgentCardWithoutBlockIndex` → `.span(items:[item])`（`Models/Chat/Code/CodeMessageTimeline.swift:299-306,453-457`）。
- 渲染仍是普通折叠工具行：`CodeMessageRowView.toolRow` → `CodeCollapsedToolRow`，文案「Ran an agent」（`CodeToolLabelPlan.swift:172,467`）。
- 行高由 `CodeRowHeightPlan` 计算（`Models/Chat/Code/CodeRowHeightPlan.swift`）。

### 3.3 Chat profile

- 顶层 agent_call 目前**被吞进步骤组**：`TimelineStepGroup` 把所有 tool 行放进 `stepItems`（`Models/Chat/StepGroup/TimelineStepGroup.swift:247-251`），只在 `isSubAgentChild` 时跳过。
- 因此 Chat profile 没有独立的 Agent 卡；用户可见面 = 悬浮胶囊 + 面板。
- 旧 `SessionTimelineEventView` 的 Agent 卡只在 `ChatTimelineView`（已无调用点）和 adapter 的 standalone 兜底里；**当前不是 live 路径**。

### 3.4 官方行为差异

- 官方 `threadSessionCard` 是独立段（flush span），不并入工具组；AA Chat 的步骤组把它当普通工具步骤 → 行为差异，本单修正。
- 官方卡 = child session 卡（状态 glyph + 标题 + 状态/时间副标题），不是「工具行 + 查看详情」。

---

## 4. 设计

### 4.1 共用组件

新增 `Views/Chat/SubAgent/SubAgentSessionCardView.swift`：

```swift
struct SubAgentSessionCardView: View {
    let card: SubAgentCard
    let onTap: () -> Void
}
```

- 视觉严格按 §2.2–2.3：surface3 白/深底、圆角 24、padding 16、VStack 8、标题 15/21、副标题 13/18.2、glyph 16。
- 标题：`card.taskName`（非空；已有 “Agent” 兜底）。
- 副标题：状态词 +（`updatedAt` 非 nil 时）短相对时间，`lineLimit(1)`。
- PR pills 不渲染。
- 整卡 Button，`PlainButtonStyle`，`contentShape(Rectangle)`；a11y label = 标题 + 状态词，hint = 查看详情，identifier `chat.subagent.card`。
- 不用 `glassEffect`、不加描边、不放入口箭头。

### 4.2 状态映射（AA → 官方视觉）

| SubAgentPhase | 状态词 | 图标 | 副标题 |
|---|---|---|---|
| `.running` | 处理中 | 旋转 spinner | 处理中 [· 时间] |
| `.starting` | 处理中 | 旋转 spinner | 处理中 [· 时间] |
| `.completed` | （无） | idle/禁用色 | [时间]（无状态词；无时间则不显示副标题） |
| `.failed` | 已停止 | `anthropicon.warning`（textSecondary） | 已停止 [· 时间] |
| `.interrupted` | 已停止 | `anthropicon.warning`（textSecondary） | 已停止 [· 时间] |
| `.unknown` | （无） | idle/禁用色 | [时间] |

- 官方失败态不是红色：warning 图标 + textSecondary；AA 照官方，不用 danger 红。
- `updatedAt`：`SubAgentCard.updatedAt`（item updatedAt）→ `ShortRelativeFormatStyle` 等价实现（AA 自写短格式；U3）。
- 若 `updatedAt` 为 nil：running 仍显示状态词；completed/unknown 无副标题，只剩标题行。

### 4.3 Code profile 接线

- `CodeMessageRowView.toolRow(_:)`：当 `calls.count == 1` 且 `SubAgentProgress.card(calls[0].item)?.isTopLevel == true` → 渲染 `SubAgentSessionCardView`，不再走 `CodeCollapsedToolRow`。
- `CodeMessageRowView` 增加 `onSubAgent: (String) -> Void`；由 `TimelineChatContentAdapter.rowView` 传入（adapter 已有 `onSubAgent`）。
- 规划器：把 `isAgentCardWithoutBlockIndex` 放宽为「任何顶层 agent_call」`SubAgentProgress.isAgentCall(item) && parentItemID == nil`（Codex/DSH 的 agent_call 可能带 blockIndex；统一按 kind 识别，附测试）。
- 行高：`CodeRowHeightPlan` 新增 `.agentCard(...)`，见 §6。
- 卡外层垂直留白：官方 `segmentVerticalPadding = 4pt`；在 Code 行里用 4pt 上下留白（进入高度公式），Chat 行沿用 collection 行距、不重复加。

### 4.4 Chat profile 接线

- `TimelineChatGrouping.units`：遇到顶层 agent_call 时 `flushAll()` + `units.append(.standalone(rowID: item.id))`（与官方 flush span 语义一致），并 `continue`。
- `TimelineChatContentAdapter`：在 `.group` 分支的 stepGroup/explicitID 判断之前，若 group 是「单行、顶层 agent_call」→ 渲染 `SubAgentSessionCardView`（点击 → `onSubAgent(row.id)`）。
- 步骤组汇总不再计入 agent 调用；`TimelineStepGroupTests` 更新（agent 卡单独成 unit、不参与 stepGroup）。
- 不再走 `SessionTimelineGroupView` 的旧 Agent 行。

### 4.5 胶囊（§7 待 pp 定）

- 方案 A（推荐）：保留胶囊，改成同一张卡的紧凑形态（16pt 状态 glyph + 标题；surface3/圆角 24 或胶囊形态按视觉验收）；点击打开面板。
- 方案 B：移除胶囊，仅保留时间线内卡（运行中卡滚出视口后不可见）。
- 方案 C：胶囊保持现状。

### 4.6 停止控件（§7 待 pp 定）

- 官方卡没有停止按钮。
- 推荐：卡本体严格官方；停止只在 `SubAgentPanelSheet` 内（面板已有）。不移到卡上。

---

## 5. 状态与边界

- 顶层 vs 嵌套：只渲染 `parentItemID == nil` 的卡；嵌套子行留在面板。
- 多个运行中子代理：每个 agent_call 一张卡；胶囊计数不变。
- 标题缺失：`SubAgentCard.taskName` 已有 “Agent” 兜底；空标题按官方「Untitled thread」处理（AA 可沿用 “Agent”）。
- 失败/中断：warning 图标 + 「已停止」，不用红色。
- Dynamic Type：标题/副标题按官方 relative 字体缩放；卡高随之变化（Code 行高需实测）。
- 深色模式：surface3/textPrimary/textSecondary 两套值见 §2。
- Reduce Motion：spinner 静态化（按系统 Reduce Motion 关旋转）。
- 状态词/时间均为 a11y 文本；整卡 a11y element。
- 运行中卡频繁更新 `updatedAt` 时，相对时间刷新节流（避免每帧重绘）。

---

## 6. 行高

官方卡高度：

```
cardHeight = 16*2
           + max(16, titleLine + (hasSubtitle ? 4 + subtitleLine : 0))
```

- `titleLine = UIFontMetrics(.body).scaledValue(for: 21)`
- `subtitleLine = UIFontMetrics(.footnote).scaledValue(for: 18.2)`
- 外层再 + 4pt 上下 segment padding（Code 行）。
- `CodeRowHeightPlan.Block` 新增 `.agentCard(hasSubtitle: Bool)`；`CodeMessageHeightMeasurer` 用同一公式。
- 估算与实渲误差 ≤2 pt；大字号/无副标题两个用例进 `CodeRowHeightPlanTests`。
- Chat：hosted cell 自测，无需公式。

---

## 7. 待 pp 决定

1. **胶囊**：A 紧凑卡（推荐）/ B 移除 / C 不动。
2. **停止控件**：卡上不放（推荐）/ 卡上保留。
3. **已完成卡**：完成后常驻时间线（推荐，官方是 child session 入口）/ 完成后隐藏。
4. **旧 Chat 清理**：本单只做卡；§10 四项（面板去 ChatMarkdownView、欢迎/公告换渲染面、交互 target 行、删旧容器）另开单（推荐）。

---

## 8. 实施阶段（每阶段可单独回滚）

- **P1 共用卡 + Code 接线**：新组件、Code 规划器放宽、Code 行高、`onSubAgent` 透传、单测 + 门禁截图。
- **P2 Chat 接线**：步骤组提取 agent_call、adapter 单行卡、汇总/测试更新。
- **P3 胶囊重做**（按 §7 决定）：紧凑卡形态或移除。
- P1/P2 各自一个提交；P3 单独提交。

---

## 9. 测试与验收

### 9.1 单测

- `SubAgentSessionCardTests`（新）：状态映射、状态词、副标题组合、空时间、失败态颜色。
- `TimelineStepGroupTests`：顶层 agent_call 独立成 standalone；不再进入 stepGroup；混排顺序。
- `CodeMessageTimelineTests`：顶层 agent_call 单独 unit（含 Codex/DSH 带 blockIndex 的行）。
- `CodeRowHeightPlanTests`：有/无副标题、大字号、卡高公式。

### 9.2 门禁

- `code-profile`：新增卡截图（light/dark、running/completed/failed）；高度断言（估算 vs 实渲 ≤2pt）。
- `timeline-autorun`：两 profile 的滚动/锚定；卡行不破坏手势期高度不变量。
- 现有 Code 行/步骤组门禁全绿。

### 9.3 真机（pp）

- Code/Chat × 运行中/完成/失败 × 深色/大字号；点击进面板；胶囊点击；滚动锚定；Reduce Motion；流式中更新。

---

## 10. 回滚 / 兼容

- 纯 iOS 视觉/分组改动，无 wire/服务端变化。
- 每阶段独立提交；出问题可单独 revert P2/P3。
- 旧 Chat 视图暂不删除，保留回退。

---

## 11. 顺带发现（不在本单修）

- `SessionTimelineEventView` 的 Agent 分支与 `onSubAgent` 在卡落地后成为死路径；§10 清理时删。
- `isAgentCardWithoutBlockIndex` 只看 Claude 的“无 blockIndex”形状；本单统一按 `kind == agent_call` 识别。
- `TimelineStepGroup.isSubAgentChild` 用 `parentItemId` 跳过子行，行为正确，保留。
- 官方 `ThreadSessionCardContext.onShown` 的调用时机未闭合（R-SA1 U1）；AA 不需要。
- 官方 `textDisabled` token 与相对时间分隔符未逐字解出（R-SA4 U4/U6）。
