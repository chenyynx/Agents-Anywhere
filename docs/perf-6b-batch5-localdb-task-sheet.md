# 批 5 + 批 1 任务单：本地行级缓存与打开窗口（症状 1/2/3）

> 级别：**L**（本地存储迁移 + 跨启动数据 + 性能）
> 基线：`origin/feat/code-profile-beta @ bae413aa`（2026-10-30 11:18）
> 工作副本：`/home/ubuntu/aa-wt-attachments`（落后 origin 96 个提交，开工前先 fast-forward）
> 状态：**方案定稿（2026-10-30）；本单不含代码改动；一条需 pp 点头见 §7**
> 依据：`docs/perf-plan-v2.md` 批 1（`:499-516`）、批 5（`:565-582`）；症状定义见 `:271-400`

---

## 0. 一句话

把「每次打开裁到 100 + 冷启动整文件解码 + 翻页必须联网」换成
「**磁盘行级缓存 + 打开恢复有界窗口 + 上滑先读磁盘**」，
根治症状 1/2/3，同时不增加内存上限、不改视觉。

### 0.1 实施状态（2026-10-30）

| 阶段 | 状态 | 证据 |
|---|---|---|
| P0 基线 | ✅ 绿 | run `41006146070` attempt 2（首次为已知 flake） |
| P1 DB + 影子双写 | ✅ 绿 | run `41008278301` attempt 2（test + build） |
| P2 读切 DB | ✅ 绿 | run `41009632468`（test + build） |
| P3a 磁盘翻页 | ✅ 绿 | run `41011391791`（test + build） |
| P3b 缓存上限 + 设置 | ✅ 绿 | run `41015260898`（test + build，应用默认开启）；包 **b705** `cf0f82f` |
| P4 不裁窗 + 300 + 200 | ✅ 绿 | 审查修复后 run `41021372619`（test + build）；包 **b711** `a105e82`（语义变更 + 审查修复） |

### 0.2 独立审查（2026-10-30）

两路 reviewer（正确性 / 测试与缓存设置）已跑完；P1/P2 已修并加回归：

- **P1 行库镜像窗口**：save 从整替换改为 upsert，窗口外的已见行不再被删；补 `upsertKeepsRowsOutsideTheCurrentWindow`。
- **P1 登出竞态**：`V2LocalStore` 的 `valid` 守卫覆盖 save/restore/开库；补 `closedStoreRefusesLateWrites`。
- **清缓存空窗口**：DB `has_older` 列覆盖回归档；清/裁剪后保留 `hasOlderItems=true`，在线重开会补最新页。
- **main-only 窗口**：本地 `loadOlder`/`loadLatest` 页携带 `excludesAgentChildren`。
- **pinned 漏同步**：侧栏 pin 与远端 dashboard pin 变化都写 `session_meta.pinned`。
- **flag-off**：JSON 回退不再谎报 `localOlderAvailable`；关闭行库时清除缓存仍能删 legacy JSON。
- **回滚**：清/裁剪后写 **state-only JSON**（`state-` 前缀），草稿/待发/队列可被 flag-off 路径读到；内容 JSON 删除，防止行复活。
- **DB 落后**：JSON mtime 比 DB 最近保存新时回落 JSON。
- **缓存统计**：LRU 在打开时刷新；只统计有内容的会话；legacy JSON 计入用量；新库 `auto_vacuum=FULL` + `synchronous=NORMAL`。

**最终验证**：run `41021372619`（b711）`test` + `build` 全绿；包见 §5.5。

**残留（不阻塞 P3/P4 真机验收）**：`timeline-autorun` 的 localdb/pinned/clear 场景尚未加；旧库 `auto_vacuum` 需一次性 VACUUM；「不限制」的 4GB 安全线可能低于显式 5GB 选项；1000 行 presentation window 未做 benchmark；`TimelineSnapshot.cacheBytes` 已成为写入路径的死字段；`limitToLatest` 仅测试使用。

---

## 1. 目标 / 非目标

### 1.1 目标

1. **二次打开不再重置为 100 条**：P4 起打开时恢复磁盘窗口（有界，默认 300 条），不再 `limitToLatest(100)`；P2 先按现状 100 读库，行为不变。
2. **上滑已见过的历史走磁盘**：`loadOlder` 先查本地行；磁盘有就不联网、不转圈；磁盘没有才发网络请求。
3. **冷启动只读有界窗口**：只读 `session_meta` + 最新 W 行（P2=100，P4=300），不再整文件解码全部 items。
4. **离线可翻已见历史**：磁盘保留范围内，离线也能上滑。
5. **性能不回退**：内存窗口上限仍是 1000 条/会话、20 会话；打开/翻页/流式刷新不出现线性变慢的可见卡顿。
6. **缓存可控**：设置页可查看用量、调整上限（默认 1GB/账号）、清除缓存；pinned 会话豁免。

### 1.2 非目标

- 不做「整个会话无限常驻内存」；内存窗口仍是有界的。
- 不改服务端 / connector 契约；不新增接口。
- 不改视觉、交互、动画（除「本地加载」与「网络加载」的必要状态区分）。
- 不引入无关第三方依赖；只加已定型的 GRDB 7.11.1（MIT，exact pin）。
- 不做全文搜索、导出、跨账号数据迁移。

---

## 2. 现状（EVIDENCE，基线 `bae413aa`）

### 2.1 打开与裁窗

- `open()` 每次打开无条件裁到最新 100 条：
  `ios/Agents Anywhere/Agents Anywhere/Repositories/V2SessionRepository.swift:198`
  （`limitToLatest(100)`；上方注释 `:184-185` 明确「A page visit starts with the latest 100 records, including cached visits」）
- `limitToLatest` 的实现：`V2SessionProjection.swift:163-169`（裁到 suffix(N)，并置 `hasOlderItems = true`）
- 内存/磁盘上限：`maximumSessions = 20`、`maximumTimelineItems = 1000`
  （`V2SessionRepository.swift:8-9`）
- 首屏先用缓存 suffix(100) 上屏：`Models/Chat/SessionChatModel.swift:262`
- 若 `hasNewerItems`（或在线且 `hasOlderItems` 且窗口无主行），`open()` 会 `loadLatest(limit:100)` 用最新页替换整个窗口：
  `V2SessionRepository.swift:200-209`

### 2.2 恢复与解码

- 冷进入走 `restoreCachedSession`：`V2SessionRepository.swift:235-258`
- 本地存储读取整份 JSON 并全量解码：
  `V2LocalStore.swift:20-28`（`restoreSession` → `archive.items.compactMap`）
- 归档里存的是原始行 JSON：
  `V2LocalArchive.swift:41-47`（`items: [JSONValue]`）
- 恢复时在主线程建 projection：
  `V2SessionRepository.swift:246-250`（`archive.projection(items:...)`）
- 每文件读写上限 64MB；磁盘按会话数/总字节裁剪：
  `V2LocalStore.swift:55-62`、`:76-87`

### 2.3 翻页

- `loadOlder` 第一步就 `try requireNetwork()`：
  `V2SessionRepository.swift:322-323`
- 每页 100 条；历史页用 `applyHistory`（prefix + `hasOlderItems = page.hasMore`）：
  `V2SessionProjection.swift:154-161`
- 没有页级磁盘缓存：已取回的页只存在于被裁的内存窗口里。

### 2.4 持久化

- 2.5s 合并写：`V2SessionRepository.swift:280-287`
- 每次 flush 写整份归档：`V2SessionRepository.swift:260-277`、`V2LocalStore.swift:30-49`
- 只有整会话 `isDirty`，没有「哪些 item 变了」的集合：
  `V2SessionRepository.swift:1324`、`:1240`

### 2.5 渲染/建模成本（不裁窗后会被放大）

- presentation 对 `data.items` 全量建 `ChatTimelineRowModel`：
  `SessionTimelinePresentation.swift:158-200`
- 新容器的 adapter 每次 refresh 为整个窗口重建 `groupsByID` + `codeRowsByGroupID`：
  `Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift:57-63`、`:1641-1673`
- 行高缓存是布局内的内存缓存（不跨打开持久化）：
  `TimelineListLayout.swift:59`、`Models/Chat/TimelineCollection/TimelineHeightCache.swift`

**结论**：不裁窗后，打开 1000 条会在「全量解码 → projection → presentation 行模型 → adapter group/row」四处各付一次 O(n)。
只加行高缓存救不了；必须把「打开时进入内存的行数」限住，把历史放到磁盘按需读。

### 2.6 现有测试把旧规则写死

- `ios/Tests/ClientCoreTests/SessionRepositoryTests.swift:8`
  `openingStartsWithOnePageAndExplicitHistoryAccumulatesAgain`
  → P4 改为 `openingKeepsTheAccumulatedWindowAndExplicitHistoryStopsAtTheStart`
- `ios/Tests/ClientCoreTests/LocalRestorationTests.swift:51`
  `openingLargeDiskCacheOfflineStillStartsWithOnePage`
  → P4 改为 `openingLargeDiskCacheOfflineKeepsTheWindow`
- `ios/Tests/ClientCoreTests/OpeningFastPathTests.swift:198`
  `cachedOpeningPresentsTheTrimmedWindowWhileTheRefreshIsBlocked`
  → P4 改为 `cachedOpeningPresentsTheCachedWindowWhileTheRefreshIsBlocked`

这三条是**产品规则**不是随手写的测试；本单要改它们，提交信息必须写明「语义变更」。

---

## 3. 方案

### 3.1 总体结构

```
内存（不变）       Entry LRU 20 会话；每会话窗口上限 1000 条
   ↑ 打开只取最新 W 条（P2=100，P4=300）
磁盘（新增）       GRDB 行级存储；用户可配缓存上限（默认 1GB/账号）
                   + 每会话 5000 行保护
   ↑ 上滑/下滑先读磁盘（每批 100 条）
网络（不变）       /latest、/history 每页 100 条；磁盘没有才请求
```

**「不裁窗」的重新定义**：不是把 1000 条塞进内存，而是**不丢弃磁盘上已见过的历史**；
打开恢复有界窗口，上滑用磁盘补齐；内存窗口仍按 1000 条上限裁剪。

### 3.2 存储引擎与表结构（三张表）

- **引擎：GRDB 7.11.1**（MIT，exact pin；`swift-tools 6.1`，iOS 13+）。
  这是 2026-10-21 已定型的路线 B（`CANONICAL/13-local-persistence.md §5.2`、`aa-ios-local-store-re.md`）：
  **不用裸 SQLite3、不引 StructuredQueries**。
- 分层：`V2SessionRepository`（@MainActor，窗口/实时/dirty 调度）→ `V2LocalStore`（actor，磁盘边界/legacy fallback，持有 `GRDB.DatabasePool` + `DatabaseMigrator`）→ `TimelineDatabase`（GRDB）。
- 工程接入：`ios/Package.swift` 加 GRDB remote package（exact pin）；Xcode 工程已有 CDMarkdownKit exact pin 先例。


```sql
CREATE TABLE IF NOT EXISTS session_meta (
  session_id              TEXT PRIMARY KEY,
  cursor                  TEXT NOT NULL,
  has_older               INTEGER NOT NULL,
  has_newer               INTEGER NOT NULL,
  excludes_agent_children INTEGER NOT NULL DEFAULT 0,
  last_access             REAL NOT NULL,
  pinned                  INTEGER NOT NULL DEFAULT 0,
  cache_bytes             INTEGER NOT NULL DEFAULT 0,
  state_blob              BLOB
);

CREATE TABLE IF NOT EXISTS timeline_items (
  session_id  TEXT NOT NULL,
  item_id     TEXT NOT NULL,
  order_seq   INTEGER NOT NULL,
  updated_seq INTEGER NOT NULL,
  payload     BLOB NOT NULL,
  PRIMARY KEY (session_id, item_id)
);
CREATE INDEX IF NOT EXISTS timeline_items_window
  ON timeline_items(session_id, order_seq);

CREATE TABLE IF NOT EXISTS schema_state (
  key   TEXT PRIMARY KEY,
  value BLOB
);
```

- `payload` = `V2TimelineItem.raw`（与现有归档同源的 `JSONValue` 编码），读时 `V2TimelineItem(json:)`，不引入第二套模型。
- `state_blob` = 现有 `V2SessionArchive` **去掉 items** 后的编码：draft / draftAttachments / pending / queued / previews / recoveryDiagnostics / acknowledgedNotifications / excludesAgentChildren / subAgentActivity / draftOriginPendingID。
- `session_meta` 的 flags 与 `state_blob` 必须同事务更新。
- `cache_bytes` = 可回收缓存字节：`timeline_items.payload` + `subAgentActivity` / 附件预览；草稿、待发、队列、通知确认**不计入上限、也不被清理**。
- `pinned` 从 `V2SessionMeta.pinned` 同步（每次 flush 更新），裁剪/清除时直接按列判断，不解析 `state_blob`。
- 数据库位置：与 JSON 归档同一 scope 目录下的 `timeline.sqlite`；`WAL`、`synchronous=NORMAL`、`busy_timeout=1000`、文件排除 iCloud 备份。
- 不加密（与官方 Chat/Code 列表库一致）；文件仍用现有 JSON 写盘的 `completeFileProtectionUntilFirstUserAuthentication`。

### 3.3 读路径

1. `open()` → `load()` → `restoreCachedSession()`
2. `restoreCachedSession`：
   - 读 `session_meta`
   - `SELECT payload FROM timeline_items WHERE session_id=? ORDER BY order_seq DESC LIMIT W`（W 可配；P2 先按现状 100，P4 再切 300；取回后反转）
   - 在 DB actor 内解码成 `V2TimelineItem`（lossy：单行坏就跳过，不丢整会话）
   - 主线程建 projection（W 条，成本有界）
   - `state_blob` 恢复 draft/pending/queued/previews/通知/子代理活动
3. `hasOlderItems` 保持「服务端还有更旧」的原义；新增 `localOlderAvailable`（磁盘是否还有更旧）与 `canLoadOlder = hasOlderItems || localOlderAvailable`。
4. `open()` 的 `loadLatest` 分支：只有 `hasNewerItems`（或主行窗口为空）才替换为最新页；替换前先查磁盘，磁盘有更新的行就直接用，避免二次打开又联网。替换后磁盘历史仍在，上滑可读。

### 3.4 翻页路径

1. `loadOlder(sessionId:limit:)` 不再第一步 `requireNetwork()`。
2. **`loadLatest` 离线时本地优先，在线仍走网络**：内存窗口在翻历史时按 `prefix(1000)` 保留最旧、把最新挤出并置 `hasNewerItems`（`V2SessionProjection.swift:278-280`）。磁盘页可能落后于 live cursor；在线用本地页会把滑动期间被丢的行和 `hasNewerItems` 一起清掉。因此只在离线时用磁盘 latest 页，在线以网络页为权威。`loadLatest` 的本地页会带上 `excludesAgentChildren`，避免把 main-only 窗口翻成普通窗口。
3. 先查磁盘：
   `SELECT payload FROM timeline_items WHERE session_id=? AND order_seq < ? ORDER BY order_seq DESC LIMIT ?`
   （按当前窗口首行的 `orderSeq`；结果反转后 `applyHistory`）
4. 磁盘取到 → 直接合并、`emit`、返回；**不联网**。
5. 磁盘没有且服务端 `hasOlderItems` → 走现有网络页；拿到后 `applyHistory` + upsert 进磁盘。
6. 离线且磁盘没有 → 保持现有离线错误语义（不假装加载成功）。

### 3.5 写路径

1. `Entry` 增加 `dirtyItemIDs: Set<V2TimelineItemID>` 与 `removedItemIDs`（或等价集合）。
2. `merge` / `mergeSingle` / `applyHistory` / `applyLatest` 的 outcome 已能给出「插入/替换」的 item；在 `emit(persist: true)` 时收集到 `dirtyItemIDs`。
3. `flushCache`（仍 2.5s 合并）在一个事务里：
   - `INSERT INTO timeline_items ... ON CONFLICT(session_id,item_id) DO UPDATE SET ... WHERE excluded.updated_seq >= timeline_items.updated_seq`
   - 删除 `removedItemIDs`（窗口裁剪/缓存预算裁剪）
   - upsert `session_meta`（cursor/flags/pinned/state_blob/last_access/cache_bytes）
   - `cache_bytes` 按 payload 长度增量维护；可回收 state（子代理活动/预览）变化时同步调整
4. 发送前 `flushCache(sessionID:)` 的语义不变。
5. 主线程不碰数据库；全部在 DB actor 串行执行。

### 3.6 窗口与预算

- 内存窗口：1000 条/会话、20 会话（**不变**）。
- 打开窗口：P2 先按现状 **100**（行为不变）；P4 与删 `limitToLatest` 一起切到 **300**（可配，benchmark 后再定）。
- 网络页：**已定 200**（对齐官方 Code events 页 200）。P3 及之前保持 100（行为不变）；**P4 与窗口 300 一起切 200**，避免「本地 300 / 网络 100」两个口径。P4 后本地/网络页都按 200。
- 翻页批次：100 条（与当前网络页一致；P4 若切 200，则本地/网络页都按 200）。
- 磁盘保留：**不再硬编码 2000 行/256MB**，改由用户可配的「缓存上限」控制（见 §3.9）。
  - 默认 1GB/账号；选项 512MB / 1GB / 2GB / 5GB / 不限制。
  - 内部仍保留每会话行数保护（默认 5000 行），防止单会话把整库撑爆。
- 裁剪：全局按 `last_access` + 总字节从最久未用会话开始删；单会话超内部保护时按 `order_seq` 从最旧删。
- `pinned` 会话默认**不参与裁剪**（用户显式保留）；若 pinned 总量本身超过上限，显示提示但不强删。
- 「不限制」仍有安全上限：`min(4GB, 设备剩余空间 20%)`，超过后只裁未 pinned 会话。
- 64MB 单文件上限不再适用；数据库的预算由「总字节 + 每会话行数保护」两条控制。

### 3.7 语义与边界（必须逐条守住）

- `orderSeq` 必填；缺行丢弃（现有 `V2TimelineItem` 已强制）。
- `supersedes` 规则按 `id + updatedSeq`；upsert 不允许旧版本覆盖新版本。
- 历史页用 prefix、实时页用 suffix，窗口上限规则与现有 `merge` 一致。
- `excludesAgentChildren`（main-only 窗口）随 meta 持久化；磁盘读取沿用该读模式，不把子代理子行混进主窗口。
- `activeAgentCards` 是 sidecar，不写入 `timeline_items`；恢复时由 snapshot/merge 重新吸收。
- `subAgentActivity`（C3 子行缓存）继续放在 `state_blob`，不进主表。
- 通知、草稿、待发、队列、附件预览的恢复语义与现有归档一致。
- 账号退出/重置：先关闭 `DatabasePool`，再删目录（与现有 `localStore.close(removing:)` 同生命周期）；签名/账号切换不能读到上一个 scope 的 DB。

### 3.8 迁移、开关、回滚

- 开关：`LocalTimelineStore.enabled`（`UserDefaults` + 启动参数覆盖；默认 off，CI gate 打开）。
- 迁移：首次启动后台 actor 扫描现有 `session-*.json`（20 个以内），逐条 upsert；写完校验行数与 id 集；写 `schema_state.migrated_v1`。
- 幂等：`INSERT OR REPLACE`；迁移中断可重跑。
- 兜底：DB 打不开 / 迁移失败 / 行解码失败 → 该会话回退 JSON 路径；JSON 文件在迁移后**保留一个大版本**，不立即删。
- 损坏：DB 打不开 → 重命名为 `timeline.sqlite.corrupt-<ts>`，重建空库，回落 JSON；不阻塞打开。
- 分阶段灰度见 §4；每阶段可单独回滚。

### 3.9 用户可配缓存上限（设置页）

**产品形态**（对齐大厂 App 的通用做法）：

- 设置 → App → **缓存**
  - 显示：`已用 320 MB / 1 GB`（按账号；可选分类：会话内容 / 附件预览）
  - 上限：512MB / 1GB / 2GB / 5GB / 不限制（默认 1GB）
  - 清理：`清除缓存`（二次确认）；只删缓存，不删草稿/待发/队列/固定会话
  - 说明 footer：固定（pinned）会话不参与清理；「不限制」仍有设备安全上限
- 上限值存 App 级 `UserDefaults`（`LocalTimelineStore.cacheLimitBytes`）；每个账号的库独立按该值裁剪。设置页显示当前账号的用量。
- 存储实现：`session_meta.cache_bytes`（payload + 可回收 state）每次 upsert/delete 增量维护；总量 = `SUM(cache_bytes)`，不扫描全表。
- 触发：每次 flush 后按增量更新，超过上限时延后到空闲/进后台执行裁剪；App 启动时也检查一次。
- 清理语义：
  - 删除 `timeline_items`、`subAgentActivity`、附件预览；
  - **保留** `draft / pending / queued / draftOriginPendingID / 通知确认` 等用户工作与状态；
  - 固定会话（`V2SessionMeta.pinned`）默认豁免。
- API：`V2LocalStore.cacheUsage()`、`clearCache(keepingPinned:)`、`setLimit(_:)`；由新增 `Business/LocalCacheService.swift` 暴露给设置页（`AppState` → service）。
- 设置变更：立即按新上限执行一次裁剪；显示裁剪结果。
- 观测：设置页显示实际占用；`db.trim` signpost 记录裁剪前后字节数。

> 与官方关系：官方 Claude 的设置里**没有**用户可配的缓存上限（EVIDENCE 范围内未找到）；官方 Chat 是内部 `pruneStale/markOpened`（阈值 UNKNOWN）。这条是 AA 自加的平台惯例项，不要写成「官方同款」。

### 3.10 与官方 Claude / OpenMinis 的对照（为什么这样设计）

- **官方 Claude Code 页**：没有正文表；正文只在内存（`SessionTranscript`/`SessionStore`），进程被杀即丢，打开读 0 行正文；只有 `codeSessions/codeSessionResponses/listSyncs` 列表表。→ 本方案是**超过官方 Code**，不是对齐。
- **官方 Claude Chat 页**：有 `messages` 表 + `conversations.revision`；写入是**整份转录** `persist/persistBatch`（页面加载/预取时写，不在 0.1s 流式路径），读整会话，离线靠 `OfflinePrefetcher`。→ 本方案借它的 GRDB/WAL/Migrator、先本地后网络、失效思路；但改成**行级 upsert**、有界窗口、页缓存。
- **OpenMinis**：只作为容器/布局参照（UICollectionView 自研 layout、三级高度缓存、自测量、浏览期 defer、`contentOffsetAdjustment` 三分支）；它是同步 TextKit 1 自测量，AA 是 TextKit 2 + 离屏 hosting 预算高度；GPL-3.0，只照设计重写，不复制代码。→ 数据层与它无关。
- **AA 路线 B**：GRDB 行级存储 + 行级 diff + `supersedes` + 页缓存 + 用户可配缓存上限；正文可恢复、离线可读、内存有界。这是 AA 自建，不是官方行为。

---

## 4. 分阶段实施（每步做什么 / 动哪些文件）

> 文件数按「唯一生产文件」计；同一文件跨阶段改动不重复计数。

**实施前置（开工前）**
1. 工作副本 fast-forward 到 origin beta（当前落后 96 个提交）。
2. GRDB 7.11.1 接入 `ios/Package.swift` 并确认 CI 能解析（exact pin）。
3. P0 基线测量完成（见下）；没有基线不动手。

### P0 · 基线测量（不改行为）

**做什么**
1. 用现有 `PerfSignpost`（`session.open` / `session.restore` / `timeline.merge` / `timeline.flush`）测 500 / 1000 / 2000 / 5000 行会话的冷打开、二次打开、翻页、流式。
2. 记录当前耗时与内存峰值，作为 P2/P3 的对照基线。
3. 确认「启动时 AppState 是否 await 选中会话恢复」——如果是，记录为独立缺口（路线 B 的 P1 启动解耦，本单不含）。

**测试（1）**
- 改 `PipelineBenchmarkTests.swift`：加 restore/open 基线段（只打印，不设硬断言）。

**验收**
- 有一份可复现的基线数字；后续每阶段的同夹具数字与基线对比。

**P0 结果（CI run `41006146070`，attempt 2 绿）**

| 行数 | save | restore | projection | present | open |
|---:|---:|---:|---:|---:|---:|
| 500* | 3598.7ms | 1092.8ms | 5.8ms | 5.5ms | 1439.2ms |
| 1000 | 44.6ms | 82.1ms | 20.5ms | 12.6ms | 176.9ms |
| 2000 | 85.8ms | 163.2ms | 37.8ms | 24.1ms | 202.6ms |
| 5000 | 243.2ms | 339.2ms | 71.5ms | 73.3ms | 358.6ms |

\* 500 行是第一次迭代，含进程冷启动/首次编码器初始化的固定成本，不作为稳态；1000+ 行近似线性（restore ≈ 0.068ms/行，projection ≈ 0.014ms/行）。
第一次 run 因已知 flake `ModelSwitchRecoveryTests.stopStaysReachableWhenADeadProjectionSaysItCannotInterrupt` 失败，rerun 同 job 后绿；未改代码（与交接单 §4 的 flaky 条目一致）。

### P1 · DB + 影子双写（读仍走 JSON）

**做什么**
1. 新增 DB actor：schema、open、WAL、事务、upsert/delete/query、损坏处理。
2. 新增开关 `LocalTimelineStore.enabled`。
3. `V2LocalStore.saveSession` 在写 JSON 的同时写 DB（影子双写）；DB 写失败只记日志，不影响 JSON。
4. gate 增加「JSON vs DB 行数/id 集一致」的影子比对。

**生产文件（6）**
- 新增 `ios/Agents Anywhere/Agents Anywhere/Repositories/TimelineDatabase.swift`（GRDB）
- 改 `ios/Agents Anywhere/Agents Anywhere/Repositories/V2LocalStore.swift`
- 改 `ios/Agents Anywhere/Agents Anywhere/Business/V2ClientServices.swift`（注入 DB）
- 新增/改 `ios/Agents Anywhere/Agents Anywhere/Repositories/LocalTimelineStore.swift`（开关；也可并入 DB 文件）
- 改 `ios/Package.swift`（GRDB exact pin）
- 改 `ios/Agents Anywhere.xcodeproj/project.pbxproj`（如包引用不在 Package.swift 内，需加 package 引用）

**测试（2-3）**
- 新增 `TimelineDatabaseTests.swift`（往返/窗口/upsert/损坏）
- gate `TimelineAutoRun.swift` 增加影子比对场景

**验收**
- 开关 off：行为与当前完全一致。
- 开关 on：每次 flush 后 JSON 与 DB 行数、id 集、order_seq 一致；CI 绿。

### P2 · 读切 DB（打开窗口先保持 100）

**做什么**
1. `restoreCachedSession` 改为读 DB：meta + 最新 100 行（与现状一致；P4 再切 300）；建 projection。
2. `state_blob` 恢复所有非 timeline 状态（draft/pending/queued/previews/通知/子代理活动）。
3. 新增 `localOlderAvailable` / `canLoadOlder`；`hasOlderItems` 语义不变。
   - 迁移实现采用**惰性导入**：首次 restore 命中 JSON 归档时顺手写入 DB，不做启动全量扫描；启动路径零新增阻塞。迁移幂等，失败回落 JSON。
4. 首屏 presentation：P2 保持现状 `suffix(100)`（与打开的 100 一致）；P4 窗口切 300 时再对齐，避免 P2 出现 100→300 二次重建。

**生产文件（6）**
- 改 `Repositories/V2SessionRepository.swift`
- 改 `Repositories/V2SessionProjection.swift`
- 改 `Domain/Session/V2SessionData.swift`
- 改 `Repositories/V2LocalArchive.swift`（拆出 items/state 编码）
- 改 `Models/Chat/SessionChatModel.swift`（首屏窗口）
- 改 `Models/Session/V2SessionModel.swift`（暴露 `canLoadOlder`，UI 用它而不是只看 `hasOlderItems`）

**测试（3）**
- 新增 `LocalDBMigrationTests.swift`（旧 JSON → DB，幂等/中断/损坏回落）
- 新增/改 `LocalRestorationTests.swift`（大缓存离线打开读到 100 条有界窗口）
- 改 `OpeningFastPathTests.swift`（首屏仍是 100 条窗口；行为不变）

**验收**
- 冷启动只解码 W 行；旧归档可完整迁移；离线打开有内容。
- 首帧不倒退（`OpeningFastPathTests` 现有 instant-opening 语义不破）。

### P3 · 磁盘翻页（上滑不联网）

> 实施拆两笔提交：**P3a** 磁盘翻页（`loadOlder`/`loadLatest` + UI `canLoadOlder`）；**P3b** 缓存上限/设置页。两笔都过 CI 后才算 P3 完成。

**做什么**
1. `loadOlder` 与 `loadLatest` 都本地优先：磁盘有 → 合并返回；磁盘没有 → 网络。
2. 网络页写入 DB；离线可翻磁盘内已见历史。
3. 磁盘预算：用户可配缓存上限（默认 1GB/账号，见 §3.9）+ 每会话行数保护；裁剪最久未用会话/最旧行。
4. `canLoadOlder` 驱动 UI；离线时已见历史不显示「需要网络」错误。
5. 设置页「缓存」：用量、上限选择、清除缓存；pinned 会话豁免。

**生产文件（9）**
- 改 `Repositories/V2SessionRepository.swift`
- 改 `Repositories/V2LocalStore.swift` / `TimelineDatabase.swift`（裁剪/用量/清理）
- 改 `Repositories/V2SessionProjection.swift`（local older 查询）
- 新增 `Models/Chat/LocalCachePolicy.swift`（上限选项/格式化/安全上限）
- 新增 `Business/LocalCacheService.swift`（usage/clear/setLimit，供设置页）
- 新增 `Views/Settings/CacheSettingsView.swift`
- 改 `Views/Settings/AccountSettingsSheet.swift`（入口）
- 改 `Resources/Localization/Localizable.xcstrings`（新增文案）

**测试（4 + gate）**
- 新增 `LocalPageCacheTests.swift`（磁盘优先/离线翻页/预算/子行）
- 新增 `LocalCachePolicyTests.swift`（上限选项/安全上限/清除保留草稿与待发）
- 改 `SessionRepositoryTests.swift`（网络 spy：磁盘命中 0 次请求）
- gate `timeline-autorun` 增加「上滑已见消息」与「缓存上限/清除」场景

**验收**
- 已见历史 <= 缓存上限范围：上滑 0 网络请求、无 spinner、顺序正确。
- 超出范围：正常联网；离线给明确错误。
- 设置页显示真实用量；改上限后按新值裁剪；清除缓存后草稿/待发/固定会话仍在。

### P4 · 放开「不裁窗」语义 + 清理

**做什么**
1. 删除 `open()` 的 `limitToLatest(100)`；窗口上限仍 1000，磁盘按预算裁剪。
2. 网络页与本地页 100→200（对齐官方 Code events 页）。
3. 更新三条写死旧规则的测试（语义变更）。
4. 首屏 presentation 与打开窗口对齐（W=300），避免 100→300 的二次重建。
   - 条件项：若 P3 benchmark 显示 1000 条窗口的 adapter refresh 超阈值，再加 presentation window（默认 300/500）或按需建组；否则不在本阶段做。
5. 稳定一个大版本后：停 JSON 写，保留只读兜底；删除 `V2LocalArchive.projection(maximumItems:)` 死代码（当前 0 调用）。
6. 提交信息写明「语义变更，不是修 bug」。

**生产文件（3）**
- 改 `Repositories/V2SessionRepository.swift`
- 改 `Models/Chat/SessionChatModel.swift`
- 改 `Models/Chat/SessionTimelinePresentation.swift`（如需要窗口化）

**测试（3 + 文档）**
- 改 `SessionRepositoryTests.swift:8`
- 改 `LocalRestorationTests.swift:51`
- 改 `OpeningFastPathTests.swift:198`
- 新增/改 `PipelineBenchmarkTests.swift`（restore/loadOlder 基准）

**验收**
- 二次打开、上滑、离线、流式中重进 全部符合 §1.1。
- 三条语义测试改为新规则后全绿；旧规则不再被断言。

### 文件总数（唯一计）

- **生产代码：17-18 个**（新增 DB actor / 开关 / 缓存策略 / 缓存服务 / 设置页；改 Package.swift / project.pbxproj + 10 个源文件 + 本地化；P4 如需 presentation 窗口再加 1 个）
- **测试/gate：11 个**（新增 4 个测试文件；改 4 个既有测试、2 个 gate、1 个 benchmark）

### 出包与验收节奏（回答「每个阶段都要出包测试吗」）

**不需要每个阶段都让你装包。** 只有 P3/P4 是用户可见变化：

| 阶段 | 用户可见变化 | 出包 | 谁来验 |
|---|---|---|---|
| P0 基线 | 无 | 不出包 | 内部跑 benchmark |
| P1 影子双写 | 无（读仍 JSON） | 不出包 | CI + 影子比对 gate |
| P2 读切 DB | 无（窗口仍 100） | 不出包（可选内部 smoke 包） | CI + 自动 gate |
| P3 磁盘翻页 + 缓存设置 | **有**（设置页、上滑不联网） | **出 1 个 IPA** | pp 真机验收 |
| P4 不裁窗 + 300 + 200 | **有**（打开/翻页行为变化） | **出 1 个 IPA** | pp 真机验收 |

- 所以正常节奏是 **2 个 pp 验收包**（P3、P4），不是 4 个。
- 每阶段一个提交；出问题时用 `aa.localdb` 开关立即回 JSON，不用回滚整包。
- 如果你希望少一轮：P3+P4 可以合成一个验收包，但回滚粒度会变粗（缓存设置和语义变更绑在一起）。

---

## 5. 测试方案

### 5.1 新增单测

| 文件 | 覆盖 |
|---|---|
| `TimelineDatabaseTests.swift` | 建库/round-trip、窗口查询（DESC LIMIT + 反转）、upsert/supersede 不倒退、删除/裁剪、坏行跳过、事务原子性、并发 actor 串行、WAL 重开 |
| `LocalDBMigrationTests.swift` | JSON→DB 迁移、幂等、中断续跑、行数/id 集校验、DB 打不开回落 JSON、损坏重命名 |
| `LocalPageCacheTests.swift` | 磁盘优先（网络 0 请求）、离线翻页、`loadLatest` 磁盘优先、每会话/总字节预算、main-only 不混子行、子代理活动仍可恢复 |
| `LocalCachePolicyTests.swift` | 上限选项解析/夹取、默认 1GB、pinned 豁免、「不限制」安全上限、清除缓存保留草稿/待发/队列/通知、用量计算 |

### 5.2 修改既有测试（语义变更，逐条写明）

- `SessionRepositoryTests.openingStartsWithOnePageAndExplicitHistoryAccumulatesAgain`
  → `openingKeepsTheAccumulatedWindowAndExplicitHistoryStopsAtTheStart`：二次打开保留 300 条窗口；显式历史到开头后不再联网。
- `LocalRestorationTests.openingLargeDiskCacheOfflineStillStartsWithOnePage`
  → `openingLargeDiskCacheOfflineKeepsTheWindow`：离线打开保留 1...300（W=300）。
- `OpeningFastPathTests.cachedOpeningPresentsTheTrimmedWindowWhileTheRefreshIsBlocked`
  → `cachedOpeningPresentsTheCachedWindowWhileTheRefreshIsBlocked`：缓存 1...120 直接上屏，无裁窗。

### 5.3 门禁

- `timeline-autorun`：新增
  1. 冷启动离线打开老会话；
  2. 上滑已见消息（断言 0 网络 + 行序）；
  3. 流式中杀进程重进；
  4. 20 会话 LRU + 用户缓存上限（1GB/较小值/不限制）+ pinned 豁免 + 清除缓存。
- `code-profile`：确认新窗口不改变 Code 页行/高度/滚动锚定。
- 双路径：flag on 一轮、flag off 一轮，均绿。

### 5.4 性能

- signpost 沿用：`session.open`、`session.restore`、`timeline.merge`、`timeline.flush`；
  新增 `db.open`、`db.restore`、`db.older`、`db.upsert`。
- 夹具：500 / 1000 / 2000 / 5000 行；测 restore 与 loadOlder。
- 目标（相对值，Simulator Debug 不当作绝对性能）：
  - 冷 restore 的耗时 ≤ 当前整份 1000 行 JSON restore 的 1/3；
  - restore 耗时随磁盘行数增长 **不显著**（只读 W 行）；
  - `session.open` 主线程段 < 100ms（设备基线另测）；
  - 首帧 presentation 不倒退。
- `PipelineBenchmarkTests` 增加 restore/loadOlder 段。
- 缓存裁剪：`db.trim` signpost；1GB 上限、20 会话、每会话 5000 行的夹具下，一次裁剪（删最旧会话/行）主线程 0 阻塞，DB actor 耗时记录在案。

### 5.5 真机验收（pp）

1. 冷启动离线进入一个老会话：有内容、不空白。
2. 翻 3 页 → 杀进程 → 重进 → 再上滑：已见消息不转圈、不重复拉。
3. 上滑过程中观察：无跳动、无 spinner、滚动锚点不丢。
4. 流式中重进：最新页替换后，上滑仍能读磁盘历史。
5. 20 会话来回切：内存/磁盘预算生效，无 OOM。
6. 磁盘满/损坏：不崩溃，回落 JSON。
7. Dynamic Type / 深色模式：窗口与行高不破。
8. 设置 → 缓存：用量显示正确；切 512MB/1GB/不限制 后按新值裁剪；清除缓存后草稿/待发/固定会话仍在。
9. pinned 会话在缓存超限时不被清；「不限制」超安全线时只裁未 pinned。

**测试包（unsigned，需自行签名）**
- **最终包（P3+P4 + 审查修复）：b711 `a105e82`**
  `https://github.com/chenyynx/Agents-Anywhere/releases/download/ipa-feat-local-timeline-store/AgentsAnywhere-feat-local-timeline-store-b711-a105e82.ipa`
- 早期 b705（P3）/ b707（P4）早于审查修复，**不要用**；b710 因 PRAGMA 只读连接错误没有产出包。

---

## 6. 风险与回滚

| 风险 | 处理 |
|---|---|
| 迁移损坏/中断 | 幂等 upsert；校验失败回落 JSON；DB 文件重命名保留 |
| 旧版本数据（字段缺失/未知） | lossy 解码，单行跳过；不整会话失败 |
| main-only 窗口混入子行 | 读取沿用 `excludesAgentChildren`；gate 断言 |
| 实时帧与磁盘写竞争 | 单 actor + 事务；`updated_seq` 防倒退 |
| 内存/磁盘预算失控 | 用户缓存上限（总字节）+ 每会话行数保护；gate 断言 |
| 缓存上限设得过小 | 属预期：只保留近期/固定会话；设置页显示用量与说明；不阻塞打开 |
| 磁盘满 / DB 写失败 | 写失败不阻塞发送；保留 JSON 路径；提示清理；DB 损坏重命名后回落 |
| 打开窗口与首屏不一致 | P2 同时改 presentation 与 open；`windowRevision` 断言 |
| 大窗口 adapter O(n) | P3/P4 benchmark；若超阈值，再加 presentation 窗口或懒 group 构建（单独任务） |
| 回滚 | 每阶段一个提交；flag off 立即回 JSON；不删 JSON 文件直到 P4 稳定 |

---

## 7. 定稿默认值（如无异议按此实施）

| 项 | 定稿值 |
|---|---|
| 存储引擎 | GRDB 7.11.1（MIT，exact pin） |
| 灰度 | P1 双写影子 → P2 切读 → P3 磁盘翻页 → P4 放开语义 |
| 打开窗口 W | P2=100（行为不变）；P4=300 |
| 网络页 | 当前 100；P4 切 200（已定，对齐官方 Code events 页） |
| 内存窗口 | 1000 条/会话、20 会话 |
| 缓存上限 | 默认 1GB/账号；选项 512MB/1GB/2GB/5GB/不限制 |
| 每会话保护 | 5000 行 |
| pinned | 默认豁免裁剪/清除 |
| 「不限制」安全线 | `min(4GB, 设备剩余空间 20%)`，超过只裁未 pinned |
| 清除缓存 | 保留草稿/待发/队列/通知确认/pinned；只删正文行与预览 |
| JSON 兜底 | 迁移后保留一个大版本，之后停写只读 |

**只需要你明确点头的一条：**

1. **语义变更**：把「每次打开从一页开始」改为「保留磁盘窗口」，三条既有测试要改断言（提交信息会写明语义变更）。

网络页 200 已按你的指示定稿（P4 切），不再作为待定项。

---

## 8. 顺带发现（不在本单修）

- `V2LocalArchive.projection(maximumItems:)` 当前 0 调用（只 `projection(items:)` 被用），P4 可删。
- adapter 每次 refresh 仍为整个窗口建 groups/codeRows（`TimelineChatContentAdapter.swift:57-63`、`:1641`）；P3 benchmark 若显示超阈值，另开任务做「按需建组」，不在本单硬塞。
- `presentOpening` 当前先用 `suffix(100)` 上屏（`SessionChatModel.swift:262`），P4 会与 W=300 对齐；需要真机确认首帧不倒退。
- 磁盘 64MB 单文件上限与 128MB 总裁剪是旧 JSON 路径的预算，行级库换成行数+总字节后要同步更新文档与 gate。
- 路线 B 的「P1 启动解耦」（AppState 不 await 选中会话恢复、cached ID 索引、磁盘缓存不显示全屏 mask）不在本单；P0 基线若显示启动阻塞明显，单独排。
- 「全量回填/有界预热」（官方 Chat `OfflinePrefetcher` 模式，后台把整个会话拉完）不在本单；本单只做用户可配缓存 + pinned 永久保留。需要“从没取过的旧页也能离线看”时再开 P5。
