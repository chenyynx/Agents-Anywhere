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

- 删除「从事件 payload 直接确认」的 `confirmEchoes`：live 与 recovery 都只从
  projection 实际并入（merge outcome）的行确认；未并入的行保持原状态。
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
  debounce 0.3s（已有本地 reconcile 时 1.5s），同会话单飞，
  之后 2/4/8s 封顶退避，成功后清零。
- 补页期间又有新行被 defer 时，projection 记下未覆盖行；旧页落地若不含它
  （`page.nextSeq` 早于该行）就保持 `hasNewerItems`，补页循环继续重试。
- 恢复联网/前台 resume 时，对被观察且窗口仍落后的会话重新排补页
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
4. `fix(ios): read the latest page authoritatively on send`（P2；开页保持本地优先）
5. `fix(ios): fill the newest window when a live row is deferred`（P3）
6. `test(ios): cover deferred newer rows and authoritative latest`（P4）
7. 审查后续：resume/联网自愈、生命周期取消、未覆盖 deferred 行的竞态修复、测试补强
   （逐条见 `git log` 与下节）

## 风险与对策

| 风险 | 对策 |
|---|---|
| 补页请求风暴 | debounce + 单飞 + 退避 |
| 抢走历史阅读位置 | 只在 `isFollowingLatest` 时补 |
| 重复行 | 补页是幂等 merge（id + supersedes），单测覆盖 |
| 丢掉已加载历史 | 用 latest 页 merge，不用整快照 hydrate |
| 行为异常需回退 | `TimelineStaleWindowHeal.enabled` 开关 |
| 本地页更旧但网络失败 | 保留本地页与 `hasNewerItems`，继续退避重试 |

## 独立审查补充（2026-11-01）

两个独立 reviewer（链路/时序、窗口/测试）均指到同一条 P1：

- **P1（已修）**：补页请求在飞行中时又有实时行被 defer，旧页落地会把
  `hasNewerItems` 清掉，而该行不在页内、cursor 又已越过它 → 永久缺行。
  修法：projection 记录「尚未被页面覆盖的 deferred 行」；latest 页落地后若仍
  不含它，保持 `hasNewerItems`，补页循环继续重试；`timeline.snapshot` 视为
  权威，清除该记录。单测 `anOlderPageDoesNotHideTheDeferredRow`。
- **生命周期（已修）**：`stop`/`dispose`/`suspend`/离线切换取消补页；
  resume/恢复联网只对被观察会话重排；`observe` 时窗口落后也会补。
- **代际（已修）**：补页读带 `readVersion` 校验，snapshot/refresh 替换窗口后
  旧页不会把已删行并回去。
- **已知限制（未修，待真机观察）**：`isFollowingLatest` 只看 projection 的
  history anchor；读者在窗口中间上滑但未触发历史翻页时 anchor 仍为 nil，
  补页的窗口裁剪理论上可能触发 `windowRevision` 重钉底部。触发需
  `hasNewerItems == true`，审查未复现；先以探针 `window_stale` 观察。

## 追加：R23（步骤行残留 running）与 R24（空行仓打不开会话）

### R23 — 步骤行一直转圈（b828 真机 2026-11-01 下午）

- 症状：工具步骤行在回合结束后仍显示 running；服务端该行已 done。
- 根因：行仓/历史页保留旧 active 副本；`mergeSingle`/`merge` 的 `supersedes`
  拒绝旧序号终态；`loadOlder` 磁盘页优先，不向服务端纠正。
- 修复：`784510ec`（终态无条件覆盖 active，`completesActiveRow`）、`f01366f7`
  （探针 STATUS / `stale_active_row`）、`b1a915af`（历史磁盘页含 active 行时
  先读服务端该区间，失败回退磁盘）。
- 验证：CI run 830 test / build / timeline-autorun 全绿；真机待验。

### R24 — 打开会话空白（b829 真机 2026-11-01 14:40）

- 证据：探针 `cursor=382522` 等于生产会话 `sess_62McfiUNa6G0AQ` 的
  `sessions.seq`；`endSeq=0 hasNewer=1 deferred=1
  latest[start 1 applied 0 skipped 0 canceled 0 failed 0] last=fill-started`。
  生产库该会话 1358 条主行，最新 200 条主行 payload 合计 11,066,525 B
  （单行最大约 2.5 MB）。服务端日志该会话 latest 请求 14:39:23 / 14:39:55 /
  14:40:54 / 14:41:59，每次 30–60 s 完成。账号 223 个会话合计 2.78 GB，
  默认缓存上限 1 GB → 行仓 LRU 淘汰删行、只留 `session_meta`
  （`TimelineDatabase.trim`：删 `timeline_items`、`has_older=1`）。
- 根因（三处叠加）：
  1. 恢复出的空窗口继承保存的 `hasNewerItems=1`。空窗口没有"最新边"，
     该标志会让所有实时行被 `mergeSingle` defer，且 `open` 仍走 latest 页。
  2. latest 页按行数（200）而不是字节设界；本会话约 11 MB。打开时
     `observe` 又排一次补页，同一大页被并发读两遍。
  3. `SessionChatModel.opensFromCachedSnapshot` 只判断投影是否存在；
     空投影被当成"已缓存"，抑制了 opening mask —— 用户看到的是伪装成
     已加载的空会话。
- 修复：`bc66f91e`、`cde97832`、`c0c643aa`、`af2d425c`
  - `settleEmptyWindow()`：恢复空窗口清 newer / deferred 水位；
  - `open` 对"恢复出空窗口"走 `refresh` → snapshot（服务端时间线预算
    2 MB + 最新一行；本会话保留 80 行 ≈ 2 MB），`refresh` 同时重建连接；
  - `latestReadInFlight` 阻止补页并发大页；fill 循环发请求前再查一次；
  - 空缓存不再算"已缓存"（本地创建除外），显示 opening mask；
  - 失败/离线保留标记并置 `needsSnapshot`，重连时由连接循环 hydrate 自动恢复；
  - `scheduleLatestFill` 只对观察中的会话生效。
- 验证：
  - 红：run 833（临时分支撤掉 `bc66f91e`/`cde97832`）→ 两条新增用例按预期
    失败（`hasNewer` 仍为 true、snapshot 0 次 / timeline 1 次、mask 未显示）；
    run 836（mutation 撤掉 `af2d425c` 的守卫）→ 新增三条用例按预期失败。
  - 绿：run 831 / 832 / 834 的 test（1256 条）以及 build、timeline-autorun
    全绿；run 835（head `c0b908fa`）test（1259 条）与 build 全绿并出包，
    timeline-autorun 在 harness 的 prepend 锚点停放检查失败
    （`screenY -673.0, expected 68.0`；该 harness 不经过本次改动的
    repository/model，run 831/832/834 的同一 gate 均绿），已重跑 run 839（同 head）timeline-autorun 绿，确认为 harness 抖动。
  - 真机：待验。装 b835 后打开被淘汰会话，应显示遮罩并在数秒内出行。
- 已知风险 / 后续：服务端 `timeline?mode=latest|history` 没有字节预算
  （2 MB 预算只在 snapshot / deferred / children）；用户手动"加载更早"或
  残留 latest 路径仍可能拉大页。列为下一次的服务器侧任务。

## 追加：R25 latest 页无字节上限 → 窗口再次冻结（2026-11-01 17:06 CST）

### 症状

b841 真机（会话 `sess_DilUOLks4LdTwg`）：发送后气泡一直转，约 60s 后提示
「上次发送的结果尚未确认」，随后回复才出现。探针（`diagnostics-20261101-170621.txt`）：

- `W endSeq=10242 cursor=153735 hasNewer=1 anchored=0 deferred=2
  latest[start 5 applied 0 skipped 0 canceled 0 failed 3] last=fill-started`
- `window_stale`：`newer` 持续 90s。
- 数据库：该会话 2656 条主行 / 40 MB；最新 200 条主行 payload 10,067 KB，
  单条最大 2.26 MB（工具行内嵌图片/文件）。
- nginx（`/var/log/nginx/moonveil_timing.log`）：同一路径的响应体
  7.0–9.8 MB，`rt=0.4–20.7s`，其中两次 499（客户端主动断开）。

### 根因

1. `timeline?mode=latest` 的 legacy 分支没有字节上限（2 MB 预算只作用于
   snapshot / deferred / children）。会话的实时尾部是工具行，latest 页被
   撑到约 10 MB；手机侧下载 1–20s，期间任意一次新的 latest 读取都会把
   `readVersion` 推高，使在飞的页在 `requireCurrent` 处被判废。
2. 自动 latest（窗口触底）、发送的 authoritative latest、补页 fill 三者
   互相判废；页越大窗口越长，形成活锁。窗口始终不前进 → 实时 echo 被
   defer → pending 永不确认 → 60s 看门狗把它降级为 uncertain。

### 修复

服务端在 v2_48 已部署 `deferActivity` 摘要窗口（`list_deferred_window`：
按展示行锚定、>8 KB 工具行用 `stub_json` 摘要、2 MB 序列化上限、span 300
行；`deferActivity` 只在 `excludeAgentChildren` 同开时生效，deferred 被
decline 时回退页同样套 2 MB 预算）。本次把客户端接到该能力上：

- 所有窗口读取（snapshot / latest / history）带 `deferActivity=true`；
  `changes` 与 `children` 不带（增量/子行必须完整）。
- 摘要行（`content.deferred=true`）展开时用 `GET /timeline/items/{id}`
  按 id 拉全文，原地替换（`V2SessionProjection.replaceDeferredItem`）；
  折叠态显示「输出预览」+ 失败/离线时的静态重试行，不显示 loading。
- 首屏与归档保存 `windowDeferredActivity`；旧归档打开时只补读一次
  （服务端回 echo 为 false 后本进程不再问）。
- 导出保持 undeferred（`exportTimeline` 显式 `deferActivity: false`）。

### 验证

- 单测（`SessionDeferredActivityTests`）：窗口读取带参、`changes`/`children`
  不带参、缺 echo 读 false、旧归档只补读一次、离线保缓存、摘要原地替换
  （旧 revision 不覆盖新行、窗口外不插入）、归档往返、摘要页治愈
  `hasNewerItems` 的冻结窗口。
- CI：iOS test + app build（build job 才是 Views 编译判据）。
- 真机：打开本会话（40 MB）应在 1–2s 内出首屏；发消息后气泡应在数秒内
  变实；工具行折叠显示「输出预览」，点开后补全文；断网时显示静态重试。

### 已知边界

- 摘要阈值 8 KB、span 300 行、2 MB 预算都由服务端控制；客户端只负责
  渲染与补读。
- 极老服务端（无 `deferActivity`/`timeline/items`）：窗口读取仍带参，
  响应无 echo → 客户端按普通完整页处理，不显示「输出预览」；补读入口
  只对 `content.deferred` 行出现，老服务端不会产生这种行。
