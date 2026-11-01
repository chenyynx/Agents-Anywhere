# 时间线窗口冻结修复任务单（2026-11-01）

> 依据 b823 真机探针（2026-11-01 12:40:41，`long-message-20261101-124930.txt`）、生产库
> `timeline_items`（session `sess_62McfiUNa6G0AQ`，只读）与服务端日志核对。
> 原则：一个根因一处修复；先量后改；每个阶段独立提交、可单独回滚。
> 相关：`docs/timeline-open-and-history-root-fixes-task-sheet.md`（R1/R13/R16/R18/R19）、
> `docs/handoff-perf-jank-20261031.md`。

## 用户可见问题

**U1 会话像卡死：发出的消息一直转圈，agent 的回复不出现。**

b823 探针（12:40:41 导出，窗口 t=0 ≈ 12:38:17）：

- 可见行最后停在 12:33:19 那轮的 steps 组（窗口末端 `orderSeq = 7649`）。
- 12:38:55 / 12:39:19 两次发送只把 `items` 从 241 → 242 → 243（两个 pending），
  之后到导出前零 apply；`hasNewerItems` 全程为 1。
- 服务端同一时间线：7660（12:38:55「？」）、7661（12:39:19「？」）、
  7664（12:39:43 agent 回复「824 还在打包…」）、7665/7669（12:44 的第三问与回复）都在。
- 两条 pending 的 `clientMessageId` 与探针 `p:41780316…` / `p:47D13DCC…` 完全一致，
  证明不是服务端丢消息，也不是 agent 没回。
- 12:39:06 客户端发出 `/runtime/interrupt`（pp 按了停止），第一条「？」本就没有回复。

## 根因（b823 代码核对）

### R20 窗口外实时行被静默丢弃，cursor 却照常前进

- `V2SessionProjection.mergeSingle`（`V2SessionProjection.swift:341-347`）：
  `hasNewerItems == true` 时，`orderSeq > 窗口末端` 的实时创建直接 `return nil`。
  这是为「历史锚定浏览」设计的保护，但用户已经在最底部（`windowAnchor == nil`）时同样生效。
- `apply(_:)` 在丢弃后仍执行 `advanceCursor(event.cursor)`（`:162`）：
  cursor 越过了从未写入窗口的行，之后增量恢复（`runRecovery` 读 events after cursor）
  永远补不回来；只有网络 latest 页或快照能补。
- 结果：一旦本地窗口落后（本例末端 7649，服务端已有 7650+），实时流再也不会前进。

### R21 后台校准未落地（待探针钉死）

- `loadLatest` 本地优先（`V2SessionRepository.swift:408-440`）：本地页末端 ≥ 窗口末端时
  立即返回，`hasNewerAfterApply = !localIsCurrent` 把 `hasNewerItems` 保留为 true，
  再起后台 `startLatestReconcile`。
- 探针里每次 `bridge loadLatest done` 都是 `newer=1`，且之后无任何行进入窗口：
  校准要么没发起、要么被取消/版本失效、要么响应未应用。当前没有可观测字段。
- 这条不先钉死也可以修：R22 让正确性入口绕过本地旧页，R23 让「窗口外实时行」主动补页。

### R22 `confirmEchoes` 确认了窗口没接收的 echo

- `V2SessionRepository.confirmEchoes`（`:1384-1390`）只看事件 payload，不看 projection
  是否真的并入该行，就调用 `model.confirmEcho`。
- pending 变 `.confirmed` 后，模型把它从 `pendingMessages` 移除；presentation 侧
  `SessionTimelinePresentation.swift:273` 规定「confirmed 且 rows 里还没有 echo 行 → 继续显示」，
  但 echo 行被 R20 丢掉了 → 气泡永远转圈。
- 同时 `.confirmed` 的 `blocksRepeatSend == false`（`V2SessionModel.swift:129-134`），
  用户继续发同样的话只会叠加更多幽灵气泡（12:44 的第三条「？」即此）。

## 修复

### P0 诊断探针（只测量，不改行为）

- `V2SessionModel` 增加仅探针可见的窗口快照（`#if AA_TIMELINE_PROBE`）：
  `endOrderSeq / cursorSequence / hasNewerItems / anchored / latest 发起、应用、跳过、取消、失败次数 / 最后一次结果`。
- 仓库在 `emit()` 与校准关键点更新；探针报告新增 `--- WINDOW ---`；
  `hasNewer && !anchored` 持续 >5s 记一条 `window_stale` finding。
- 目的：下一个真机包直接判定 R21 是「没发起 / 被取消 / 版本失效 / 应用失败」。

### P1 pending 不再假确认（止永久转圈）

- `confirmEchoes` 确认前检查 `projection.data.items` 是否包含该 id；不包含就不确认。
- 保持 `.accepted`：`watchEcho` 的 30s/60s 兜底仍然有效；不会绕过重复发送保护。

### P2 正确性入口走权威 latest

- `loadLatest(sessionId:limit:authoritative:)`：`authoritative == true` 时跳过本地旧页，
  直接网络 latest；网络失败才退回本地页并保留 newer 标记。
- 使用入口：`noteComposerSend()`（发送）与 `watchEcho` 的 30s 兜底
  （两者都在后台 Task 里，不阻塞界面）。
- `open()` 与滚动回底保持本地优先（不让开页等网络）；本地页落后时
  `applyUsableLocalLatest` 同时排一次 P3 的保证性补页，开页后自动收敛。

### P3 窗口外实时行主动补页（断根）

- `V2TimelineMergeOutcome` 增加 `deferredNewer`：区分「因 newer 保护被丢弃」与普通忽略。
- `receive` 收到 defer 信号、且 projection 处于「跟最新」状态时，调度补页：
  debounce 0.3s，同会话单飞，失败退避 1/2/4/8/15s，成功后清零。
- `runRecovery` 结束若 `hasNewerItems && isFollowingLatest`，同样调度补页
  （覆盖断线期间 cursor 已越过缺失行的情况）。
- 读者在历史锚定中不补，回到底部后再补，保持「不抢阅读位置」。
- 开关 `TimelineStaleWindowHeal.enabled`（默认 true），可 `defaults write` 关闭。

### P4 测试与验收

- 单测：
  - projection：`hasNewerItems` + 窗口外实时创建 → `deferredNewer`；latest 页落地后行出现、flag 清除。
  - 仓库：echo 被窗口丢弃 → pending 不得 confirmed；补页落地 → confirmed 且 echo 行在 items。
  - 入口：`loadLatest(authoritative:)` 不走旧本地页；发送 / `watchEcho` 使用它；
    `open` 的本地页落后分支排保证性补页。
  - 回归：历史锚定期间实时行仍 defer，不跳位、不重复。
- 真机：杀 App 制造本地窗口落后 → 重开 → 发送；判据为 pending→echo 1s 内完成、
  回复出现、`newer=0`、`WINDOW.endSeq` 前进到最新；连发 3 条不堆幽灵气泡。
- CI：iOS test + app build（build job 才是编译判据）。

## 提交划分

1. `docs(ios): plan the stale timeline window fix`（本文件）
2. `probe(ios): record projection window and latest-fill outcomes`（P0）
3. `fix(ios): confirm a pending send only when its echo is in the window`（P1）
4. `fix(ios): read the latest page authoritatively on open and send`（P2）
5. `fix(ios): fill the newest window when a live row is deferred`（P3）
6. `test(ios): cover deferred newer rows and authoritative latest`（P4）

## 风险与对策

| 风险 | 对策 |
|---|---|
| 补页请求风暴 | debounce + 单飞 + 退避 |
| 抢走历史阅读位置 | 只在 `isFollowingLatest` 时补 |
| 重复行 | 补页是幂等 merge（id + supersedes），单测覆盖 |
| 丢掉已加载历史 | 用 latest 页 merge，不用整快照 hydrate |
| 行为异常需回退 | `TimelineStaleWindowHeal.enabled` 开关 |
| 本地页更旧但网络失败 | 保留本地页与 `hasNewerItems`，继续退避重试 |
