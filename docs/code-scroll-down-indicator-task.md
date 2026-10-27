# Code 页回底按钮（ScrollDownIndicator）任务单（2026-10-27）

> 目标：Code 页离开底部后显示官方同款「向下滚动」圆形玻璃按钮；点击回到底部并恢复跟随。
> 基线：`feat/code-profile-beta` @ `28fb6580`（build 597 验收通过）。`dev` 不碰不合。
> 原则：先证据后实现；U 明确标 U，不冒充官方值。

## 0. 结论

- 官方控件是 **`ClaudeCoreUI.ScrollDownIndicator`**：圆形玻璃按钮 + `anthropicon.arrowDown`，不是 `ScrollToBottomTextButton`（44 pt 文本按钮是另一组件）。
- 官方 Code 页把它放在 **composer 上方的 pills bar**（`SessionPillsBar.onScrollDown` → `BarPillRow` overlay，leading 一侧）；AA 没有 pills bar，**pp 2026-10-27 真机定：composer 之上、水平居中**（产品决定，见 §3.4）。
- 官方默认尺寸：内容圆 **40×40 pt**（`iconSize 16 + 2×12`），最小点击区 **44×44**；淡入淡出 **0.2 s easeInOut**，Reduce Motion 跳过动画。
- 显示阈值：官方宿主侧判定 **U**；同页 `TranscriptScrollPosition._canScrollDown` 的公式是 `target − visibleBottom > 1 物理像素`，作为 `hidden = !canScrollDown` 的依据 [I]。动画回底可停在布局底端前约 1px（gate 600 实测 0.333 pt @3×），且键盘/输入框 inset 往返会在底部留下几 pt 残差（pp 2026-10-27 真机：键盘收回后按钮又在底部出现），故改为 **`.end` placement 隐藏 + 16 pt 死区**（见 §3.1）。
- 图标资源已从 1.261005.20 提取并与 1.261019.51 逐字节一致（md5 `051cc5d474df11fd1ed6480cab45baba`）。

## 1. 官方证据（本会话补）

### 1.1 组件与动画（既有证据）

- `ScrollDownIndicator` 4 个字段：`__presence: LazyState<Presence?>`、`_iconSize: ScaledMetric<CGFloat>`、`hidden: Bool`、`onPress: () -> ()`；`Presence = shown / fadingOut / gone`。
- `hidden` 变化用 **`Animation.easeInOut(duration: 0.2)`**（`DAT_10422ea60 = 0.2`）；Reduce Motion 时不淡出；`onChange(of: hidden, initial: false)`。
- 来源：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/UPSTREAM/part-u-scroll-text-drawer.md` §5.1、`CANONICAL/11-motion-haptics.md:303`。

### 1.2 图标与几何（本会话反汇编，1.261005.20）

| 项 | 值 | 证据 |
|---|---|---|
| 初始化 | `ScaledMetric(wrappedValue: 16.0, relativeTo: .footnote)` | `FUN_100c2e718`：`0x4030000000000000 = 16.0` |
| 内边距 | **12.0 pt** | `FUN_1009e5770` 返回 `DAT_1042cba20 = 12.0`；`FUN_100c2ee0c` 做 `iconSize + 2×padding` 的 `_FrameLayout` |
| 内容圆 | 16 + 24 = **40×40 pt**（默认字号） | 同上 |
| 图标 | `Anthropicon(name: "arrowDown", size: .large, isBold: false, symbolName: "anthropicon.arrowDown")` | 静态值 `FUN_100a2eab8`：`DAT_1061451c0 = 0x776f44776f727261` → `"arrowDown"`，`+0x10 = 2`（`.large`），`symbolName` 前缀 21 字符 = `"anthropicon.arrowDown"` |
| 按钮样式 | iOS 26：`Glass.regular.interactive().tint(nil)` + `glassEffect(in: Circle())`；更早系统：圆形填充 | `FUN_100c2e15c`（`GlassV7regular` / `interactive(1)` / `tint(0)` / `glassEffect_2in` + `Circle`） |
| 最小点击区 | **44.0 pt** | `FUN_100c2e15c`：`movz x9, 0x4046, lsl 48` @ `0x100c2e628` |
| 按压动画 | `Spring(duration: 0.2, bounce: 0)`；具体视觉量 **U** | `FUN_100c2e15c` 尾部 `SpringV8duration6bounce` |
| a11y label | 本地化键 **`scroll_down`** = "Scroll down" / "向下滚动" | `FUN_100dc6d50` 内联小字符串 `0x645f6c6c6f726373` = `"scroll_d"` + `"own"` |
| 图标字形 | `arrowDown` 3 档画布 11×12 / 12×13 / **14×15** | `EVIDENCE/anthropicon-map.tsv:22` |

- 资源提取：sbx `ubuntu@100.79.4.30:2222`，`carfile-go` 从 `/home/ubuntu/claude-decrypted.ipa`（1.261005.20）导出 `anthropicon.arrowDown`；md5 **`051cc5d474df11fd1ed6480cab45baba`**，与 1.261019.51 的 `icons-all` 同文件相同（617 B，`viewBox 0 0 8.97279 9.83518`）。

### 1.3 宿主位置与显示条件

- Code 页 `SessionPillsBar`（composer 上方 pills bar）持有 `onScrollDown: (() -> Void)?`；`BarPillRow` 在该闭包非 nil 时把 `ScrollDownIndicator` 以 **overlay(alignment: .leading)** 叠在 pills 行上。
  - 字段：`/home/ubuntu/wiring/out/swift_types.csv`（`SessionPillsBar.onScrollDown`、`BarPillRow.onScrollDown/pills/_rowHeight`）。
  - 水平偏移 `FUN_10298ae14`：`±(pillHeight + rowHeight) / 2`（RTL 取负），即按钮贴在 pills 行 leading 一侧 [I]。
- 显示/隐藏动画：pills 行自身 `easeInOut(0.15)`（`DAT_10422ea08 = 0.15`，`FUN_10298addc`）；指示器内部仍是 **0.2 s**。
- **宿主阈值 U**：`_hostDrawsScrollDownIndicator` 只是环境键，未解出 `hidden` 的判定。
- 同页可下滚判据（EVIDENCE 公式 / INFERENCE 命名）：`target − visibleBottom > 1 物理像素`，`part-ag-scroll-params-draft.md:78`（`0x1019ddbf0`）。本任务以 `hidden = !canScrollDown` 落地 [I]。AA 的产品规则：`.end` placement 一律隐藏；阅读态用 **16 pt 死区**（约一行），避开动画回底的 1px 残差、键盘/输入框 inset 往返的小残差和亚行抖动。官方宿主阈值仍是 U。

## 2. AA 现状

- Code 页 `TimelineChatTimelineView` 包 `TimelineCollectionView`；无任何回底控件。
- Controller 已有：`viewport`（`TimelineCollectionController.swift:1581`）、`bottomShortfall`（`:1593`）、`publishViewport()`（`:1611`）、`requestBottom(animated:forced:)`（`:1651`）、`setNavigationSuspended`（`:1956`）。
- `requestBottom(forced: false)` 只对 `placement == .end` 生效（`:1659-1662`）；回底按钮必须传 `forced: true`（同 `:1649` 注释“Forced commands (pill …)”）。
- Chat 的 `TimelineBottomPill`（`ChatTimelineView.swift:756`）是 AA 自制文本胶囊，不复用到 Code。

## 3. 方案

### 3.1 Controller

- 新增：
  - `var canScrollDown: Bool { guard isViewLoaded, !isFollowingEnd else { return false }; return viewport.isMeasured && bottomShortfall > 16 }`（`.end` placement 隐藏 + 16 pt 死区；见 §1.3）
  - `var showsScrollDownIndicator: Bool { canScrollDown && !navigationSuspended }`
  - `var onScrollDownIndicatorChanged: ((Bool) -> Void)?`（controller 自有，**不经** `TimelineCollectionView` 的 per-update 赋值，避免被 `updateUIViewController` 清空）
- 在 `publishViewport()` 末尾、`setNavigationSuspended()` 后发布布尔翻转（去重）。
- **时序约束**：回调在 `onControllerReady`（`makeUIViewController` 内）安装，此时 SwiftUI 尚未加载 controller 的 view；`viewport` 会解引用 `UICollectionView!`（`viewDidLoad` 才创建）。`canScrollDown` 必须先 `isViewLoaded` 短路，attach 里不得读 `showsScrollDownIndicator`（build 601 开屏 SIGTRAP 的根因）。初始值由第一次 `publishViewport` 回调送达。
- 不改行高、不改 `CodeRowHeightPlan`/measurer。

### 3.2 视图

- 新增 `Views/Chat/Code/CodeScrollDownIndicator.swift`：
  - `@ScaledMetric(relativeTo: .footnote) iconSize = 16`，`padding = 12`，内容圆 `iconSize + 24`。
  - 图标 `AnthropiconView(name: "anthropicon.arrowDown", size: .large)`（新增资产 + `AnthropiconAssets.table` 行 `[11×12, 12×13, 14×15]`）。
  - `glassEffect(.regular.interactive(), in: Circle())`（AA 部署目标 iOS 26.2，官方 `#available(iOS 26)` 的旧系统分支不落地）。
  - `.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())`；`.buttonStyle(.plain)`。
  - 显示/隐藏：`.transition(.opacity)` + `easeInOut(0.2)`；`accessibilityReduceMotion` 时无动画。
  - a11y：`"向下滚动"`（官方 `scroll_down` 中文），identifier `code.timeline.scrollDown`。
  - 无触感（官方只证 `onPress`，未证 haptic）。
- 一个 `@Observable` 小状态 `CodeScrollDownIndicatorState`，由 `TimelineChatBridge` 持有并接 controller 回调；只有 overlay 叶子读它，页面 body 不因滚动重算。

### 3.3 接线

- `TimelineChatTimelineView`：在 `TimelineCollectionView` 上 `.overlay(alignment: .bottom)`（水平居中，无 leading padding）；
  - bottom = `safeAreaInsets.bottom + 8`（`safeAreaInsets.bottom` = composer bar + home + keyboard，列表全 bleed，用它把按钮抬到 composer 之上）；8 pt 同时把 44 pt 点击区抬离 composer bar 的命中区（pp 真机反馈点按钮时键盘弹起；2 pt 间隙偏紧，键盘是否由点击穿透引起未证实 [I]）。
- 点击：`bridge.controller?.requestBottom(animated: true, forced: true)`。
- 键盘：不额外隐藏；按钮随 `safeAreaInsets` 一起抬升（官方 pills bar 在 composer 栈内 [I]）。
- 返回动画期间按钮保持可见，到顶后按 `canScrollDown` 自然消失（官方宿主判定 U，不做额外抑制）。

### 3.4 位置证据等级

- 官方 = pills bar 的 leading 一侧（`BarPillRow` overlay + 偏移公式），EVIDENCE。
- AA 无 pills bar；build 601/603 先按 leading 16 落地，pp 2026-10-27 真机要求**居中** → 本批改为水平居中、距 composer 8 pt（外框）。这是产品决定，不是官方位置。

## 4. 门禁与验证

- `TimelineAutoRun` 新增 `scrollDownIndicator` 场景（`run()` 中 `bottom()` 之后）：
  1. 滚到顶 → `showsScrollDownIndicator == true`；回调收到 `true`；
  2. 调按钮同一个入口 `requestBottom(animated: true, forced: true)` → 贴底 → `showsScrollDownIndicator == false`；回调收到 `false`；
  3. Reduce Motion 下重复一次，要求同样贴底且隐藏（动画被跳过）；
  4. 回调序列去重（无连续重复值）。
- `CodeProfileAutoRun` 新增 `scrollDown` 截图阶段 → `code-scroll-down.png`，CI 断言该 PNG 存在且非空，供真机前先核对不挡内容的外观。
- CI：`test` / `build` / `code-profile` + `timeline_autorun` 全绿；行高 gate delta 不变。
- 真机验收（pp）：长文上滑 → 按钮出现；点击 → 回底并重新跟随；流式中；键盘弹起；Reduce Motion。

## 5. 不做 / 遗留（U）

- `ScrollToBottomTextButton` / 44 pt 文本按钮（另一组件，Code 页不用）。
- 官方宿主侧精确阈值与“返回中是否立即隐藏”：U；本批按 `.end` placement 隐藏 + 阅读态 16 pt 死区（产品规则）。
- 官方指示器挂在 `SessionPillsBar` 上；pills bar 为空（无 diff/outputs）时宿主是否仍显示为 **U**（`SessionPillsBarSlot` 的 body 在 bar 为 nil 时整体不渲染）。AA 无 pills bar，按 `canScrollDown` 独立显示。
- 按压动画的具体视觉量（scale/opacity/时长曲线组合）：U；本批不加按压反馈。
- 是否在键盘弹起时隐藏：官方无直接证据；按 pills bar 随 composer 抬升实现 [I]。
- Chat 页继续用现有 `TimelineBottomPill`；不混入本批。

## 6. 文件清单

- `ios/Agents Anywhere/Agents Anywhere/Assets.xcassets/anthropicon.arrowDown.imageset/`（新增）
- `ios/Agents Anywhere/Agents Anywhere/Views/Components/AnthropiconAssets.swift`（表项）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeScrollDownIndicator.swift`（新增）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineCollectionController.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatTimelineView.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineAutoRun.swift`（门禁）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeProfileAutoRun.swift`（截图）
- `.github/workflows/ios-build.yml`（截图列表）
