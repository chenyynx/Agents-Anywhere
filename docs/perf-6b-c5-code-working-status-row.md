# Code 页工作状态行独立化（任务单）

> 状态：待实现（2026-10-23）。分支：`feat/code-profile-beta`。不合并 dev。
> 目标：把「三个点 + Computing…」从消息行内部拆成独立 transcript 行（官方 `CodeThinkingView` 的做法），使状态行的出现/消失不再改变消息行的签名与高度。
> 关系：本任务与 `docs/perf-6b-c5-code-timeline-height-policy.md` 并行；本任务先落地，因为要从 Code 组签名中移除 `showsWorkingStatus`。

## 1. 背景

- 现状：工作状态行画在最后一条消息行内部（`CodeMessageRowView.swift:80-84`），`showsWorkingStatus` 进入组签名（`TimelineContentSignature.swift:70,105`）与高度测量（`CodeMessageHeightMeasurer` / `CodeRowHeightPlan`）。
- 后果：
  1. 回合开始/结束、或状态行换主人时，**消息行 re-key**，触发高度重算/测量；
  2. 回合恰好在用户拖拽/惯性中结束时，状态行内容立即消失但行高被停泊到松手，出现短暂空带；反向出现时内容被裁切；
  3. 高度链多一个与消息正文无关的 re-key 源。
- 官方做法：`••• Computing…` 是 `CodeThinkingView` 的**工作态行**（`CANONICAL/20-working-mark.md:0-8`）；列表配置另有 `workingMark: WorkingMarkSeat<ID>?` 槽位，`WorkingMarkSlots/SlotView` 跨行落座（`CANONICAL/05-layout-scroll.md:199`、`CANONICAL/20-working-mark.md §5`）。本任务先做「独立行」，跨行落座的动画留作后续视觉项。

## 2. 目标 / 非目标

**目标**
- 新增独立 item `.workingStatus`，在回合运行期间出现在本回合最后一条消息之后；
- 消息组不再包含状态行：签名、行视图、高度测量、probe 描述全部移除 `showsWorkingStatus`；
- 状态行的出现/消失只改变它自己的 item，不改变任何消息行的 key；
- 状态行高度固定、可预测，由同一套 hosted cell 合约测量/上报。

**非目标**
- 不做官方 `WorkingMarkSeat` 的跨行落座动画（单独立项）；
- 不改 WorkingMark 的帧表、pose、弹簧、动词表；
- 不改 Chat 页（Chat 行的 tail 状态逻辑保持现状）。

## 3. 设计

### 3.1 新 item
- `TimelineListItem` 新增 `.workingStatus`，`itemID = "working:status"`。
- `TimelineItemIdentity.build` 增加参数 `hasWorkingStatus: Bool`，插入位置：**最后一个 group 之后、notices 之前**（与本回合最后一条消息相邻；没有 group 时放在 olderPrompt 之后）。
- 该 item 不是 group，不参与 `codeGroups`/`CodeMessageBuilder`。

### 3.2 状态行视图
- 新增 `CodeWorkingStatusRow`（或复用现有 `CodeThinkingStatusLine` 外层包一层行边距）：
  - 内容 = `CodeThinkingStatusLine`（20×20 mark + 旋转动词）；
  - 行边距沿用 Code 行 5/16/5/16；高度 = 20 + 2×4 + 上下行边距（按 `CodeRowHeightPlan.Metrics` 计算，约 38pt）；
  - 动词每秒轮换不改变高度；视图自身用 `TimelineView(.periodic(by: 1.0))`，不触发高度重测。
- 高度 key：固定内容摘要（`statusLine` 是否显示、动词轮换不入 key）；高度用 `.fixed(...)` 预估，cell 自测一次后以实测为准。

### 3.3 Adapter
- `refresh()`：
  - 计算 `hasWorkingStatus = model.sendingPlaceholder != nil`（与现有 `workingStatusGroupID` 的触发条件一致）；
  - 不再计算/使用 `workingStatusGroupID` 作为消息组的高度/签名输入；保留“最后一条消息 group id”仅用于插入位置（`workingAnchorGroupID`）；
  - `TimelineItemIdentity.build(..., hasWorkingStatus:)` 生成 item；
  - `CodeMessageRowView` 不再传 `showsWorkingStatus`（删除参数与调用点）；
  - `heightPolicy(for:)`：`.workingStatus` 返回 `.measured`（hosted cell 合约）；
  - `estimateKind(for:)`：`.workingStatus` 返回 `.fixed(statusLineHeight)`；
  - `probeDescribe`：`.workingStatus` 输出 `working status`；消息组不再输出 `status=1`。
- Tail：
  - `tailStatusLineVisible` 保留在 Chat/旧路径；Code 页 tail 不再画状态行（状态行已是独立 item）。若 `TimelineTailContentSignature.statusLineVisible` 仍被 Chat 使用，保持不变；仅 Code adapter 传 false。
  - `CodeWorkingIndicator.showsTailStatusLine` 在 Code adapter 中不再使用；保留函数供 Chat/旧路径。

### 3.4 高度与签名
- `TimelineGroupContentSignature` 删除 `showsWorkingStatus` 字段与 hash 输入（`TimelineContentSignature.swift:70,105`）。
- `CodeRowHeightPlan` 删除 `showsWorkingStatus` 参数与 `statusLineHeight` 分支；`CodeMessageHeightMeasurer` 同步删除参数。
- `TimelineContentSignature` 新增 `.workingStatus(revision:)`（或复用 `.tail` 形状），驱动 reconfigure/高度 key。
- 消息组签名从此只含 rows（id/revision/updatedSeq）——后续高度线的“绘制内容摘要”在此基础上再做。

### 3.5 边界
- 空消息组（只有 reasoning）：现状靠 `showsWorkingStatus` 保留一行；拆开后空组不渲染，状态行独立存在。补单测。
- 无 group 的运行回合（如刚发送、尚无助手消息）：状态行放在 olderPrompt 之后、tail 之前；不得重复（一轮只有一个）。
- 回合结束：状态 item 移除；消息行 key 不变。
- 流式尾行 + 状态行：状态行固定在最后一条消息之后，不随流式文本 re-key。
- 加载更早/换窗：状态 item 的 itemID 固定；窗口替换不应导致它重复或丢失。
- 手势：状态行插入/移除走现有 apply/补偿规则；因为它位于回合末尾（视口底部），阅读中通常不在屏内。

## 4. 文件清单
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/TimelineCollection/TimelineItemIdentity.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/TimelineCollection/TimelineContentSignature.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineCollectionController.swift`（cell 复用/高度策略如需）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMessageRowView.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMessageHeightMeasurer.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeRowHeightPlan.swift`
- 新增 `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeWorkingStatusRow.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeProfileAutoRun.swift`（gate 用例）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineProbe.swift`（describe 文案如需）
- 单测：`ios/Tests/ClientCoreTests/`（新增状态行用例；更新 CodeRowHeightPlanTests）

## 5. 验证
- 单测：
  1. 回合开始/结束：消息组签名不变；仅 `.workingStatus` item 出现/消失；
  2. 一轮只有一个状态 item；无 group 时位置正确；
  3. 状态行高度 = 固定值；动词轮换不改变 key；
  4. 空消息组不再因状态行保留。
- 模拟器 gate：`code_profile` 的 rowHeights 用例改完后仍绿；新增状态行高度用例。
- 真机探针：回合运行中拖拽，状态行不改变消息行高度；回合结束（非拖拽）时状态行行高收掉、无残留空白。

## 6. 风险与回滚
- 风险：插入位置与官方不一致（最后一条消息之后 vs tail 之前）；空组可见性变化；状态行与 pending 消息的相对顺序。
- 回滚：单 commit；恢复 `showsWorkingStatus` 即可回到旧行为（保留签名 hash 的旧字段注释）。

## 7. 未决
- 官方 `CodeThinkingView` 的精确插入位置（最后一条消息内部 vs 消息之后）需以官方截图复核；本任务先按“最后一条消息之后”落地，视觉补齐阶段再对齐。
