# AA iOS 本地消息库 / 离线缓存：Hark 报告验收（2026-10-21）

> 对象：`/home/ubuntu/wiring/docs/part-ad-local-message-store.md`（本地 `/home/ubuntu/aa-test/part-ad-local-message-store.md`）
> 方法：先查交付完整性；再用 sbx 工具抽样复现关键 EVIDENCE；与 `part-p`/`part-x` 的已知结论交叉对照；区分 EVIDENCE / INFERENCE / UNKNOWN。

## 1. 结论

**总评 A−，报告可作为产品决策依据。**

最重要的发现：**官方 Code 页没有本地消息库/离线正文**。

- Code 页只有 3 张列表表：`codeSessions` / `codeSessionResponses` / `listSyncs`。
- **没有** `messages` / `events` / `turns` / `transcript` / `blocks` / `streaming` 这类表。
- Code 正文只在内存（`SessionStore` / `SessionRegistry`）；进程被杀即丢。
- **Chat 页**（普通聊天）才有 `messages` 表 + `conversations.revision` + `OfflinePrefetcher`，离线可读。

所以“照官方 Code 页做”= **不做 Code 正文本地库**；AA 要做冷启动/离线正文，属于**超过官方 Code 页**，需要自己设计。

## 2. 抽样复现（全部通过）

| 抽验点 | 方法 | 结果 |
|---|---|---|
| 主库表存在 | `strings -a Claude \| grep 'CREATE TABLE "messages"'` 等 | ✅ 命中 `messages` / `codeSessions` / `codeSessionResponses` / `listSyncs` |
| 没有 Code 消息表 | 精确搜 `events/turns/transcript/transcripts/blocks/streaming/codeMessages/sessionEvents` 的 `CREATE TABLE` | ✅ 0 命中 |
| Code 不持有 DB | `swift_types.csv` 查 `ClaudeCode.SessionStore.Dependencies` 全字段 | ✅ 无 `DatabaseWriter` / `EntityStorage` / `PersistenceStorage` / `FileManaging` |
| Chat 离线预取器存在 | `swift_types.csv` 查 `ClaudeChat.OfflinePrefetcher` | ✅ 类型与字段存在 |
| `messages` schema | 二进制建表串 | ✅ `id TEXT PK`、`conversationId` FK CASCADE、索引；与报告一致 |

## 3. 分题评级

| 题 | 评级 | 说明 |
|---|---|---|
| Q1 表清单 | **A** | 17 张业务表全列；负向结论有搜索范围；`messages` 只属 Chat，Code 只有 3 张列表表 |
| Q2 写路径 | **A−** | Code“SSE→内存不落库”有 schema + 类型双证据；Chat `persist/persistBatch` 是整份转录写入；但 persist 的**调用时机** UNKNOWN |
| Q3 读路径 | **A−** | Chat 的 cache→network 状态机、Code 的 0 行本地读有证据；Chat `messages(id)` 的 SQL ORDER/LIMIT UNKNOWN |
| Q4 离线 | **A** | Chat 离线可读、Code 只读列表元数据；有 `OfflinePrefetcher`、屏幕枚举、状态机证据 |
| Q5 失效/裁剪 | **B+** | CASCADE/触发器/revision/pruneStale 方法有证据；`pruneStale` 阈值、TTL、VACUUM 未解 |
| Q6 游标 | **B+** | schema 无 transcript 游标/resumeToken；UserDefaults 不落盘是强 INFERENCE，未做到 EVIDENCE |
| Q7 DB 配置 | **A−** | DatabasePool/WAL、每(账号,host,组织)一库、无 SQLCipher；库文件子目录 UNKNOWN |

## 4. 关键事实（按报告的 EVIDENCE/INFERENCE 分档）

### 4.1 EVIDENCE

- `messages` 表（Chat）：`id, conversationId, sender, index, createdAt, updatedAt, content(JSON blocks), attachments, files, flags...`；FK CASCADE。
- `conversations`：`leafMessageId`、`revision`（转录失效键）。
- `codeSessions`：19 列；`served BLOB` = `SessionResource` JSON 快照（**不含转录**，只有服务端摘要文本、挂起工具 input、消息 ID 引用）。
- Code 模块没有任何 `@Table` 类型（除 `CodeSession` 本身）；DB 依赖只在 ClaudePersistence/ClaudeData/ClaudeApp 等模块。
- Code 文件写盘原语（Data.write / FileHandle / createFile）逐模块排除了转录；HTTP 缓存 `URLCache` 内存 4MiB/磁盘 0。
- Chat 的 `OfflinePrefetcher`、`MessagesLoadState{neverLoaded, liveOnly, cachedOnly, serverLoaded}`、`LoadSource{network, cache}`、`ScreenResolvedOutcome` 均有类型/字符串证据。

### 4.2 INFERENCE / UNKNOWN

- Code 正文“完全不持久化”的 UserDefaults 部分：强 INFERENCE（<=15 字节键名扫描 + 类型持有关系），不是逐指令 EVIDENCE。
- Chat `persist` 的调用时机（turn 完成/整页加载/进后台）：UNKNOWN。
- Chat `messages(id)` 运行时 SQL 的 ORDER/LIMIT：UNKNOWN（StructuredQueries 运行时拼）。
- `pruneStale` 阈值、`SessionRegistry.recent` 容量、`sessionCacheMchars` 单位：UNKNOWN。
- `FileManaging` 槽 8/19 的协议见证调用未做数据流归因；少量窄键名 UserDefaults 可能漏扫。

## 5. 对 AA 的产品含义

### 路线 A：严格对齐官方 Code 页

- **不做 Code 正文本地库**；只保留 `codeSessions` 元数据 + 列表游标。
- 离线/冷启动只能看列表，正文等网络。
- 优点：官方的真实行为，风险最低；缺点：不解决 AA 的冷启动/切会话慢。

### 路线 B：超过官方 Code 页（自建 Code 正文库）

- 官方 Code 页没有可抄的正文 schema，必须自己设计。
- 可借用 Chat 页已验证的模式：
  - `messages` 表 + `conversationId` FK CASCADE + `index`
  - `conversations.revision` 做整份转录失效键
  - `OfflinePrefetcher` + `MessagesLoadState/LoadSource`
- Code 特有、Chat 没有、必须自己补：
  - `(sessionId, sequenceNum)` 高水位（官方 `lastSequenceNum` 只在内存）
  - `olderCursor` / `resumeToken` 持久化（官方不落库）
  - 流式中途不写库：只在 turn 完成/拿到 revision 时整份写入
  - 裁剪策略（官方 `pruneStale` 阈值未知）

## 6. 建议

1. **先定产品目标**：AA 是要“和官方 Code 页一样（不存正文）”，还是“比官方多离线/冷启动正文”？
2. 如果选路线 B，下一步不是直接写代码，而是补一份**Code 正文库设计任务单**：schema、sequence/cursor、写入时机、打开读多少行、裁剪/迁移、gate。
3. 若只想先解决“切会话秒开”，可先做**进程内/内存缓存 + 列表元数据**，不急着上磁盘正文库；这与官方 Code 行为一致。
4. 报告里的 UNKNOWN 不影响路线选择，但会影响实现细节（尤其 Chat SQL 分页/裁剪阈值）。要抄 Chat 的 `OfflinePrefetcher` 前，建议再让 Hark 补 Q2/Q3/Q5 的三个 UNKNOWN。

## 7. 状态

- 报告已验收；本文只记录结论，没有改 AA 代码。
- 未合并 dev、未出包。
