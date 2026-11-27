# 交接：切 tab 回来"重播流式动画"——对齐官方（2026-11-27）

> 状态：**未开工**。已完成的是逆向取证与方案设计；下个会话按本文实现。
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
