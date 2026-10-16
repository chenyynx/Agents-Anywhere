# 上游合并 · 受控方案（sync/upstream-2.1.0）

> 任务单/决策依据。分支 `sync/upstream-2.1.0`（含义：合并 anywhere-labs 上游 2.1.0 的受控同步分支），从 `dev` 起。
> 上游 = `anywhere-labs/Agents-Anywhere`，同步点 `7df5b31f`（v2.0.3）→ `58d98da2`（2.1.0，88 提交）。
> 我们 dev 领先 331 提交。合并方式：**按块小步 cherry-pick，绝不整体 merge**。

## 决议（pp 2026-10-16）
- **合**：connector DSH 修复、共享 plumbing、server 去 SQLite、runtime phase、iOS perf 其余、管理看板重做、Codex IPC 接管
- **不合**：上游 `.github/workflows/ci.yml`（会丢 iOS 门禁）；`08805a5a` revert（方向相反）
  - 但上游 `ci.yml` 的「按路径选检查 + faulthandler 超时」逻辑**择机移植**进我们的 `backend-ci.yml`
- **产品裁决**：`44fd79fc` → **显示** Claude 中断/空回复消息（删掉我们的隐藏逻辑）
- **迁移**：上游 v2_42/43/44 **重编号**到 v2_44+（我们 v2_42/43 已上生产）

## 防回归规矩（每块都做）
1. 合并前：在 dev 上跑该模块全量，存 green 快照（server 全量去 sbx `100.79.4.30:2222 ~/aa-speed -n 8`）
2. 每条被碰到的"皇冠修复"做**撤回实验**：撤掉我们的语义 → 对应测试须变红；不红=守卫丢了，补
3. 不变量清单逐条核对（见文末）
4. 真实数据 diff 输出（timeline JSON 逐字节同）
5. L 级：集成树解完后派 `reviewer` 子代理独立审查
6. 以 CI 为准（本地绿≠CI 绿）；合并只落 sync 分支，dev 不动，绿了才合回

## 执行顺序（按依赖）
- **块1 · connector DSH 修复** ← 先做，冲突只 1 文件
- **块2 · server 去 SQLite**（+ 测试迁 Postgres；DSH 探针依赖它）
- **块3 · 跨端协议**（f9982895 uploadProgress / d736f3e6 phase）
- **块4 · iOS perf 20 提交**（38 冲突，单线）
- **块5 · Codex IPC 接管**
- **块6 · 管理看板重做**

## 逐块进度
| 块 | 状态 | 冲突 | 备注 |
|---|---|---|---|
| 1 connector DSH | 🔄 进行中 | ingest.py 1 块 | — |
| 2 server 去 SQLite | ⬜ 未开始 | — | — |
| 3 跨端协议 | ⬜ 未开始 | — | — |
| 4 iOS perf | ⬜ 未开始 | 38 文件 | — |
| 5 Codex IPC | ⬜ 未开始 | — | — |
| 6 看板重做 | ⬜ 未开始 | — | — |

## 块1 · connector DSH 修复提交（时间序，老→新）
```
8092e13e  spool snapshot JSON（降内存）
3f5c3e61  探针 + 文档
61a238a3  孤立代理字符规范化
d03066cf  relay 保活，任务不再静默死
205e37b5  被拒会话只隔离自己（#278 根治）
6267cf1e  快照 >8MiB 分页上传
98b2b087  第一页失败立即失败
```
另（connector+desktop 跨端，同批但碰 desktop-workbench）：`dc10e2cb` `37aea149` `2da37d6b`

## 不变量清单（合并时逐条核对——防"语义被合没"）
- tool 行按 **declared truth（nativeMessageId + blockIndex）** 排序，不按到达顺序
- reasoning 行**永不** parent 到 subagent
- 会话身份**跨重启存活**（rebind）
- 轨道脉冲（orb）**只**由 live 路径触发
- 幽灵真人回合不落库；子代理帧不触发主链 reset
- Claude 中断/空回复消息 → **显示**（本次新决策）

## 关键约束
- 本仓**不提交 lockfile**，本地绿≠CI 绿
- github 操作绕本机代理（直连超时切 `127.0.0.1:8118`）
- 提交：Conventional Commits + 作用域（`fix(dsh): …`），**不带 [cc] 前缀**
- 该文件在被追踪的 `docs/_internal/`，会随分支提交

## 块 2 待办（延后）：测试套件 Postgres 化 + 丢失的 v2_42/43 测试
- 采纳上游后，server 测试套件必须跑真 Postgres（conftest 强制 `AGENT_SERVER_TEST_DB_URL`）。19 个文件仍用 `_sqlite_url`。
- **块 2 待办**：把下列**仅我们有、随合并丢失**的 v2_42/43 及 v1 测试**按上游 Postgres fixture 重写补回**（目前 `test_database_migrations.py` 取了上游 PG 版，这些丢了）：
  - `test_current_schema_version_is_v2_43`（现应为 v2_46）
  - `test_v2_42_adds_the_native_item_id_column_and_index`
  - `test_v2_42_backfills_native_item_id_from_the_payload`
  - `test_v2_42_downgrade_then_upgrade_round_trips`
  - `test_v2_42_index_check_ignores_an_unusable_index`
  - `test_v2_42_upgrade_keeps_ddl_out_of_the_chain_transaction`
  - `test_v2_42_backfill_pages_without_skipping_or_looping`
  - `test_v2_43_adds_the_native_message_id_column_and_index`
  - `test_v2_43_backfills_native_message_id_from_the_payload`
  - `test_v2_43_downgrade_then_upgrade_round_trips`
  - `test_v2_43_backfill_pages_without_skipping_or_looping`
  - v1 相关：`test_unversioned_v1_database_archives_then_removes_legacy_storage`、`test_runtime_sqlite_environment_is_rejected`、`test_explicit_sqlite_url_remains_available_for_legacy_tools`、`test_v1_rehearsal_requires_postgres_target`（v1 工具已随上游移除，可能整体作废）
- 迁移号已重编号：我们 v2_42/43（已上生产）保留；上游 → **v2_44/45/46**；`CURRENT_SCHEMA_REVISION=v2_46`。
- 迁移号重编号后必须验：空库→v2_46→降级→升级往返（上游自验法，见 test_every_adjacent_schema_upgrade）。

## 块 7 · 独立审查后的修复（pp 2026-10-16 令"可以"）

三个 reviewer（A iOS 语义 / B 数据链 / C 跨端契约）审完，复现属实的 P2 修复：

### F1 · 发送队列 echo 对账被上游门控吃掉（iOS）
- **根因**：合并取了上游版 `V2SessionModel.swift` 的 `if !pendingMessages.isEmpty { for item in items { confirmEcho(item) } }`；上游无发送队列故等价，我们有队列故不等价。队列在途时 `pendingMessages` 为空，批量读取路径（hydrate/loadLatest/applyHistory/snapshotRequired）的对账被跳过 → 队列头滞留至 `demoteStaleAwaitingEcho`（60s）。
- **修法**：门控补 `|| !sendQueue.items.isEmpty`；补一条经 `update()` 驱动、无 pending、队列在途的对账用例（现有用例直调 `confirmEcho` 绕过该行）。

### F3 · recoveryDiagnostics 新增项可能不落盘（iOS）
- **根因**：上游把 `emit` 改成写入门控（`persist==true` 才标脏）、`flushCache` 只写 `isDirty` 条目；dev 二者都无条件。`recordRecoveryDiagnostic` 记完低于阈值就 `return`，不标脏 → 若前次 flush 已清 dirty，新诊断不落盘。
- **修法**：`recordRecoveryDiagnostic` 记录后标脏并 `schedulePersistence()`；补一条"先 flush → 记诊断 → 再读 archive"的用例。

### F2 · "显示中断/空回复"端到端未达成（**待 pp 决策，未动**）
- 复现：iOS 隐藏逻辑确已删净（`TimelineEntryPresentation.swift:228-231`）；**connector 源头仍丢**（`runtimes/claude/sessions/reader.py:625`、`runtimes/claude/turns/lifecycle.py:3366`）。
- **修正 A 的判断**：connector 抑制**在 dev 上已有**（非合并引入）；上游 `44fd79fc` 只改 iOS 三文件。故"显示"从头只做了 iOS 半边。
- 要真显示需一并放开 connector 抑制（跨端 + 需论证不复发幽灵回合）→ 等 pp 拍板。

