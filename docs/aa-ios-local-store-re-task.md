# AA iOS 本地消息库 / 离线缓存 逆向任务单（2026-10-21）

> 目标：把官方 Claude iOS App 的**会话消息本地持久化、打开会话读路径、离线/冷启动行为**逆清楚，供 AA 决定是否/如何做本地消息库。
> 执行：Hark（sbx）。只读逆向，不改 AA 仓库。
> 证据分档：**EVIDENCE**（指令/反编译/类型元数据直读）· **INFERENCE**（结构推出，未逐条验证）· **UNKNOWN**（查不到，写明试过什么）。
> 输出：结论先行 + 每题分档 + 地址；拿不到就写 UNKNOWN，不要猜。

## 0. 一句话

上一轮只逆到“Code 页**会话列表**用 GRDB 持久化”，没有回答“**消息正文是否落库、打开会话从本地读多少、离线/冷启动能不能先显示**”。本单只补这三类问题。

## 1. 已有证据（不要重做）

先读：

- `/home/ubuntu/wiring/docs/part-p-code-list-storage.md`
  - `EntityStorage<T0,T1>` 第一字段是 `GRDB.DatabaseWriter`（`0x104c886d8`）
  - 表：`codeSessions`（19 列）、`codeSessionResponses(key,entityId,position)`、`listSyncs(table,key,nextCursor,syncedAt)`
  - 列表分页 = 游标 + `FixedRequest`；watch 走 `v1/code/sessions/watch`
- `/home/ubuntu/wiring/docs/part-x-publish-derive-db.md`
  - 发布节流 0.1s；行派生全量重建，无按行缓存
  - GRDB 读 SQL 由 StructuredQueries 运行时拼装，二进制无静态 SELECT
  - 打开会话主链**未发现**整表读 `codeSessionResponses`/`events`；确切行数/LIMIT UNKNOWN
- `/home/ubuntu/wiring/docs/part-c.md`
  - `SessionTranscriptPager`：opaque cursor + 本地 sequence 高水位，两套分页状态；不是本地库
- `/home/ubuntu/wiring/docs/part-l-turn-lifecycle.md`
  - TurnKeys 跨重启持久化 UNKNOWN
- `/home/ubuntu/wiring/docs/part-e-chatwarmer.md`
  - ChatWarmer 无网络/GRDB/CoreData 调用

本单从这些结论之后开始，**不要重复证明**。

## 2. 必须回答

### Q1（P0）消息/事件相关的本地表清单与 schema

- 枚举二进制里所有 GRDB `CREATE TABLE` / migration 字符串，列出**与消息/事件/转录相关**的表（可能不只 `codeSessions` 三张）。
- 对每张表给：表名、列名/类型、主键、唯一索引、外键/关系、用途。
- 特别确认是否存在：`events`、`messages`、`turns`、`transcript`、`blocks`、`streaming` 这类表；如果不存在，明确写“没有找到”，并说明搜过哪些字符串。
- 区分 **Code 页**（Claude Code session）与 **Chat 页**（普通聊天）的库/表；本文以 Code 页为主，发现共享要写明。

### Q2（P0）写入路径：SSE 帧 → 内存 → GRDB？

- 从 SSE 帧入口（part-X 已给的 `0x1027feabc` / `0x10276d5c8` / `0x10276d918` 一带）往下追：
  - 哪些结构被写入数据库？raw frame、API message、`DisplayMessage`、`SessionTranscriptEntry`、渲染块，还是只写会话列表元数据？
  - 写库函数地址、调用点、事务边界（`write`/`writeInTransaction`/upsert）。
  - 写入时机：每 0.1s 发布？每批完成？turn 完成？app 进后台？
- 如果消息正文**不落库**，给出证据（写路径里没有 DB 调用 / 表不存在），并说明正文只存在哪些内存结构、生命周期多长。

### Q3（P0）打开会话 / 冷启动的读路径

- 从打开会话主链（part-X §4/§10 的 `0x1027da650`、`0x1027ac20c` 等）追：
  - 打开时读了哪些表、什么查询（表名、WHERE/ORDER/LIMIT 若可见）。
  - 首屏渲染用的是**本地行**还是**网络页**；两者顺序/合并方式。
  - `SessionTranscriptPager` 是否把本地行和网络页合并；如果有，合并键/顺序。
  - 第一次打开（DB 空）与再次打开（DB 有数据）分别走什么分支。
- 给出“打开时从本地读多少行”的结论；拿不到 LIMIT 就写 UNKNOWN，并写还差哪条指令。

### Q4（P0）离线 / 冷启动行为

- 断网/服务端失败时，会话页是否还能显示本地消息？显示到什么范围（全部/第一页/仅列表元数据）？
- App 被杀掉再启动，消息正文是否还在？如果不在，正文缓存在哪（内存/磁盘/无）。
- ChatWarmer 不碰 DB 已证；它是否只预热网络/内存？冷启动首屏的数据来源链。
- 给出“离线可读/不可读”的明确结论 + 证据。

### Q5（P1）失效、删除、裁剪

- 会话归档/删除、消息编辑/重发、服务端快照替换时，本地库怎么处理（delete/upsert/removed 集合）。
- 是否有 TTL、容量上限、按会话裁剪、vacuum/清理任务。
- 本地行与 `nativeMessageId` / sequence / revision 的一致性规则。

### Q6（P1）游标 / resumeToken 持久化

- `listSyncs.nextCursor` 已证；transcript 是否有持久化游标/高水位？
- `resumeToken` 是否落盘（part-P 已判 UNKNOWN）；断线重连/gap fill 用哪个值。
- 冷启动后如何知道“本地最后一条”和“服务端下一条”。

### Q7（P2）数据库配置

- 数据库路径、`DatabaseQueue`/`DatabasePool`、WAL、加密、migration 版本管理。
- Code 页与 Chat 页是否共库；`EntityStorage` 泛型被哪些实体使用。
- 是否有多进程/扩展访问（通知扩展、widget）约束。

## 3. 方法建议

- 先全量扫 `__cstring` / `__swift5_reflstr` 里的 `CREATE TABLE`、`CREATE INDEX`、`INSERT INTO`、`ON CONFLICT`、`GRDB`、`StructuredQueries` 字符串，建立表清单。
- 用 `types.json` / `swiftdump.py` 找 `EntityStorage`、`DatabaseWriter`、`FetchableRecord`、`PersistableRecord` 的具体实体类型。
- 用 `q.py --callers/--callees --exact-only --drop-shared` 追 DB 写/读辅助的调用者。
- 用 `fieldrefs.py` / `offsetscan.py` 追 `EntityStorage` 字段和表名字符串引用。
- 反编译时优先找“表名 + SQL”常量物化点，再向上追调用链。
- 二进制：`/home/ubuntu/swift-recover/unpacked/Payload/Claude.app/Claude`（thin arm64，base `0x100000000`）。
- 工具：`/home/ubuntu/wiring/scripts/`（`q.py`、`calls.py`、`dis1.py`、`xrefs.py`、`fieldrefs.py`、`offsetscan.py`）、`/home/ubuntu/wiring/out/`（`swift_types.csv`/`witness.csv`/`callgraph.db`）、Ghidra `DecompileAt.java -readOnly`。
- 临时输出放 sbx `/tmp/hark-local-store/`，不要覆盖已有 `/tmp/aa`、`/tmp/muse`。

## 4. 输出

写到：`/home/ubuntu/wiring/docs/part-ad-local-message-store.md`

格式：

1. 开头 6 条一句话结论（Q1–Q6 各一条，Q7 可合并）。
2. 表清单（表名/列/主键/用途/证据）。
3. 写路径时序（SSE → … → DB，或“不落库”的证据链）。
4. 打开/冷启动读路径时序（本地 vs 网络）。
5. 每题按 `EVIDENCE / INFERENCE / UNKNOWN` 分节，带地址。
6. 最后一节「对 AA 的最小实现建议」：只写建议，不写代码、不改仓库。
7. 所有负向结论（“没有这张表”“没有 DB 调用”）要写清搜索范围/字符串/函数簇。

## 5. 不要做

- 不要重做 part-P / part-X / part-c / part-l / part-e 已证结论。
- 不要假设“官方有本地消息库”；没有证据就写没有。
- 不要改 AA 仓库、不要动产品代码、不要去 206 跑重活。
- 不要把 INFERENCE 写成 EVIDENCE；拿不到就 UNKNOWN。

## 6. 验收

- Q1/Q2/Q3/Q4 必须有明确结论（哪怕是“没有本地消息库”），并给证据地址或搜索范围。
- Q5/Q6/Q7 可以部分 UNKNOWN，但要写清还差哪条指令/哪个调用点。
- 报告能直接回答：**AA 要做本地消息库，官方有哪些可复用的结构、哪些必须自己设计、离线首屏到底读什么。**
