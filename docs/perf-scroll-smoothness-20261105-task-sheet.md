# 滚动流畅度专项任务单（2026-11-05）

> 目标：聊天正文滑历史、侧栏抽屉开合都要「丝滑」，消除可感知掉帧。
> 级别：L（核心用户流程 + 性能线）。先量后改，一假设一提交。
> 关联：`docs/handoff-perf-jank-20261031.md`、`docs/diagnostics-and-performance-task-sheet.md`、`docs/handoff-code-timeline-20261031.md`。

## 1. 症状（pp 真机，2026-11-05，最新 beta）

| # | 场景 | 描述 |
|---|---|---|
| S1 | 侧栏抽屉 | 消息/会话多了以后，开合抽屉卡 |
| S2 | 聊天正文 | 上下滑历史「滑一下卡一下」；纯浏览就掉帧，流式输出时更卡，长会话更明显 |

验收环境：pp 的 iPhone 真机 + 最新 beta 包（不拿模拟器当结论）。

## 2. 已有证据（2026-10-31，b788/b794 probe）

- 长会话 `applyMsMax=1185ms`、`frameRateHitches=42`、`maxFrameMs=958`、`keyChanges=2212`
- 同一条 881pt 长消息 8 秒内 re-key 7 次，每次重配整段 markdown
- 8KB/100 行粘贴 → 7916pt 巨型气泡（阈值已改 2,000 字符/60 行）
- 抽屉：旧探针漏记；b794 已加 `drawer_hitch` / `noteDrawerTransition`
- 之后已合入：`a0152026`（诊断探针、120Hz 抽屉、发送键回滚）等；**旧包结论不能直接当现状**

## 3. 策略

**Phase 0 · 静态审计（本任务单落地前）**
- 读两条链路：时间线 apply/测量/重配；侧栏装配与列表惰性。
- 产出「假设 → 证据需求」清单（见 §4），不做无证据改动。

**Phase 1 · 量**
- 从当前 beta head 出 probe 包：`ios-build.yml` dispatch，`build=true`、`probe=true`。
- pp 复现：①抽屉开合 10–20 次；②长会话快速上下滑 15s（含一次流式）；各打点导出。
- 读 `FINDINGS`：`apply_spike` / `measure_spike` / `frame_hitch` / `drawer_hitch` / `shellSessionsMs*`。

**Phase 2 · 修**
- 按数据定优先级；每项单独提交、单独 gate。

**Phase 3 · 复测**
- 同一台真机、同一会话；probe + 正式包双跑；回归原有 gate。

## 4. 待证假设（先证实再改）

### A. 聊天正文

- **A1 apply 重配**：内容 revision 变化 → 整段 markdown 重配 + 同步测量。旧证据指向这里（1139ms/次）。
- **A2 离屏测量**：长会话里一次 apply 同步测量过多行；是否已按视口限窗，需要数据确认现状。
- **A3 流式 churn**：每个 chunk 触发一次 apply/reconfigure；是否合并到帧边界。
- **A4 高度 key 抖动**：wire revision / reveal / footer 快照变化导致 key 变动 → 无谓 reconfigure。

### B. 侧栏抽屉

- **B1 嵌套 Lazy 容器**：`ChatSidebarView` 的 `LazyVStack`（41 行）内嵌 `ChatSidebarProjects` 的 `LazyVStack`（36 行），再嵌 `sessionRows` 的 `LazyVStack`（173 行）。嵌套 Lazy 容器在 SwiftUI 里常退化为全量构建，会话越多越慢。
- **B2 每次 body 重建都 map+sort**：`ChatShellView.sidebarSessions`（72–88 行）在每次 `body` 求值时过滤、映射、排序全部会话；抽屉关闭时延迟写 `isOpen` 会再次触发。已有 `noteShellSessions` 计时点（79 行）说明此前已怀疑。
- **B3 每行线性查找**：`ChatSidebarView.sessionContext`（154–161 行）每行做 `projects.first` + `devices.first` → O(会话×项目)。
- **B4 主卡片合成成本**：抽屉动画对全屏聊天卡片做 transform；长会话可见 cell 多、材质/阴影/圆角叠加，可能拖慢合成。

## 5. 修复候选（等数据取用，不预先全做）

- 高度与内容 revision 解耦：只变高度不重配 cell。
- 连续测量合并到帧边界；滚动中取消低优先级测量；离屏测量限定视口 + 预算。
- markdown 解析缓存（revision + width）。
- 侧栏列表扁平化：项目/会话行合并进同一个 `LazyVStack`，去掉嵌套。
- 侧栏数据预计算：`ChatSidebarProjects` 只在数据变更时算一次；`context` 字符串预算为字典。
- 抽屉过渡期暂停时间线与侧栏重建（`sidebarDrawerIsTransitioning` 已有）。

## 6. 验收指标

- hitch（>33ms）率 < 0.5%，单帧 ≤ 50ms。
- `apply` p99 < 50ms，max < 100ms。
- 抽屉 20 次开合 hitch ≤ 2。
- 无视觉跳页/空白/位置漂移（原有 reading-anchor 断言保持绿）。

## 7. 开放问题

- S1 的「消息多了」指侧栏会话条目多，还是当前会话消息多？（probe 的 `drawer_hitch` + `shellSessionsMs*` 可区分）
- pp 当前侧栏是「按项目」还是「全部会话」？（两条路径不同，probe 报告会带列表项数）
