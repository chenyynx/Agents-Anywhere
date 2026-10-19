# AA 会话性能方案 v2

> 审计基线：**`origin/dev @ 89d0d141`**（2026-10-18 22:35:43 +0800）
> 审计用工作树：`/home/ubuntu/aa-ring-work`（干净、detached 到该提交）
> 旧文档 `docs/perf-audit-and-plan.md` 审的是 `72bedc8d`（pre-2.1.0，落后 161 个提交），
> 92 条引用里 **47 条在 dev 上已是不同代码**。本文档不继承旧文档的任何结论。
>
> 证据等级：
> - **EVIDENCE**：在 `89d0d141` 上直接读到的代码 / 提交 / 配置
> - **INFERENCE**：由 EVIDENCE 推导，未运行验证
> - **UNKNOWN**：既没有代码证据也没有运行时证据

---

## 实施状态

| 批 | 状态 | 提交 |
|---|---|---|
| 0 观测 | ✅ 已提交 | `66e16ad7` |
| 1 不裁窗 | ⛔ 阻塞：①语义变更待确认 ②必须排在批 6 之后 | — |
| 2 积压合并 | ✅ 已提交 | `6ac21214` |
| 3 merge 增量 | ✅ 已提交 | `0817f660` |
| 4 分组缓存 | ⏳ 未开始 | — |
| 6.5 上滑锚点 | ✅ 已提交；真机：跳动减轻为"偶尔小跳" | `9060611c` |
| 6a 懒渲染 | ❌ **已尝试并回滚**：下拉加载失效、锚点测量不触发 | `c2326744` → 回滚 `47fd9408` |
| 5 行级存储 | ⏳ 未开始 | — |
| 6b UICollectionView | 🔵 已立项；**M1 任务单 v5 已写，真实 hosting cell/绝对 owed/持久底部均已用模拟器原型验证** | `docs/perf-6b-m1-task-sheet.md` |
| 7 推送 | ⏳ 待定 APNs 凭据归属 | — |
| 8 流保活 | ⏳ 待抓包结论 | — |

**6a 的教训（写进方案，避免重犯）**：`LazyVStack` 破坏了挂在子视图上的滚动机制——
`onScrollVisibilityChange`（下拉提示）与 `onGeometryChange`（历史锚点）在懒容器下不再可靠。
半吊子虚拟化不可行，容器替换必须连带重接交互（即 6b 的做法）。

分支 `perf/session-open-and-render`，工作树 `/home/ubuntu/aa-ring-work`。
**本地只有 Swift 6.0.3，未编译、未跑测试**——只做了 `swiftc -parse`（全部通过）。
CI（`.github/workflows/ios-build.yml`）是唯一的编译/测试门。

---

## Part 1 · AA 现状审计

### 1.1 打开路径（用户症状 1、2）

**入口调用链**（EVIDENCE）：

```
SessionChatModel.prepareOpening()            SessionChatModel.swift:248
 ├─ memory hit → presentOpening(suffix(100))  :257-258   （首屏立即有内容）
 ├─ await repository.open(sessionId:)         :262
 │    ├─ load()                               V2SessionRepository.swift:175
 │    │    ├─ restoreCachedSession()          :225      （仅当 entry 不在内存）
 │    │    │    └─ localStore.restoreSession  V2LocalStore.swift:18
 │    │    │         ├─ 整文件 Data(contentsOf:)          :42
 │    │    │         ├─ JSONDecoder → Envelope<Archive>   :43
 │    │    │         └─ 每行 JSONValue → V2TimelineItem    :20（actor 内，不占主线程）
 │    │    │    └─ archive.projection(items:…)  V2LocalArchive.swift:101（主线程建投影）
 │    │    └─ 有投影 → 直接返回缓存
 │    ├─ limitToLatest(100)                   :196      ★ 每次都裁
 │    └─ hasNewerItems → loadLatest(limit:100) :198     ★ 网络补最新页
 └─ 再次 presentOpening(data.items)           SessionChatModel.swift:271
```

**事实**：

| # | 事实 | 锚点 | 等级 |
|---|---|---|---|
| O1 | 每次 `open()` 都把窗口裁到最新 100 条，并把 `hasOlderItems` 置真 | `V2SessionRepository.swift:196` → `V2SessionProjection.swift:163-168` | EVIDENCE |
| O2 | 用户之前翻出来的历史页（最多 1000 条）在下次进入时被全部丢弃 | O1 的直接后果 | EVIDENCE |
| O3 | 冷进入要读整份会话文件 + 解码全部 items（上限 1000 条） | `V2LocalStore.swift:42-43`、`:20` | EVIDENCE |
| O4 | 内存常驻上限 20 个会话（LRU），超出才淘汰；观察中的条目不会被淘汰 | `V2SessionRepository.swift:8`、`:1271-1282` | EVIDENCE |
| O5 | 最后一个观察者离开时关闭 socket 并尝试淘汰 | `:286-289`、`:593` | EVIDENCE |
| O6 | 打开时若 `hasNewerItems`，会额外发一次网络请求 | `:197-198` | EVIDENCE |

**结论**：症状 2（看过的消息重载）与症状 3（上滑重新拉旧消息）**同一个根因**——O1。
症状 1（切会话等同步）的冷路径成本是 O3；热路径（entry 常驻）是内存命中，不等网络。

### 1.2 历史分页（用户症状 3）

| # | 事实 | 锚点 | 等级 |
|---|---|---|---|
| P1 | 分页必须联网，离线直接抛错 | `V2SessionRepository.swift:311` | EVIDENCE |
| P2 | 每页 100 条 | `:310`、`:322` | EVIDENCE |
| P3 | 单飞：同一会话同时只有一个 historyTask | `:314` | EVIDENCE |
| P4 | 合并历史页走 `merge(history: true)`：**重建全量字典 + 全量排序** | `V2SessionProjection.swift:192-225` | EVIDENCE |
| P5 | 窗口硬上限 1000 条，超出后向旧方向截断 | `:220`、`V2SessionRepository.swift:9` | EVIDENCE |
| P6 | 没有页级缓存：已取回的页只存在于被裁的窗口里 | O1/O2 | EVIDENCE |

### 1.3 实时同步（用户症状 1 的一半、症状 5）

| # | 事实 | 锚点 | 等级 |
|---|---|---|---|
| R1 | 只有被观察的会话才开 socket；`start()` 要求 `!entry.observers.isEmpty` | `V2SessionRepository.swift:669-671` | EVIDENCE |
| R2 | 最后一个观察者离开 → `stop(entry)` + `evict()` | `:286-289` | EVIDENCE |
| R3 | 重连退避：1/2/4/8/15/15… 秒，上限 15s | `:746-748` | EVIDENCE |
| R4 | 收到缺口帧（`sequence > seq+1`）立即触发一次 recovery round | `:779-781` | EVIDENCE |
| R5 | 每一帧都 `apply` + `emit`；`emit` 默认 `persist: true` | `:792`、`:800`、`:1199` | EVIDENCE |
| R6 | **上游的积压帧合并 `emitAfterBacklog` 在 2.1.0 合并时丢了调用点，现在是死代码** | 定义 `:1187-1197`；全仓 0 个调用 | EVIDENCE |
| R7 | 会话列表有独立的实时流（dashboard WS），不依赖打开会话 | `Business/V2DashboardService.swift:28`、`Stores/AppState.swift:354` | EVIDENCE |

**R6 的来龙去脉**（EVIDENCE）：`5536261b`（2026-10-13，上游）引入 `emitAfterBacklog` 并在 `receive` 里把 `emit` 换成它；合并提交 `fde5785c`（adopt upstream 2.1.0）的解冲突结果里调用点消失，函数定义保留。后果：断线恢复时缓冲的两层 ×2048 帧仍会逐帧触发 O(n) 重投影。

### 1.4 发送（用户症状 4 的前半）

| # | 事实 | 锚点 | 等级 |
|---|---|---|---|
| S1 | 发送是一条 HTTP POST，不做快照重取 | `V2SessionRepository.swift:408-416` | EVIDENCE |
| S2 | 回声按 `clientMessageId` 归一 | `:1213` `confirmEchoes` | EVIDENCE |
| S3 | 发送前的落盘只写当前会话（上游 `66471b5f` 已修） | `V2SessionModel.swift:449` | EVIDENCE |
| S4 | 流式期间持久化合并窗口 2.5s | `V2SessionRepository.swift:267-273` | EVIDENCE |

### 1.5 渲染（用户症状 5）

| # | 事实 | 锚点 | 等级 |
|---|---|---|---|
| V1 | 时间线是**非懒** `VStack`，所有分组一次性建视图 | `Views/Chat/ChatTimelineView.swift:588` | EVIDENCE |
| V2 | 每次 body 重新分组：`TimelineGrouping.groups(rows)` | `:574` | EVIDENCE |
| V3 | 每次 body 建 `Set(rows.map(\.id))` 和 notices 字典 | `:577-578` | EVIDENCE |
| V4 | 分组视图 `.equatable()`，未变化的分组跳过 body | `:616` | EVIDENCE |
| V5 | 每次 flush 建 `Set(rows.map(\.id))` 并全量遍历 pending | `SessionTimelinePresentation.swift:117-150` | EVIDENCE |
| V6 | 流式期间按 0.24s + 1/60s ≈ **3.9 Hz** 批量上屏 | `ReplyPresentation.swift:11`、`SessionTimelinePresentation.swift:137` | EVIDENCE |
| V7 | 空闲时按最早一个 reveal 结束时间唤醒，不是固定节拍 | `SessionTimelinePresentation.swift:178-187` | EVIDENCE |

### 1.6 推送（用户症状 4 的后半）

| # | 事实 | 锚点 | 等级 |
|---|---|---|---|
| N1 | `Info.plist` 无 `UIBackgroundModes`、无 `BGTaskSchedulerPermittedIdentifiers`、无 `aps-environment` | `ios/Agents Anywhere/Info.plist` | EVIDENCE |
| N2 | iOS 端 0 处 `registerForRemoteNotifications` / `UNUserNotificationCenter` | 全仓 grep，命中 0 | EVIDENCE |
| N3 | server 端 0 处 `apns` / `device_token` / `push_token` | `server/` grep，命中 0 | EVIDENCE |
| N4 | 因此"后台/锁屏收到通知并落到最新状态"在当前架构下**不可能** | N1–N3 的直接结论 | EVIDENCE |

### 1.7 上游 2.1.0 已经做掉的（不能重复做）

| 提交 | 内容 | 在 dev 上是否仍生效 |
|---|---|---|
| `66471b5f` | 只持久化脏会话、2.5s 合并、发送只落当前会话、trim 每 20 次 | ✅ 生效（`:253`、`:270`、`V2LocalStore.swift:31`） |
| `5536261b` | 断线积压帧合并为一次发布 | ❌ **调用点被合并丢掉（R6）** |
| `782a17e7` | 时间线事件只解析一次 + 增量合并 | ✅ 生效（`V2TimelineMergeOutcome`） |
| `54932159` | 流式 Markdown 只重解析未完成尾部 | ✅ 生效（`MarkdownStreamSplit`） |
| `fe9952de` | 行级判等 + 解析缓存 | ✅ 生效（`.equatable()`、TimelineDiff） |
| `9b16e20e` | 归档解码移进 store actor | ✅ 生效（`V2LocalStore.restoreSession`） |
| `a3e04981` | 侧栏/AppState 热路径不读 Keychain | ✅ 生效（`V2Timestamp`） |

> 注意：`V2LocalArchive.projection(maximumItems:now:)`（`:90-99`）里的 `JSONEncoder` 往返仍在，
> 但**全仓 0 个调用点**（本会话已验证）；实际恢复路径只用 `projection(items:)`（`:101`，
> 调用点 `V2SessionRepository.swift:237`）。旧文档把它当成主路径问题，是**误报**。
> 正确处置：删掉这段死代码，避免以后被误用，**不是**性能项。

---

## Part 2 · 官方对照

> 来源：`/home/ubuntu/wiring/docs/part-p…part-v`、`part-d`。每条都给了类型地址或字段名。
> 未在本次会话重新反编译的，标"报告 EVIDENCE"；本会话直接验证过的，标"已验证"。

### 2.1 存储与列表

| 维度 | 官方 | 证据 | AA | AA 证据 |
|---|---|---|---|---|
| 持久化形态 | **GRDB/SQLite**，三张表：`codeSessions`（19 列）/ `codeSessionResponses(key,entityId,position)` 槽位表 / `listSyncs(table,key,nextCursor,syncedAt)` | `EntityStorage.database: GRDB.DatabaseWriter` `0x104c886d8`（part-p，报告 EVIDENCE） | **整文件 JSON**，每会话一个 `session-<digest>.json` | `V2LocalStore.swift:38-58`（已验证） |
| 游标持久化 | `listSyncs` 表只存 `nextCursor`，**不存 resumeToken** | part-p（报告 EVIDENCE） | 归档里存 `cursor: String` | `V2LocalArchive.swift:36`（已验证） |
| 常驻会话 | `SessionRegistry.recent` 上限 **10** | `FUN_1027996fc(idx,10)` removeSubrange（part-p，报告 EVIDENCE） | 内存 20、磁盘 20 | `V2SessionRepository.swift:8`、`V2ClientServices.swift:46`（已验证） |
| 列表实时性 | 独立 SSE `v1/code/sessions/watch`，带 `resume_token`/`session_ids`/`from_sequence_num`；`session_ids` 上限 100 | `FUN_101f191a0`、`0x101f19078`（part-p，报告 EVIDENCE） | 独立的 dashboard WS | `V2DashboardService.swift:28`（已验证） |

### 2.2 打开与预热

| 维度 | 官方 | 证据 | AA | AA 证据 |
|---|---|---|---|---|
| 冷/热判据 | `SessionOpenTemperature{cold, warmMem}`，判据=内存里是否已有该会话投影 | `0x104cc0b28` 等（part-r，报告 EVIDENCE + INFERENCE） | 无显式温度，等价物是 `cached(sessionId:)` 内存命中 | `V2SessionRepository.swift:122`（已验证） |
| 预热 | `SessionPrimer` 预热的是**新建会话的服务端资源**（`PrimedSession{id,resource,placeholderTags}`），输入即预热，`headStartMs` 量化收益 | `0x104cc9184`、`0x104e7db28`（part-r，报告 EVIDENCE） | 无 | — |
| 首屏窗口 | 首屏种子页 + 双游标，不清空已有页 | part-q（报告 EVIDENCE） | 每次 `open()` 裁到最新 100 | `V2SessionRepository.swift:196`（已验证） |

### 2.3 分页

| 维度 | 官方 | 证据 | AA | AA 证据 |
|---|---|---|---|---|
| 页大小 | **200**（gap 补页 `mov w4,#0xc8`） | `0x1027f924c` 一带（part-q，报告 EVIDENCE） | 100 | `V2SessionRepository.swift:310`（已验证） |
| 游标 | 双轨：`olderCursor`（只写）+ `lastSequenceNum`（只做 max），**从不互相比较** | part-q（报告 EVIDENCE，穷举偏移访问） | 单轨：`items.first.orderSeq` + `cursor` | `:315-322`（已验证） |
| 缺口补偿 | `catch_up_truncated` 有两条路径：逐行补 / 整段重载 | part-q（报告 EVIDENCE） | 缺口帧触发 recovery round | `:779`（已验证） |

### 2.4 实时流

| 维度 | 官方 | 证据 | AA | AA 证据 |
|---|---|---|---|---|
| 帧类型 | `SessionSseFrame` 六种：`client_event`/`ephemeral_event`/`delivery_update`/`session_update`/`catch_up_truncated`/未知 | `0x101ec52f4`（part-q，报告 EVIDENCE） | V2SessionEvent + 缺口检测 | `:773-781`（已验证） |
| 三层分工 | 控制器（连接/帧）→ 装配（delta 语义）→ 发布（节流） | part-q（报告 EVIDENCE + INFERENCE） | repository（连接/投影）→ presentation（批量上屏） | `SessionTimelinePresentation.swift:155-190`（已验证） |
| 离屏会话 | `SessionRegistry.recent` 保留 10 个强引用；未证实是否保持流 | part-p / part-r（报告 EVIDENCE + UNKNOWN） | **最后一个观察者离开即断流** | `V2SessionRepository.swift:286-289`（已验证） |
| 重连宽限 | `SessionReconnectGraceStore{clock, task}`，窗口值 **UNKNOWN** | `0x104cc93a4`（part-r） | 无宽限，直接退避重连 1/2/4/8/15s | `:746-748`（已验证） |

### 2.5 发送

| 维度 | 官方 | 证据 | AA | AA 证据 |
|---|---|---|---|---|
| 队列形态 | `SessionPendingSends`：`IdentifiedArray<Entry>`，4 态 `pending/sending/posting/failed(parked:)`，单飞泵，park 可恢复 | part-s（报告 EVIDENCE） | `pendingMessages` + `sendQueue` | — |
| 崩溃恢复 | **无持久化**，靠服务端回放 | part-s（报告 EVIDENCE） | **有持久化**：只有从没上线的 `queued` 项会重放 | `V2LocalArchive.swift:70-87`（已验证） |
| 发送网络 | 一条 POST，不回读快照 | — | 一条 POST，回声按 `clientMessageId` 归一 | `V2SessionRepository.swift:408-416`（已验证） |

> AA 在发送队列持久化上**领先**官方（官方崩溃即丢），不要照抄。

### 2.6 渲染

| 维度 | 官方 | 证据 | AA | AA 证据 |
|---|---|---|---|---|
| 列表容器 | **`UICollectionView`** + 自研 `UICollectionViewLayout`（虚拟化） | part-v（报告 EVIDENCE） | SwiftUI `ScrollView` + **非懒 `VStack`** | `ChatTimelineView.swift:588`（已验证） |
| 文本排版 | **TextKit 2**（`NSTextLayoutManager`） | part-v（报告 EVIDENCE） | Textual（SwiftUI 文本库） | `ios/Packages/Textual`（已验证） |
| 帧同步 | `UIUpdateLink` + `nextPresentationCommit` | part-s / part-v（报告 EVIDENCE） | 无显式帧对齐，3.9Hz 批量上屏 | `ReplyPresentation.swift:11`（已验证） |
| 图片 | Kingfisher + `downsampledTo` | part-v（报告 EVIDENCE） | `AttachmentImageCache` + `Task.detached` 解码 | `ChatMessageAttachments.swift:239-246`（已验证） |

### 2.7 掉帧观测

| 维度 | 官方 | AA |
|---|---|---|
| 采帧 | `CADisplayLink`（mainRunLoop + commonModes，30/60/60 fps） | 无 |
| 绝对档 | >16 / >25 / >75 / >700 ms | 无 |
| 预算档 | >1× / >3× budget；hitch 三档 minor/major/severe | 无 |
| 百分位 | p50/p90/p95/p99/max | 无 |
| 反馈环 | **没有**"掉帧→降级渲染" | 无 |
| 证据 | part-t（报告 EVIDENCE） | — |

### 2.8 推送

| 维度 | 官方 | 证据 | AA |
|---|---|---|---|
| 后台模式 | `UIBackgroundModes = ['audio', 'remote-notification']` | **本会话已验证**：`/data/claude-unpack/Payload/Claude.app/Info.plist` | 无 `UIBackgroundModes`（已验证） |
| 注册链 | `PushManager.init` + `registerForRemoteNotifications` + `PushRegistrar` → `/notification/channels`，`PushChannelPost{accountId, login, organizationId, token, osPushPermissionGranted}` | part-d（报告 EVIDENCE） | 无任何推送代码（全仓 grep 命中 0，已验证） |
| 服务端 | 有 device token/通道上报 | 推断自 `/notification/channels` | server 无 `apns`/`device_token`/`push_token`（grep 命中 0，已验证） |

### 2.9 转录窗口与合并（本轮新增，来源 `part-w`）

| 维度 | 官方 | 证据 | 对 AA 的意义 |
|---|---|---|---|
| 打开时的 pager | 每次打开**新建实例**：`olderCursor=nil` / `lastSequenceNum=0` / `hasCommittedFirstSeed=0` 全部归零 | `SessionTranscriptPager.init` `0x1027bbc2c`（EVIDENCE） | AA 的 entry 是复用的；官方是每次新建 |
| 转录本体 | `SessionTranscript` 是 `Inputs` 的**派生值**（视图侧 `LazyState<SessionTranscript>`），不是滑动窗口 | `swiftinterface.txt:59598`（EVIDENCE + INFERENCE） | AA 的投影是可变结构，两者模型不同 |
| 打开时裁窗 | **正面证明：派生层不裁**。重建主体 `0x1025415e4`（1888 B）逐行读完：主循环从索引 0 走到 `Inputs.messages` 完整 count，逐条构造 entry 后 append；函数体内无 `prefix/suffix/removeFirst/removeLast`、无行数上限比较 | `part-y` §1（EVIDENCE，逐行确认） | 官方打开时不裁窗（在派生层） |
| 构造层 | `Inputs` 唯一 messages 写入点 `0x102c203bc`：messages 经 `0x102c29af4` 的 value-witness `initializeWithCopy` **全量拷贝**，无 range/count 参数；其余 8 个 builder 都是单字段 setter | `part-y` §2（EVIDENCE） | 构造层同样不裁 |
| 视图层 | `SessionMessageList.sourceMessages` 是 `let` 全量字段；`__transcriptInputs` / `__transcript` 从它构造；开屏只在旧 Inputs 为空时全量构建一次，热开不重算 | `part-y` §3（EVIDENCE + 1 处 INFERENCE） | 视图层同样不裁 |
| 残余 UNKNOWN | `SessionStore.messages` 自身装入时是否截断——上游投影层未验证 | `part-y` 未解清单 #1 | **唯一未闭合的一环** |
| 行上限 | `SessionTranscript._entries` 是 `IdentifiedArray`（底层 `OrderedDictionary`），**没有行数上限常量** | `swiftinterface.txt:62877`（EVIDENCE） | 官方靠虚拟化，不靠行数上限 |
| 页合并 `0x1027fb06c` | **水位过滤 + 顺序追加**：拍平 → `seq > 水位` 过滤（`0x1027fb320`）→ CoW 追加到裸 Swift Array → 5 个 delegate 回调 → `lastSequenceNum` 单调 max | 反编译 `/tmp/w1.txt`（EVIDENCE） | **官方不做全量排序**——批 3 的方向与官方一致 |
| 去重判据 | 序列号水位，不是行 ID 集合 | `0x1027fb320`（EVIDENCE） | AA 用 id 字典去重，机制不同 |
| 首屏种子 vs 增量 | 两个函数：种子 `0x1027f7b54`（async 一次性落地 + 派生后续任务）；增量 `0x1027fb06c`（同步纯合并） | 反编译（EVIDENCE） | AA 也用两条路径（snapshot / merge） |
| 截断重载 | 走**种子模式** `w2=1` | `0x1027fac08`（EVIDENCE） | — |
| gap 补齐重试 | 最多 **4 次** | `0x1027fc010`（EVIDENCE） | AA 的 recovery 重试策略可对照 |

**结论**
- **批 3**（单条事件不做全量排序）有官方依据：官方页合并本来就是顺序追加，从不全量排序。
- **批 1**（打开不裁窗）现在有**正面证明**：派生层、构造层、视图层三层都不裁。
  唯一未闭合的是上游 `SessionStore.messages` 装入时是否截断（UNKNOWN）。

### 2.10 发布节流 / 行派生 / 打开打点（本轮新增，来源 `part-x`）

| 维度 | 官方 | 证据 | 对 AA 的意义 |
|---|---|---|---|
| 发布节流窗口 | **编译期常量 0.1 秒**（Duration 立即数 `0x16345785d8a0000` attoseconds），**不可注入**；可注入的只有 `isEnabled` 与 `now` | `0x10276d854–d868`（EVIDENCE） | AA 的呈现节拍是 0.2567s（3.9Hz，`ReplyPresentation.swift:11`）；官方是 ≤10Hz 的发布节流 |
| 积压合并机制 | **单一 `_streamingText` 缓冲 + 装配器差异比对，没有队列** | `part-x` Q1（EVIDENCE） | AA 是"多帧合并到下一轮主队列"，机制不同但目标相同 |
| `publishPending` | "到点未发布"挂起标志 | `+0x78`（EVIDENCE） | — |
| `drainGate` | 三态 `open / draining / awaitingFreshStart` | `+0x29`（EVIDENCE） | — |
| 行派生触发 | 对 `Inputs` **逐字段 Equatable 比较**，任一变才重建；不是每帧、不是定时 | `0x102c1f518`（EVIDENCE） | AA 的分组在 view body 里重算；应改成"变化才派生" |
| 行派生算法 | **全量 for-loop + 巨型 kind switch，没有按行 memo / 脏标记 / 版本号**（负向结论） | `0x1025415e4`（EVIDENCE） | **不要做按行缓存**；官方是"变化即全量派生" |
| GRDB 读路径 | 二进制里**没有静态 SELECT**；SQL 由 StructuredQueries 运行时拼装 | `"Empty query generated by StructuredQueries"` @`0x1049514e0`（EVIDENCE） | LIMIT / ORDER BY **UNKNOWN**，不能拿官方读法当依据 |
| `SessionPage.rows` | 无静态截断；来源是网络页映射，不是本地库 | `part-x` Q3（EVIDENCE） | — |
| 打开打点 | `openStart` 写在**导航同步路径**（`DispatchTime.now()`）；`open_time` 终点在 `0x102710660`；`open_render` 有独立三门闸（openEmitted==0 && navReady==1 && !bridgeOpenStatusChecked） | `0x102711658` / `0x1027da650` / `0x1027108e0`（EVIDENCE） | AA 的批 0 应拆成 `open` 与 `first_render` 两段 |

---

## Part 3 · 归因

> 每个症状追到**一条或多条**代码路径。候选改动按"收益 ÷ 风险"排序，不按新旧方案顺序。

### 症状 1 · 切换会话要等同步

**直接根因（按影响排序）**
1. **冷路径整文件读 + 全量解码**：会话不在内存时，`restoreCachedSession` 要读完整 JSON 文件、解码整个归档、再逐条把 `JSONValue` 解成 `V2TimelineItem`（上限 1000 条）。证据：`V2LocalStore.swift:38-45`、`:18-21`、`V2SessionRepository.swift:225-246`。
2. **每次 `open()` 可能多发一次网络请求**：`hasNewerItems` 为真时走 `loadLatest(limit:100)`。证据：`V2SessionRepository.swift:197-198`。
**不是根因**：HTTP 往返本身、发送链路、归档写入（上游已把写放大修掉）。

**尚未区分的三个分叉**（谁是主因，需要批 0 的埋点才能判定）：
1. 磁盘 `session.restore` 区间（actor 解码 + 主线程建投影）
2. `open` 区间里的 `loadLatest` 网络往返
3. `session.open` 之外的视图构建（SwiftUI 首次布局）

在埋点落地前，不能断言"症状 1 就是磁盘慢"。

**候选改动**
- A. 本地行级存储（窄口径 3 张表，与官方同构）→ 只读窗口内需要的行，不再读整份文件；
- B. 页级缓存：把"已取回的页"单独存盘，按需拼接；
- C. 保留窗口（见症状 2）→ 减少冷路径触发次数。
**推荐**：C 先做（零存储改造），再做 A；B 可与 A 合一。

### 症状 2 · 看过的消息回来又"重新加载"

**直接根因**：`open()` 无条件 `limitToLatest(100)`。证据：`V2SessionRepository.swift:196` → `V2SessionProjection.swift:163-168`。
**后果**：任何一次重新进入会话，内存里 100 条以外的内容被丢弃；`hasOlderItems` 被置真，UI 又显示"加载较早的消息"。

**候选改动**
- D. **打开时不裁窗**：保留该会话上次的窗口；只在超过硬上限（1000）时按"最久未访问"裁剪。
- E. 若担心内存，给窗口设字节预算而不是条数（与官方 GRDB 的行窗口策略对齐）。

### 症状 3 · 上滑加载过的旧消息，再上滑又拉一次

**直接根因**
1. 同上 D（裁窗把已加载页丢了）；
2. `loadOlder` 必须联网，本地没有页缓存。证据：`V2SessionRepository.swift:311`。
3. 每合并一页都全量重建字典 + 全量排序。证据：`V2SessionProjection.swift:193`、`:218`。

**候选改动**
- D（不裁窗）
- F. 页缓存（磁盘行级，按 `orderSeq` 区间索引），离线可翻已看过的页
- G. `merge` 改增量插入（见症状 5）

### 症状 3b · 上滑加载时页面跳动（2026-10-19 pp 明确）

> 原话："就算裁窗，官方的那个也很丝滑，不会像我们这个一样，往上滑看以前的消息页面跳。"
> 这是**独立于"重载"**的第二个问题：数据可以重新拉，但**视口不能跳**。

**AA 现在的机制**（EVIDENCE）

```
loadOlder() 记录锚点                       ChatTimelineView.swift:306-317
  └─ TimelineHistoryPosition(origin: 已测量的 group layout, originOffset)
页面落地后
  └─ onGeometryChange(锚点 group)           ChatTimelineView.swift:617-626
       └─ historyDidLayOut → laidOut()      TimelineHistoryPosition.swift:45-54
            └─ scrollTo(y: originOffset + newY - originY)   :491-493
```

**候选根因（按可能性排序，均需埋点确认）**
1. **修正在布局之后**：`historyDidLayOut` 由 `onGeometryChange` 触发，而 `scrollTo` 又经
   `ChatLayoutUpdate.submit` → `DispatchQueue.main.async`（`ChatTimelineView.swift:510-527`）——
   至少晚一个 runloop turn。前插的那一帧，视口已经跳了。
2. **SwiftUI 对内容尺寸变化锚定顶部**：代码注释自证
   （`SessionTimelinePresentation.swift:80-83`："the scroll view anchors content-size changes to the top"）。
   前插 N 行后内容整体下移，offset 不变 ⇒ 读者看到的是原来上方的旧内容。
3. **呈现层 3.9Hz 批量**：页面落地时机受 reveal 批次影响（`ReplyPresentation.swift:11`），
   修正窗口不可控。

**官方怎么做到不跳**（EVIDENCE，`part-c §2.1–2.2`）

`TranscriptListLayout`（`UICollectionViewLayout` 子类）持有三个关键状态：

```
+0x20  offsetOwedToUpdate: CGFloat?      // 欠读者的位移
+0x29  isInsideAnUpdate: Bool
+0x10  rowsOwedToNextUpdate: ([RowID], [RowID: Double])?
```

- `prepareForCollectionViewUpdates:`（`0x101a41474`）与 `invalidateLayoutWithContext:`（`0x101a4133c`）
  都进入 update（`0x101a413fc`）
- `finalizeCollectionViewUpdates`（`0x101a416e0`）退出 update（`0x101a41618`）
- 更新期间消费 `rowsOwedToNextUpdate`（`0x101a41270`）算出欠账，写进 `offsetOwedToUpdate`
- **`targetContentOffsetForProposedContentOffset:`（`0x101a41564`）返回 `offsetOwed ?? proposed`**
  （`0x101a41544`）

**结论**：官方是在 **UIKit 的同一次 update 事务内**把 offset 修正掉的，所以没有可见跳帧。
SwiftUI 的"布局后 scrollTo"做不到同帧修正——这是**架构差异，不是参数问题**。

**候选改动**
- M. 把修正从 async 改成同步（风险：布局回调里 `scrollTo` 可能被忽略或形成循环）
- N. 改用 iOS 17+ 的 `scrollPosition(id:)` / `scrollTargetLayout()` 让系统锚定
- O. 批 6b 换 `UICollectionView` + 自研 layout（官方同构，唯一能保证同帧修正）

**⚠️ 6b 的衔接**：现有锚点测量挂在锚点 group 的 `onGeometryChange` 上（`ChatTimelineView.swift:617-633`）。
换成 collection view 后该回调不再存在；锚点必须改为布局在 `targetContentOffset` 内用新旧 attributes 求差（任务单 §3.4.2），并保留 `TimelineHistoryPosition` 的单测。
6a 已证明“懒容器不渲染离屏行 ⇒ 回调不触发”，这正是 6b 要正面接管的原因。

### 症状 4 · 没有后台推送；通知不落到最新

**直接根因**：**完全没有推送基础设施**。
- iOS：`Info.plist` 无 `UIBackgroundModes`/`aps-environment`；全仓 0 处 `registerForRemoteNotifications`/`UNUserNotificationCenter`。证据：本会话已验证。
- server：0 处 `apns`/`device_token`/`push_token`。证据：本会话 grep。
- 补充：即使有推送，离屏会话的 socket 已断（`:286-289`），冷启动仍要走症状 1 的冷路径。

**结论**：这是**独立立项**，不属于本次渲染/同步优化批次。官方同构件：`PushManager` + `PushRegistrar` + `/notification/channels`（part-d）+ 后台 `remote-notification`。

### 症状 5 · 消息多时卡顿

**直接根因（四条，全部有证据）**
1. **非懒 `VStack`**：所有分组一次性建视图。`ChatTimelineView.swift:588`。
2. **每帧全量合并 + 全量排序**：`apply(event)` → `merge([item])` → 重建整个 `byID` 字典 → `sorted()` 整个数组。`V2SessionProjection.swift:193`、`:218`。
3. **每帧 `emit`**：`receive` 末尾无条件 `emit(entry)`（默认 `persist: true`）。`:800`、`:1199`。
4. **积压帧合并是死代码**：`emitAfterBacklog` 有定义、0 调用；上游 `5536261b` 的修复在 `fde5785c` 合并时丢失。`:1187`。
5. 次要：每次 body 重新分组 + 建 `Set(rows.map(\.id))`。`ChatTimelineView.swift:574`、`:577`；每次 flush 建 `Set` 并全量遍历。`SessionTimelinePresentation.swift:119`。

**尚未区分的三个分叉**：
- 每帧 CPU（`timeline.merge` / `timeline.flush` 区间）
- 布局（非懒 `VStack` 的全量 pass）
- 视图构建（首次进入 / 窗口大改）
这三者的主导地位随场景不同（流式 vs 滑动 vs 进入），必须用埋点分开看；
不能把"消息多就卡"直接归给其中任何一个。

**候选改动（按性价比）**
- H. **恢复 `emitAfterBacklog` 调用点**（1 行）——立即把断线积压的 O(帧×n) 降成 O(帧×log n + n)
- I. **`merge` 增量插入**——单条事件不再全量排序
- J. **分组/`Set` 从 body 移出并缓存**（按 rows 身份做记忆化）
- K. **懒渲染**（`LazyVStack` 或 UICollectionView）——改动交互几何，需单独评估
- L. 埋点：先加 os_signpost，再决定 K 做不做

---

## Part 3.5 · 成本模型与每批的依据

> 回答两个问题：**钱花在哪**、**每一步的依据是什么**。
> 没有官方对照的批次必须标出来，不能冒充"官方同构"。

### A. 打开路径的成本

| 步骤 | 复杂度 | 执行线程 | 备注 |
|---|---|---|---|
| `Data(contentsOf:)` 整文件读 | O(文件字节) | actor | 单文件上限 64MB（`V2LocalStore.swift:41`） |
| 归档 JSON 解码 | O(文件字节) | actor | `V2LocalStore.swift:43` |
| 每行 `JSONValue → V2TimelineItem` | O(items) | actor | `V2LocalStore.swift:20`，上限 1000 |
| 建投影 | O(items) | **MainActor** | `V2LocalArchive.swift:101` |
| `limitToLatest(100)` | O(items) | **MainActor** | `V2SessionRepository.swift:196` |
| `loadLatest(100)` | 网络 | — | 仅 `hasNewerItems` 时（`:198`） |
| 行模型构建 | O(items) | **MainActor** | `ChatTimelineRowModel.init` + `TimelineRowStructure`，每行一次 |
| 行展示模型构建 | O(items) | **MainActor** | `TimelineEntryPresentation.init`，行 body 首次渲染时构建并缓存（`SessionTimelinePresentation.swift:54-59`，调用点 `SessionTimelineEventView.swift:106`、`:186`） |
| **视图构建 + 布局** | **O(items)** | **MainActor** | 非懒 `VStack`（`ChatTimelineView.swift:588`）：所有分组、所有行一次性建视图 |

**结论**：磁盘只是冷路径的一段。**即使 entry 常驻内存**，打开一个曾翻过很多页的会话仍要：
建 O(n) 行模型 → 建 O(n) 行展示模型 → 一次性布局 O(n) 个视图。
这三段都在主线程，**与磁盘无关**。

> 这直接解释了"当初为什么裁窗"：裁到 100 是把上面三段从 O(1000) 压回 O(100)。
> 也意味着：**不先做批 6（懒渲染），就不能取消裁窗**，否则打开会更慢，不是更快。

项目全线默认 `@MainActor`（`ios/Package.swift:16`）。

### B. 实时路径的每帧成本

| 步骤 | 复杂度 | 位置 | 批 2 后 | 批 3 后 |
|---|---|---|---|---|
| `merge` | 原 O(n log n)：重建全量字典 + 全量排序 | `V2SessionProjection.swift:193,218` | 不变（每帧仍合并） | **O(n)**：一次扫描 + 原地替换/插入 |
| `model.update` | O(n) 循环，逐行恒等比较 | `V2SessionModel.swift:500-518` | **积压时只跑 1 次** | 不变 |
| `stage` | O(n) filter + 分配数组 | `SessionTimelinePresentation.swift:107-113` | **积压时只跑 1 次** | 不变 |
| `flush` | O(n) 循环；未变化行 O(1) 早退 | `SessionTimelinePresentation.swift:28`、`:117-150` | **积压时只跑 1 次** | 不变 |
| `groups` | O(n) 分组 | `TimelineGrouping.swift:46-76`（body 里调用） | 不变 | 不变 |

**批 2 的真实作用**：不减少每帧合并，只把积压期间重复的 `model.update`/`stage`/`flush` 合并成一次。
**批 3 的真实作用**：每帧合并从 O(n log n) 降到 O(n)。

> 上游提交信息里的 "frames × log n" 说的是**发布**被合并，不是合并算法本身。

### C. 渲染路径的成本

| 事实 | 锚点 | 等级 |
|---|---|---|
| `VStack` 一次布局遍历全部子视图 | `ChatTimelineView.swift:588` | INFERENCE（SwiftUI 框架行为） |
| 流式文本高度变化 → 触发一次布局 pass | 同上 | INFERENCE |
| 每行 `.equatable()`，未变化的分组不重算 body | `:616` | EVIDENCE |
| `TimelineContent.body` 读 `rows`/`notices`/`isRunning`，任一变化就重算 `groups` | `:574-584` | EVIDENCE |
| 单行文本变化只影响该行（行模型是独立 `@Observable`） | `SessionTimelinePresentation.swift:4-50` | EVIDENCE |

**推论**：流式卡顿主要是**布局**（VStack 全量 pass）和**合并**（批 3 处理），
不是"每帧重建所有行"——`.equatable()` 和独立行模型已挡住那部分。
**批 4 的收益比我先前的说法小**：只在 body 确实重算时省一次 O(n) 分组，不是主因。

### D. 每批的依据分级（不许混淆）

| 批 | AA 侧依据 | 官方对照 | 依据等级 |
|---|---|---|---|
| 0 观测 | 无（纯工具） | `open_time` / `open_render` 的起止点已解（`part-x` Q4）；TTFT/first_text 四事件 | **官方同构（口径可对齐）**；AA 应拆 `open` 与 `first_render` 两段 |
| 1 不裁窗 | 症状 2/3 的直接根因（`V2SessionRepository.swift:196`） | **派生层 / 构造层 / 视图层三层均正面证明不裁**（`part-y` §1-§3）；上游 `SessionStore.messages` 装载未验证 | **官方同构**（唯一残余：上游投影层 UNKNOWN） |
| 2 积压合并 | 上游 AA `5536261b` | 官方是 **0.1s 常量节流** + 单 `_streamingText` 缓冲 + 装配器差异（`part-x` Q1） | **官方同族**（目标一致：一次积压只发布一次；机制不同） |
| 3 merge 增量 | `PipelineBenchmarkTests`（可量化 apply 段） | 官方页合并 `0x1027fb06c` = **水位过滤 + 顺序追加**，无排序、无字典（`part-w` 结论 3） | **官方同构**（方向一致） |
| 4 分组缓存 | body 重算时 O(n)（`ChatTimelineView.swift:574`） | 官方对 `Inputs` 做**逐字段比较，变化才全量派生**；**没有按行 memo**（`part-x` Q2） | **官方同构（方向）**：目标是"变化才派生一次"，**不是按行缓存** |
| 5 行级存储 | 冷路径整文件读（`V2LocalStore.swift:42-43`） | GRDB 三张表（`part-p`）；**读路径 LIMIT/ORDER BY 是 UNKNOWN**（SQL 运行时拼装，`part-x` Q3） | **表结构同构；读法无依据** |
| 6 懒渲染 | 非懒 VStack（`ChatTimelineView.swift:588`） | `UICollectionViewDiffableDataSource` + cell 复用 + 自研 layout | **官方同构** |
| 7 推送 | 症状 4，基础设施为 0 | `PushManager`/`PushRegistrar`/`PushChannelPost`/`UIBackgroundModes` | **官方同构** |
| 8 流保活 | 离屏即断（`V2SessionRepository.swift:286-289`） | `SessionRegistry.recent`=10；是否保流 UNKNOWN | **官方部分 + 待抓包** |

---

## Part 4 · 批次与改动

> 原则：每批可独立提交、独立回滚；行为改变与重构分开；不可逆/跨端改动单独成批。
> 路径均为绝对路径。`$IOS` = `/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere`。

### 批 0 · 观测（不改行为）

**目标**：让后面每一批都有 before/after 数据，避免"感觉快了"。

| 项 | 内容 |
|---|---|
| 新增文件 | `/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Business/PerfSignpost.swift` |
| 埋点 | `open.cold` / `open.warm` / `restore.decode` / `projection.merge` / `presentation.flush` / `first.paint` |
| 官方口径 | `open_time` 起点在**导航同步路径**（`DispatchTime.now()`，`0x102711658`/`0x1027da650`），终点 `0x102710660`；`open_render` 是独立的三门闸（`0x1027108e0`）。AA 应把 **`open` 与 `first_render` 分成两段**（`part-x` Q4） |
| 冷热判定 | `cold`/`warm_mem` 由谓词 `0x10257ef04` 的返回值决定（0→cold，非 0→warm_mem），**不是读 `navTemp` 字段**；`navTemp` 可能只是结果缓存（`part-y` Q2，修正 part-R 旧口径） |
| 开关 | 环境变量 `AA_PERF_SIGNPOST=1`，默认关闭 |
| 单测 | 无（只要求编译通过） |
| 风险 | 极低 |

**已有可用基准**：`/home/ubuntu/repos/Agents-Anywhere/ios/Tests/ClientCoreTests/PipelineBenchmarkTests.swift`
已经把 decode / apply / model / present 四段分开计时（1000 条 × 300 事件），
批 3 的前后对比直接用它。

---

### 批 1 · 打开不裁窗（症状 2/3）

**目标**：重新进入会话不再丢掉已加载的历史页。

| 项 | 内容 |
|---|---|
| 改动文件 | `/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Repositories/V2SessionRepository.swift`<br>`/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Repositories/V2SessionProjection.swift` |
| 改动 | 去掉 `open()` 里的无条件 `limitToLatest(100)`（`:196`）；改为只在 `items.count > maximumTimelineItems` 时从"最久未访问"一侧裁。`limitToLatest` 保留给"显式刷新/回收"使用 |
| 内存边界 | 每会话 1000 条 × 20 会话 = 上限 2 万条；加一条 per-entry 字节预算断言 |
| 单测 | `SessionRepositoryTests` / `OpeningFastPathTests`：①打开→翻 3 页→再打开，条数不变；②超过 1000 条时裁到 1000；③`hasOlderItems` 语义不变 |
| ⚠️ 语义冲突 | 现有用例 `SessionRepositoryTests.openingStartsWithOnePageAndExplicitHistoryAccumulatesAgain`（`ios/Tests/ClientCoreTests/SessionRepositoryTests.swift:40-42`）**写死了旧规则**：翻到 300 条后重新打开，断言只剩 201…300。这不是随手写的测试，是"每次打开从一页开始"这条产品规则。批 1 必须同步改用例，并在提交信息里写明这是**语义变更**，不是修 bug |
| 官方对照 | **三层正面证明不裁**：派生 `0x1025415e4` 全量循环、构造 `0x102c203bc` 全量 `initializeWithCopy`、视图 `sourceMessages` 全量 `let`（`part-y` §1-§3，EVIDENCE）。唯一残余：上游 `SessionStore.messages` 装载时是否截断（UNKNOWN） |
| 与批 6 的耦合 | **批 1 必须排在批 6 之后。** 非懒 `VStack` 下，打开一个 1000 条的会话要一次性建：O(n) 行模型 + O(n) 行展示模型 + O(n) 个视图并布局（`V2SessionTimelinePresentation` / `SessionTimelineEventView.swift:106` / `ChatTimelineView.swift:588`）。裁窗正是把这段压回 O(100) 的补偿。先取消裁窗会让"打开"变慢 |
| 防回归 | 现有 `OpeningFastPathTests` 全绿；新增"二次打开"用例 |
| 风险 | 中（内存、回退时的滚动位置） |
| 回滚 | 单提交还原 |

---

### 批 2 · 恢复积压帧合并（症状 5 的一半）

**目标**：把上游在 2.1.0 合并时丢掉的 `emitAfterBacklog` 调用点接回去。

| 项 | 内容 |
|---|---|
| 改动文件 | `/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Repositories/V2SessionRepository.swift` |
| 改动 | `receive()` 末尾 `emit(entry)` → `emitAfterBacklog(entry)`（`:800`）；确认 `emitScheduled` 字段仍存在（`:1292`） |
| 官方依据 | 官方是 **0.1s 常量节流**（`0x10276d854`）+ 单 `_streamingText` 缓冲 + 装配器差异，目标同样是"一次积压只发布一次"（`part-x` Q1）。机制不同，但方向可对照 |
| 单测 | 抽出 `PublishCoalescer`（纯类型：`schedule()` 多次只触发一次）后单测；或在 `ForegroundCatchUpTests` 加"连续 100 帧只发布 1 次"的断言（需要可注入的 scheduler） |
| 防回归 | `ForegroundCatchUpTests`、`RealtimeTests` |
| 风险 | 低（语义=推迟到下一轮主队列） |
| 备注 | 这行是**恢复上游已有优化**，不是新发明；提交信息要写明来源 `5536261b` 与丢失点 `fde5785c` |

---

### 批 3 · `merge` 增量插入（症状 5 的主因）

**目标**：单条事件不再重建全量字典 + 全量排序。

| 项 | 内容 |
|---|---|
| 改动文件 | `/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Repositories/V2SessionProjection.swift` |
| 改动 | 为 `timeline.item_created` / `timeline.item_updated` 增加 `mergeSingle(_:)`：二叉查找定位（按 `(orderSeq, id)`）→ 命中且 `supersedes` 则原地替换；未命中则插入。窗口守卫、`activeAgentCards` 吸收、`hasOlder/hasNewer` 语义保持原样。批量路径（snapshot/history/latest）继续用现有 `merge` |
| 单测 | `SessionProjectionTests` 扩充：①乱序插入得到与批量 merge 相同的序列；②同一 id 的 supersede；③窗口外丢弃；④activeAgentCards 不受窗口影响；⑤**属性测试**：随机 200 条事件，增量结果 == 批量重放结果 |
| 官方依据 | 官方页合并 `0x1027fb06c` 是"按 seq 水位过滤 + 顺序追加到裸 `Array`"，**从不全量排序**（`part-w` 结论 3，EVIDENCE）。本批方向与之一致 |
| 基准 | `PipelineBenchmarkTests`：记录改造前后 `apply` 段毫秒数 |
| 防回归 | 属性测试 + 现有 `TimelineItemOrderSequenceTests` |
| 风险 | 中高（顺序/去重语义是历史事故区；`SessionProjectionTests` 已有 21 条相关断言） |

---

### 批 4 · 分组与 `Set` 移出 body（症状 5 的次要项）

**目标**：`ChatTimelineView.body` 不再每次重新分组。

| 项 | 内容 |
|---|---|
| 改动文件 | `/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Models/Chat/SessionTimelinePresentation.swift`<br>`/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Views/Chat/ChatTimelineView.swift` |
| 改动 | 在 `flush()` 里当 `rows`/`notices` 变化时算一次 `groups` / `rowIDs` / `noticesByTarget`，存进 presentation；view 直接读 |
| 官方依据 | 官方对 `Inputs` 逐字段比较，**变化才全量派生**；明确**没有**按行 memo / 脏标记 / 版本号（`0x102c1f518` / `0x1025415e4`，`part-x` Q2）。本批按同一原则：变化才重算，**不做按行缓存** |
| 单测 | `SessionPresentationTests`：分组结果与逐次计算一致；notices 变化会触发重算 |
| 防回归 | `ChatLayoutStabilityTests`、`TimelineHistoryPositionTests` |
| 风险 | 中（缓存失效点漏掉 notices 会显示陈旧分组） |

---

### 批 5 · 本地行级存储（症状 1）

**目标**：冷路径只读"窗口内的行"，不再读整份文件、不再全量解码。

| 项 | 内容 |
|---|---|
| 新增文件 | `/home/ubuntu/repos/Agents-Anywhere/ios/Agents Anywhere/Agents Anywhere/Repositories/TimelineDatabase.swift` |
| 依赖 | **不加第三方**：Apple SDK 自带 `import SQLite3` |
| 表 | `session_meta(session_id PK, cursor, has_older, has_newer, last_access)`<br>`timeline_items(session_id, item_id, order_seq, updated_seq, payload BLOB, PK(session_id,item_id))` + 索引 `(session_id, order_seq)`<br>`schema_state(key PK, value)` |
| 读 | `restoreSession` 只取 `ORDER BY order_seq DESC LIMIT 300`，在 actor 内解码 |
| 写 | 只 upsert 变化的 item（配合已有 `isDirty`），删除被裁掉的行 |
| 迁移 | 首次启动：读现有 JSON 归档 → 写库 → 校验条数 → 成功后保留 JSON 一个版本 |
| 回退 | 开关 `aa.localdb`；打不开/迁移失败自动回落现有 JSON 路径 |
| 单测 | `LocalRestorationTests` 扩充：①写读往返；②单行损坏被跳过；③裁剪；④迁移幂等；⑤DB 打不开时回落 JSON |
| 风险 | 高（数据迁移，跨版本） |
| 备注 | 与官方同构（GRDB 三表），但我们 3 表里不含 `listSyncs`——列表游标已在 `V2DashboardArchive` 里 |

---

### 批 6 · 容器与布局（6a / 6b）

**6a（已尝试并回滚）**

`VStack → LazyVStack`，提交 `c2326744`，回滚 `47fd9408`。
真机结果：**下拉加载失效、历史锚点测量不触发、上滑仍跳**。

> 教训：半吊子虚拟化不可行。`onScrollVisibilityChange`（下拉提示）与
> `onGeometryChange`（历史锚点）都挂在子视图上，懒容器不保证它们存在或回调。

**6b（已立项，分两个里程碑）**

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M1** | `UICollectionView` + 自研 layout + 三级高度缓存 + 播种 + 绝对 `targetContentOffset`（append/prepend）+ 持久底部目标 | 任务单 v5：`docs/perf-6b-m1-task-sheet.md` |
| **M2** | 取消裁窗 + 用例语义更新 | 依赖 M1 |

> M1 必须包含高度播种：否则 `contentSize` 是估计值，**开屏落底无法保证**，
> 滚动时未测行也会让内容在手指下位移。这也是原 M1/M2 合并的原因。

**运行时验证（2026-10-19，模拟器，详见任务单 §12.0/§12.3）**：
- 单参数 `targetContentOffset` 在非动画 `apply` 下被调用且 owed 落地（`proposed 0 → returned 9200`）。
- 绝对 owed mid-list：`originOffset 7458 → target 16658`，锚点屏幕位移 0；重复查询幂等。
- 真实 `UIHostingConfiguration` + 异步解析：首次 45 → settled 163，自测高回调到达；
  部分可见 `aboveOrPartial` 下方锚点位移 0，`fullyAboveOnly` 位移 105。
- 流式 10 tick 只有 1 次自测高/1 次 pin，shortfall 264；控制器重解析后 0；动画 no-op 回调 0。
→ 持久底部目标不是优化项，是正确性项；补偿判据用 `aboveOrPartial`。

---

### 批 6.5 · 上滑锚点（症状 3b）

**目标**：上滑加载更早消息时，视口不跳。

| 项 | 内容 |
|---|---|
| 官方依据 | `TranscriptListLayout` 的 update 事务闸：`prepareForCollectionViewUpdates` 进入、`finalizeCollectionViewUpdates` 退出、`targetContentOffsetForProposedContentOffset:` 返回 `offsetOwed ?? proposed`——**同一次 update 内修正**（`part-c §2.1–2.2`，EVIDENCE） |
| AA 现状 | 6.5 已把 `TimelineHistoryPosition.laidOut` 移进布局回调内**同步**算并 `scrollTo`（`ChatTimelineView.swift:484-496`）；`historyLayout` 状态仍经 `historyUpdates.submit` 异步发布。6b 把它进一步移进布局的 `targetContentOffset`。 |
| 候选方案 | M 同步修正（低改动/高风险）<br>N `scrollPosition(id:)` + `scrollTargetLayout()`（系统锚定）<br>O UICollectionView（官方同构，成本最高） |
| 单测 | `TimelineHistoryPositionTests` 扩充：`laidOut` 的偏移计算、edge/firstRowID 不匹配时不修正、重复 layout 去抖（0.5pt 阈值） |
| 真机判据 | 上滑连续加载 3 页：①视口内的首行不位移；②不出现回弹；③加载完成后不再自动纠偏 |
| 风险 | 中高（方案 O 会并入批 6b） |
| 依赖 | 与批 6b 一起验证；6a 已回滚，锚点改由 layout 的 `targetContentOffset` 接管 |

---

### 批 7 · 推送（症状 4，独立立项）

**目标**：后台/锁屏能收到"回合完成"，点开落到最新。

| 端 | 改动 |
|---|---|
| iOS | `Info.plist` 加 `UIBackgroundModes=[remote-notification]`；entitlements 加 `aps-environment`；新增 `PushManager` / `PushRegistrar`；token 上报 |
| Server | 新迁移 `server/migrations/versions/v2_N.py`：`device_tokens` 表；`/notification/channels` 端点；APNs 发送器（token-based `.p8`） |
| Connector | 回合终态触发推送事件 |
| 单测 | server pytest（token 注册/去重/失效清理）；iOS 单测（注册状态机、token 变更） |
| 风险 | 高（凭据、跨端、通知权限） |
| 前置 | 先答复 pp：APNs Key 存在哪、由谁管 |

---

### 批 8 · 跨会话流保活（待抓包确认）

**目标**：前台时最近看过的会话保持热更新，而不是离开即断。

| 项 | 内容 |
|---|---|
| 现状 | 最后一个观察者离开 → `stop` + `evict`（`V2SessionRepository.swift:286-289`） |
| 官方 | `SessionRegistry.recent` 保留 10 个强引用；**是否保持流仍未证实**（part-p/part-r UNKNOWN） |
| 前置 | 抓包任务书场景 F 的结论 |
| 改动 | 若有证据：前台保留最近 N 个会话的 socket（含后台宽限定时器，对齐官方 `SessionReconnectGraceStore`） |
| 单测 | `ForegroundCatchUpTests` + 新的生命周期测试 |
| 风险 | 中（电量/流量） |
| 决策 | **没有抓包证据就不做**——不能拿推断当依据 |

---

### 批次顺序与依赖

```
批 0 观测（先有数据）
  ↓
批 2 积压合并（1 行，独立）
批 3 merge 增量（独立，与批 2 并行）
  ↓
批 4 分组缓存
  ↓
批 6.5 上滑锚点 ★ 已提交（真机：跳动减轻为"偶尔小跳"）
  ↓
批 6b 容器替换 ★ 主路径（6a 已回滚，不再作为前置）
  ↓
批 1 不裁窗（依赖 6b 的容器/窗口语义稳定）
  ↓
批 5 行级存储（依赖批 1 稳定后的窗口语义）
  ↓
批 7 推送（独立立项，可并行）
批 8 流保活（等抓包，可能不做）
```

**两条关键顺序约束**
1. `批 6b → 批 1`：裁窗的前提是容器能稳定处理 1000 行窗口；6a 的 `LazyVStack` 已证明“先懒渲染再验证”会破坏下拉/锚点，6b 是替代路径。
2. `批 6.5 → 批 6b`：6.5 的锚点语义已进 `TimelineHistoryPosition`；6b 必须把它移进 layout 的 `targetContentOffset`，并保留现有单测。

---

## Part 5 · 单测与回归

### 5.1 测试能覆盖到哪（先划边界）

| 层 | 是否进 SwiftPM 测试目标 | 后果 |
|---|---|---|
| `API` / `Network` / `Models` / `Domain` / `Business` / `Repositories` | ✅ 是 | 批 1–5 全部可单测 |
| `Views` / `Stores` / `App` / `Services` | ❌ 被 `exclude` | 批 6 只能测抽出来的纯逻辑 + 真机 |

证据：`/home/ubuntu/repos/Agents-Anywhere/ios/Package.swift:11-15`。

**推论**：批 4/6 的改动要尽量把逻辑挪进 `Models`（可测），`Views` 只保留渲染。

### 5.2 每类改动的测试写法

**A. 纯数据/状态机（批 1/2/3/4/5）**
- 位置：`/home/ubuntu/repos/Agents-Anywhere/ios/Tests/ClientCoreTests/`
- 复用现有夹具：`TestSupport.swift`、`Fixtures/`
- 重点文件：`SessionProjectionTests.swift`、`SessionRepositoryTests.swift`、`OpeningFastPathTests.swift`、`LocalRestorationTests.swift`、`SessionPresentationTests.swift`

**B. 属性测试（批 3 必做）**
```
随机生成 200 条事件（insert / update / supersede / 窗口外）
  ├─ 路径 X：逐条 mergeSingle
  └─ 路径 Y：全部丢进 merge（现有批量实现）
断言 X.data.items == Y.data.items（含 order、revision、hasOlder/hasNewer）
```
这是防止"增量插入改变顺序语义"的唯一硬保险。

**C. 基准（批 3）**
- 用现有 `PipelineBenchmarkTests`，记录改造前后 `apply` 毫秒数
- **不在 CI 里断言时间**（噪声会假红）；只在 PR 描述里贴前后数字
- 可以断言"结果正确"，例如最后一条 `revision`

**D. 真机（批 6/7）**
批 6 必须给人工步骤（5 条）：
1. 1000 条历史，快速上下甩动 10 次，观察掉帧
2. 流式输出时视口不跳
3. 上滑触发加载，锚点不跳
4. 键盘弹出/收起，底部消息不被遮
5. 深色/浅色、动态字号各来一次

### 5.3 防回归

| 手段 | 落在哪 |
|---|---|
| CI 门禁 | `.github/workflows/ios-build.yml`（`swift test --package-path ios`，macos-26） |
| 属性测试 | 批 3 |
| 二次打开用例 | 批 1 |
| 迁移幂等用例 | 批 5 |
| 开关回退 | 批 5 `aa.localdb`、批 6 `aa.timeline.collectionView` |
| 观测 | 批 0 的 signpost + `PipelineBenchmarkTests` 的前后数字 |
| 逐批提交 | 每批一个 commit，提交信息写"为什么" |

### 5.4 不能验证的部分（必须如实说）

- **本机 iOS 编译不了**：206 的 Swift 6.0.3，包要求 6.2（`ios/Package.swift:2`）→ 只能等 CI
- 因此"先红后绿"必须在 PR 上通过 CI 完成，本地只能做静态复核
- 批 6 的滚动体验、批 7 的推送到达，都只能真机验证

---

## 附录 A · 剩余 UNKNOWN（静态分析能到哪）

| # | UNKNOWN | 影响批次 | 已试路径 | 能否关闭 |
|---|---|---|---|---|
| 1 | 上游 `SessionStore.messages` 装入时是否截断 | 批 1 | `part-y` §1-§3 已证明派生/构造/视图三层；上游投影层未解 | 静态可继续挖，但不是阻塞项 |
| 2 | `SessionOpenTemperature` 谓词 `0x10257ef04` 的精确语义 | 批 0 | 调用链已通；泛型 metadata 运行时实例化 | 影响小，不影响打点拆分 |
| 3 | GRDB 的 `LIMIT` / `ORDER BY` | 批 5 | 无静态 SELECT；SQL 运行时拼装（`part-x` Q3 / `part-y` Q3） | **静态不可得**，需运行时 |
| 4 | 官方重连退避 / 心跳 / grace 窗口 | 批 8 | 全程静态分析，无抓包 | 需抓包（任务书已备） |
| 5 | 前台跨会话是否保流 | 批 8 | `SessionRegistry.recent`=10 已证；保流行为未证 | 需抓包（场景 F） |

---

## 附录 B · 审计方法

- 引用复核脚本：`/home/ubuntu/aa-test/verify_citations.py`（行锚点）、`/home/ubuntu/aa-test/compare_baselines.py`（两棵树逐行对比）
- 审计基线工作树：`/home/ubuntu/aa-ring-work`（`origin/dev @ 89d0d141`）；当前开发在 `perf/session-open-and-render`
- 抓包任务书：`/home/ubuntu/wiring/docs/capture-brief-claude-code-page.md`

---

