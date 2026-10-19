# 6b-M1 任务单 v3：时间线容器替换（UICollectionView + 布局 + 插入补偿）

> 定级 **L**。依据：`docs/perf-plan-v2.md` 批 6b；官方证据 §2.6/§2.9；OpenMinis 参考见附录 C。
> **v3 修订**：v2 经第二轮独立审查（1 P0 / 11 P1 / 14 P2），本版逐条修复。
> 三处架构拍板见 §0.1。

---

## 0. 目标

把 `ChatTimelineView` 的滚动容器换成 `UICollectionView` + 自研 `UICollectionViewLayout`，
**在同一次布局事务内**完成高度修正与插入补偿，行为逐条对齐现状，并消除"加载很多页后滚动卡"。

**验收**：行为清单全绿；1000 行窗口滚动无 >16ms 的 hitch（Release 真机，采集方法见 §7.4）；
开屏落底无可见滚动；上滑加载的视口位移 ≤ 现状 6.5。

### 0.1 三处架构拍板（回应第二轮审查）

| 决策 | 选择 | 理由 |
|---|---|---|
| 高度缓存键 | **稳定 item id + 宽度 + Dynamic Type 字号** | 前插会移动 `Int` 索引，索引键必然错位（P0-1） |
| 插入补偿 | **M1 内实现 `targetContentOffsetForProposedContentOffset`（append + prepend 都做）** | 否则 `.sizeChanges` 的贴底语义补不回来，流式跟随只能异步追平（P1-3） |
| 历史锚点修正落点 | **移进布局的 `targetContentOffset`**，不再用"布局后 `scrollTo`" | UIKit 下布局回调里没有安全的同步 `setContentOffset` 落点（P1-5）；官方同构 |
| 底部目标 | **控制器持有"已武装的底部目标"，内容尺寸变化后重新解析，直到用户接管** | 一次性 `setContentOffset` 丢失了 `ScrollPosition` 的持久语义（P1-1） |

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
1. `UICollectionView` + 自研 layout + 三级高度缓存（id 键）+ 播种。
2. `targetContentOffsetForProposedContentOffset`：append、prepend、容器尺寸变化。
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
    let width: CGFloat       // 量化到 0.5pt
    let dynamicType: String  // UIContentSizeCategory.rawValue
}

final class TimelineListLayout: UICollectionViewLayout {
    private var measured: [TimelineHeightKey: CGFloat] = [:]
    private var precalc:  [TimelineHeightKey: CGFloat] = [:]
    private var estimate: [TimelineHeightKey: CGFloat] = [:]
    private var streamingIDs: Set<String> = []          // 不是 Range
    var isAutoScrollPinning = false                     // 由 controller 每帧设置
}
```

- **键**：三档全部用 `TimelineHeightKey`；宽度或字号变化时整档失效（`invalidateLayout` + 重播种）。
- **`prepare()`**：纯算术；`measured → precalc → estimate → 200`；维护 `itemAttributes` 有序数组。
- **`layoutAttributesForElements(in:)`**：二分定位区间，返回视口 ± 半屏；返回值用 `[UICollectionViewLayoutAttributes]`。
- **播种**：每次 snapshot apply **之前**，为新 item 写入 precalc（`NSAttributedString.boundingRect`，按 key 缓存）
  或 estimate（内容启发式）。不得覆盖已有 `measured`。
- **实测回写**：布局在 `invalidationContext(forPreferredLayoutAttributes:withOriginalAttributes:)`
  收到 cell 的 preferred 高度，写入 `measured`。

#### 3.4.1 offset 补偿判据（纯函数，可单测；修正 P1-7）

```
输入：cell 原 frame、preferred 高度、viewport、isStreaming、isAutoScrollPinning、isUserScrolling、keyboardTransition
输出：offsetDelta

1. isUserScrolling 或 keyboardTransition → 0（只延迟补偿，不延迟尺寸）
2. cell 完全在视口上方（maxY ≤ offsetY）→ delta
3. cell 完全在视口下方 → 0
4. cell 顶边越过视口顶（minY < offsetY < maxY）→ delta
5. cell 完全可见且非流式 → 0
6. 流式 cell 且 isAutoScrollPinning 且 delta > 0 → delta
7. 其余 → 0
```

> 第 5 条与 OpenMinis 的实现不同：OpenMinis 对"可见且非流式"也补偿；本任务单不照抄，
> 因为 AA 的行在流式中会同时改变高度与位置，按"完全可见"再判一次更安全。实现时用真机 14 号用例验证。

#### 3.4.2 插入补偿（修正 P1-3 / P1-5）

`targetContentOffsetForProposedContentOffset(_:withScrollingVelocity:)` 返回：

```
proposed + owed
```

`owed` 的来源：
- **append**：新 item 全部在视口下方 → `owed = 0`（底部钉住由 `isAutoScrollPinning` 决定：
  钉住时 `owed = newContentHeight - oldContentHeight`，否则 0）。
- **prepend**：布局在 `prepare(forCollectionViewUpdates:)` 记录"锚点行在新旧布局中的 y 差"，
  `owed = oldAnchorY - newAnchorY`（正值表示内容整体下移，offset 需加上同量）。
- **容器尺寸变化**：不在此处处理，走 I6 的显式重算。

历史锚点（I13）由此**不再需要布局后的 `scrollTo`**：把 `TimelineHistoryPosition` 的
`origin（anchorRowID, edge, y）` 传给布局，布局在 `prepare(forCollectionViewUpdates:)` 里
用新旧 attributes 求差，作为 `owed` 返回。

### 3.5 采样与相位（修正 P1-10 / P1-11）

**采样公式**（必须与 SwiftUI `ScrollGeometry` 并排验证一次）：

```
containerHeight = collectionView.bounds.height
topInset        = adjustedContentInset.top
bottomInset     = adjustedContentInset.bottom
offsetY         = contentOffset.y
contentHeight   = contentSize.height
```

> 风险：输入条已通过 `safeAreaInset` 缩短 `bounds`，若 `adjustedContentInset.bottom` 又含输入条，
> 会**双重扣减**。C4 的验收第一步是"并排打印 SwiftUI 与 UIKit 采样值"，差值必须 ≤ 1pt。

**采样触发**：`scrollViewDidScroll`、`contentSize` KVO、`adjustedContentInset` KVO、
`viewSafeAreaInsetsDidChange`、`viewDidLayoutSubviews`。

**相位合成**（不假设 1:1 映射）：

| 事件 | 合成相位 |
|---|---|
| `scrollViewWillBeginDragging` | `.interacting`（`.tracking` 在 UIScrollView 无来源，明确不产生） |
| `scrollViewDidEndDragging(willDecelerate:)` | 否 → `.idle`；是 → `.decelerating` |
| `scrollViewDidEndDecelerating` | `.idle` |
| 我们自己的 `UIViewPropertyAnimator` 开始/完成 | `.animating` / `.idle` |
| 其余 | 不变 |

> `.tracking` 缺失会影响 `pull.begin` 的起点吗？`phaseChanged` 的 `wasInteracting` 在 idle→interacting
> 时恒为 false，与现状相同。C1 用独立事件序列单测锁定；C4 真机做**逐事件日志对比**。

---

## 4. 逐项对接

> 只列与 v2 不同的、或审查点名的项；其余按 §3 的机制直接推导。

- **I1/I31**：相位合成见 §3.5；`settleUserScroll` 的 64ms 任务原样保留。
- **I2/I3**：采样与发布见 §3.5；禁止在原生回调里直接写 SwiftUI `@State`。
- **I4**：底部目标**持久化**（§0.1）：控制器保存 `armedBottomTarget`，
  每次 contentSize/布局变化后重新解析并设置；用户接管（相位变为 interacting）时清除。
  400ms 兜底 = **先 `finishScrollToBottom(command)` 再 `openingPositionDidSettle()`**（P1-2）。
  两段收敛顺序：`layoutIfNeeded` → 算 → 设 → 复测；连续两次 `contentHeight` 不变且可见 cell 已测量才算稳定。
- **I5**：`UIViewPropertyAnimator` + `UISpringTimingParameters(response:0.28, dampingRatio:1)`；
  Reduce Motion 直接设；中断走 `stopAnimation(true)` 并结算。
- **I6**：内容或容器尺寸变化都按 `shouldPin` 语义处理；容器变化在 `viewSafeAreaInsetsDidChange`/`layoutSubviews` 后显式重算。
- **I10/I11**：四个可见性由 `TimelineVisibilityProbe` 纯函数计算（阈值与探针尺寸见 I14/I15）。
- **I12/I13**：见 §3.4.2。
- **I18**：挂起时取消；恢复时重放相位，且 `historyLayout != nil` 时重跑锚点重算。
- **I22**：`windowRevision` 变化时，只在 `!readerTookOver && !navigationIsSuspended && hasOpened` 时重跑 I4（P2-3）。
- **I23**：`isOpeningReady` 期间禁手势/无障碍（不是 `openingPositionSettled`）；顶部 edge effect 用
  `ChatPageScrollEdge` 现有的 `topEdgeEffect.style = .soft` 实现（仓库已有用法）。
- **I26**：`animatingDifferences: false`；尾部内部的队列/状态行动画保留。

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
- 每个提交可独立 revert；C6 删除旧路径后，回退需连同 C5 一起。
- **运行时回退**：保留 `UserDefaults` 开关 `aa.timeline.collectionView`（默认 **off**，M1 验完再翻）。
  开关关闭时走旧 `ScrollView` 路径——两套路径在 C6 之前同时存在。
  > 这条是对 v2 的修正：L 级 UI 重写不能只靠提交级回退。

---

## 7. 测试

### 7.1 纯逻辑单测（必须住 `Models`，不能住 `Views`）
1. `TimelineItemIdentity`：顺序、去重（首条胜出）、四类提示。
2. `TimelineVisibilityProbe`：**写死 96pt / 2pt 探针矩形与相交定义**，用手算夹具，不复用实现公式。
3. `TimelineOffsetTarget`：底部 offset（含 inset 钳制、sub-viewport）。
4. `TimelinePhaseMapping`：独立事件序列 → 相位；覆盖"`.tracking` 永不产生"与"动画完成"。
5. `TimelineContentSignature`：group/提示/pending/tail 的变化检测，含"流式追加 revision 不变"用例。
6. `TimelinePreferredAttributesDecision`：§3.4.1 的七条判据逐条。
7. `TimelineInsertionOwed`：append/prepend 的 `owed` 计算。
8. `TimelineHeightKeying`：宽度 0.5pt 量化、字号变化失效。

### 7.2 真机清单（补充 P2-9）
1. 冷开最新会话：落底、不闪
2. **1000 行冷开**：落底、不闪
3. 快速上下甩动 10 次：无 >16ms hitch（Release）
4. 上滑加载 3 页：锚点不劣化；**加载后下拉提示仍可用、锚点仍触发**（6a 回归判据）
5. 下拉加载更新：起手时提示可见才加载
6. 键盘弹起/收起：最新行贴输入条
7. 输入框长高/变矮：同上
8. 抽屉滑出/滑入：不误判；关闭后锚点仍生效
9. 浮动"到底部"出现/消失时机一致；状态栏点按回顶正常
10. 流式：新行从底部出现、不跳；**工具组持续追加行可见**
11. 流式结束：footer/复制操作出现
12. 滚走再滚回：Markdown/图片/reveal 无可见重解析（I25）
13. 新增消息/前插历史：**无插入动画**
14. **测量后旋转 / 改动态字号，继续滚动**：行高正确、不重叠
15. **发送后回底 / 审批卡出现停跟随、消失回底**（I27–I29）
16. 旋转/分屏（iPad）：内容列 16/20 边距正确、760 居中
17. 滚动条不出现；短内容回弹；开屏期间 VoiceOver 不读内容
18. **Catalyst**：状态栏点按回顶、导航栏 scroll edge 仍注册

### 7.3 已知测不到（必须写进汇报）
- UIKit delegate 的真实事件顺序（只能真机日志逐事件对比）。
- `UIHostingConfiguration` 复用时的行内状态（只能真机 12 号）。
- Catalyst 运行时。

### 7.4 性能验收（修正 P2-10）
- **Release 真机**（不是 Debug），机型记录在案。
- 采集：新增 `CADisplayLink` 采帧（与官方 `FrameHitchRecorder` 同口径：>16/>25/>75/>700ms），
  `AA_PERF_SIGNPOST` 关闭时零成本。
- 判据：1000 行窗口连续滚动 10 秒，**>16ms 的帧占比 < 5%**，无 >75ms 帧。
- 基线：先在当前 HEAD `47fd9408` 上采一次，PR 里贴前后数字。

---

## 8. 分步提交

| 提交 | 内容 |
|---|---|
| C1 | `Models` 纯逻辑（§7.1 的 8 组）+ 单测 |
| C2 | `TimelineListLayout`（id 键、三级缓存、prepare、LAFE 二分、补偿判据、插入 owed） |
| C3 | `TimelineCollectionController` + `UIViewControllerRepresentable` 骨架 |
| C4 | 接线 I1–I9、I27–I32（相位、采样、开屏、键盘、跟随） |
| C5 | 接线 I10–I26（pull、锚点、提示、窗口替换、修饰符、内容列） |
| C6 | 翻转 `aa.timeline.collectionView` 默认值，删除旧路径 |

C4/C5 后各出一次包；开关默认 off，pp 验完再翻。

---

## 9. 事前验尸（含 6a 教训）

1. **开屏落顶/落错**：首布局 contentSize 未稳定 → 两段收敛 + 400ms 兜底（先 complete 再 settle）。
2. **键盘弹起页面上移/下拉**：viewport 双重扣减或 sizeChanges 判据错 → §3.5 并排校验 + 真机 6/7。
3. **滚动中实测修正拽走视口**：§3.4.1 判据错或 `defer` 语义错 → 真机 3/14。
4. **前插后全行错高**：缓存仍用索引键 → 单测 8 必绿 + 真机 4。
5. **加载 3 页后下拉失效**（6a 原样复发）→ 真机 4 合并验证。
6. **cell 复用丢行内状态** → 真机 12。

---

## 10. 审查修订对照（v3）

| 审查项 | 落点 |
|---|---|
| P0-1 Int 键 | §3.4 `TimelineHeightKey`；§7.1 第 8 条 |
| P1-1 持久底部目标 | §0.1、§4 I4 |
| P1-2 兜底未 complete | §4 I4 |
| P1-3 插入无补偿 | §0.1、§3.4.2；M1 范围 |
| P1-4 漏 follow 链路 | §1 I27–I32；§4 I27–I32 |
| P1-5 同步/异步矛盾 | §0.1、§3.4.2（锚点移入布局） |
| P1-6 宽度/字号失效 | §3.4 键；§7.2 第 14 条 |
| P1-7 补偿判据 | §3.4.1 七条 |
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

---

## 11. 开工前置条件

1. pp 审阅 v3。
2. pp 确认下拉规则维持现状。
3. 基线 `47fd9408`；先采一次性能基线（§7.4）。
4. **完成 `spike/6b-collection` 原型，把四个运行时未知变成事实**（见 §12）。

---

## 12. v3 第三轮审查待办（**未修复**，10 条 P1）

> 第三轮审查在 v3 上仍报 10 条 P1。按准则 §7 已停下汇报；pp 选择先做运行时原型。
> 原型结果回来后，本表逐条修复，再出 v4。

| # | 问题 | 修法 |
|---|---|---|
| 1 | 前插 owed 符号写反：`oldAnchorY - newAnchorY` 恒为负 | 改为 `newAnchorY - oldAnchorY`（与 `TimelineHistoryPositionTests.swift:27-37` 的既有语义一致） |
| 2 | 用错重载 `targetContentOffsetForProposedContentOffset(_:withScrollingVelocity:)` | 改用单参数 `targetContentOffset(forProposedContentOffset:)`；并验证无动画 apply 是否触发 |
| 3 | owed 没有一次性/事务闸，后续布局会重复应用 | 只在 update 窗口内有效，`finalizeCollectionViewUpdates` 清零；单测"同一 owed 只消费一次" |
| 4 | `UISpringTimingParameters(response:dampingRatio:)` 不存在；`contentOffset` 不可用 UIViewPropertyAnimator 动画 | 改 CADisplayLink 逐帧驱动，或退回 `setContentOffset(animated:)` 并把 `scrollViewDidEndScrollingAnimation` 补进相位源 |
| 5 | 漏 `shouldInvalidateLayout(forPreferredLayoutAttributes:)`（默认返回 false）→ 实测回写整条链不触发 | 显式 override 返回 true；补 `layoutAttributesForItem`/`contentSize`；index path 越界钳制 |
| 6 | 高度键缺内容版本，离屏行滚回用旧 measured | 键加 `revision/updatedSeq` 或在 `changedIDs` 时清除对应 measured 并重播种 |
| 7 | 高度键缺 App 字号/行距设置（`ChatMetrics`/`ChatTypeSettings`） | 键加排版修订号，或设置变化时清空三档 |
| 8 | 补偿判据第 4 条（顶边越过视口顶）会每批跳一次 | 只在"完全在视口上方"或"增长发生在视口上方"时补偿；部分可见返回 0 |
| 9 | pull 的 2pt `contentHeight` 闸会被自绘自测取消 → 上滑加载失效（6a 复发） | 浏览期 `deferSelfSizing`（官方做法），或把 pull 判据改为视口锚定 |
| 10 | 行内本地状态（Markdown 解析、图片、reveal、选区）在 cell 回收后丢失 | 状态外置到行模型/有界缓存，或明确降低验收并写清用户可见代价 |

### 第三轮 P2 中必须一起处理的
- 状态栏点按回顶缺相位源（`scrollViewShouldScrollToTop`/`DidScrollToTop`）
- §5"offset 一律异步"与 I8 键盘逐帧钉底冲突：键盘窗口内允许同步 `setContentOffset`，带重入闸
- `isAutoScrollPinning` 的真值来源未定义；审批卡出现（I29）后仍会贴底
- 内容列：先加 16/20 边距再限 760 → iPad 正文实际 720；20pt spacing 作用于所有顶层 item
- iOS 顶部 soft edge effect：`ChatPageScrollEdge` 仅在 Catalyst 生效，iOS 需直接设 `collectionView.topEdgeEffect.style`
- 播种成本无预算：1000 行同步 `boundingRect` 在主线程，需要成本上限或懒播种
- 运行时开关切换会因 `TimelineScrollState.hasOpened` 卡在顶部，需要重置状态
- 签名覆盖不全：`turnAction` footer、状态行 orb 活动
- 历史结算 64ms/`isPositionedByUser` 的归属未交代
- 测试 7 会与错误符号共用假设 → 改为"屏幕位置不变量"断言
- `safeAreaInset` 前提写错（缩的是 safe area，不是 bounds）
- contentSize 变化会重新引入 body 风暴 → 纯测量修正走非失效通道
- 验收口径自相矛盾（>16ms vs >75ms）；基线采帧器是本次新增，需单独埋点提交

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
