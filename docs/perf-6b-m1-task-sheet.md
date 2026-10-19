# 6b-M1 任务单 v5：时间线容器替换（UICollectionView + 布局 + 插入补偿）

> 定级 **L**。依据：`docs/perf-plan-v2.md` 批 6b；官方证据 §2.6/§2.9；OpenMinis 参考见附录 C。
> **v5 修订**：v4 经两份独立审查（去重后 8 条 P1、3 条根因）；随后把原型扩到真实 `UIHostingConfiguration` cell、异步解析、inset、两种补偿判据、绝对 owed、持久底部目标（§12.0）。本版按实测逐条修复，§12 为修订台账。
> 架构拍板见 §0.1。

---

## 0. 目标

把 `ChatTimelineView` 的滚动容器换成 `UICollectionView` + 自研 `UICollectionViewLayout`，
**在同一次布局事务内**完成高度修正与插入补偿，行为逐条对齐现状，并消除"加载很多页后滚动卡"。

**验收**：行为清单全绿；1000 行窗口滚动无 >16ms 的 hitch（Release 真机，采集方法见 §7.4）；
开屏落底无可见滚动；上滑加载的视口位移 ≤ 现状 6.5。

### 0.1 架构拍板（v5）

| 决策 | 选择 | 理由 |
|---|---|---|
| 高度缓存键 | **稳定 item id + 内容修订号 + 宽度 + Dynamic Type 字号 + 排版修订号** | 前插会移动 `Int` 索引（P0-1）；离屏行内容更新后 measured 会失真（§12.0 二轮实测：45→265） |
| 异步内容闸 | **行模型提供 `settledRevision`；未 settled 时保留 precalc，不接受 cell 的占位首测** | hosting cell 首次 45 → 解析后 163；不设闸会把占位高写进 measured，行先塌再长（§12.0 四轮） |
| 插入补偿 | **绝对目标 `originOffset + (newAnchorY - originY)`，单参数 `targetContentOffset` 返回；finalize 兜底落地；update 事务内不再叠加 adjustment** | mid-list 实测 `originOffset=7458 → owedTarget=16658`，锚点位移 0；重复查询均返回 `9140`（§12.0 四轮） |
| 可见行补偿 | **增长点位于视口顶上方（`cell.minY < offsetY`，含部分可见）就补偿；用户滚动期间延迟的是尺寸（`deferSelfSizing`），不是补偿** | `fullyAboveOnly` 下方锚点位移 105pt；`aboveOrPartial` 为 0（§12.0 四轮） |
| 历史锚点修正落点 | **移进布局的 `targetContentOffset`**，不再用"布局后 `scrollTo`" | UIKit 下布局回调里没有安全的同步 `setContentOffset` 落点（P1-5）；官方同构；三轮实测锚点屏幕位移 0 |
| 底部目标 | **控制器持有"已武装的底部目标"，每次 contentSize/布局变化后重新解析，直到用户接管** | 一次性目标短差 365pt；流式 10 tick 布局只 pin 1 次、shortfall 264，控制器重解析后归 0（§12.0） |

> 因为 M1 已包含前插补偿，**M2 只剩"取消裁窗 + 用例语义更新"**。

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
| I13 | 历史锚点修正 | 见 §0.1：移进布局 `targetContentOffset` | `:484-499` |
| I14 | 尾部可见性 | near 探针 **96pt**、end 探针 **2pt** | `:695-705` |
| I15 | 提示可见性 | older 0.9 / latest 0.5 / tail near 0.01 / tail end 0.5 | `:610-616`、`:654`、`:695-705` |
| I16 | 内容坐标空间 | `.coordinateSpace("chat.timeline.content")` | `:708` |
| I17 | 开屏遮罩 | `.opacity(openingPositionSettled)` | `:69` |
| I18 | 抽屉/导航挂起 | 取消采样/pull/目标；恢复重放相位 + 重跑锚点 | `:49`、`:168-178` |
| I19 | 点空白收键盘 | `TimelineKeyboardDismissLayer` | `:291`、`:774-780` |
| I20 | 浮动"到底部" | `TimelinePillStack` | `:279-285`、`:736-770` |
| I21 | 行内容 | 分组 / notices / pending / tail | `:594-706` |
| I22 | 窗口整体替换 | `windowRevision` → `reassertOpeningReturn`（带守卫） | `:190-202`、`TimelineScrollState.swift:133-138` |
| I23 | 容器修饰符 | 指示器隐藏 / 始终回弹 / 顶部 soft edge effect / **`isOpeningReady` 期间禁手势与无障碍** | `:74-76`、`:94-95` |
| I24 | 内容列 | **16/20pt 自适应**（不是 24）、16pt 顶部、760 最大宽、居中、**组间距 20pt** | `ChatPageContentColumn.swift:13-20`、`ChatTimelineView.swift:594`、`:707` |
| I25 | 行内本地状态 | Markdown 解析、附件解码、复制反馈、reveal ledger、Textual 选区 | `ChatMarkdownView.swift:18-47`、`StreamingGlyphReveal.swift:45-49`、`ChatMessageAttachments.swift:126-130`、`SessionTimelineEventView.swift:296-350` |
| I26 | 快照更新语义 | 同 id 内容更新 / id 去重 / 队列与状态行的 SwiftUI 动画 | `:670-691` |
| I27 | 新 pending / 队列变化 → 回底 | `onChange(pendingMessages.last?.id)`、`onChange(sendQueue.items.map(\.id))` | `:179-186` |
| I28 | 流式回合变化 → 回底 | `onChange(responseRevision)` | `:187-189` |
| I29 | 审批卡出现/消失 | `setInteractionPresented`：出现停跟随，消失回底 | `:203-208`、`TimelineScrollState.swift:140-145` |
| I30 | 导航代际变化 → 释放目标 | `onChange(navigationGeneration)` | `:209-211` |
| I31 | 松手 64ms 后判定 reading/following | `settleUserScroll` | `:240-248`、`TimelineScrollState.swift:189-199` |
| I32 | 历史请求结算 | `HistorySettlement` + 64ms | `:256-267` |

---

## 2. 目标与非目标

### 目标（M1）
1. `UICollectionView` + 自研 layout + 三级高度缓存（`TimelineHeightKey`：id + 内容修订 + 宽度 + 字号 + 排版修订）+ 播种。
2. 单参数 `targetContentOffset(forProposedContentOffset:)`：append、prepend、容器尺寸变化。
3. `invalidationContext`：自测高度修正的 offset 补偿。
4. I1–I32 行为对齐；滚动性能显著优于现状。

### 非目标
- ❌ 取消裁窗 / 窗口上限调整 → M2
- ❌ TextKit 2、`UIUpdateLink` → 不在 6b
- ❌ 下拉规则变更 → 等 pp

---

## 3. 架构

### 3.1 组件（`UIViewControllerRepresentable`）

```
TimelineCollectionView: UIViewControllerRepresentable
 └─ TimelineCollectionController: UIViewController
      ├─ UICollectionView
      ├─ TimelineListLayout: UICollectionViewLayout
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

- **去重**：id 前缀化（`g:` / `n:` / `p:`）；重复时**首条胜出并记日志**，不用 `assertionFailure`
  （release 不拦，diffable 重复 id 会抛异常）。
- **内容更新**：`apply(animatingDifferences: false)`；
  每次呈现层 flush 后 `reconfigureItems(changedIDs)`。
  `changedIDs` 由**内容签名**决定（见 §3.2.1），覆盖 group、提示项、notice、pending、tail。
- `groupsByID` 每次 apply 前重建。

#### 3.2.1 内容签名（修正 P1-8）
- `group`：`rows.map(\.id)` + 每行 `revision`/`updatedSeq` 的序列（**不用 `layoutGeneration`**，它在追加时不递增）。
- `olderPrompt`/`latestPrompt`：`(pullReady, isLoading, keepsOlderPrompt)` 三元组。
- `pending`/`notice`：membership id 列表。
- `tail`：队列 id+状态 roster、`sendingPlaceholder` 是否存在、`hasNewerItems`。

### 3.3 Cell 与内容列（修正 P1-9 / P2-2）

- `TimelineHostingCell` + `UIHostingConfiguration`，按 item 分支。
- **水平边距 = 16（<414pt）/ 20（≥414pt）**，与 `ChatPageContentColumn.systemMargin` 一致；
- 最大宽 760、居中；**组间距 20pt**（`VStack(spacing: 20)` 的等价物）；
- 16pt 顶部只加在第一个 item；
- 队列/状态行/尾部**留在 `tail` 一个 item 内**（保留其 SwiftUI `.transition` 与高度动画），不拆分。

### 3.4 布局与高度模型（修正 P0-1 / P1-6 / P1-7）

```swift
struct TimelineHeightKey: Hashable {
    let itemID: String
    let contentRevision: Int   // 行的 revision/updatedSeq；内容变了必须换键
    let width: CGFloat         // 量化到 0.5pt
    let dynamicType: String    // UIContentSizeCategory.rawValue
    let typographyRevision: Int // ChatMetrics/ChatTypeSettings 的排版修订号
}

final class TimelineListLayout: UICollectionViewLayout {
    private var measured: [TimelineHeightKey: CGFloat] = [:]
    private var precalc:  [TimelineHeightKey: CGFloat] = [:]
    private var estimate: [TimelineHeightKey: CGFloat] = [:]
    private var streamingIDs: Set<String> = []          // 不是 Range
    var isAutoScrollPinning = false                     // 由 controller 每帧设置
}
```

- **键**：三档全部用 `TimelineHeightKey`。
  - **内容修订**：`changedIDs` 命中某 item 时，让它的 `contentRevision` 进键，并在 apply 前按新键重新播种。二轮实测反例：离屏流式行文本增长时 `measured` 仍是 45；进入视口后自测到 265、内容高度 +220，直接造成回底短差 220pt（§12.0）。
  - **内容修订的继承**：流式行每 tick 换键；新键在播种时继承上一键的 `measured`（不是回落到 estimate），这样 `invalidationContext` 的 delta 是相对上一帧显示高度，不是相对公式估算。
  - **字号/排版**：宽度、Dynamic Type 或 `typographyRevision` 变化时整档失效（`invalidateLayout` + 重播种）。
  - **`typographyRevision` 来源**：完整 `ChatTypeScale`（scheme/body/lineSpacing/paragraph/headings/inlineCode）的稳定哈希 + Bold Text + Dynamic Type；设置变化用 `NSUserDefaultsDidChangeNotification`（或设置页显式通知），trait 变化用 `traitCollectionDidChange`。不能只读三个 key（`ChatTypeSettings` 目前没有修订号）。
- **异步内容闸（P1）**：行模型提供 `settledRevision`（Markdown 解析完成、图片尺寸就绪）。布局只在 `settledRevision == contentRevision` 时接受 `preferredLayoutAttributesFitting`；此前保留 precalc/estimate，**不得让占位首测覆盖播种**。实测：hosting cell 首次 `45` → 解析后 `163`（§12.0）；若 45 被写入 measured，行会先塌再长。
- **缓存生命周期**：每个 item 只保留当前键（旧键删除）；item 离开快照时删除该 id 全部高度档；`prepare()` 的兜底不能用一个全局 `200`——按 kind 给默认值（提示 44、tail 12/32、普通行 200）。
- **`prepare()`**：纯算术；`measured → precalc → estimate → kindDefault`；维护 `itemAttributes` 有序数组。
- **`layoutAttributesForElements(in:)`**：二分定位区间，返回视口 ± 半屏；返回值用 `[UICollectionViewLayoutAttributes]`。
- **播种**：每次 snapshot apply **之前**，为新 item 和 `changedIDs` 写入 precalc（`NSAttributedString.boundingRect`，按 key 缓存）
  或 estimate（内容启发式）。不得覆盖已有 `measured`。**播种成本要有上限**：仅播种视口 ± 一屏的 item，其余按需/分帧；1000 行同步 `boundingRect` 不允许出现在开屏主线程。
- **实测回写**：布局在 `invalidationContext(forPreferredLayoutAttributes:withOriginalAttributes:)`
  收到 cell 的 preferred 高度；只有该行已 settled 才写入 `measured`，否则丢弃并保留播种值。

#### 3.4.1 offset 补偿判据（纯函数，可单测；v5 重写）

```
输入：cell 原 frame、preferred 高度、viewport、isStreaming、isArmedBottom、isUserScrolling、keyboardTransition
输出：offsetDelta 或 "deferSelfSizing"

1. isUserScrolling（tracking/decelerating）或 keyboardTransition → 延迟 self-sizing；不在此刻改 offset。
   松手/键盘过渡结束后一次性应用延迟高度并补偿。不存在"延迟补偿、不延迟尺寸"。
2. isStreaming + isArmedBottom → 贴底：同事务能 pin 就 pin；不能则交给控制器的
   持久底部目标在 contentSize 变化后重解析（实测 10 tick 只有 1 次自测回调）。
3. cell.minY < offsetY（增长点位于视口顶上方，含部分可见）→ delta。
4. cell 完全在视口下方 → 0（除非第 2 条）。
5. cell 完全可见且非流式 → 0。
6. 其余 → 0。
```

> 实测（§12.0 四轮）：部分可见异步行增长，`aboveOrPartial` 下方锚点位移 **0**；`fullyAboveOnly` 位移 **105**（同步增长场景 **79**）。旧第 4 条「部分可见 → 0」删除。
> 用户滚动期间必须延迟的是**尺寸**；只延迟补偿在物理上不成立（尺寸生效即已位移）。

#### 3.4.2 插入补偿：绝对目标（v5 重写）

单参数 `targetContentOffset(forProposedContentOffset:)`（**不是** `...withScrollingVelocity:` 重载）返回 **绝对目标**：

```
target = originOffset + (newAnchorY - originY)
```

- `originOffset`：请求开始时的静止偏移，**必须**是 `max(-topInset, offsetY)`（现状 `TimelineHistoryPosition.init` 的过冲钳制；单测 `outwardPullRestoresTheRestingInsetInsteadOfKeepingOverscroll` 期望 920）。v4 只传 `(anchorRowID, edge, y)` 无法重建它。
- `newAnchorY - originY`：锚点在新旧布局中的 y 差。
- 返回绝对值而不是 `proposed + delta`：同一事务内 UIKit 可能查询多次；绝对值天然幂等（实测 `9140` 两次）。
- `owedConsumed`：首次查询置位；`finalizeCollectionViewUpdates` 若仍未被消费，直接 `setContentOffset(target)` 兜底，然后清零。
- **事务闸**：`prepare(forCollectionViewUpdates:)` 进入、`finalize` 退出；事务内 `invalidationContext` 不产生 `contentOffsetAdjustment`（官方 `isInsideAnUpdate` 同构），避免与 owed 叠加。
- **锚点是 group item，不是 row id**：前插页与锚点行可能合并进同一个 tool group；布局必须用“包含 `anchorRowID` 的 group item + 存储的 edge”求 y（现状 `ChatTimelineView.swift:589-591` 的 `groups.first { $0.rows.contains(...) }`）。
- **append**：新 item 全在视口下方 → 目标 = 当前 offset（`owed` 为 0）；底部钉住由持久底部目标负责。
- **容器尺寸变化**：不在此处处理，走 I6 的显式重算。
- **实测（§12.0 四轮）**：mid-list 前插 `originOffset=7458 → owedTarget=16658`，锚点屏幕位移 0；重复查询 `9140/9140`；带 top inset 60。

历史锚点（I13）由此**不再需要布局后的 `scrollTo`**：把 `TimelineHistoryPosition` 的
`origin（anchorRowID, edge, y）` **和 `originOffset`** 一起传给布局，布局在
`prepare(forCollectionViewUpdates:)` 里用新旧 attributes 求差，返回绝对目标。

> 实现落点：`TimelineHistoryPosition.originOffset` 现在是 `private`，需要暴露为只读，或抽一个
> `TimelineInsertionTarget { originOffset, anchorItemID, edge }` 纯类型交给布局；
> 同时控制器在 apply 前提供 `rowID -> group item id` 映射（合并 group 用），布局不能拿 row id 直接当 item id。

### 3.5 采样与相位（修正 P1-10 / P1-11）

**采样公式**（必须与 SwiftUI `ScrollGeometry` 并排验证一次）：

```
containerHeight = collectionView.bounds.height
topInset        = adjustedContentInset.top
bottomInset     = adjustedContentInset.bottom
offsetY         = contentOffset.y
contentHeight   = contentSize.height
```

> `safeAreaInset` 缩短的是 **safe area**，不是 `bounds`。采样用 `bounds.height + adjustedContentInset`，
> 但要并排校验，避免把同一份输入条高度在 bounds 与 inset 里各算一次。C4 第一步：并排打印 SwiftUI 与 UIKit 采样值，差值必须 ≤ 1pt。

**采样触发**：`scrollViewDidScroll`、`contentSize` KVO、`adjustedContentInset` KVO、
`viewSafeAreaInsetsDidChange`、`viewDidLayoutSubviews`。

**相位合成**（不假设 1:1 映射）：

| 事件 | 合成相位 |
|---|---|
| `scrollViewWillBeginDragging` | `.interacting`（`.tracking` 在 UIScrollView 无来源，明确不产生） |
| `scrollViewDidEndDragging(willDecelerate:)` | 否 → `.idle`；是 → `.decelerating` |
| `scrollViewDidEndDecelerating` | `.idle` |
| `setContentOffset(animated:)` 开始 / `scrollViewDidEndScrollingAnimation` | `.animating` / `.idle`（`contentOffset` 不能交给 `UIViewPropertyAnimator` 动画） |
| `scrollViewShouldScrollToTop` / `scrollViewDidScrollToTop` | `.animating` / `.idle`（状态栏点按回顶的相位源） |
| 其余 | 不变 |

> **动画完成看门狗（实测）**：`setContentOffset(animated:)` 的目标等于当前 offset 时，
> `scrollViewDidEndScrollingAnimation` **不回调**（no-op 实测 0 次）。普通回底也要加“动画时长 + 1 帧”的 watchdog；
> `scrollViewWillBeginDragging` 立即 complete 当前命令。程序化中断实测会回调 1 次，但用户拖拽中断不能依赖它。

> `.tracking` 缺失会影响 `pull.begin` 的起点吗？`phaseChanged` 的 `wasInteracting` 在 idle→interacting
> 时恒为 false，与现状相同。C1 用独立事件序列单测锁定；C4 真机做**逐事件日志对比**。

---

## 4. 逐项对接

> 只列与 v2 不同的、或审查点名的项；其余按 §3 的机制直接推导。

- **I1/I31**：相位合成见 §3.5；`settleUserScroll` 的 64ms 任务原样保留。
- **I2/I3**：采样与发布见 §3.5；禁止在原生回调里直接写 SwiftUI `@State`。
- **I4**：底部目标**持久化**（§0.1）：控制器保存 `armedBottomTarget`，并定义真值：
  - 武装：开屏（I4）、发送/新 pending（I27）、流式回合（由 `contentSize`/几何路径驱动，**不是** `responseRevision`）、审批卡消失（I29）、窗口重断言（I22）。
  - 解除：用户开始拖拽（`scrollViewWillBeginDragging`）、历史浏览（`browseHistory`）、审批卡出现（I29）、导航挂起。
  - 重解析：每次 `contentSize` 变化都重算底部并贴住，**不只开屏**。实测流式 10 tick 布局只 pin 1 次、shortfall 264；控制器重解析后归 0（§12.0 四轮）。
  - `finishScrollToBottom` 若会清 `armedBottomTarget`，必须只清“当前命令”，不能把“用户仍在底部”的语义一起清掉；400ms 兜底先 complete 再 settle。
  - 两段收敛：`layoutIfNeeded` → 算 → 设 → 复测；连续两次 `contentHeight` 不变且可见 cell 已测量才算稳定。
- **I5**：`setContentOffset(_:animated:)` + `scrollViewDidEndScrollingAnimation` 合成相位。
  `UISpringTimingParameters(response:dampingRatio:)` 不存在，且 `contentOffset` 不可交给 `UIViewPropertyAnimator` 动画，不要再走这条（P1）。
  Reduce Motion 直接设；中断用 `setContentOffset(..., animated: false)` 结算。
  - **no-op 不回调**（实测 0 次）：普通回底也加“动画时长 + 1 帧”的 watchdog；`scrollViewWillBeginDragging` 立即 complete 当前命令。
  - `setContentOffset(animated:)` 的曲线与现状 `interactiveSpring(response:0.28, dampingFraction:1)` 不完全一致；接受该手感差异，或用 CADisplayLink 近似（单独验收）。
- **I6**：内容或容器尺寸变化都按 `shouldPin` 语义处理；容器变化在 `viewSafeAreaInsetsDidChange`/`layoutSubviews` 后显式重算。
- **I10/I11**：**下拉规则不变**（§2）：仍用 `TimelineHistoryPull` 的 2pt `contentHeight`/`visibleHeight` 闸 + 24pt 位移 + `wasInteracting`；新容器把同样的 `TimelineViewport` 采样喂给现有纯类型。用户滚动期间 `deferSelfSizing` 保证内容高度不在手指下变化；若真机仍测到变化，再按纯函数扩展，不在 M1 改规则。
- **I12/I13**：见 §3.4.2。
- **I18**：挂起时取消；恢复时重放相位，且 `historyLayout != nil` 时重跑锚点重算。
- **I22**：`windowRevision` 变化时，只在 `!readerTookOver && !navigationIsSuspended && hasOpened` 时重跑 I4（P2-3）。
- **I23**：`isOpeningReady` 期间禁手势/无障碍（不是 `openingPositionSettled`）。
  iOS 直接设 `collectionView.topEdgeEffect.style = .soft`；`ChatPageScrollEdge` 只在 Catalyst 编译（`ChatPageScrollEdge.swift:8-12`），Catalyst 的注册逻辑放进 collection controller 的 `didMoveToWindow`/`viewDidLayoutSubviews`，不能放在 representable 的 `.background`（祖先链找不到 collection view）。
- **I26**：`animatingDifferences: false`；尾部内部的队列/状态行动画保留。
- **I27/I28**：I27 的 pending/队列变化按现状回底；**I28 的 `responseRevision` 只在交互审批被接受时递增，不覆盖流式**（`SessionChatModel.swift:666`）。流式跟随由 I4 的持久底部目标 + `contentSize` 变化驱动，不要按 `responseRevision` 实现。
- **I21/I26 引用修正**：I21 的分组输入还包括 `interactionTargets` 与 `TimelineTurnActions.build`（`ChatTimelineView.swift:580-586`）；I26 的“同 id 内容更新/id 去重”在 `SessionTimelinePresentation`，不在 tail 的 `:670-691`。

---

## 5. 并发与时序

| 问题 | 答案 |
|---|---|
| 状态归谁所有 | 滚动状态 `TimelineScrollState`；controller：`nativePhase`、`armedBottomTarget`；数据 `SessionChatModel`；高度 `TimelineListLayout` |
| 顺序 | UIKit delegate 主线程串行；无自定义队列 |
| 重复 | 相位只在变化时上报；采样去重；快照 apply 幂等 |
| 取消 | 导航挂起/抽屉/用户接管取消目标与动画；任务取消不回写 |
| **重入** | `setContentOffset` 会同步触发 `didScroll`。规则：原生回调**只投递样本**；offset 变更一律经异步合并器；布局内的 `targetContentOffset` 由 UIKit 自己应用，不属于重入路径 |
| 锁 | 布局在主线程调用，`streamingIDs` **不需要锁**（v2 的锁前提错误，P2-1）；若未来发现后台 prepare，再加锁并记录证据 |

---

## 6. 兼容与回退（修正 P2-11）

- 不改数据契约、不改 `V2SessionRepository`、不改投影。
- C1 往 `Models` 加**纯算术**类型（可测），不是"不改 Models"。
- 每个提交可独立 revert；C6b 删除旧路径后，**revert C6b 即恢复旧路径**（不需要回退 C5）。
- **运行时回退**：`UserDefaults` key `aa.timeline.collectionView`，默认 **off**；另加 DEBUG 启动参数/环境变量
  `AA_TIMELINE_COLLECTION_VIEW=1`（或 `-aa.timeline.collectionView YES`），写进 C4/C5 出包说明——否则 pp 拿到的包永远跑旧路径。
  开关关闭时走旧 `ScrollView` 路径——两套路径在 C6b 之前同时存在。
- **C6 拆两步**：C6a 翻默认值并观察一个版本；C6b 删除旧路径。不要在同一个提交里既翻默认又删回退路径。
  > 这条是对 v2 的修正：L 级 UI 重写不能只靠提交级回退。

---

## 7. 测试

### 7.1 纯逻辑单测（必须住 `Models`，不能住 `Views`）
1. `TimelineItemIdentity`：顺序、去重（首条胜出）、四类提示。
2. `TimelineVisibilityProbe`：**写死 96pt / 2pt 探针矩形与相交定义**，用手算夹具，不复用实现公式。
3. `TimelineOffsetTarget`：底部 offset（含 inset 钳制、sub-viewport）。
4. `TimelinePhaseMapping`：独立事件序列 → 相位；覆盖"`.tracking` 永不产生"与"动画完成"。
5. `TimelineContentSignature`：group/提示/pending/tail 的变化检测，含"流式追加 revision 不变"用例。
6. `TimelinePreferredAttributesDecision`：§3.4.1 的六条判据逐条；必须覆盖“部分可见（minY<offsetY）→ 补偿”“用户滚动 → deferSelfSizing”“流式 + armed → 贴底”。
7. `TimelineInsertionOwed`：绝对目标 `originOffset + (newY-oldY)`；**断言"锚点行屏幕位置不变量"（delta≈0）**，不写 `old-new` 符号假设；调用两次返回同一值；过冲钳制期望 920。
8. `TimelineHeightKeying`：宽度 0.5pt 量化、字号变化失效、**内容修订变化必须换键**；`typographyRevision` 由完整 `ChatTypeScale` 哈希得出。
9. `TimelineOffscreenRevision`：模拟"离屏行内容更新 → 进入视口"，旧 measured 不得复用（复现 §12.0 二轮 45→265）。
10. `TimelineArmedBottomTarget`：每次 contentSize 变化后重解析；开屏/发送/流式/审批消失都武装；用户拖拽/历史浏览/审批出现解除。
11. `TimelineOneShotOwed`：绝对目标；两次查询返回同一值；未消费时 finalize 兜底；`owedConsumed` 清零。
12. `TimelineAsyncSettled`：settled 前不接受 preferred 高度；settled 后只测量一次（§12.0 四轮 45→163）。
13. **布局必须委托这些纯类型**：`TimelineListLayout` 直接持有并调用它们，而不是在 `Views` 里另写一份；加 DEBUG 断言（finalize 时 owed 未消费应为 0；measured 键与当前 revision 一致），否则纯类型测试全绿也证明不了调用点（`Package.swift:11-15` 把 Views 排除在测试目标外）。

### 7.2 真机清单（补充 P2-9）
1. 冷开最新会话：落底、不闪
2. **1000 行窗口**（M1：从底部连续翻 9 页达到约 1000 行；“1000 行冷开”属 M2，因为 `open()` 裁到最新 100 行）：落底、不闪
3. 快速上下甩动 10 次：无 >16ms hitch（Release）
4. 上滑加载 3 页：锚点不劣化；**加载后下拉提示仍可用、锚点仍触发**（6a 回归判据）
5. 下拉加载更新：起手时提示可见才加载
6. 键盘弹起/收起：最新行贴输入条
7. 输入框长高/变矮：同上
8. 抽屉滑出/滑入：不误判；关闭后锚点仍生效
9. 浮动"到底部"出现/消失时机一致；状态栏点按回顶正常
10. 流式：新行从底部出现、不跳；**工具组持续追加行可见**
11. 流式结束：footer/复制操作出现
12. 滚走再滚回 + **首次滚过未解析页**：Markdown/图片/reveal 无可见重解析；首次物化不得先塌后长（§12.0 四轮 45→163）
13. 新增消息/前插历史：**无插入动画**
14. **测量后旋转 / 改动态字号，继续滚动**：行高正确、不重叠
15. **发送后回底 / 审批卡出现停跟随、消失回底**（I27–I29）
16. 旋转/分屏（iPad）：内容列 16/20 边距正确、760 居中
17. 滚动条不出现；短内容回弹；开屏期间 VoiceOver 不读内容
18. **Catalyst**：状态栏点按回顶、导航栏 scroll edge 仍注册
19. **异步 Markdown 首次物化**：加载 3 页，页内含长回复；甩动穿过，视口内内容不因解析完成跳位
20. **队列新增/删除动画、状态行 12↔32**：in-flight 不裁切、不瞬变
21. **动画/流式期间内容增长**：底部目标仍贴底（shortfall≈0），无二次回弹
22. **no-op 回底**：已在底部时点回底，相位不卡 `.animating`（watchdog 生效）

### 7.3 已知测不到（必须写进汇报）
- UIKit delegate 的真实事件顺序（只能真机日志逐事件对比）。
- `UIHostingConfiguration` 复用时的行内状态（只能真机 12 号）。
- 真实 Markdown 解析耗时/图片解码（spike 用 600ms 模拟）；用户拖拽（`simctl` 不能合成触摸，需 XCUITest）。
- Catalyst 运行时。

### 7.4 性能验收（修正 P2-10）
- **Release 真机**（不是 Debug），机型记录在案。
- 采集：新增 `CADisplayLink` 采帧（与官方 `FrameHitchRecorder` 同口径：>16/>25/>75/>700ms），
  `AA_PERF_SIGNPOST` 关闭时零成本。
- 判据：1000 行窗口连续滚动 10 秒；主判据 = **>16ms 的帧占比 < 5%**；硬失败 = 出现任一 >75ms 帧（两者不是二选一）。
- 1000 行窗口构造：从底部连续翻 9 页（每页 100）后开始测；不要用冷开。
- “≤ 现状 6.5”的测量：同一组上滑 3 页操作，记录锚点行屏幕 Y 的最大位移；基线在 `47fd9408` 上采，注明机型和页数。
- 基线：先在当前 HEAD `47fd9408` 上采一次，PR 里贴前后数字。

---

## 8. 分步提交

| 提交 | 内容 |
|---|---|
| C1 | `Models` 纯逻辑（§7.1 的 13 组）+ 单测 |
| C2 | `TimelineListLayout`（id+修订键、settled 闸、三级缓存、prepare、LAFE 二分、补偿判据、绝对 owed、事务闸） |
| C3 | `TimelineCollectionController` + `UIViewControllerRepresentable` 骨架；用真实 hosting cell 跑一遍模拟器探针（C3 门） |
| C4 | 接线 I1–I9、I27–I32（相位、采样、开屏、键盘、跟随、动画 watchdog） |
| C5 | 接线 I10–I26（pull 保持现状、锚点、提示、窗口替换、修饰符、内容列） |
| C6a | 翻转 `aa.timeline.collectionView` 默认值，观察一个版本 |
| C6b | 删除旧路径 |

C4/C5 后各出一次包；开关默认 off，pp 验完再翻。

---

## 9. 事前验尸（含 6a 教训）

1. **开屏落顶/落错**：首布局 contentSize 未稳定 → 两段收敛 + 400ms 兜底（先 complete 再 settle）。
2. **键盘弹起页面上移/下拉**：viewport 双重扣减或 sizeChanges 判据错 → §3.5 并排校验 + 真机 6/7。
3. **滚动中实测修正拽走视口**：§3.4.1 判据错或 `defer` 语义错 → 真机 3/14。
4. **前插后全行错高**：缓存仍用索引键 → 单测 8 必绿 + 真机 4。
5. **加载 3 页后下拉失效**（6a 原样复发）→ 真机 4 合并验证。
6. **cell 复用丢行内状态** → 真机 12。
7. **离屏行内容更新后高度失真**：measured 不随内容修订失效 → 滚回/回底短差（二轮实测 220pt）→ §3.4 键含 revision；真机 12/14。
8. **底部目标一次性解析**：从顶部跳底差 365pt（三轮实测）→ §0.1 持久武装 + §7.1 第 10 条。
9. **hosting cell 不按 tick 重测**：流式 10 tick 只有 1 次自测高回调、布局只 pin 1 次 → 控制器每次 contentSize 变化重解析；否则 shortfall 264（§12.3）。
10. **no-op 回底卡相位**：目标等于当前 offset 时回调 0 → watchdog + `scrollViewWillBeginDragging` complete（§3.5/I5）。
11. **异步解析首帧占位高覆盖播种**：settled 闸 + precalc 不被覆盖；真机 12/19。
12. **估算精度无验收**：未测行从估算到实测的位移没有门 → 抽样精度门 + 真机“连续上滑 1000 行”用例（§7.2 #19）。

---

## 10. 审查修订对照（v3 + v4 运行时证据）

| 审查项 | 落点 |
|---|---|
| P0-1 Int 键 | §3.4 `TimelineHeightKey`；§7.1 第 8 条 |
| P1-1 持久底部目标 | §0.1、§4 I4 |
| P1-2 兜底未 complete | §4 I4 |
| P1-3 插入无补偿 | §0.1、§3.4.2；M1 范围 |
| P1-4 漏 follow 链路 | §1 I27–I32；§4 I27–I32 |
| P1-5 同步/异步矛盾 | §0.1、§3.4.2（锚点移入布局） |
| P1-6 宽度/字号失效 | §3.4 键；§7.2 第 14 条 |
| P1-7 补偿判据 | §3.4.1 六条（v5 重写） |
| P1-8 提示不在 changedIDs | §3.2.1 内容签名 |
| P1-9 边距写错 | §3.3、§1 I24 |
| P1-10 采样公式 | §3.5 |
| P1-11 相位非 1:1 | §3.5 相位合成 |
| P2-1 锁前提错误 | §5 最后一行 |
| P2-2 去重不用 assert | §3.2 |
| P2-3 I22 守卫 | §4 I22 |
| P2-4 禁手势的门 | §4 I23 |
| P2-5 收敛顺序 | §4 I4 |
| P2-6 队列动画/拆分 | §3.3、§1 I26 |
| P2-7 探针尺寸 | §1 I14 |
| P2-8 测试空白 | §7.1 全部、§7.3 |
| P2-9 真机缺口 | §7.2 |
| P2-10 验收不可测 | §7.4 |
| P2-11 回退矛盾 | §6 运行时开关 |
| P2-12 6a 教训 | §9 第 5 条 |
| P2-13 Catalyst | §7.2 第 18 条 |
| P2-14 OpenMinis 证据 | 附录 C 标注"未在本工作区复核" |
| v4 运行时四问 | §12.0（run `39204102103`） |
| v4 回底短差 | §0.1、§4 I4、§7.1 第 10 条 |

---

## 11. 开工前置条件

1. pp 审阅 v5（§12.1 + §12.4 的处置）。
2. pp 确认下拉规则维持现状（本版已按“不变”落）。
3. 基线 `47fd9408`；先采一次性能基线（§7.4）。
4. ✅ `spike/6b-collection` 已跑四轮模拟器：真实 hosting cell、异步解析、绝对 owed、持久底部目标均已实测；用户拖拽仍未测（§12.3）。
5. 拖拽项不阻塞 C1：pull 保持现状闸门，`deferSelfSizing` 兜住拖拽期尺寸变化；若真机 4 号复现 6a 失效，再补 XCUITest。
6. v5 通过聚焦审查后开 C1；C3 出包前必须用真实 hosting cell 跑一遍同一探针（C3 门）。

---

## 12. v5 修订台账（运行时原型结论 + 两轮审查处置）

### 12.0 运行时原型结论（已实测）

> 环境：GitHub Actions `macos-26` / Xcode 26.5 / iPhone Air 模拟器 / iOS 26.5 / 视图 420×635。
> 代码：`spike/6b-collection` @ `b3177dc2`（一次性分支，验完删除）。
> 证据：run `39204102103` 的 artifact `spike-autorun.json`；前两轮 `39202055415`、`39202972950` 保留作缺陷对照。
> 时间：2026-10-19 13:30 CST。模拟器与真机共用 UIKit，语义结论可迁移；手感/性能仍需真机验收。

| # | 问题 | 实测 | 结论 |
|---|---|---|---|
| 1 | 无动画 diffable apply 是否调用 `targetContentOffset(forProposedContentOffset:)` | `targetOffsetCalls=1`，`proposed=0`，`returned=9200` | ✅ 调用 |
| 2 | 一次性 `owed` 是否落地 | 锚点 `item-1` 屏幕 Y `0→0`（`anchorScreenDeltaY=0`）；内容高度 `112416→121616`（+9200） | ✅ 落地；符号 = `newAnchorY - oldAnchorY` |
| 3 | 自测高 invalidation 是否到达 | 可见流式行 10 tick：`reconfigure=10`、`shouldInvalidate=10`、`invalidationContext=10`；measured `45→265`，content `131181→131401` | ✅ 回调链成立；但 `contentOffsetAdjustment` 分支未执行（spike 只测完全在视口上方），见 §12.3 |
| 4 | 拖拽中 `contentHeight` 是否变化 | 未测（`simctl` 不能合成触摸，需 XCUITest） | ⏳ 未测；按 §3.4.1/§7 的保守判据推进 |
| 5 | 回底是否到底 | 从顶部瞬时跳底：`shortfall=365pt`；按新 contentSize 重算后 `0` | ❌ 一次性目标不够；§0.1 持久武装必要 |

补充证据（二轮 `39202972950`，流式行被挤出视口）：
- 离屏行的 `measured=45` 未随文本增长；动画回底把它带入视口后自测到 `265`，内容 +220，`shortfall=220`。
- 直接证明 P1 #6：**高度缓存键必须含内容修订号**，否则离屏更新会留下陈旧高度。
- 该轮流式 `shouldInvalidate=0`、`streamingItemVisible=false`，不能用来判断自测链路；三轮已修正。

计时（仅参考，不作为预算）：三轮 tick `avg=19.44ms`、`max=31.9ms`（模拟器；包含 spike 自身的 O(n) 全量重建，M1 走高度缓存 + 只动变化行，不能用这个数当验收基线）。

### 12.1 十条 P1 的处置

| # | 原问题 | v4 处置（落点） |
|---|---|---|
| 1 | owed 符号写反 | 已改 `newAnchorY - oldAnchorY`；三轮实测 +9200 落地（§3.4.2、§12.0） |
| 2 | 用错重载 | 改为单参数；三轮实测被调用（§3.4.2、§12.0） |
| 3 | owed 无一次性闸 | 首次查询置 `owedConsumed`；`finalizeCollectionViewUpdates` 未消费则兜底 `setContentOffset` 后清零；两次查询同一绝对值（§7.1 第 11 条） |
| 4 | 动画 API 不存在/不可动画 | 改 `setContentOffset(animated:)` + `scrollViewDidEndScrollingAnimation`；**no-op 不回调（实测 0），普通回底加 watchdog**（§4 I5、§3.5） |
| 5 | 漏 `shouldInvalidateLayout(forPreferredLayoutAttributes:)` | 显式返回 true；三轮实测 10/10（§3.4） |
| 6 | 高度键缺内容版本 | 键加 `contentRevision`；二轮实测 45→265/短差 220 为反例；§3.4、§7.1 第 9 条 |
| 7 | 高度键缺字号/行距 | 键加 `typographyRevision`；来源与观察点见 §3.4（本轮未测，保留） |
| 8 | 判据第 4 条每批跳 | **v5 重写为 `aboveOrPartial`**（`minY < offsetY` 就补偿）；实测旧判据下方位移 105，新判据 0（§3.4.1、§12.3） |
| 9 | pull 的 2pt contentHeight 闸 | **保持现状闸门**（2pt + 24pt + `wasInteracting`）；`deferSelfSizing` 兜住拖拽期尺寸变化；不改规则（§4 I10） |
| 10 | cell 复用丢行内状态 | 状态外置到行模型/有界缓存；真机 12 号验收；不降低验收口径 |

### 12.2 第三轮 P2（原清单备查；v5 在各节给出落点，未单列的按原句执行）
- 状态栏点按回顶缺相位源（`scrollViewShouldScrollToTop`/`DidScrollToTop`）
- §5"offset 一律异步"与 I8 键盘逐帧钉底冲突：键盘窗口内允许同步 `setContentOffset`，带重入闸
- `isAutoScrollPinning` 的真值来源未定义；审批卡出现（I29）后仍会贴底
- 内容列：先加 16/20 边距再限 760 → iPad 正文实际 720；20pt spacing 作用于所有顶层 item
- iOS 顶部 soft edge effect：`ChatPageScrollEdge` 仅在 Catalyst 生效，iOS 需直接设 `collectionView.topEdgeEffect.style`
- 播种成本无预算：1000 行同步 `boundingRect` 在主线程，需要成本上限或懒播种
- 运行时开关切换会因 `TimelineScrollState.hasOpened` 卡在顶部，需要重置状态
- 签名覆盖不全：`turnAction` footer、状态行 orb 活动
- 历史结算 64ms/`isPositionedByUser` 的归属未交代
- 测试 7 已改为"屏幕位置不变量"断言（§7.1 第 7 条）
- `safeAreaInset` 前提写错（缩的是 safe area，不是 bounds）
- contentSize 变化会重新引入 body 风暴 → 纯测量修正走非失效通道
- 验收口径已在 §7.4 拆清：主判据 >16ms 占比 <5%，硬失败任一 >75ms；采帧器单独埋点提交

### 12.3 v5 扩展原型（真实 hosting cell / 绝对 owed / 持久底部）

> 环境：同上；代码 `spike/6b-collection` @ `f2382492`；run `39208410042`；时间 2026-10-19 14:17 CST。
> cell 换成 `UIHostingConfiguration`；异步行先渲染占位 `…`，600ms 后填充 blocks（模拟 `ChatMarkdownView` 的 detached parse）；top inset 60。

| 探针 | 实测 | 结论 |
|---|---|---|
| hosting cell 异步解析 | 首次 `45` → settled `163`；shouldInvalidate/invalidationContext 各 1 | ✅ hosting cell 会重新上报高度 |
| 部分可见 + aboveOrPartial | 下方锚点位移 `0`；adjustmentApplied=1 | ✅ 新判据成立 |
| 部分可见 + fullyAboveOnly | 下方锚点位移 `105`；adjustmentApplied=0 | ❌ 旧判据是 bug |
| 同步增长 aboveOrPartial / fullyAboveOnly | `0` / `79` | 同上 |
| mid-list prepend（inset 60） | `originOffset=7458 → owedTarget=16658`；锚点位移 0；content +9200 | ✅ 绝对目标 |
| owed 重复查询 | `9140` / `9140` | ✅ 幂等 |
| 流式 + pinning | 10 tick 仅 1 次自测高/1 次 pin；shortfall 264；控制器 repin 后 0 | ❌ 不能只靠布局同事务 pin |
| 动画 no-op | `didEndScrollingAnimation=0` | ❌ 需要 watchdog |
| 程序化中断 | `didEnd=1`，停在中断点 | 仅说明回调会来；用户拖拽仍未测 |
| 首帧塌缩 | 首次 45（占位）→ 163（解析后） | ⚠️ 需要 settled 闸 + 预播种，避免占位覆盖 |

未测：用户拖拽（`simctl` 不能合成触摸）；真实 Markdown 解析耗时（探针用 600ms 模拟）；Catalyst；真机手感/性能。

### 12.4 v5 对两份审查 8 条 P1 的处置

| # | 根因 | 处置（落点） |
|---|---|---|
| 1 | 高度模型假设内容稳定（Markdown/hosting） | `settledRevision` 闸；precalc 不被占位首测覆盖；C3 用真实 hosting cell 探针门（§3.4、§8 C3） |
| 2 | 补偿判据顺序/部分可见 | §3.4.1 重写：`aboveOrPartial`、`deferSelfSizing`、流式优先 |
| 3 | owed 是 delta、无过冲钳制、无 finalize 落地 | §3.4.2 绝对目标 + `originOffset` + finalize 兜底 + 事务闸 |
| 4 | 底部目标只覆盖开屏/一次性 | §4 I4 真值表 + 每次 contentSize 重解析；C4 出包验 |
| 5 | 动画中断/no-op | §3.5/I5 watchdog + `scrollViewWillBeginDragging` complete |
| 6 | pull 规则被改但未定义 | §2/§4 I10：**保持现状 2pt/24pt 闸**；`deferSelfSizing` 兜住拖拽期高度变化 |
| 7 | 验收不可执行（开关/1000 行） | §6 DEBUG 启动参数；§7.2 #2 改为 M1“翻 9 页”；冷开移到 M2 |
| 8 | 估算精度无验收 | §7.2 #19 + §7.4 抽样精度门/连续上滑用例 |

> 第三轮 10 条 P1（§12.1）与第三轮 P2（§12.2）继续有效；本表只列 v4 新增的 8 条。

---

## 附录 C · OpenMinis 参考（**二手证据，未在本工作区复核**）

上游 `OpenMinis/OpenMinis`（GPL-3.0），`src/ios/Agent/MessageList/`：

| 机制 | 位置 |
|---|---|
| 自研 layout | `MessageListLayout.swift:15` |
| 三级缓存 | `MessageListLayout.swift:32/38/142` |
| `prepare()` 纯算术 | `:191-282` |
| 可见区 ± 半屏 + 提前 break | `:289-311` |
| `contentOffsetAdjustment` 三分支 | `:551-577` |
| 浏览期 `deferSelfSizing` | `:66` |
| diffable + prefetch | `CollectionViewMessageListV3.swift:1164/874` |
| 快照前播种 | `:2924-3150` |
| apply 期间抑制补偿 | `:3300-3305` |

> 上述行号来自上游快照，未在 AA 工作区复核；引用时以实际拉取的源码为准。
> 许可证 GPL-3.0：**只照设计重写，不复制代码。**
