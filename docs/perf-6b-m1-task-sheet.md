# 6b-M1 任务单 v6：测量驱动高度 + 绝对插入补偿

> 定级 **L**。依据：`docs/perf-plan-v2.md` 批 6b；官方证据 §2.6/§2.9；OpenMinis 已核对 `b4c0661d`（附录 C）。
> **v6 修订**：v5 的两份审查（去重后约 11 条 P1）否定了“依赖 `UIHostingConfiguration` 逐 tick 自测高”的前提；本版改为**测量驱动**：高度在 apply 前由测量层算好，cell 固定高度，不驱动布局；同时借用 OpenMinis 的三级缓存与浏览期 defer（已拉取上游核对，见附录 C）。
> 关键证据见 §12。

---

## 0. 目标

把 `ChatTimelineView` 的滚动容器换成 `UICollectionView` + 自研 `UICollectionViewLayout`，
**在同一次布局事务内**完成高度修正与插入补偿，行为逐条对齐现状，并消除“加载很多页后滚动卡”。

**验收**：行为清单全绿；1000 行窗口滚动满足 §7.4；开屏落底无可见滚动；上滑加载的视口位移 ≤ 现状 6.5。

### 0.1 架构拍板（v6）

| 决策 | 选择 | 理由 |
|---|---|---|
| 高度真值 | **测量层在 apply 前算好；布局只消费固定高度；cell 不驱动高度** | 自测高逐 tick 不可靠：10 tick 只回 1 次（§12.2）；测量驱动把“边滚边猜”变成“进场前已知” |
| 高度缓存 | **稳定 item id + 内容修订 + 宽度 + Dynamic Type + 排版修订；三档 measured/precalc/estimate** | 前插移动索引；离屏更新会让旧 measured 失真；稳定 id 不重映射 |
| 异步内容 | **先解析（Markdown/图片尺寸）再测量；测量完成即 settled；没有视图回写 settled 的接口** | `ChatMarkdownView` 的解析在 view `@State`，行模型不知道何时完成（P1） |
| 插入补偿 | **绝对目标 `originOffset + (newAnchorY - originY)`；插入页整页测量；finalize 兜底；update 事务闸** | 前插页的行大多离屏，估算误差会变成锚点位移（P1）；绝对值幂等 |
| 可见行补偿 | **OpenMinis 三分支：完全在上方 / 可见非流式 / 流式+贴底；部分可见不补偿** | 已在 `MessageListLayout.swift:540/545/556` 核对；部分可见补偿会把正在读的行推走 |
| 浏览期 defer | **有缓存的行只 park 收缩/稳定；增长放行；无缓存允许首次测量** | OpenMinis `:377-445` 同款；防止拖拽中裁切/重叠，同时不取消 pull（6a 教训） |
| 底部目标 | **控制器状态机；每次 contentSize/测量完成重解析；读者回到/停在底部重新武装** | 一次性目标短差 365/220pt；流式 10 tick 布局只 pin 1 次（§12.2） |
| 下拉规则 | **保持现状 2pt/24pt + wasInteracting，不改规则** | pp 明确；稳定高度 + defer 后 contentHeight 不在手指下变化 |

> 因为 M1 已包含前插补偿，**M2 只剩“取消裁窗 + 用例语义更新”**（即 plan 的批 1）。

---

## 1. 行为清单（32 项，逐条对齐）

| # | 交互 | 现状实现 | 位置 |
|---|---|---|---|
| I1 | 滚动相位 | `onScrollPhaseChange`；`wasInteracting` 决定松手加载 | `ChatTimelineView.swift:96-135` |
| I2 | 几何采样（含 inset/bounds） | `onScrollGeometryChange` 五元组 | `:136-167`、`:714-719` |
| I3 | 视口发布门控 | `publishViewportSample` + 决策纯函数 | `:408-446` |
| I4 | 开屏瞬时回底 | edge target + 400ms 兜底 + 尾部到达判定 | `:212-238`、`:326-339`、`:361-365` |
| I5 | 返回动画 | `interactiveSpring`；Reduce Motion；中断完成 | `:340-351` |
| I6 | 尺寸变化锚点 | `.defaultScrollAnchor(.bottom, for:.sizeChanges)`（内容或容器） | `:84-93` |
| I7 | 键盘交互收起 | `.scrollDismissesKeyboard(.interactively)` | `:73` |
| I8 | 键盘钉底 | 先 pin 再 publish | `:155-156`、`:392-403` |
| I9 | 键盘过渡窗口 | `TimelineKeyboardMonitor` + 三类通知 | `:294-304`、`:451-483`、`:787-829` |
| I10 | 上拉加载历史 | older pull；提示 0.9；位移 ≥24pt | `:249-255`、`:306-317`、`:610-616` |
| I11 | 下拉加载更新 | latest pull；提示**默认 0.5** | `:268-275`、`:318-325`、`:646-655` |
| I12 | 历史锚点测量 | 锚点 group 的 frame；`firstRowID = model.timeline.rows.first?.id` | `:623-633` |
| I13 | 历史锚点修正 | 见 §3.4.5：移进布局 `targetContentOffset` | `:484-499` |
| I14 | 尾部可见性 | near 探针 **96pt**、end 探针 **2pt** | `:695-705` |
| I15 | 提示可见性 | older 0.9 / latest 0.5 / tail near 0.01 / tail end 0.5 | `:610-616`、`:654`、`:695-705` |
| I16 | 内容坐标空间 | `.coordinateSpace("chat.timeline.content")` | `:708` |
| I17 | 开屏遮罩 | `.opacity(openingPositionSettled)` | `:69` |
| I18 | 抽屉/导航挂起 | 取消采样/pull/目标；恢复重放相位 + 重跑锚点 | `:49`、`:168-178` |
| I19 | 点空白收键盘 | `TimelineKeyboardDismissLayer` | `:291`、`:774-780` |
| I20 | 浮动“到底部” | `TimelinePillStack` | `:279-285`、`:736-770` |
| I21 | 行内容 | 分组 / notices / pending / tail；分组输入含 `interactionTargets` 与 `TimelineTurnActions.build` | `:580-586`、`:594-706` |
| I22 | 窗口整体替换 | `windowRevision` → `reassertOpeningReturn`（带守卫） | `:190-202`、`TimelineScrollState.swift:133-138` |
| I23 | 容器修饰符 | 指示器隐藏 / 始终回弹 / 顶部 soft edge effect / **`isOpeningReady` 期间禁手势与无障碍** | `:74-76`、`:94-95` |
| I24 | 内容列 | **16/20pt 自适应**（不是 24）、16pt 顶部、760 最大宽、居中、**所有顶层 item 之间 20pt** | `ChatPageContentColumn.swift:13-20`、`ChatTimelineView.swift:594`、`:707` |
| I25 | 行内本地状态 | Markdown 解析、附件解码、复制反馈、reveal ledger、Textual 选区 | `ChatMarkdownView.swift:18-47`、`StreamingGlyphReveal.swift:45-49`、`ChatMessageAttachments.swift:126-130`、`SessionTimelineEventView.swift:296-350` |
| I26 | 快照更新语义 | 同 id 内容更新 / id 去重（`SessionTimelinePresentation`）；队列/状态行动画留在 tail | `SessionTimelinePresentation.swift`、`ChatTimelineView.swift:670-691` |
| I27 | 新 pending / 队列变化 → 回底 | `onChange(pendingMessages.last?.id)`、`onChange(sendQueue.items.map(\.id))`；带 `!hasInteractions` 守卫 | `:179-186` |
| I28 | 审批接受 → 回底 | `onChange(responseRevision)` **只在交互审批被接受时递增**；流式跟随走 contentSize/几何路径 | `SessionChatModel.swift:666`、`ChatTimelineView.swift:187-189` |
| I29 | 审批卡出现/消失 | `setInteractionPresented`：出现停跟随，消失回底 | `:203-208`、`TimelineScrollState.swift:140-145` |
| I30 | 导航代际变化 → 释放目标 | `onChange(navigationGeneration)` | `:209-211` |
| I31 | 松手 64ms 后判定 reading/following | `settleUserScroll` | `:240-248`、`TimelineScrollState.swift:189-199` |
| I32 | 历史请求结算 | `HistorySettlement` + 64ms | `:256-267` |

---

## 2. 目标与非目标

### 目标（M1）
1. `UICollectionView` + 自研 layout + **测量驱动高度**（三级缓存，稳定 id 键）+ 播种。
2. 单参数 `targetContentOffset(forProposedContentOffset:)`：绝对目标，append / prepend（容器尺寸变化走 I6）。
3. `invalidationContext`：测量修正与流式增长的 offset 补偿（OpenMinis 三分支）。
4. I1–I32 行为对齐；滚动性能显著优于现状。

### 非目标
- ❌ 取消裁窗 / 窗口上限调整 → M2（plan 批 1）
- ❌ TextKit 2 全量替换、`UIUpdateLink` → 不在 6b（测量层可局部用 TextKit/Textual）
- ❌ 下拉规则变更 → 保持现状

---

## 3. 架构

### 3.1 组件（`UIViewControllerRepresentable`）

```
TimelineCollectionView: UIViewControllerRepresentable
 └─ TimelineCollectionController: UIViewController
      ├─ UICollectionView
      ├─ TimelineListLayout: UICollectionViewLayout
      ├─ TimelineHeightCache / TimelineHeightMeasurer   // Models/Services
      ├─ MarkdownParseCache                            // Models/Services
      ├─ UICollectionViewDiffableDataSource<Section, TimelineListItem>
      └─ Coordinator: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching
```

### 3.2 数据源与身份

```swift
enum TimelineListItem: Hashable {
    case olderPrompt
    case group(String)        // rows[0].id
    case notice(String)
    case pending(String)
    case latestPrompt
    case tail
}
```

- **去重**：id 前缀化（`g:` / `n:` / `p:`）；重复时**首条胜出并记日志**，不用 `assertionFailure`。
- **内容更新**：`apply(animatingDifferences: false)`；每次呈现层 flush 后 `reconfigureItems(changedIDs)`。
- `changedIDs` 由**内容签名**决定，必须覆盖所有**影响高度**的字段：
  - `group`：`rows.map(\.id)` + 每行 `revision`/`updatedSeq` + `TimelineTurnActions.build` 的输入（`isRunning`/`hasNewerItems`/pending）。
  - `olderPrompt`/`latestPrompt`：`(pullReady, isLoading, keepsOlderPrompt, hasOlderItems)`。
  - `notice`：membership id + `status`/`revision`（审批接受/失败要 reconfigure）。
  - `pending`：membership id + 附件内容签名。
  - `tail`：队列 id+状态 roster、`sendingPlaceholder`、状态行文本/orb 活动、`hasNewerItems`。
- 纯视图状态（Textual 选区、reveal 动画）不进签名；外置到行模型/有界缓存。

### 3.3 Cell 与内容列

- `TimelineHostingCell` + `UIHostingConfiguration`，但**高度由布局给定**；cell 的 `preferredLayoutAttributesFitting` 不再作为高度真值（可用于一致性校验）。
- **水平边距 = 16（<414pt）/ 20（≥414pt）**；最大宽 760、居中；**所有顶层 item 之间 20pt**；16pt 顶部只加在第一个 item。
- 队列/状态行/尾部留在 `tail` 一个 item 内，保留其 SwiftUI `.transition` 与高度动画；cell 高度与 SwiftUI 内部动画的同步要在真机 20 号用例验。

### 3.4 高度管线：测量驱动（v6 核心）

#### 3.4.1 键与缓存

```swift
struct TimelineHeightKey: Hashable {
    let itemID: String
    let contentRevision: Int
    let width: CGFloat          // 0.5pt
    let dynamicType: String
    let typographyRevision: Int
}

final class TimelineHeightCache {          // Models, testable
    private var measured: [TimelineHeightKey: CGFloat] = [:]
    private var precalc:  [TimelineHeightKey: CGFloat] = [:]
    private var estimate: [TimelineHeightKey: CGFloat] = [:]
    // 每个 item 只保留当前键；旧键删除
}
```

- 三档：`measured`（与真实渲染校验过）/ `precalc`（同一测量引擎的快速路径，误差目标 ≤8pt）/ `estimate`（启发式）；兜底按 kind（提示 44、tail 12/32、普通 200），不用全局 200。
- 内容修订变化：新键在 apply 前测量/播种；旧键删除。
- 流式行**不继承**旧 measured：每批由测量层重测；未完成时沿用上一帧高度并标记 pending，完成后按 delta 修正。
- `typographyRevision`：完整 `ChatTypeScale`（含 `codeBlockRatio`、`codeBlockLineSpacingRatio`、`inlineCodePin`、`codeBlockPin`、`inlineCodeBold`）+ Bold Text + Dynamic Type 的稳定哈希；设置/trait 变化整档失效。iOS 17+ 用 `registerForTraitChanges`，不要用已弃用的 `traitCollectionDidChange`。
- 缓存生命周期：每个 item 只保留当前键；item 离开快照时删除该 id 全部档；播种只做视口 ± 一屏，历史页整页按 §3.4.2。

#### 3.4.2 测量层（apply 前）

`TimelineHeightMeasurer`（协议）：
- `TextualHeightMeasurer`：文本/Markdown 用与前台同一 Textual/TextKit 布局；`precalc` 走快速路径。
- `HostingHeightMeasurer`：复杂行（图片/工具组/附件）用离屏 `UIHostingController` + 真实行视图，主线程批量测量。
- **一致性门（C3 必过）**：抽样 N 行，比较 `measured` 与实际 cell 高度；文本 ≤1pt、复杂 ≤4pt。测量与渲染不一致，测量驱动不成立。

时序：
- 新 item / `changedIDs`：在 snapshot apply **之前**测量。**历史页（100 行）整页测量**，不只视口 ± 一屏——这是前插锚点精确的前提。
- 开屏：测量当前窗口（`open()` 裁到最新 100 行）的可见 ± 一屏；其余按需/分帧。
- 流式：0.1s 节流（官方 `SessionLiveStreamStore` 同节奏）；每批测量变化行，拿到高度后显式更新 offset/底部目标。
- 测量预算：单次 apply 建议 ≤50ms（整页）/ ≤8ms（流式 tick）；超时用 precalc 并标记 pending，余下在滚动路径外继续测量，完成后按 §3.4.4 修正。
- **禁止**把 cell 的 `preferredLayoutAttributesFitting` 当高度真值；布局给定高度，cell 只渲染。

#### 3.4.3 异步内容（Markdown/图片）

- Markdown 解析从 `ChatMarkdownView` 的 view `@State` 外置到 `MarkdownParseCache`（Models/Services），按文本哈希缓存；行模型拿到 parsed blocks 后才交给测量层。
- 图片尺寸同理：解码/尺寸就绪后再测量；未就绪时用 precalc + pending，完成后修正。
- 不存在“视图回写 settled”的接口：**测量完成就是 settled**；行模型只暴露 `contentRevision` 和可测量内容。
- 首次物化不得先塌后长：apply 前用测量值；未完成时用 precalc（不是 0/占位高），并标记 pending。

#### 3.4.4 高度修正与 offset 补偿（OpenMinis 同构 + 测量驱动）

`invalidationContext` 的补偿只在“测量修正”或“流式增长”时发生；外层条件
`!isTracking && !isDecelerating && !suppressContentOffsetAdjustment`：

1. **cell 完全在视口上方**（`cellBottom <= viewportTop`）→ `contentOffsetAdjustment = delta`。
2. **cell 可见且非流式**（`cellTop >= viewportTop && cellTop < viewportBottom`）→ `delta`，保持下方内容不动。
3. **流式 cell + `isAutoScrollPinning` + delta > 0** → `delta`，同帧贴底。
4. 其余（含部分可见、用户拖拽/减速中）→ 0；由 defer/下一帧修正。

> 与 OpenMinis `MessageListLayout.swift:540/545/556` 一致；部分可见不补偿。测量驱动保证新行/变化行在 apply 前已测量，因此“部分可见行临时长高”只剩 pending 测量的边缘路径；真机 3/14 验证。

**浏览期 defer（OpenMinis `:377-445`）**：
- 用户拖拽/减速中，有缓存的行：收缩/稳定修正 park 到 `deferredHeights`；**增长放行**（避免裁切/重叠）；无缓存的行允许首次测量。
- 松手后**先结算 pull**（用 pre-defer 的 viewport），再一次性应用 deferred 修正并补偿。顺序写死，避免 6a 的 2pt 闸取消。
- 拖拽中流式增长：放行；除非 armed bottom，不改 offset。

#### 3.4.5 插入补偿：绝对目标

单参数 `targetContentOffset(forProposedContentOffset:)` 返回**绝对目标**：

```
target = originOffset + (newAnchorY - originY)
```

- `originOffset`：请求开始时的静止偏移，**必须**是 `max(-topInset, offsetY)`（现状 `TimelineHistoryPosition.init` 的过冲钳制；单测期望 920）。
- 前插页的 `newAnchorY` 来自**整页测量**（§3.4.2），不是估算；测量未完成的行用 precalc 并标记 pending，完成后按 §3.4.4 修正。
- 返回绝对值而不是 `proposed + delta`：同一事务可能查询多次；绝对值幂等。
- `owedConsumed`：首次查询置位；`finalizeCollectionViewUpdates` 未消费则 `setContentOffset(target)` 兜底后清零。
- **事务闸**：`prepare(forCollectionViewUpdates:)` 进入、`finalize` 退出；事务内只处理 owed。若同一事务里还有测量修正，把 delta **累加进 target**（或等事务结束后按 §3.4.4 补偿），不重复发 `contentOffsetAdjustment`，也不静默丢弃。
- **锚点是 group item，不是 row id**：用“包含 `anchorRowID` 的 group item + 存储的 edge”求 y；控制器在 apply 前提供 `rowID -> group item id` 映射。
- **firstRowID 守卫**：`TimelineHistoryPosition` 的 `firstRowID`/`edge`/`originOffset` 一起传入；窗口替换时沿用现状 `layout.firstRowID != origin.firstRowID` 的守卫。
- **容器尺寸变化**：不在此处处理，走 I6 的显式重算。
- **实测（§12.1）**：mid-list 前插 `originOffset=7458 → owedTarget=16658`，锚点屏幕位移 0；重复查询 `9140/9140`；带 top inset 60。该实测的“anchor delta 0”只证明 UIKit 应用绝对目标；整页高度精度由 §3.4.2/C3 门保证。

### 3.5 采样、相位与底部状态机

**采样公式**（必须与 SwiftUI `ScrollGeometry` 并排验证一次）：

```
containerHeight = collectionView.bounds.height
topInset        = adjustedContentInset.top
bottomInset     = adjustedContentInset.bottom
offsetY         = contentOffset.y
contentHeight   = contentSize.height
```

> `safeAreaInset` 缩短的是 **safe area**，不是 `bounds`。采样用 `bounds.height + adjustedContentInset`，但要并排校验，避免同一份输入条高度算两次。C4 第一步：并排打印 SwiftUI 与 UIKit 采样值，差值 ≤1pt。

**采样触发**：`scrollViewDidScroll`、`contentSize` KVO、`adjustedContentInset` KVO、`viewSafeAreaInsetsDidChange`、`viewDidLayoutSubviews`、**每次测量完成/快照 apply 后无条件发布一次探针状态**（6a 教训）。

**相位合成**：

| 事件 | 合成相位 |
|---|---|
| `scrollViewWillBeginDragging` | `.interacting`（`.tracking` 无来源，明确不产生） |
| `scrollViewDidEndDragging(willDecelerate:)` | 否 → `.idle`；是 → `.decelerating` |
| `scrollViewDidEndDecelerating` | `.idle` |
| `setContentOffset(animated:)` 开始 / `scrollViewDidEndScrollingAnimation` | `.animating` / `.idle` |
| `scrollViewShouldScrollToTop` / `scrollViewDidScrollToTop` | `.animating` / `.idle`（状态栏回顶） |
| 其余 | 不变 |

> **动画完成看门狗（实测）**：目标等于当前 offset 时 `scrollViewDidEndScrollingAnimation` **不回调**（no-op 0 次）。普通回底加“动画时长 + 1 帧”watchdog；`scrollViewWillBeginDragging` 立即 complete 当前命令。

**底部目标状态机（I4）**：

| 事件 | 动作 |
|---|---|
| 开屏 / 发送 / 新 pending / 审批消失 / 窗口重断言 | 武装（仅当 reader 在底部或 `mode != .reading`；发送路径保留 `!hasInteractions`） |
| 读者滑回/停在底部（`settleUserScroll` → following） | 重新武装 |
| 用户开始拖拽 / `browseHistory` / 审批出现 / 导航挂起 | 解除 |
| 导航恢复 | 若 reader 仍在底部则重新武装 |
| 任何 contentSize/测量完成 | 若已武装，重解析底部并贴住 |
| 浮动“到底部”点按 / `loadLatest` | 走同一 armed 目标，不用一次性 `setContentOffset` |

---

## 4. 逐项对接

- **I1/I31**：相位合成见 §3.5；`settleUserScroll` 的 64ms 任务原样保留。
- **I2/I3**：采样与发布见 §3.5；禁止在原生回调里直接写 SwiftUI `@State`。
- **I4**：底部目标状态机见 §3.5；每次 contentSize/测量完成重解析；`finishScrollToBottom` 只清当前命令，不清“用户仍在底部”的语义。
- **I5**：`setContentOffset(_:animated:)` + `scrollViewDidEndScrollingAnimation`；no-op 不回调（实测 0），加 watchdog；拖拽打断在 `scrollViewWillBeginDragging` complete。曲线与 `interactiveSpring(0.28, 1)` 不完全一致，接受或 CADisplayLink 近似（单独验收）。
- **I6**：`shouldPin` 由底部状态机 + `interactionIsPresented` 派生。审批卡出现：**清除跟随目标**（I29），但卡片插入本身按现状 `.defaultScrollAnchor(.bottom, for:.sizeChanges)` 的语义进入视口（一次性，不重新武装；不把页面拽回底部）。
- **I10/I11**：**下拉规则不变**：仍用 `TimelineHistoryPull` 的 2pt contentHeight/visibleHeight 闸 + 24pt 位移 + `wasInteracting`；新容器把同样的 `TimelineViewport` 喂给现有纯类型。浏览期 defer 的定序见 §3.4.4。
- **I12/I13**：见 §3.4.5；控制器在 update 后从布局 attributes 构造 `TimelineHistoryLayout`（firstRowID/anchorRowID/edge/y）并调用 `laidOut`/`receivedPage`，把“结算”和“修正”拆开；修正只由 target 做。
- **I18**：挂起时取消；恢复时重放相位，且 `historyLayout != nil` 时重跑锚点重算。
- **I22**：`windowRevision` 变化时，只在 `!readerTookOver && !navigationIsSuspended && hasOpened` 时重跑 I4。
- **I23**：`isOpeningReady` 期间禁手势/无障碍；iOS 直接设 `collectionView.topEdgeEffect.style = .soft`；`ChatPageScrollEdge` 只在 Catalyst 编译（`:8-12`），Catalyst 注册逻辑放 collection controller 的 `didMoveToWindow`/`viewDidLayoutSubviews`，不能放 representable 的 `.background`。
- **I25**：Markdown 解析外置到 `MarkdownParseCache`；附件解码/reveal/选区状态外置到行模型/有界缓存，cell 回收不丢。
- **I26**：`animatingDifferences: false`；尾部内部的队列/状态行动画保留。
- **I27/I28**：I27 按现状回底（带 `!hasInteractions`）；I28 的 `responseRevision` 只在交互审批被接受时递增，流式跟随走 contentSize/底部状态机。

---

## 5. 并发与时序

| 问题 | 答案 |
|---|---|
| 状态归谁所有 | 滚动状态 `TimelineScrollState`；controller：`nativePhase`、`armedBottomTarget`、deferred 修正；数据 `SessionChatModel`；高度 `TimelineHeightCache`；测量 `TimelineHeightMeasurer` |
| 顺序 | 测量在 apply 前；apply 在主线程；布局只读缓存；流式测量 0.1s 节流 |
| 重复 | 相位只在变化时上报；采样去重；快照 apply 幂等；同一 key 的测量去重 |
| 取消 | 导航挂起/抽屉/用户接管取消目标与动画；测量任务取消不回写 |
| **重入** | `setContentOffset` 同步触发 `didScroll`。原生回调只投递样本；offset 变更经合并器；布局的 `targetContentOffset` 由 UIKit 应用，不属于重入路径 |
| 锁 | 高度缓存只在主线程读写（测量结果回主线程提交）；若测量在后台，结果通过 `@MainActor` 提交，布局不直接读后台可变状态 |

---

## 6. 兼容与回退

- 不改数据契约、不改 `V2SessionRepository`、不改投影。
- C1 往 `Models` 加**纯算术/纯状态机**类型（可测），不是“不改 Models”。
- 每个提交可独立 revert；C6b 删除旧路径后，**revert C6b 即恢复旧路径**（不需要回退 C5）。
- **运行时回退**：`UserDefaults` key `aa.timeline.collectionView`，默认 **off**；另加**Release 可用**的入口
  （设置页隐藏行或 URL scheme；不能只靠 `#if DEBUG`/启动参数——pp 装的是 Release IPA）。
  开关关闭时走旧 `ScrollView` 路径；切换开关要重置 `TimelineScrollState.hasOpened`。
- **C6 拆两步**：C6a 翻默认值并观察一个版本；C6b 删除旧路径。不要在同一个提交里既翻默认又删回退路径。
- 采帧器（CADisplayLink）单独一个 C0/前置提交，不混在 6b 功能提交里。

---

## 7. 测试

### 7.1 纯逻辑单测（必须住 `Models`，不能住 `Views`）
1. `TimelineItemIdentity`：顺序、去重（首条胜出）、四类提示。
2. `TimelineVisibilityProbe`：写死 96pt / 2pt 探针矩形与相交定义，用手算夹具；**另含提示项 0.9/0.5 可见比例**。
3. `TimelineOffsetTarget`：底部 offset（含 inset 钳制、sub-viewport）。
4. `TimelinePhaseMapping`：独立事件序列 → 相位；覆盖 `.tracking` 永不产生、动画完成、no-op watchdog。
5. `TimelineContentSignature`：group/提示/notice 状态/pending/tail orb/turnAction footer 的变化检测。
6. `TimelinePreferredAttributesDecision`：§3.4.4 的分支逐条（完全上方/可见非流式/流式+贴底/部分可见→0/defer）。
7. `TimelineInsertionOwed`：绝对目标、两次查询同一值、过冲钳制 920、firstRowID 守卫。
8. `TimelineHeightKeying`：宽度 0.5pt、字号/排版失效、内容修订换键、缓存生命周期。
9. `TimelineHeightCache`：三档优先级、pending 修正、流式不继承旧 measured、kind 默认值。
10. `TimelineArmedBottomTarget`：武装/解除/重新武装（读者回到底部）、contentSize 连续变化后贴底。
11. `TimelineOneShotOwed`：`owedConsumed`、finalize 兜底后清零。
12. `TimelineMeasurementPipeline`：整页测量、预算超时→precalc+pending、完成后修正。
13. `TimelinePullDeferOrdering`：拖拽中 park 收缩/稳定、增长放行、松手先结算 pull 再应用 deferred。
14. **布局必须委托这些纯类型**：`TimelineListLayout` 直接持有并调用；加 DEBUG 断言（finalize 后 owed 已清零；measured 键与当前 revision 一致），否则纯类型全绿也证明不了调用点（`Package.swift:11-15` 把 Views 排除在 `ClientCore` 外）。

### 7.2 模拟器集成门（C3 必过，CI 执行）
用 `spike` 同款 `simctl` + 应用内 autorun 方式，驱动**真实 cell**，输出 JSON 并断言：
1. **测量一致性**：抽样 N 行，`measured` 与实际 cell 高度差（文本 ≤1pt、复杂 ≤4pt）。
2. **前插**：插入页 100 行整页测量；锚点屏幕位移 ≤0.5pt；`targetOffsetCalls≥1`；重复查询同一值。
3. **异步 Markdown**：首次物化直接是完整高度（不得 45→163 塌缩）；解析完成后无可见跳位。
4. **流式**：每个节流 tick 的 measured 高度递增；cell 高度 ≥ 内容高度（不裁切/不重叠）；底部 shortfall ≤0.5pt；浏览时不被拽底。
5. **底部状态机**：发送/流式/审批消失/读者回到底部都能重新武装；拖拽/审批出现/导航挂起解除；no-op 回底不卡相位。
6. **下拉**：拖拽中 park 修正，松手仍能加载（6a 回归判据）；提示 0.9/0.5 可见性翻转正确。
7. **历史结算**：页落地后 64ms 内结束 loading；`firstRowID` 不匹配时不修正。

### 7.3 真机清单
1. 冷开最新会话：落底、不闪
2. **1000 行窗口**（M1：从顶部上拉加载 9 页达到约 1000 行；冷开属 M2）：落底、不闪
3. 快速上下甩动 10 次：无 >16ms hitch（Release）
4. 上滑加载 3 页：锚点不劣化；加载后下拉提示仍可用、锚点仍触发
5. 下拉加载更新：起手时提示可见才加载
6. 键盘弹起/收起：最新行贴输入条
7. 输入框长高/变矮：同上
8. 抽屉滑出/滑入：不误判；关闭后锚点仍生效
9. 浮动“到底部”/状态栏回顶：时机一致，不压过回顶动画
10. 流式：新行从底部出现、不跳；工具组持续追加行可见；每 tick 行高与内容一致
11. 流式结束：footer/复制操作出现
12. 滚走再滚回 + 首次滚过未解析页：Markdown/图片/reveal 无可见重解析、无塌缩
13. 新增消息/前插历史：无插入动画
14. 测量后旋转 / 改动态字号，继续滚动：行高正确、不重叠
15. 发送后回底 / 审批卡出现停跟随、消失回底
16. 旋转/分屏（iPad）：内容列 16/20 边距、760 居中、所有顶层 item 20pt
17. 滚动条不出现；短内容回弹；开屏期间 VoiceOver 不读内容
18. Catalyst：状态栏回顶、导航栏 scroll edge 仍注册
19. 异步 Markdown 首次物化：加载 3 页含长回复，甩动穿过，不因解析完成跳位
20. 队列新增/删除动画、状态行 12↔32：in-flight 不裁切、不瞬变
21. 动画/流式期间内容增长：底部目标仍贴底（shortfall≈0），无二次回弹
22. 读者滑回底部：重新武装，后续流式/状态行增长仍跟随

### 7.4 性能与测量预算
- **Release 真机**；采帧器与官方 `FrameHitchRecorder` 同口径（>16/>25/>75/>700ms）。
- 判据：1000 行窗口连续滚动 10 秒；主判据 **>16ms 帧占比 <5%**；硬失败任一 **>75ms**。
- 1000 行窗口构造：从顶部上拉加载 9 页（每页 100）后开始测。
- 测量预算：整页 ≤50ms、流式 tick ≤8ms；超时记 pending，不得阻塞主线程 >50ms。
- 测量一致性：抽样 20 行，文本误差 ≤1pt、复杂 ≤4pt；否则先修测量器。
- “≤ 现状 6.5”的测量：同一组上滑 3 页操作，记录锚点行屏幕 Y 最大位移；基线在 `47fd9408` 上采。

---

## 8. 分步提交

| 提交 | 内容 |
|---|---|
| C1 | `Models` 纯逻辑：identity、visibility（含提示比例）、offset、phase、signature、preferred decision、insertion owed、height key/cache、armed bottom、one-shot、measurement pipeline、pull/defer ordering + 单测 |
| C2 | `TimelineListLayout`（稳定 id+测量缓存、三分支补偿、绝对 owed、事务闸、defer park） |
| C3 | `TimelineCollectionController` + `UIViewControllerRepresentable` 骨架 + **模拟器集成门**（§7.2 全绿才能进 C4） |
| C4 | 接线 I1–I9、I27–I32（相位、采样、开屏、键盘、跟随、watchdog） |
| C5 | 接线 I10–I26（pull 保持现状、锚点、提示、窗口替换、修饰符、内容列、Markdown 外置） |
| C6a | 翻转 `aa.timeline.collectionView` 默认值，观察一个版本 |
| C6b | 删除旧路径 |

C3 门不过，不进 C4；C4/C5 后各出一次包，开关默认 off，pp 验完再翻。

---

## 9. 事前验尸（含 6a/OpenMinis 教训）

1. **测量与渲染不一致**：`TextualHeightMeasurer` 与真实 Textual 行误差超阈值 → C3 一致性门；超阈值改用 `HostingHeightMeasurer`。
2. **测量成本拖慢开屏/加载**：整页 100 行测量超 50ms → 预算 + precalc/pending + 分帧；优先保证不阻塞主线程。
3. **流式行仍被裁**：测量完成但 offset 未跟上 → 每个节流 tick 显式更新 offset/底部目标；真机 10/21。
4. **前插锚点误差**：插入页整页测量；测量 pending 的行用 precalc + 完成后修正；真机 4 + C3 门。
5. **浏览期 defer 与 pull 顺序错**：松手先结算 pull，再应用 deferred；真机 4/5。
6. **底部目标只覆盖开屏**：状态机 + 读者回到底部重新武装；真机 15/22。
7. **历史结算断链**：控制器构造 `TimelineHistoryLayout` 并喂 `laidOut`/`receivedPage`；C3 门“64ms 内结束 loading”。
8. **内容签名漏高度字段**：notice status/tail orb/turnAction footer 必须进签名；真机 11/20。
9. **测量缓存无界/全量失效**：每 item 只留当前键；宽度/字号变化整档失效并分帧重播种。
10. **Release 开关不可操作**：设置页隐藏行/URL scheme；C4 包说明写清。

---

## 10. 审查修订对照

| 审查项 | 落点 |
|---|---|
| v5 P1：settled 无数据源 | §3.4.3 测量完成即 settled；Markdown 外置解析 |
| v5 P1：流式 10 tick 1 次自测 | §3.4.2 测量层显式重测 + 0.1s 节流；cell 不驱动高度 |
| v5 P1：底部只覆盖开屏 | §3.5 底部状态机（武装/解除/重新武装/重解析） |
| v5 P1：Release 开关不可用 | §6 设置隐藏行/URL scheme |
| v5 P1：纯逻辑测试证明不了集成 | §7.2 模拟器集成门 + §7.1 #14 DEBUG 断言 |
| v5 P1：前插页高度预测误差 | §3.4.2 整页测量 + §3.4.5 pending 修正 |
| v5 P1：历史结算断链 | §4 I12/I13 + §7.2 #7 |
| v5 P1：defer 与 pull 顺序 | §3.4.4 定序 + §7.1 #13 |
| v5 P1：事务闸吞补偿 | §3.4.5 事务闸只挡 owed 叠加；测量修正走 §3.4.4 |
| v5 P2：group id 不稳定 | §3.2 映射 + §3.4.5 firstRowID/group item |
| v5 P2：签名覆盖缺口 | §3.2 内容签名全字段 |
| v5 P2：锚点 row/group/firstRowID | §3.4.5 + §7.1 #7 |
| v5 P2：typography 枚举不全 | §3.4.1 完整 ChatTypeScale 哈希 |
| 附录 C 行号漂移 | 附录 C 已按 `b4c0661d` 核对 |

---

## 11. 开工前置条件

1. pp 审阅 v6（测量驱动 + OpenMinis 缓存策略）。
2. pp 确认下拉规则维持现状。
3. 基线 `47fd9408`；先采一次性能基线（§7.4）。
4. OpenMinis 上游已核对 `b4c0661d`（附录 C）；只照设计重写，不复制代码。
5. C1 可立即开工；C3 门不过，不进 C4。
6. 用户拖拽仍未真机测；C3 门的拖拽/pull 用例用模拟器脚本 + 真机 4/5 补验。

---

## 12. v6 修订台账

### 12.1 运行时证据（保留）

> 环境：GitHub Actions `macos-26` / Xcode 26.5 / iPhone Air 模拟器 / iOS 26.5 / 视图 420×635。
> 代码：`spike/6b-collection` @ `f2382492`（一次性分支，验完删除）；run `39208410042`。
> 数字已由两名 reviewer 独立下载 artifact 核对。

| 探针 | 实测 | 用途 |
|---|---|---|
| 单参数 targetContentOffset | 非动画 apply 下被调用；`proposed 0 → returned 9200` | 原语成立 |
| 绝对 owed mid-list | `originOffset 7458 → target 16658`；锚点 delta 0；重复查询 9140/9140 | 设计成立 |
| hosting 异步解析 | 首次 45 → settled 163；回调 1 次 | 自测高**会**上报，但不可靠 |
| 部分可见 aboveOrPartial / fullyAboveOnly | 下方锚点 0 / 105 | 旧判据是 bug |
| 流式 + pinning | 10 tick 仅 1 次自测/1 次 pin；shortfall 264；手动 repin 后 0 | 不能只靠自测/cell pin |
| 动画 no-op | `didEndScrollingAnimation=0` | 需要 watchdog |

### 12.2 v5 审查的关键否定

- `waitForApply` 在 `sync()` 已同步写 `lastGeneration` 后立即返回，没等 apply 完成。
- `streamingItemVisible` 是硬编码 `true`；`settledRevision` 在仓库中不存在；`repinIfArmed()` 是手动调一次。
- 结论：**v5 的“持久底部/逐 tick 已实测”是过度解读**；v6 不再依赖这些证据。

### 12.3 v6 为什么换测量驱动

- 自测高在 10 个流式 tick 只回 1 次（§12.1），布局继续用旧高度 → 裁切/重叠。
- 前插页 100 行大多离屏，自测高拿不到；估算误差直接变锚点位移。
- 测量驱动在 apply 前把高度算好；cell 固定高度；插入/流式/回底都变成确定性。
- OpenMinis 的 verified 做法（三级缓存 + defer + contentOffsetAdjustment 三分支）作为浏览期/补偿的参照；官方 TextKit 2 作为测量驱动的方向。

---

## 附录 C · OpenMinis 参考（已核对上游 `b4c0661d`）

上游 `OpenMinis/OpenMinis`（GPL-3.0），`src/ios/Agent/MessageList/`：

| 机制 | 位置（2026-10-19 拉取核对） |
|---|---|
| 自研 layout | `MessageListLayout.swift:12`（类头：cells self-size via `preferredLayoutAttributesFitting`） |
| 三级缓存 | `estimatedHeights:23`、`precalcHeights:29`、`heightCache:124` |
| `prepare()` 纯算术 | 循环从 `:190` 开始，日志 `:246` |
| LAFE + 提前 break | `:255-280`（`expandedRect`，break `:274`） |
| `contentOffsetAdjustment` 三分支 | `:540` 完全在视口上方；`:545` 可见且非流式；`:556` 流式 + `isAutoScrollPinning`；外层 `!isTracking && !isDecelerating` 在 `:532` |
| 浏览期 `deferSelfSizing` | 定义 `:48`；判定在 `shouldInvalidateLayout` `:377-445`：有缓存时只 park 缩小/稳定，**允许增长**；无缓存允许首次测量 |
| diffable + prefetch | `CollectionViewMessageListV3.swift:1164`、`:1176-1186`（**关闭 UIKit 主线程 prefetch**，profile 显示它会挂） |
| 快照前播种 | `setPrecalcHeight` 调用点 `:3116`、`:3224`、`:3317` |
| apply 期间抑制补偿 | `suppressContentOffsetAdjustment` 定义 `MessageListLayout.swift:53`；开关 `CollectionViewMessageListV3.swift:5768-5770` |
| 插入补偿方式 | 用 `contentOffsetAdjustment`，**没有** layout `targetContentOffset`（`targetContentOffset` 只出现在 `scrollViewWillEndDragging` 的指针参数 `:5402`） |
| 缓存键 | **Int 索引**（`heightCache[index]`），插入时手动重映射 `:776-784`；AA 用稳定 item id，不复用索引键 |

> 以上行号已在 `b4c0661d` 上核对。GPL-3.0：**只照设计重写，不复制代码。**
