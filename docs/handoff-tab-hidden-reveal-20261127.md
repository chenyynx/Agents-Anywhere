# 交接：切 tab 回来"重播流式动画"——对齐官方（2026-11-27）

> 状态：**已实现，待真机验收**（2026-11-27 晚，分支 `feat/tab-hidden-reveal`；CI run 46004512243 / b1705 test+build 双绿）。实现记录与和 §3 的偏差见文末 §8。
> 关联红线：`AGENTS.md`「iOS tab 切换性能红线」——**切 tab 已不卡，任何改动不得回退**（b1699 基线：`shell.tabs.frame` worstMs 中位 ≈89ms、p90 ≈108ms、常态无 >200ms）。

## 0. 一句话

官方切走再切回时，隐藏期间到达的文本会**按流式节奏重播**（不是一次蹦出来）；AA 现在是墙钟 deadline，回来立即全显。要对齐需要**三层同时**成立：数据照收、隐藏页不 apply、**揭示 progress 冻结并在可见时续放**。

## 1. 问题与目标

- 现状（b1701）：切 tab 不卡了（页面常驻壳，`e251fb33b`…`798160c69`，b1699 真机确认）。
- 但观感与官方不同：
  - 官方：切走 → 回来，流式文本"继续打字"（重播积压），然后追平；
  - AA：隐藏期间墙钟照走，回来时 deadline 已过 → 积压文本**一次全出**。
- 目标：隐藏期间数据照收、视图不 apply、揭示 progress 冻结；切回（转场 settle 后）从旧 progress 按节奏续放。

## 2. 官方机制（EVIDENCE，见 `CANONICAL/29` §16–§18）

文档：`/home/ubuntu/aa-test/claude-ios-re/CANONICAL/29-tab-shell-261123.md` §16「隐藏页更新策略」、§17「停稳更新时序」、§18「流式揭示 RevealDriver（含切走续播）」。

- **数据层无可见性闸**：`TabBarPageReporter.report(event:)`（`0x1005e7cc8`）不碰数据；会话模型字段无 `isOnScreen/isPaused`（§16 EVIDENCE）。
- **列表引擎帧链接常开**：全二进制 `setEnabled:` 唯一调用点是 `1`（`0x1004ead48`），无运行期 disable（§17.9，负向 EVIDENCE）。
- **可见性由适配器自算**：`isHidden`/`isDescendantOfView:` 于函数 `0x10050b058`（§17.10，INFERENCE-high）。
- **揭示驱动器 `ClaudeMarkdownUI.RevealDriver`**（§18 EVIDENCE）：
  - 帧源 `DisplayFrames: FrameSource`（CADisplayLink；`steps`/`link`/`frameTime`）；
  - progress 持久：`released: Int`、`runs`、`nextRun`、`phase(releasing|whole|handedBack)`；driver 由内容模型持有，切走不清零；
  - 节奏 `RevealPacing{charactersPerSecond; longestLagSeconds}`（cps/lag 默认值 U）；
  - 常量：`runPatience 0.35s`、`runEndPatience 1.5s`、`fadeDuration 0.6s`、`firstFadeDuration 0.12s`；mask = `CAShapeLayer` 淡入。
- **U（不阻塞实现）**：隐藏时精确停点（帧步进在哪行为空）；`DisplayFrames` tick/steps 注册点；cps/longestLag 默认值。

## 3. AA 现状（要改的地方）

- 揭示时钟：`ReplyPresentation.revealSeconds = 0.24`、`drawSlack = 0.1`、`batchInterval`；`ChatMarkdownView.revealDeadlines: [Int: Date]`，每次文本变化把 deadline 推到 `now + 0.34`（`Views/Chat/Markdown/ChatMarkdownView.swift`）。
- 单字形动画：`StreamingGlyphReveal` + `GlyphRevealLedger`（`Models/Chat/GlyphRevealLedger.swift`）。
- 隐藏页：常驻壳持续 apply/绘制（`ShellTabsView` 的 opacity 0）；切 tab 的 350ms 转场窗口已有 park（`shellTabTransitioning` → `bridge.setNavigationSuspended`）。
- 前车之鉴：`f5da4f032` 曾挂起隐藏页**数据 apply**（停错层）→ 切回白屏，`60165f5ed` 回退。本次只停"视图 apply + 揭示时钟"，**数据永远不停**；且只对已呈现过快照的页面生效。

## 4. 实施方案（建议顺序）

1. **揭示 progress 化**（核心，先做）：
   - 用 `revealedChars`（每 block/leaf）+ `targetChars`（当前文本长度）替代 `revealDeadlines`；
   - 一个 per-page `RevealClock`（CADisplayLink 或 `TimelineView(.animation)`，优先 CADisplayLink 以对齐官方）在**可见时**按 cps 推进 `revealedChars`；不可见（`shellTabVisible == false` 或 `shellTabTransitioning`）时冻结；
   - 续播受 `longestLagSeconds` 上限约束（值先取经验值，如 2–3s，可调）。
2. **隐藏页停 apply**：复用 `shellTabVisible`，让时间线 `apply`/`reload` 在隐藏时挂起、切回 settle 后 flush；**硬前提**：`hasPresentedSnapshot == true` 才允许挂起；flush 带每帧预算/分批 + 超时兜底（0.5s）。
3. **开关与回退**：1/2 各用独立 commit；第 2 步加设置开关（默认开），出问题可关。
4. **护栏**：每步出包必须真机对照 `shell.tabs.frame`（红线：中位 >120ms 或可复现 >200ms 常态窗口 → 回退）。

## 5. 验收（真机）

- 对流式中的会话：切到别的 tab 停 2–3s 再切回 → 能看到积压文本**按节奏续播**再追平，而不是一次全出；
- 可见页流式手感不变（0.24s/批的节奏保持或更接近官方）；
- `shell.tabs.frame`：中位 ≤120ms、无 >200ms 常态窗口（b1699 基线 89/108/无 >200）；
- 键盘/滚动/锚点无回归（切回时 flush 不得让列表跳）。

## 6. 相关文件

- 壳：`Views/ChatShell/ShellTabsView.swift`、`ShellTabsHost.swift`、`ShellTabEnvironment.swift`（`shellTabVisible`）
- 时间线：`Views/Chat/TimelineCollection/{TimelineChatTimelineView,TimelineCollectionController}.swift`、`TimelineChatBridge.setNavigationSuspended`
- 揭示：`Views/Chat/Markdown/{ChatMarkdownView,StreamingGlyphReveal}.swift`、`Models/Chat/{ReplyPresentation,GlyphRevealLedger}.swift`
- 诊断：`shell.tabs.frame` / `shell.tabs.phase` / `tab.stack`（probe 包）
- 逆向：`CANONICAL/29` §16–§18；`EVIDENCE/round-tab-shell-261123/decomp/{hidden-*,hidden2-*,hidden3-*,reveal-*}`

## 7. 恢复提示词（复制给下一个会话）

```
继续 AA iOS next 线的"切 tab 回来重播流式动画"任务。先读：
1) /home/ubuntu/aa-wt-hang/docs/handoff-tab-hidden-reveal-20261127.md（交接全文）
2) /home/ubuntu/aa-test/claude-ios-re/CANONICAL/29-tab-shell-261123.md §16–§18（官方证据）
3) /home/ubuntu/aa-wt-hang/AGENTS.md 的「iOS tab 切换性能红线」

按交接第 4 节实施：①揭示 progress 化（可见时才推进，隐藏冻结、回来续播）；②隐藏页停 apply（仅已呈现过快照的页面，flush 带预算与超时兜底）；③各独立 commit + 开关。每包真机验 shell.tabs.frame 不破红线（中位 ≤120ms、无 >200ms 常态）。当前 next head 以 git log -1 为准；切 tab 卡顿已收口（b1699），不得回退。
```

---

## 8. 实现记录（2026-11-27）

### 8.1 和 §3 的关键偏差（事实修正）

§3 把 `ChatMarkdownView.revealDeadlines` 当成生产揭示时钟，**这是过时的**：W7 之后 Chat/Code 两页的正文都由 `CodeMessageRowView` → `CodeMarkdownTextLeaf`（TextKit）渲染，`ChatMarkdownView` 只用于公告/子代理摘要/自动门；`assistantMarkdown(for:)` 与 `assistantStreamingDocument(for:)` 在生产路径返回 nil。**生产可见的流式文本来自 `CodeStreamingPublisher` 的整段快照（0.1s 前缘节流）**，在 `TimelineChatContentAdapter.codeStreamingTexts(for:)` 汇聚。因此同一机制落在 **adapter 的文本投影层**，而不是 SwiftUI 字形层：

- `StreamingRevealCursor`（`Models/Chat/StreamingRevealTimeline.swift`）= 官方 `Progress.released` 的 AA 对应物：字符计数、持久、只增；时钟 `StreamingRevealClock` 在隐藏期间冻结，`now(at:)` 把隐藏时长扣掉，回到页面从冻结计数续放。
- 官方常量沿用 `StreamingRevealTimeline` 已有的 320 cps / 640 cps catch-up / 2 s drain；新增 `longestLagSeconds`（默认 3 s = 960 字符）在锚定时跳过更老的积压。
- 采样发生在每次 adapter refresh（Code 文本本来就只在 apply 时重绘），不用 CADisplayLink：per-frame 光标没有 per-frame 渲染器可画，只会空转；节奏由 `codeStreamingTexts` 的前缀 + `codeRevealRevisions` 进 content signature 保证。
- 首次见到一段文本时**全显**（官方驱动挂载时也不回放已有内容）；只有光标已经存在、文本在隐藏期间增长的部分才重播。
- **隐藏期间才第一次出现**的助手消息（包括在隐藏期间就结束、回来时已 settled 的）走 `startFromTail`：从最近 `longestLagSeconds` 的尾巴开始按节奏补播，不会整段直出；这类 settled 消息没有 publisher，由 `codePendingReplays` 提供临时揭示源，追平后交回持久文本。
- VoiceOver / Reduce Motion 下不建光标（官方同样不建 reveal driver），直接画完整快照。
- 隐藏页的回合阶段/完成**震动**也必须过 `shellTabVisible` 门（`TimelineChatTimelineView` 两条 phase haptic + send-confirmed；`CompletionFeedback` 两段 pulse），否则隐藏页会在别的 tab 响。

### 8.2 两步实现（各自 commit）

1. `e6d6c1b82` **揭示 progress 化**：`StreamingRevealClock/Cursor` + adapter 投影 + 续播泵（refresh 发现落后 → 10 Hz 泵到追平，wire 静默也能放完）+ 单测（时钟冻结/续放、首帧全显、cps 节奏、longestLag、缩短修正）。
2. `f06c554f2` **隐藏页停 apply**：`TimelineCollectionController.pageHidden` 闸（`apply`/`reloadFromContent`/`applyPendingIfNeeded` 停靠）；硬前提 `hasAppliedSnapshot`（首个快照照常落地，防 `f5da4f032` 白屏）；返回后 0.5 s watchdog flush（shell 转场先由 `navigationSuspended` 的 settle 边 flush）；开关 `ShellTabPreferences.hiddenPauseKey = "aa.native.tabs.hidden-pause"`（默认开，设置→诊断日志可关）。
3. `1f11f5664` **返回时先补最终文本再 complete**：隐藏页 refresh 停靠期间 publisher 的 receivedText 会落后；先 `receive(fullText:)` 再 `complete()`，完成快照才是整段答案（否则完成于隐藏期间的回复只会显示离屏前的前缀）。
4. `cdaadf88d` **隐藏期间首次出现的消息补播尾巴**：b1705 真机日志里回复的消息行在隐藏期间才首次出现、回来前已结束（`shell.tabs.reveal cursors 0→1`、无 pump）；新增 `codePendingReplays` + `startFromTail`，仍流式的同型消息也从尾巴起播；同时给隐藏页 phase/completion haptic 加 `shellTabVisible` 门（日志 21:21:57/58 在 wiki/artifacts 仍响）。
5. 其余小修：`3e0bd6a00` 修 CI 的 Int/Double 混算；`b8317dea3`/`14532f7e2` 诊断 kind 归 info + 字段；`f1654cb36` 过时注释。

### 8.3 诊断（真机对照）

- `shell.tabs.reveal`：`visible` / `cursors` / `behind` / `backlog`（页面可见性边沿；计数来自最近一次采样，resume 时真正欠的字符数看下一条）。
- `shell.tabs.reveal.pump`：续播泵启动时的 `backlog` / `rows`（真正开始续播时的欠账）。
- `timeline.page.hidden`：`hidden` / `parked` / `pending` / `deferredReload`。
- `timeline.page.flush`：`waitedMs` / `flushMs` / `parked` / `items`（watchdog 兜底 flush 的耗时，用于看切回落地帧成本）。
- `shell.tabs.frame`：每包必看——worstMs 中位 ≤120ms、无 >200ms 常态窗口。

### 8.4 真机验收清单（待 pp）

1. 对流式中的会话：切到别的 tab 停 2–3 s 再切回 → 积压文本按节奏续播再追平（不是一次全出）。
2. 可见页流式手感不变（正常速度下光标始终追平，文本仍按 0.1 s 快照节奏出现）。
3. `shell.tabs.frame`：中位 ≤120ms、无 >200ms 常态（b1699 基线 89/108）。
4. 切回时列表不跳、键盘/滚动/锚点无回归。
5. 设置里关掉「隐藏标签页暂停时间线刷新」后：隐藏页恢复原来的实时 apply（用于回退定位）。
