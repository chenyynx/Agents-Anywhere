# Code 页下一批交接（2026-10-27）

> 新会话先读本文件 + `docs/code-user-attachments-handoff.md` + `docs/code-text-interaction-task.md` + `MEMORY.md`。
> 铁律：`dev` 不碰不合；只从 `feat/code-profile-beta` 出包；不 force push；出包/交流带构建号；CI dispatch 必须带 `title`。

## 0. 当前状态

- 工作副本：`/home/ubuntu/aa-wt-attachments`
- 分支：`feat/code-profile-beta`
- HEAD：`594ceb3f`（回底按钮死区修正；其后只有 docs）
- 最新包：build **601**（`AgentsAnywhere-feat-code-profile-beta-b601-594ceb3.ipa`，17,134,134 B，`CFBundleVersion=601`）
- CI：run `40524112345`（`iOS Build · 回底按钮·静止死区修正`）`test` / `build` / `code-profile` / `timeline-autorun` 全绿；gate `failures: []`
- 已合入 composer/scroll 结构线（`c36b6fad`），`dev` 未碰未合
- 已验证通过：
  - Code 用户附件（图片 tiles / 文件卡 / 失败卡 / pending）build 590
  - 正文链接点击 + 单块选中复制 build 597
  - 回底按钮（CI 门禁 + 截图）build 601，**待 pp 真机验收**
  - 附件/正文链接的官方截图交叉证据见 `docs/code-user-attachments-handoff.md`、`docs/code-text-interaction-task.md`
  - 回底按钮证据/任务单见 `docs/code-scroll-down-indicator-task.md`

## 1. 下个会话顺序（pp 2026-10-27 定）

1. **回底按钮**（Code 页）— 已实现，build 601 待真机验收
2. **SubAgent 卡** — 验收通过后开工

先完成 1 的真机验收，再开 2；每项先证据/任务单，不直接猜。

## 2. 任务 1：Code 页回底按钮

### 2.1 目标

Code 页滚动离开底部后，显示官方“回到/滚动到底部”控件；点击回到底部并重新跟随。当前 Code 页**没有**这个控件（Chat 有 AA 自制的 `TimelineBottomPill`，Code 走 collection view，未接）。

### 2.2 官方证据（先读）

- `/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/UPSTREAM/part-u-scroll-text-drawer.md` §5：
  - `ScrollDownIndicator`：`Button` + 图标；iOS 26 走 SwiftUI `Glass.regular.interactive()` + `Circle`；内部 `Presence = shown / fadingOut / gone`；`Animation.easeInOut(duration: 0.2)`；Reduce Motion 跳过淡出；`hidden` 由父视图传入，**视图内没有距离阈值**。
  - `ScrollToBottomTextButton`：`FrameLayout(height: 44.0)`；`fillsWidth` 决定是否撑满（INFERENCE）。
- `/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round19/motion.md:203,312`：Code 页无“到底部”指示器；官方共享 `ScrollDownIndicator`；AA 缺失，属功能差异。
- `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/11-motion-haptics.md:303`：`ScrollToBottomTextButton` 高 44.0 pt（E）。
- 可见性阈值（距底多少 pt 才出现）官方仍 **U**；宿主侧 `_hostDrawsScrollDownIndicator` 只是环境键。先按产品观感取一个可解释阈值，并在任务单写明 U，不要假装官方值。

### 2.3 AA 现状与接线点

- Chat 的 AA 实现（可参考外观/交互，不要直接搬 Code）：
  - `/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Views/Chat/ChatTimelineView.swift:284` 传 `isBottomShown: scrolling.showsBottomButton()`；
  - 同文件 `TimelineBottomPill`（约 `:765`）：`Label("到底部", appSymbol:"arrow.down")`，`glassEffect(.regular.interactive(), in:.capsule)`，44pt 触达，键盘弹起时隐藏。
- Code 页：
  - `/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatTimelineView.swift` 目前没有 bottom pill；它包 `TimelineCollectionView` + `TimelineChatBridge`。
  - `TimelineCollectionController.requestBottom(animated:forced:)`：`/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineCollectionController.swift:1620`。
  - 滚动状态：`TimelineScrollState.showsBottomButton()`：`/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Models/Chat/TimelineScrollState.swift:313`；controller 的 `phase`/`onPhaseChanged`：`TimelineCollectionController.swift:93/164`。
  - 需要把“是否显示回底按钮”从 controller 暴露给 SwiftUI（新增回调/observable，基于 `viewportIsAtBottom`/`readerRestsAtBottom`/`showsBottomButton` 语义），再由 `TimelineChatTimelineView` 覆盖一层 SwiftUI 控件；点击调 `controller.requestBottom(animated:true, forced:false)`。
- 位置：在 composer/safeAreaBar 之上，不能压 composer；键盘弹起时是否隐藏、以及是否用 `ScrollDownIndicator`（圆形玻璃图标）还是 `ScrollToBottomTextButton`（44pt 文本），先按官方截图/证据定，不要直接复用 Chat 的“到底部”文案。

### 2.4 实现/验证要点

- 只加 overlay，不改行高；不能让 `CodeRowHeightPlan`/gate delta 变化。
- Reduce Motion 跳过 0.2s 淡出（官方 E）。
- 触感：官方 `ScrollDownIndicator` 只知 `onPress`；未证 haptic，不要自创。
- 门禁：`timeline-autorun` 增加回底场景（离开底部 → 显示 → 点击 → 贴底 → 隐藏）；code-profile 截图确认不挡内容。
- 真机验收：长文上滑、点回底、流式/键盘/Reduce Motion 四种场景。

## 2.5 回底按钮实现记录（build 601，待真机验收）

- 新增 `Views/Chat/Code/CodeScrollDownIndicator.swift`：40×40 pt 玻璃圆（`@ScaledMetric(.footnote) 16 + 2×12`）、`anthropicon.arrowDown`（`.large`，官方 SVG md5 `051cc5d4…`）、44 pt 点击区、`easeInOut(0.2)` 淡入淡出（Reduce Motion 跳过）、a11y「向下滚动」。
- 资产：`Assets.xcassets/anthropicon.arrowDown.imageset`（1.261005.20 提取，与 1.261019.51 逐字节相同）；`AnthropiconAssets.table` 新增 `[11×12, 12×13, 14×15]`。
- Controller：`canScrollDown` / `showsScrollDownIndicator` / `onScrollDownIndicatorChanged`；只在 `publishViewport` 与 `setNavigationSuspended` 发布布尔翻转。
- 阈值：官方宿主判定 U；沿用 `_canScrollDown` 语义，但 AA 动画回底会停在布局底端前 **1 物理像素**（gate 600 失败；build 601 `settledShortfall = 0.33333333333394 @3×`），故用 **1 pt 死区**。这是 AA 适配，不是官方值。
- 位置：composer 之上、**水平居中**、`safeAreaInsets.bottom + 2`（pp 2026-10-27 真机定；官方 pills bar 是 leading 一侧，AA 无 pills bar）。build 601/603 的 leading 版已被此决定取代。
- 点击：`requestBottom(animated: true, forced: true)`（`forced:false` 对 `.reading` 页会被拒，见 `TimelineCollectionController.swift:1662`）。
- 门禁：`TimelineAutoRun` 新增 `scrollDownIndicator` 场景，build 601 报告：
  - `shownAway=true`、`hiddenAtBottom=true`、`animatedFlips=[true,false]`；
  - Reduce Motion 同样 `[true,false]`、`hiddenReduced=true`；
  - `settledPhase=idle`、`settledPlacement=end`。
- 截图：`code-profile` 新增 `code-scroll-down.png`（真实 Code 行 + 控件），已随 CI artifact 输出。
- 待真机验收：长文上滑出现 → 点击回底并恢复跟随 → 流式中不抢滚动 → 键盘弹起随 composer 抬升 → Reduce Motion 无淡入淡出。
- 已知 U：官方 pills bar 为空时是否仍显示；按压动画视觉量；返回过程中是否立即隐藏；键盘弹起是否隐藏。

## 3. 任务 2：SubAgent 卡

### 3.1 现状

- Code 页已有 `CodeToolSegments` / `CodeCollapsedToolRow` / `CodeToolDetailView`，但**SubAgent 卡**的官方 Code 页结构与状态尚未闭合；不要直接拿 Chat 的 `SubAgentCapsule`/`SubAgentPanelSheet` 当 Code 视觉。
- 现有可参考的 AA 代码：`/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Views/Chat/SubAgentCapsule.swift`、`SubAgentPanelSheet.swift`、`SubAgentGlyph.swift`（Chat 页资产/面板）。
- 官方证据入口：`/home/ubuntu/aa-test/claude-ios-re/CANONICAL/01-architecture.md`、`04-tool-calls.md`、`21-artifacts.md`、`EVIDENCE/round19/tool-row-status.md`；先确认 Code 页子代理卡是哪个类型、出现位置、状态/入口/展开行为，再写任务单。

### 3.2 开工前

- 先写任务单 + 证据闭合（尺寸、颜色、字体、图标、状态、点击/展开、与主时间线/详情的关系）。
- 不能把 SubAgent 卡与回底按钮混在一个提交/一个包里；先回底按钮验收，再开 SubAgent。

## 4. 构建/CI 规则

- 分支：`feat/code-profile-beta`；`dev` 不碰不合。
- dispatch `.github/workflows/ios-build.yml` 必须带 `title`：
  ```json
  {"ref":"feat/code-profile-beta","inputs":{"title":"回底按钮","build":"true","code_profile":"true"}}
  ```
- 包名：`AgentsAnywhere-feat-code-profile-beta-b<run>-<sha>.ipa`；所有交流带构建号。
- 已知 flaky：`ModelSwitchRecoveryTests.stopStaysReachableWhenADeadProjectionSaysItCannotInterrupt`（测试内自带 `PROBE874`）；只 rerun 失败 job 一次，不据其改代码。
- 出包后下载核对 `CFBundleVersion`；不自动下载/安装。

## 5. 恢复提示词（下个会话直接粘贴）

> 继续 AA Code 页。先读 `/home/ubuntu/aa-wt-attachments/docs/code-page-next-handoff.md`、`/home/ubuntu/aa-wt-attachments/docs/code-scroll-down-indicator-task.md`、`/home/ubuntu/aa-wt-attachments/docs/code-user-attachments-handoff.md`、`/home/ubuntu/aa-wt-attachments/docs/code-text-interaction-task.md`、`/home/ubuntu/.claude/projects/-home-ubuntu/memory/MEMORY.md`。
> 工作副本 `/home/ubuntu/aa-wt-attachments`，分支 `feat/code-profile-beta`，代码 head `594ceb3f`（其后只有 docs，最新提交以 `git log` 为准），最新包 build 601；dev 不碰不合。
> **回底按钮已实现，build 601 待 pp 真机验收**；验收通过后再做 **SubAgent 卡**（先证据闭合，参考 `CANONICAL/01-architecture.md`、`04-tool-calls.md`、`21-artifacts.md`、`EVIDENCE/round19/tool-row-status.md`）。
> 出包/交流带构建号；CI dispatch 必须带 `title`；不 force push、不合 dev。
