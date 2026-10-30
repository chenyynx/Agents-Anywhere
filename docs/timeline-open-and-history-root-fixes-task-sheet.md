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

## R6 开屏后页脚从分隔行跳走（2026-10-31 05:40 报告，"打开页面怎么乱跳一下"）

**证据（b764 探针，`long-message-20261031-054051.txt`）**
- `g:claude_compact_2391…`（压缩分隔行）在 t=4.14 由 121pt 收到 30pt，contentH 32928→32837、offset 32131→32079，0.18s 动画；t=4.12 同时新增 `g:steps:msg_23963b14`。
- 121.5 = 30（分隔行）+ 4 + 44（review 卡）+ 4 + 39.5（copy/时间行）→ ceil 121（`AssistantFooterMetrics` / `SessionTurnActionsRow.rowHeight`）。
- 结论：121 不是错误测量；是 `TimelineTurnActions.build` 把该回合的页脚挂在了"压缩分隔行"这个 Chat 渲染的 group 上。新 step group 到达后 host 迁走（或页脚被抑制），分隔行掉了 91pt，被 `animateRowHeight` 动画成可见跳动。

**根因**
- `TimelineTurnActions.build` 对回合内每个 group 都推进 `endGroupID`；分隔行（marker/system）和 Code 的 step group（`CodeStepGroupRowView` 不画页脚）都可能成为 host。host 不渲染页脚时会消失/迁移，每次迁移都让可见行改变 39.5–91pt。

**修法（一处根因，一处修复）**
- `build` 增加 host 资格：全为 marker/system 行的 group 不作 host（Chat/Code 通用）；新增 `footerHostEligible` 谓词参数，Code adapter 传入 `stepGroupsByID[group.id] == nil`。
- 非 host 的 group 仍累计 replies/changes/active（抑制规则不变）；页脚固定落在回合内最后一个可渲染的回复 group 上。
- 不改高度模型、布局或动画：分隔行不会再拿到 121pt。

**测试（红先绿后，ClientCore）**
- 回合 = user → assistant → compact 分隔行：页脚 key 必须落在 assistant group（当前实现落在分隔行）。
- 注入谓词排除 step group：页脚落在最后一个有资格的 group；无资格 group 则不产出。
- 既有用例（tool 结尾、file-change 结尾、steering）保持绿。

**验证与未覆盖**
- CI test + build（Views 不在 test target，必须看 build job）。
- 真机：打开"最后事件是压缩分隔行 + 稍后 step group"的会话，分隔行高度不得变化，页脚应位于最后一条回复下。
- 未覆盖：开屏 179 行 apply 的 258ms 主线程尖峰（步骤 7）；窗口替换瞬间的屏外 staleCell（步骤 5 证据包）。

## R7 加载历史后可见 cell 错配 → 大片空白（2026-10-31 05:56 报告）

**证据（b764 探针，`long-message-20261031-060408.txt`）**
- t=18.23 apply：`items 239→238`、`changed=0`（顶部 prompt 行被移除，整窗索引平移）。
- t=18.24 `[staleCell]` + `[fitMismatch]`：可见 cell `g:090732b8…` `frameH=1821 fit=53`（1768pt 空白），另一 cell `g:msg_e6ead750…` `frameH=44 fit=1821`——两个 cell 的内容/行高互换；`visible=1`，`maxStaleDelta=1777`。
- 现有 `syncVisibleCellFrames` 在 50ms 后才跑，且对 `usesCellReportedHeight` 的 hosted 行直接 `continue`，所以这条 1768pt 空白带没被修；下一次 apply（t=18.40）才恢复。用户看到的就是“加载页面空白”。
- 同报告的 ±30k/47k 位移不是缺陷：21.95 与 24.43 的落点 56836 精确等于 `57481 − 645`（右下角回底按钮的 one-viewport pre-place），20.4–21.3 是 `askedForStart` 的整距弹簧；均为显式滚动请求。

**根因**
- 结构性快照（窗口替换 / prompt 行增删）会改变全部 index path；UIKit 可能把 cell 移到新 index path 但没有重新绑定内容。`TimelineHostingCell` 没有记录自己配置的是哪个 item，controller 的可见校正又跳过 hosted 行，于是 cell 以旧内容 + 旧 frame 留在屏幕上，短行内容被拉进 1821pt 的 frame，剩余区域全空。

**修法**
- `TimelineHostingCell` 记录 `itemID`（configure 时写入，reuse 清空）。
- `syncVisibleCellFrames(forceHosted:layoutNow:)`：可见 cell 的 `itemID` 与当前 item 不符（含 nil）→ `reconfigureItems` 重新绑定；force 模式下同时检查 hosted 行 frame，失配即 invalidate 并同步 `layoutIfNeeded`。
- 结构性 apply（`windowReplaced || items.count != oldItems.count`）在 apply completion 内立即 `layoutIfNeeded` + 强制 reconcile，不再等 50ms。
- 探针新增 `cell reconcile rebind=N frame=N force=N` 一行（H 区），下次真机报告可直接验证。

**验证（待做）**
- CI test + build（Views 不进 test target，看 build job）。
- 真机：翻历史触发顶部 prompt 增删，页面不得出现空白带；probe 应出现 `cell reconcile` 且不再有对应 `staleCell/fitMismatch`。
- 未覆盖：t=2.88 历史页 apply 后 offset 从 6833.67 掉到 -97（锚点被顶到窗口顶部）——同一报告的第二个独立问题，见 R8，不在本修复里混改。
