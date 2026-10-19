# 6b-M1 任务单 v7：测量驱动高度 + 绝对插入补偿

> 定级 **L**。依据：`docs/perf-plan-v2.md` 批 6b；官方证据 §2.6/§2.9；OpenMinis 已核对 `b4c0661d`（附录 C）。
> **v7 修订**：v6 的两份审查（去重后 8 条 P1 + 一组 P2）指出：固定高度管线漏了 fold/inline notice/tail 的交互式高度；Textual 没有独立测量 API，Markdown 只能走离屏 hosting；部分可见 pending 修正、owed 取消、底部强制命令、键盘门也需要补齐。本版逐条修。
> 关键证据见 §12。

---

## 0. 目标

把 `ChatTimelineView` 的滚动容器换成 `UICollectionView` + 自研 `UICollectionViewLayout`，
**在同一次布局事务内**完成高度修正与插入补偿，行为逐条对齐现状，并消除“加载很多页后滚动卡”。

**验收**：行为清单全绿；1000 行窗口滚动满足 §7.4；开屏落底无可见滚动；上滑加载的视口位移 ≤ 现状 6.5。

### 0.1 架构拍板（v7）

| 决策 | 选择 | 理由 |
|---|---|---|
| 高度真值 | **测量层在 apply 前算好；布局只消费固定高度；cell 不驱动高度** | 自测高逐 tick 不可靠：10 tick 只回 1 次（§12.1；该探针 `waitForApply` 未等 apply，只作方向证据）；测量驱动把“边滚边猜”变成“进场前已知” |
| 高度缓存 | **稳定 item id + 内容修订 + 宽度 + Dynamic Type + 排版修订；三档 measured/precalc/estimate** | 前插移动索引；离屏更新会让旧 measured 失真；稳定 id 不重映射 |
| 异步内容 | **先解析（Markdown/图片尺寸）再测量；测量完成即 settled；没有视图回写 settled 的接口** | `ChatMarkdownView` 的解析在 view `@State`，行模型不知道何时完成（P1） |
| 测量实现 | **Markdown/复杂行用离屏 `UIHostingController` 承载真实行视图；TextKit 2 只做纯文本 precalc** | Textual 是 SwiftUI View，没有独立测量 API；离屏 hosting 是唯一与渲染一致的路径（P1） |
| 交互式高度 | **fold 展开/折叠、inline notice、tail 是受控例外：允许 cell preferred 高度作为修正信号，由 controller 驱动 update；其余行固定高度** | 点开折叠/inline 审批卡会改变行高；固定高度会裁切（P1） |
| 插入补偿 | **绝对目标 `originOffset + (newAnchorY - originY)`；插入页整页测量；finalize 兜底；update 事务闸** | 前插页的行大多离屏，估算误差会变成锚点位移（P1）；绝对值幂等 |
| 可见行补偿 | **测量修正：`cell.minY < viewportTop`（含部分可见）→ delta；cell 自测/流式修正：OpenMinis 三分支** | spike 实测部分可见位移 105pt；pending 修正必须补偿；两类修正分开（P1） |
| 浏览期 defer | **有缓存的行只 park 收缩/稳定；增长放行；无缓存允许首次测量；减速结束后再应用** | OpenMinis `:377-445` 同款；防止拖拽中裁切/重叠；应用时点在减速结束后（P2） |
| 底部目标 | **强制命令（pill/loadLatest/审批消失/窗口重断言）无条件武装；跟随武装才看 `readerRestsAtBottom`/mode/interaction；每次 contentSize/测量完成重解析** | 现状这些路径是无条件 `requestBottom()`（P1）；一次性目标短差 365/220pt |
| 下拉规则 | **保持现状 2pt/24pt + wasInteracting，不改规则；流式并发增长仍可能取消（现状同）** | pp 明确；defer 只能消除 6a 的懒容器失效，不能撤销已经发生的 cancel（P2） |

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
  - `group`：`rows.map(\.id)` + 每行 `revision`/`updatedSeq` + `TimelineTurnActions.build` 的输入（`isRunning`/`hasNewerItems`/pending）+ **`TimelineDisclosureState`（fold 展开/折叠）** + **inline notice 的 membership/status（`noticesByTarget`）** + **附件 preview 尺寸状态（`previewPixelSize`）**。这些都会改变行高。
  - `olderPrompt`/`latestPrompt`：`(pullReady, isLoading, keepsOlderPrompt, hasOlderItems)`。
  - `notice`：membership id + `status`/`revision`（审批接受/失败要 reconfigure）。
  - `pending`：membership id + 附件内容签名。
  - `tail`：队列 id+状态 roster、`sendingPlaceholder`、状态行文本/orb 活动、`hasNewerItems`。
- 纯视图状态（Textual 选区、reveal 动画）不进签名；外置到行模型/有界缓存。

### 3.3 Cell 与内容列

- `TimelineHostingCell` + `UIHostingConfiguration`，但**默认行高度由布局给定**；cell 的 `preferredLayoutAttributesFitting` 只用于一致性校验与受控例外（§3.4.4）。
  - hosting 配置必须 `.margins(.all, 0).minSize(width: 0, height: 0)`；测量宽度 = `bounds.width - hosting margins`，否则默认 margins 会破坏 16/20pt 内容列并让测量/渲染宽度不一致（OpenMinis `CollectionViewMessageListV3.swift:1406` 同款）。
- **水平边距 = 16（<414pt）/ 20（≥414pt）**；最大宽 760、居中；**所有顶层 item 之间 20pt**；16pt 顶部只加在第一个 item。
- 队列/状态行/尾部留在 `tail` 一个 item 内，保留其 SwiftUI `.transition` 与高度动画。**tail 是受控例外**：`preferredLayoutAttributesFitting` 可作为高度修正信号，由 controller 在动画中逐帧更新布局高度；不能让固定高度 cell 直接裁掉 0.2s 的 32↔12 状态行动画。

### 3.4 高度管线：测量驱动（v6 核心）

#### 3.4.1 键与缓存

```swift
struct TimelineHeightKey: Hashable {
    let itemID: String
    let contentRevision: Int
    let width: CGFloat          // 0.5pt
    let dynamicType: String
    let typographyRevision: Int
    let layoutDirection: Int    // RTL/LTR；MarkdownBlockLayout 会据此重建缓存
}

final class TimelineHeightCache {          // Models, testable
    private var measured: [TimelineHeightKey: CGFloat] = [:]
    private var precalc:  [TimelineHeightKey: CGFloat] = [:]
    private var estimate: [TimelineHeightKey: CGFloat] = [:]
    private var displayedHeight: [String: CGFloat] = [:]  // 每 item 上一帧实际高度
}
```

- 三档：`measured`（与真实渲染校验过）/ `precalc`（纯文本用 TextKit 2 快速路径；Markdown/复杂行没有可靠的独立 precalc → 用 estimate/占位）/ `estimate`（启发式）；兜底按 kind（提示 44、tail 12/32、普通 200），不用全局 200。
- **内容修订必须合并**：group 的 `contentRevision` = 所有行 revision/updatedSeq + `TimelineDisclosureState` + inline notice membership/status + 附件 preview 尺寸；否则展开/审批卡出现不会换键（P1）。
- 内容修订变化：新键在 apply 前测量/播种；旧键可保留到新键测量完成，或由 `displayedHeight` 兜底。
- 流式行**不继承**旧 measured：每批由测量层重测；未完成时用 `displayedHeight[itemID]`（上一帧实际高度），完成后按 delta 修正。不要回落到 estimate/kind 默认（会先塌一下）。
- `typographyRevision`：完整 `ChatTypeScale`（含 `codeBlockRatio`、`codeBlockLineSpacingRatio`、`inlineCodePin`、`codeBlockPin`）+ `ChatColorSettings.inlineCodeBold`（它影响行宽，不在 scale 里）+ Bold Text + Dynamic Type + `layoutDirection` 的稳定哈希；设置/trait 变化整档失效。iOS 17+ 用 `registerForTraitChanges`，不要用已弃用的 `traitCollectionDidChange`。
- 缓存生命周期：每个 item 保留当前键 + `displayedHeight`；item 离开快照时删除该 id 全部档；播种只做视口 ± 一屏，历史页整页按 §3.4.2。

#### 3.4.2 测量层（apply 前）

`TimelineHeightMeasurer`（协议）：
- `HostingHeightMeasurer`（**主**）：Markdown/复杂行用离屏 `UIHostingController` + 真实行视图，主线程批量测量。Textual 是纯 SwiftUI View，没有独立测量 API（`StructuredText` 是 View，`sizeThatFits` 只在内部 BlockVStack/attachment）；离屏 hosting 是唯一与渲染一致的路径。
- `TextKit2HeightMeasurer`（**辅**）：只给纯文本/无 Markdown 的行做 precalc；不要用它测 Markdown/表格/代码块/附件。
- **一致性门（C3 必过）**：抽样按行类型分层（message/reasoning/tool 折叠与展开/code/table/image/notice/pending/tail）；比较 `measured` 与 **cell 内容视图的 fitting height**（不是 `cell.frame.height`，后者在固定高度下恒等，会假绿）；方向 cell 高度 ≥ 内容高度；文本 ≤1pt、复杂 ≤4pt。
- **吞吐门（C2/C3）**：用真实 100 行长回复/代码块/表格测 p50/p95；测量预算必须在实测后写死，不能先写 50ms/8ms。

时序：
- 新 item / `changedIDs`：在 snapshot apply **之前**测量。**历史页（100 行）整页测量**，不只视口 ± 一屏——这是前插锚点精确的前提。
- 开屏：测量当前窗口（`open()` 裁到最新 100 行）的可见 ± 一屏；其余按需/分帧。
- 流式：0.1s 节流；测量输入必须是 `row.text`（displayed，可能少最后一个 glyph）+ parsed blocks，不是 raw item 文本；拿到高度后显式更新 offset/底部目标。
- 测量预算：先测吞吐再定；超时用 `displayedHeight`/estimate 标记 pending，余下在滚动路径外继续测量，完成后按 §3.4.4 修正。
- **禁止**把 cell 的 `preferredLayoutAttributesFitting` 当一般高度真值；只有受控例外（fold/tail/inline notice）可用（§3.4.4）。

#### 3.4.3 异步内容（Markdown/图片）

- Markdown 解析从 `ChatMarkdownView` 的 view `@State` 外置到 `MarkdownParseCache`。
  - **增量状态**：按行保留 `MarkdownParseState` + `MarkdownStreamSplit`，只重解析未完成尾部；`Task` 取消/成功守卫保留，旧结果不能覆盖新结果。不要每 tick 按全文哈希全量解析。
  - **落点**：纯解析状态机（无 Textual 依赖）放 `Models` 可测；Textual/SwiftUI 适配放 `Services`，用协议注入。
  - **测量输入**：`row.text`（displayed）+ parsed blocks，不是 raw item 文本。
- 图片尺寸同理：解码/尺寸就绪后再测量；未就绪时用 `displayedHeight`/estimate + pending，完成后修正。
- 不存在“视图回写 settled”的接口：**测量完成就是 settled**；行模型只暴露 `contentRevision` 和可测量内容。
- 首次物化不得出现 45→163 级塌缩：apply 前用测量值；未完成时用 `displayedHeight`/precalc（不是 0/占位高）并标记 pending。验收口径是“首帧与 settled 高度差 ≤ 容差”，不是“首帧必须完整高度”（解析未完成时不可能）。

#### 3.4.4 高度修正与 offset 补偿（OpenMinis 同构 + 测量驱动）

补偿分**两类**，不要混在一起：

**A. Pending 测量修正（controller 驱动）**：apply 后测量才完成的行。
- `cell.minY < viewportTop`（含部分可见）→ `delta`。这是 v5 spike 实测“部分可见位移 105pt”的修复；不补偿会让正在读的下方内容跳。
- `cell.minY >= viewportTop`（在视口内或下方）→ 0，除非流式+贴底。
- 外层条件：`!isTracking && !isDecelerating && !keyboardTransition && !suppressContentOffsetAdjustment`。

**B. Cell 自测/交互式高度例外（OpenMinis 同构）**：fold 展开、inline notice、tail 状态行、流式 cell。
1. cell 完全在视口上方（`cellBottom <= viewportTop`）→ `delta`。
2. cell 可见且非流式（`cellTop >= viewportTop && cellTop < viewportBottom`）→ `delta`。
3. 流式 cell + `isAutoScrollPinning` + delta > 0 → `delta`，同帧贴底。
4. 其余（含部分可见）→ 0；由 defer/下一帧修正。

> `isAutoScrollPinning` 定义：`armedBottomTarget != nil && !interactionIsPresented && !userIsScrolling && mode != .reading`（映射 OpenMinis `scrollMode == .autoScrolling`）。审批卡出现/读者阅读时为 false。
> `keyboardTransition` 期间不补偿：键盘自己的逐帧 pin 驱动 offset；窗口结束后再重解析底部目标。
> fold/tail/inline notice 是受控例外：它们的 `preferredLayoutAttributesFitting` 可以作为修正信号；普通行仍由测量层给定高度。

**浏览期 defer（OpenMinis `:377-445`）**：
- 用户拖拽/减速中，有缓存的行：收缩/稳定修正 park 到 `deferredHeights`；**增长放行**（避免裁切/重叠）；无缓存的行允许首次测量。
- **减速结束后**（`scrollViewDidEndDecelerating` / 稳定）先结算 pull，再一次性应用 deferred 修正并补偿；不要在 `didEndDragging(willDecelerate:true)` 时应用（此时仍在减速，补偿会被外层 `!isDecelerating` 抑制）。
- 拖拽中流式增长：放行；除非 armed bottom，不改 offset。
- **范围说明**：defer 只消除 6a 的“懒容器导致 pull 取消失效”；拖拽中流式增长 >2pt 仍会取消 `TimelineHistoryPull`（现状同）。不要把“绝不取消”写进验收；真机 4/5 要专门测“流式同时上滑加载”。

#### 3.4.5 插入补偿：绝对目标

单参数 `targetContentOffset(forProposedContentOffset:)` 返回**绝对目标**：

```
target = originOffset + (newAnchorY - originY)
```

- `originOffset`：请求开始时的静止偏移，**必须**是 `max(-topInset, offsetY)`（现状 `TimelineHistoryPosition.init` 的过冲钳制；单测期望 920）。
- **owed 带代际并会被用户接管取消**：`owed` 携带 `navigationGeneration`（或 history request id）；用户开始拖拽、点浮动回底、`loadLatest`、导航代际变化时一律清除 owed。慢请求落地时若代际已变，`targetContentOffset` 原样返回 proposed，不修正。
- 前插页的 `newAnchorY` 来自**整页测量**（§3.4.2），不是估算；测量未完成的行用 `displayedHeight`/precalc 并标记 pending，完成后按 §3.4.4 修正。
- **append 不设 owed**：新 item 全在视口下方时，`owed` 为 nil，`targetContentOffset` 原样返回 proposed；底部跟随由 §3.5 状态机负责。v5 的“append owed=0”不要丢。
- 返回绝对值而不是 `proposed + delta`：同一事务可能查询多次；绝对值幂等。
- `owedConsumed`：首次查询置位；`finalizeCollectionViewUpdates` 未消费则 `setContentOffset(target)` 兜底后清零。兜底前先 `layoutIfNeeded()`，若目标仍被旧 contentSize 钳制，下一 runloop 复测一次，避免静默留在半途。
- **事务闸**：`prepare(forCollectionViewUpdates:)` 进入、`finalize` 退出；事务内只处理 owed。若同一事务里还有测量修正，把 delta **累加进 target**（或等事务结束后按 §3.4.4 补偿），不重复发 `contentOffsetAdjustment`，也不静默丢弃。
- **锚点是 group item，不是 row id**：用“包含 `anchorRowID` 的 group item + 存储的 edge”求 y；控制器在 apply 前提供 `rowID -> group item id` 映射。group 合并导致 id 变化时，把旧 group 的 measured/displayedHeight 迁移到新 group。
- **firstRowID 的两种语义拆开**：
  - **修正**：`layout.firstRowID != origin.firstRowID` 表示“页确实插到了顶部”，此时才应用修正；相等 → 跳过（这是现状 `laidOut` 的方向，不要写反）。
  - **结算**：`isReadyToFinish` 等 `latestLayout.firstRowID == expectedFirstRowID`（或 expected 为 nil）。
  - 窗口替换守卫用 `anchorRowID`/`edge` 相等，不是 firstRowID。
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
| **强制命令**：浮动“到底部”点按 / `loadLatest` / 审批消失 / 窗口重断言 | **无条件武装**（这些路径现状就是无条件 `requestBottom()`；不要套 reader/mode 闸） |
| 开屏 / 发送 / 新 pending | 跟随武装：仅当 `readerRestsAtBottom` 或 `mode != .reading`；发送路径保留 `!hasInteractions` |
| 读者滑回/停在底部（`settleUserScroll` → following） | 重新武装；但 `interactionIsPresented` 时不再武装 |
| 用户开始拖拽 / `browseHistory` / 审批出现 / 导航挂起 / 状态栏回顶 | 解除 |
| 导航恢复 | 若 `readerRestsAtBottom` 且无审批则重新武装 |
| 任何 contentSize/测量完成 | 若已武装，重解析底部并贴住 |
| 键盘过渡 | 键盘自己的逐帧 pin 驱动 offset；armed 目标暂停补偿，窗口结束后重解析 |

> `requestBottom()` 本身是无条件的，会把 `mode` 置为 `.returning`；阅读/交互闸作用在“跟随”上，不作用在显式命令上。
> 保留现状 `readerRestsAtBottom`（键盘钉底的几何真值）与 R2 一次性 latch `bottomReconcileIsSpent`；新状态机不能把它们删掉。`isAutoScrollPinning` 的定义见 §3.4.4。

---

## 4. 逐项对接

- **I1/I31**：相位合成见 §3.5；`settleUserScroll` 的 64ms 任务原样保留。
- **I2/I3**：采样与发布见 §3.5；禁止在原生回调里直接写 SwiftUI `@State`。
- **I4**：底部目标状态机见 §3.5；强制命令（pill/loadLatest/审批消失/窗口重断言）无条件武装，跟随武装才看 `readerRestsAtBottom`/mode/interaction；每次 contentSize/测量完成重解析；`finishScrollToBottom` 只清当前命令，不清“用户仍在底部”的语义。
- **I5**：`setContentOffset(_:animated:)` + `scrollViewDidEndScrollingAnimation`；no-op 不回调（实测 0），加 watchdog；拖拽打断在 `scrollViewWillBeginDragging` complete。曲线与 `interactiveSpring(0.28, 1)` 不完全一致，接受或 CADisplayLink 近似（单独验收）。
- **I6**：`shouldPin` 由 `isAutoScrollPinning`（§3.4.4）+ `interactionIsPresented` 派生。审批卡出现：**清除跟随目标**（I29）已确定；卡片是否进入视口现状**未验证**——先按 §7.2 #23 真机验（读者上滑 50 行 + 审批到达 + 键盘弹出），再写死“一次性进入/不拽底”的规则，不要凭 `.sizeChanges` 的文档推断。
- **I10/I11**：**下拉规则不变**：仍用 `TimelineHistoryPull` 的 2pt contentHeight/visibleHeight 闸 + 24pt 位移 + `wasInteracting`；新容器把同样的 `TimelineViewport` 喂给现有纯类型。浏览期 defer 的定序见 §3.4.4；**流式并发增长仍可能取消**（现状同），不要把“绝不取消”写进验收。
- **I12/I13**：见 §3.4.5；控制器在 update 后从布局 attributes 构造 `TimelineHistoryLayout`（firstRowID/anchorRowID/edge/y）并调用 `laidOut`/`receivedPage`。**修正**用 `layout.firstRowID != origin.firstRowID`（页插入）才应用；**结算**等 `latestLayout.firstRowID == expectedFirstRowID`；两者不要混。
- **I18**：挂起时取消；恢复时重放相位，且 `historyLayout != nil` 时重跑锚点重算。
- **I22**：`windowRevision` 变化时，只在 `!readerTookOver && !navigationIsSuspended && hasOpened` 时重跑 I4。
- **I23**：`isOpeningReady` 期间禁手势/无障碍；iOS 直接设 `collectionView.topEdgeEffect.style = .soft`；`ChatPageScrollEdge` 只在 Catalyst 编译（`:8-12`），Catalyst 注册逻辑放 collection controller 的 `didMoveToWindow`/`viewDidLayoutSubviews`，不能放 representable 的 `.background`。
- **I25**：Markdown 解析外置到 `MarkdownParseCache`（增量 `MarkdownParseState`）；附件解码/reveal/选区/`TimelineDisclosureState`（fold 展开）/inline notice 状态外置到行模型/有界缓存，cell 回收不丢；其中 disclosure/inline notice 会改变行高，必须进内容签名。
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
- **出包第 0 步**：打开开关，并用可见标记（设置页版本行/诊断页/日志）确认 collection view 已生效；否则 22 项验收全在旧路径上假绿。
- **C4/C5 必须保持旧路径完整可用**（尤其 C5 的 Markdown 外置会改 `ChatMarkdownView`）；不要为了新路径把旧路径改坏。
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
6. `TimelinePreferredAttributesDecision`：§3.4.4 的两类分支逐条（pending 部分可见补偿 / 自测三分支 / 流式+贴底 / defer / keyboard）。
7. `TimelineInsertionOwed`：绝对目标、两次查询同一值、过冲钳制 920、owed 代际取消；**修正方向**用 `firstRowID != origin`（插入）才应用，**结算**等 `== expected`，两者分开测。
8. `TimelineHeightKeying`：宽度 0.5pt、字号/排版失效、内容修订换键、缓存生命周期。
9. `TimelineHeightCache`：三档优先级、pending 修正、流式不继承旧 measured、kind 默认值。
10. `TimelineArmedBottomTarget`：武装/解除/重新武装（读者回到底部）、contentSize 连续变化后贴底。
11. `TimelineOneShotOwed`：`owedConsumed`、finalize 兜底后清零。
12. `TimelineMeasurementPipeline`：整页测量、预算超时→precalc/displayedHeight+pending、完成后修正；Markdown 只走 hosting 测量。
13. `TimelinePullDeferOrdering`：拖拽中 park 收缩/稳定、增长放行、减速结束后先结算 pull 再应用 deferred；流式并发增长仍可能取消（现状同）。
14. **布局必须委托这些纯类型**：`TimelineListLayout` 直接持有并调用；加 DEBUG 断言（finalize 后 owed 已清零；measured 键与当前 revision 一致），否则纯类型全绿也证明不了调用点（`Package.swift:11-15` 把 Views 排除在 `ClientCore` 外）。
15. **保留现有 `TimelineHistoryPositionTests` 全绿**：尤其 `prependingPreservesTheOffsetInsideALongMessage`、`outwardPullRestoresTheRestingInsetInsteadOfKeepingOverscroll`、`prefixedToolGroupsRetainTheirExistingTrailingBoundary`；新 owed 类型不得改变这些语义。
16. `TimelineDisclosureAndNoticeSignature`：fold 展开/折叠、inline notice 出现/消失/状态变化必须改变 group 的 `contentRevision` 并触发重测。

### 7.2 模拟器集成门（C3 必过，CI 执行）
用 `spike` 同款 `simctl` + 应用内 autorun 方式，驱动**真实 cell**，输出 JSON 并断言：
1. **测量一致性**：按行类型分层（message/reasoning/tool 折叠与展开/code/table/image/notice/pending/tail）；比较 `measured` 与 **内容视图的 fitting height**（不是 `cell.frame.height`，后者在固定高度下恒等，会假绿）；方向 cell 高度 ≥ 内容高度；文本 ≤1pt、复杂 ≤4pt。
2. **前插**：插入页 100 行整页测量；锚点屏幕位移 ≤0.5pt；`targetOffsetCalls≥1`；重复查询同一值；**owed 代际取消**（拖拽后落地不修正）。
3. **异步 Markdown**：首帧与 settled 高度差 ≤ 容差（不是“首帧必须完整高度”）；不得出现 45→163 级塌缩；解析完成后无可见跳位。
4. **流式**：每个节流 tick 的 measured 高度递增；cell 高度 ≥ 内容高度（不裁切/不重叠）；底部 shortfall ≤0.5pt；浏览时不被拽底；**同一 tick 只移动一次**（布局补偿与控制器更新去重）。
5. **底部状态机**：强制命令（pill/loadLatest/审批消失/窗口重断言）无条件武装；跟随武装；读者回到底部重新武装；拖拽/审批出现/导航挂起解除；no-op 回底不卡相位；R2 latch 保留。
6. **下拉**：优先用 **XCUITest 真实拖拽**。若暂用 autorun，必须驱动真实 delegate 回调，并在拖拽中注入一次 >2pt 的 `contentHeight` 变化后断言松手仍触发 `loadOlder`；否则明确标“拖拽未覆盖”，不能拿它当 6a 回归判据。提示 0.9/0.5 可见性翻转正确。
7. **历史结算**：页落地后 64ms 内结束 loading；**修正**用 `firstRowID != origin`（插入）才应用；**结算**等 `== expected`。
8. **fold/inline notice**：展开长推理/工具组、inline 审批卡出现/消失，cell 高度更新、不裁切；键含 disclosure/notice。
9. **tail 动画**：队列新增/删除、状态行 12↔32，动画期间不裁切、不瞬变。
10. **第 0 步**：开启 `aa.timeline.collectionView` 并用可见标记确认新容器生效；否则整轮作废。
11. **审批卡现状**：读者上滑 50 行 + 审批到达 + 键盘弹出，记录卡片是否进入视口/是否拽底；先验现状，再写规则。

### 7.3 真机清单
0. **开关第 0 步**：设置隐藏行/URL scheme 开启 `aa.timeline.collectionView`，用可见标记确认新容器生效；否则以下全部作废
1. 冷开最新会话：落底、不闪
2. **1000 行窗口**（M1：从顶部上拉加载 9 页达到约 1000 行；随后回底，落底、不闪；冷开属 M2）
3. 快速上下甩动 10 次：按 §7.4 判据（>16ms 占比 <5%，无 >75ms）
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
15. 发送后回底 / 审批卡出现停跟随、消失回底；另测“读者上滑 50 行 + 审批到达 + 键盘弹出”，先记录现状（卡片是否进入视口/是否拽底），再对照新实现
16. 旋转/分屏（iPad）：内容列 16/20 边距、760 居中、所有顶层 item 20pt
17. 滚动条不出现；短内容回弹；开屏期间 VoiceOver 不读内容
18. Catalyst：状态栏回顶、导航栏 scroll edge 仍注册
19. 异步 Markdown 首次物化：加载 3 页含长回复，甩动穿过，不因解析完成跳位
20. 队列新增/删除动画、状态行 12↔32：in-flight 不裁切、不瞬变
21. 动画/流式期间内容增长：底部目标仍贴底（shortfall≈0），无二次回弹
22. 读者滑回底部：重新武装，后续流式/状态行增长仍跟随
23. **展开/折叠长推理、工具组、inline 审批卡出现/消失**：行高正确、不裁切、不重叠
24. **状态行 12↔32、队列新增/删除**：动画期间不裁切、不瞬变（tail 受控例外）

### 7.4 性能与测量预算
- **Release 真机**；采帧器与官方 `FrameHitchRecorder` 同口径（>16/>25/>75/>700ms）。
- 判据：1000 行窗口连续滚动 10 秒；主判据 **>16ms 帧占比 <5%**；硬失败任一 **>75ms**。
- 1000 行窗口构造：从顶部上拉加载 9 页（每页 100）后开始测。
- 测量吞吐：C2/C3 先用真实 100 行长回复/代码块/表格测 p50/p95；**预算按实测写死，当前不写 50ms/8ms**。
- 测量一致性：按行类型分层抽样 20 行，比较内容视图 fitting height 与 `measured`；文本误差 ≤1pt、复杂 ≤4pt；precalc 误差单独设门（目标 ≤8pt，未测）。
- 超时/pending：超时用 `displayedHeight`/estimate 标记 pending，后台继续测量；不得阻塞主线程超过实测 p95 预算。
- “≤ 现状 6.5”的测量：同一组上滑 3 页操作，记录锚点行屏幕 Y 最大位移；基线在 `47fd9408` 上采。

---

## 8. 分步提交

| 提交 | 内容 |
|---|---|
| C0 | CADisplayLink 采帧器 + 基线采集（单独提交，不混在功能里） |
| C1 | `Models` 纯逻辑：identity、visibility（含提示比例）、offset、phase、signature（含 disclosure/notice）、preferred decision、insertion owed（含代际）、height key/cache、armed bottom、one-shot、measurement pipeline、pull/defer ordering + 单测 |
| C2 | `TimelineListLayout` + `HostingHeightMeasurer`（稳定 id+测量缓存、两类补偿、绝对 owed、事务闸、defer park、吞吐门） |
| C3 | `TimelineCollectionController` + `UIViewControllerRepresentable` 骨架 + **模拟器集成门**（§7.2 全绿才能进 C4） |
| C4 | 接线 I1–I9、I27–I32（相位、采样、开屏、键盘、跟随、watchdog） |
| C5 | 接线 I10–I26（pull 保持现状、锚点、提示、窗口替换、修饰符、内容列、Markdown 外置） |
| C6a | 翻转 `aa.timeline.collectionView` 默认值，观察一个版本 |
| C6b | 删除旧路径 |

C3 门不过，不进 C4；C4/C5 后各出一次包，开关默认 off，pp 验完再翻。

---

## 9. 事前验尸（含 6a/OpenMinis 教训）

1. **测量与渲染不一致**：`HostingHeightMeasurer` 与真实 cell 内容 fitting height 误差超阈值 → C3 一致性门；先修测量器，不要靠估算掩盖。
2. **测量成本拖慢开屏/加载**：整页 100 行测量超实测 p95 预算 → 分帧/pending + 后台继续；优先保证不阻塞主线程。
3. **流式行仍被裁**：测量完成但 offset 未跟上 → 每个节流 tick 显式更新 offset/底部目标；真机 10/21。
4. **前插锚点误差**：插入页整页测量；测量 pending 的行用 precalc + 完成后修正；真机 4 + C3 门。
5. **浏览期 defer 与 pull 顺序错**：松手先结算 pull，再应用 deferred；真机 4/5。
6. **底部目标只覆盖开屏**：状态机 + 读者回到底部重新武装；真机 15/22。
7. **历史结算断链**：控制器构造 `TimelineHistoryLayout` 并喂 `laidOut`/`receivedPage`；C3 门“64ms 内结束 loading”。
8. **内容签名漏高度字段**：notice status/tail orb/turnAction footer 必须进签名；真机 11/20。
9. **测量缓存无界/全量失效**：每 item 只留当前键；宽度/字号变化整档失效并分帧重播种。
10. **Release 开关不可操作**：设置页隐藏行/URL scheme；C4 包说明写清。
11. **fold/inline notice 高度不更新**：disclosure/notice 必须进签名与内容修订；真机 23。
12. **键盘过渡双重移动**：keyboardTransition 不进补偿门，由键盘 pin 驱动；窗口结束后重解析底部。
13. **tail 动画被固定高度裁切**：tail 受控例外，controller 驱动高度动画；真机 24。
14. **慢请求落地拽走用户**：owed 带代际，拖拽/pill/loadLatest/导航变化清除；C1 单测。

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
| v6 P1：固定高度漏 fold/inline notice/tail | §3.2 签名 + §3.4.1 内容修订 + §3.3/§3.4.4 受控例外 + §7.2 #8 |
| v6 P1：Textual 无独立测量 API | §3.4.2 HostingHeightMeasurer 为主 + 吞吐门 |
| v6 P1：C3 一致性同义反复 | §7.2 #1 比较内容 fitting height + 分层抽样 |
| v6 P1：部分可见 pending 修正 | §3.4.4 A 类 aboveOrPartial |
| v6 P1：owed 未在用户接管时取消 | §3.4.5 代际 + §7.1 #7 |
| v6 P1：底部强制命令与跟随武装冲突 | §3.5 强制/跟随分表 + `readerRestsAtBottom`/R2 latch |
| v6 P1：键盘过渡双重移动 | §3.4.4 keyboardTransition 门 |
| v6 P2：firstRowID 方向 | §3.4.5 + §7.2 #7 |
| v6 P2：append owed 规则丢失 | §3.4.5 append 不设 owed |
| v6 P2：开关验收假绿 | §6 第 0 步 + §7.3 #0 |
| v6 P2：审批卡 `.sizeChanges` 未验证 | §4 I6 + §7.2 #11 |

---

## 11. 开工前置条件

1. pp 审阅 v7（测量驱动 + OpenMinis 缓存策略 + 交互式高度例外）。
2. pp 确认下拉规则维持现状。
3. 基线 `47fd9408`；先采一次性能基线（§7.4）。
4. OpenMinis 上游已核对 `b4c0661d`（附录 C）；只照设计重写，不复制代码。
5. C1 可立即开工；**C2 前修完 §10 的 v6 P1**；C3 门不过，不进 C4。
6. 用户拖拽仍未真机测；C3 门优先用 XCUITest，暂用 autorun 时必须驱动真实 delegate + 注入 >2pt 变化，否则明确标“未覆盖”。

---

## 12. v7 修订台账

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

> 注：`16658` 与 `9140` 是不同场景（不同 origin/inset），不要当同一事务的幂等证据；幂等由 `9140/9140` 单独证明。
> “部分可见 105”是 **self-sizing** 探针；v7 把它用于 pending 测量修正（§3.4.4 A 类），自测/流式仍用 OpenMinis 三分支（B 类）。

### 12.2 v5 审查的关键否定

- `waitForApply` 在 `sync()` 已同步写 `lastGeneration` 后立即返回，没等 apply 完成。
- `streamingItemVisible` 是硬编码 `true`；`settledRevision` 在仓库中不存在；`repinIfArmed()` 是手动调一次。
- 结论：**v5 的“持久底部/逐 tick 已实测”是过度解读**；v7 不再依赖这些证据。

### 12.3 v7 为什么换测量驱动

- 自测高在 10 个流式 tick 只回 1 次（§12.1；该探针的 `waitForApply` 没等 apply 完成，计数只作方向证据，不作精确吞吐）。布局继续用旧高度 → 裁切/重叠。
- 前插页 100 行大多离屏，自测高拿不到；估算误差直接变锚点位移。
- 测量驱动在 apply 前把高度算好；cell 固定高度；插入/流式/回底都变成确定性。
- OpenMinis 的 verified 做法（三级缓存 + defer + contentOffsetAdjustment 三分支）作为浏览期/补偿的参照；官方 TextKit 2 作为测量驱动的方向（官方在 cell 物化后实测；AA 因 SwiftUI/Textual 行改为 apply 前离屏 hosting，见 §13.2）。

### 12.4 v6 两份审查与 v7 处置

| # | v6 问题 | v7 处置 |
|---|---|---|
| 1 | 固定高度漏 fold/inline notice/tail 高度 | §3.2 签名 + §3.4.1 内容修订 + §3.3/§3.4.4 受控例外；§7.2 #8 |
| 2 | Textual 无独立测量 API | §3.4.2 改为 HostingHeightMeasurer 为主，TextKit 2 只做纯文本 precalc；吞吐门 |
| 3 | C3 一致性检查同义反复 | §7.2 #1 比较内容视图 fitting height，分层抽样，禁止比较 cell.frame |
| 4 | 部分可见 pending 修正判据矛盾 | §3.4.4 A 类 `cell.minY < viewportTop` 补偿；B 类保持 OpenMinis 三分支 |
| 5 | owed 未在用户接管时取消 | §3.4.5 owed 代际；拖拽/pill/loadLatest/导航变化清除；§7.1 #7 |
| 6 | 底部强制命令与跟随武装冲突 | §3.5 强制/跟随分表；保留 `readerRestsAtBottom` + R2 latch |
| 7 | 键盘过渡双重移动 | §3.4.4 加 `keyboardTransition` 门；键盘 pin 驱动 offset |
| 8 | firstRowID 方向写反/含混 | §3.4.5 拆“修正（!=）”“结算（==）”；§7.2 #7 |
| 9 | append owed 规则丢失 | §3.4.5 append 不设 owed，原样返回 proposed |
| 10 | 开关第 0 步缺失，验收假绿 | §6 第 0 步 + §7.3 #0 |
| 11 | 审批卡 `.sizeChanges` 断言未验证 | §4 I6 改为先真机验 §7.2 #11 |
| 12 | tail 动画与固定高度无同步 | §3.3 tail 受控例外 + §9 #13 + §7.3 #24 |

> C1 可开工；C2 前修完上表 P1 项；C3 门不过，不进 C4。

---

## 13. Claude App 逆向对照（Part Z，2026-10-19）

> 来源：sbx `/home/ubuntu/wiring/docs/part-z-textkit-height.md`（另一 agent 的静态逆向，Q1–Q8 + 第三轮补充；仍在补）。
> 原则：官方证据用于校正“官方怎么做”的表述；AA 的差异凡有架构原因的，写明原因，不伪装同构。

### 13.1 已证实、与 v7 一致

- **owed 是绝对 contentOffset**；同一事务多次 `targetContentOffset` 是纯读、无副作用；事务内高度修正**覆盖** owed（后答覆盖前答），不累加；finalize 时与当前 offset 不同才 `setContentOffset` 并清零（Q3）。
- 新行先带估计高度；宽度变化只清 `isMeasured`、**保留旧高度**，等重新测量（Q1/Q5）。
- Markdown 在数据层解析，cell 只排版/报高度；没有“视图回写 settled”的独立状态（Q6）。
- 滚动目标是显式 `placement`（`.reading(RowID, offsetIntoRow)` / `.end`），每次内容变化现算，不缓存绝对值；no-op 有阈值结算（Q4）。
- 底部跟随不是单独 flag：`placement == .end`；拖动改成 `.reading` 即解除；回到底部重新武装（Q4）。
- 列表层 `UIUpdateLink` 只用于滚动缓动/帧采样，不参与高度修正；Markdown 打字揭示另有独立 link（Q8）。
- **tool group 合并保持行 ID 稳定**：聊天行 ID 是 `(消息 ID, .block(index))`；合并只改同一 block 的 `_content`（single → collapsed，lines 增长），列表看到的是同一行 reconfigure + 高度变化，不是删行插行（§6.8）。这支持 v7 用“首行 id 作 group id + 高度迁移兜底”的做法。
- **只有助手正文走 TextKit 2**；用户消息、工具卡、files、分隔线、working、footer、历史加载器全部走 `UIHostingConfiguration` 回退（§6.8）。AA 的 hosting 测量对非正文行是必需路径，不是临时替代。
- **审批卡不走 `askedToStay`**：`askedToStay` 的唯一来源是 `cancelEditing`（取消编辑后放回原分支后续行，避免拽到底部）（§6.8）。v7 的“审批出现停跟随 / 消失回底”是 AA 产品语义，不是官方同构。
- **图片高度**：附件 tile 有 `pixelSize` 时加载前即可定比例；搜索图库等异步图片加载完才长高一次（§6.8）。v7 把 `previewPixelSize` 放进签名，未知尺寸的图片按 pending 处理。
- **Markdown 尾部重排**从“改动段落的前一段”开始，宽度变化才全文失效；流式 TextKit 2 只重排尾部（§6.4）。这支持 v7 的增量解析方向；AA 的 Textual/离屏 hosting 仍需整行测量。
- **滚动动画每帧重问目标**：Mover 的 `UIUpdateLink` tick 每帧调用 target 闭包；目标变化 ≥1 个物理像素才改写当前目标，并按差值平移 pace，不重新起飞（§6.6）。飞行/缓动中内容长高可以连续追赶。
- **流式行高跟揭示进度，不跟数据到达**：`RevealDriver.clampedHeight` 把 intrinsic 高度钳在已揭示的行，每推进一段 `invalidateIntrinsicContentSize` → `heightDidChange`，揭示结束才解除（§6.7）。AA 的 Textual 揭示当前不改变 intrinsic 高度，是产品差异，不在 6b 范围。

### 13.2 与 v7 的差异（有意保留，写明原因）

| 项 | 官方 | v7 / AA | 原因 |
|---|---|---|---|
| 测量时机 | 新行先用估计，cell 物化后由 TextKit 2 / `heightDidChange` 实测 | apply 前离屏 hosting 测量 | AA 行是 SwiftUI/Textual，没有独立测量 API；spike 实测 `UIHostingConfiguration` 逐 tick 自测不可靠（§12.1） |
| 缓存档位 | estimate + measured 两档（`isMeasured`） | measured / precalc / estimate 三档 | 纯文本 precalc 是 AA 的加速路径；Markdown 仍只走 hosting |
| 历史锚点 | `placement.reading(RowID, offsetIntoRow)`；前插页用逐行估计 | group item + edge + `firstRowID` 修正/结算 | AA 顶层 cell 是 group，内部行不可寻址；group 合并需要 `firstRowID` 判页插入 |
| 底部命令 | `sent` → `placement.row(sent, .top)`；审批 `askedToStay`；拖动中忽略 `askedForEnd` | 发送/pending 回底；审批消失回底；强制命令无条件 | 对齐 AA 现状；6b 不改产品语义 |
| 自测高 | `setSelfSizingInvalidation:0`；cell 只在 `isMeasured=false` 时自测一次 | measured 行拒绝 preferred；fold/notice/tail 受控例外 | AA 的 SwiftUI hosting 行没有 `heightDidChange` 通道，受控例外需要 UIKit 自测失效通知 |
| 回底动画 | 自研 Mover + Spring（ease 0.4 / fly 0.36）+ `UIUpdateLink` | UIKit `setContentOffset(animated:)` + watchdog | 6b 不改动画机制；no-op 无回调已实测（§12.1） |
| 安全区 | `contentInsetAdjustmentBehavior = .never`，手动维护 inset | 保留 `.automatic` | AA 用 safeAreaInset/键盘；C4 第 0 步先并排校验采样差 ≤1pt |

### 13.3 对 C4/C5 的动作

1. **C4 第 0 步**：并排打印 SwiftUI 与 UIKit 的 viewport 五元组；差 >1pt 再决定是否改 `.never` 与手动 inset。
2. **C5 Markdown 外置解析**必须与测量输入一致（`row.text` + parsed blocks）；C3 gate 的代表行只证明机制，产品行一致性在 C5 重跑。官方只有助手正文是 TextKit 2，其余行是 hosting；AA 的 Textual 没有等价 API，不要在没有 UIKit renderer 的前提下假设 TextKit 2 快路径。
3. **tool group 合并**不要把“删行插行”当默认路径：同一 group 的行 ID 稳定时，只重配 + 改高；高度迁移仅作防御。审批卡不要套官方 `askedToStay`，它只服务取消编辑。
4. **流式 0.1s 节流**在 C4/C5 接线时落实；测量完成按 key 代际丢弃旧结果（`applyMeasuredHeight` 已 guard 当前 key）。底部跟随每次内容变化/帧重解析目标，阈值按 1 个物理像素（`1/displayScale`）而不是写死 0.5pt；流式揭示高度若以后做，按揭示进度而非数据到达。
5. **历史锚点**继续用 group item + row→group 映射；group 合并时迁移 `displayedHeight`（§3.4.5）。官方没有 `firstRowID`，不据此删掉 v7 的守卫。
6. **估算回退**：若 C2/C3 吞吐 p95 过高，再引入官方估算公式（Part Z §6.1：4000 字符上限、块距 12pt、默认 44/180）作为 pending 回退；当前不写死数字。

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
