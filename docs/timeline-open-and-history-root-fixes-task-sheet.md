# 时间线：开屏位置与历史翻页根治任务单（2026-10-31）

> 依据 b750/b752/b753 三份真机探针报告（02:24 / 02:38 / 02:54 / 03:10）与代码核对。
> 原则：每个用户可见问题对应唯一根因，一处修复；不在同一 bug 上叠补丁。
> 相关历史：`docs/handoff-code-timeline-20261031.md`、b741–b744 的窗口/锚点工作。

## 用户可见问题

| # | 现象 | 证据（探针） |
|---|---|---|
| U1 | 重新进入后停在页面中间，几秒后才到底部 | 03:10 报告：t=0.13 `auto-older fire top=0`；t=3.71 才被拉到底；t=4.27 才触发 latest 对账 |
| U2 | 自动加载有时失效（停在顶部不加载，只能手点） | 02:24 报告：58.31 最后一次 fire 后视口一直停在 -96.67，直到报告结束无新 fire |
| U3 | 翻页后位置"跳一下" | 02:24：apply 时 anchorY 320→540（上方增长 220pt）但 offset 不动；t=53.99 settle 一次 +497 瞬时写 |
| U4 | 底部"加载新消息"提示行出现（产品决定：不要） | 03:10：t=4.30/4.34 `prompt:latest` |
| U5 | 偶发整屏一帧错位 26pt | 02:54：t=51.93 批量 staleCell dy=26 dh=0 |

## 根因与修法

### R0 开屏落底未被保护（U1）
- 根因：冷开屏前几帧内容为空、视口在顶部；`maybeAutoLoadOlder` 只看"接近顶部"，立即触发历史加载，`beginHistoryPaging` 把驱动 placement 从 `.end` 改成 `.reading`，落底意图被顶掉。
- 修法：`beginOpeningBottom` 设置 `openingBottomPending`（2s 兜底），落底被观测到（`measuredAtBottom`）或读者拖动时清除；期间禁止 near-top 触发。

### R5 删除"加载新消息"提示行（U4，产品决定）
- 根因：`TimelineItemIdentity.build` 按 `hasLatestPrompt`（= `session.hasNewerItems`）插入 `.latestPrompt` 行。
- 修法：identity 不再产出该行（参数一并删除）；回底由滚动/手势触发，不靠行。

### R1 回底武装不校验读者意图（U3 的跳变来源之一，02:54 的 +31,005）
- 根因：`beginWindowReplacementReturn` / `armWindowReplacementReturn` 武装后，窗口 apply 时 `resolveWindowReplacementBottom` 只挡 tracking/decelerating；状态栏回顶既不是 tracking 也不是 decelerating，且不置 `readerTookOver`。
- 修法：`readerIntentGeneration`（拖动起始 / 状态栏回顶 / 历史分页开始 +1）；武装时记录，执行时不一致即作废；`pendingGestureBottomRequest` 同样校验；状态栏回顶经 `onReaderScrollToTop` 置 `readerTookOver`。

### R2 自动加载闩是位置驱动（U2）
- 根因：`olderAutoLoadArmed` 只在视口离顶 >320pt 时重新上膛；页面落点恰在顶部时闩永久死亡。
- 修法：每次新的读者手势（`scrollViewWillBeginDragging`）重上膛一次。一个手势最多一页；停在顶部不会链式加载。

### R3 晚期测量修正瞬时写（U3 的"跳"半）
- 根因：历史页落点后，上方行的测量结果延迟到达（布局对"锚点上方整行"给出 correction），补偿在 settle 窗口内以 `setContentOffset` 一次写；官方模型由 Mover 应答 `rowMeasured`（`EVIDENCE/UPSTREAM/part-z-textkit-height.md:81`）。
- 修法：settle 走"重绑锚点 + `easeSettledHistoryPlacement()`"（内容弹簧），不再瞬时 `enforce`；保留一屏漂移上限，读者已离开则不拽回。

### R4 一帧 cell 错位（U5，调研先行）
- 未定位：staleCell dy=26 dh=0 的批量出现说明 apply 后那一帧 cell 未随 layoutAttributes 重配。
- 计划：先读 `scheduleVisibleCellFrameSync` / `scheduleVisibleCellSettle` 与 apply 的先后关系，再单独提交；不并入 R0–R3。

## 排期与提交
1. R0（独立）
2. R5（独立，更新 identity 测试）
3. R1（独立；含 `onReaderScrollToTop` 接线）
4. R2（依赖 R1 的代际基建，仅一行语义）
5. R3（含 settle 探针一行）
6. R4 调研（另行）

## 验证
- 红先绿后：timeline-autorun 门禁加场景（顶部武装回底→窗口替换→offset 不变；停在顶部→不链式 fire；上滑一次→fire 一次）；撤销实验在临时 worktree 做。
- 真机清单：后台切回直接落底；顶部连续上滑一页一次；停在顶部不自动连翻；翻页无离散跳；无"加载新消息"行；启动无中间态。
- CI：test + build + probe；L 级完成后派独立 reviewer（链路/时序、测试有效性）。
