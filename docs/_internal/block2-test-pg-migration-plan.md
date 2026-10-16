# 块 2 任务单 · server/connector 测试套件 Postgres 化

> 目标：server + connector 全量套件在真 Postgres 上**串行**跑绿（= CI 门禁绿）。
> 归属：sync/upstream-2.1.0 合并的后续块。上游把 SQLite 后端整个删了，测试从"每测试临时 sqlite 文件"改为"共享 Postgres 库 + 每测试 TRUNCATE"。

## 关键事实（已实测）
- **必须串行**：上游 conftest 用共享库 + autouse TRUNCATE；`-n 8` 会让 worker 互相 truncate → 海量假失败（Deadlock/FK）。上游 CI 串行。（记忆里 `-n 8` 是旧 sqlite 套件的。）
- **判据**：上游自带 PG 测试 `test_usage_statistics.py` → 15/15 过；`import agent_server.app` OK → **合并后 server 是好的**，失败是"我们的测试未迁 PG"。
- 唯一真实非 sqlite 失败样本：`test_sessions_sort_by_latest_timeline_item_not_session_update`（0.2s asyncio 超时）→ 待查是否 flaky。
- Postgres 环境（sbx `100.79.4.30:2222`）：PG16 已装，角色 `agents_anywhere`/库 `agents_anywhere_test`；`AGENT_SERVER_TEST_DB_URL=postgresql+asyncpg://agents_anywhere:agents_anywhere_dev_password@127.0.0.1:5432/agents_anywhere_test`。

## 转换规则（机械，Category A）
- `upgrade_database(sqlite_path=db_path)` → 迁移类测试改用 `fresh_database_url` fixture + `upgrade_database(db_url=url)`；非迁移类（只要一个已迁移库）→ 删掉，靠 autouse fixture 的 `reset_shared_database()`。
- `Store(db_path)` → `Store()`（新签名：`db_url=None` 读 `AGENT_SERVER_DB_URL`；测试 client 用共享库）。
- `_sqlite_url(path)` / `sqlite:///` / `tmp_path/"*.sqlite3"` → 删除。
- 需要"干净空库驱动迁移"的 → `fresh_database_url` fixture。

## 范围（静态确认：用 sqlite 的文件）
- **server（18）**：test_events, test_red2b_janitor_reverify, test_red_r2_janitor_attack/guard/reachability/stranding, test_repair_reasoning_parent_attribution, test_repair_stranded_running_items, test_snapshot_active_agents, test_timeline_agent_orphan_prune, test_timeline_intra_message_order(_paths), test_timeline_janitor, test_timeline_message_group_order, test_timeline_message_identity, test_timeline_repack_pagination, test_timeline_startup_maintenance, test_timeline_write_buffer
- **connector（3）**：test_tool_row_order_intra_message_e2e, test_paths, test_runtime_storage（其余命中的是 probe×3 + _reference，非 pytest 用例）
- **补回丢失测试**：v2_42/43 迁移测试（见 upstream-sync-2.1.0-plan.md §块2待办），按 fresh_database_url 重写。

## 执行方式
- 我做：转换规则定义、迁移测试重写、隔离/flaky 诊断（判断密集）。
- 子代理：per-file 的机械转换（按文件域拆，并行）。

## 验收
- `cd server && uv run pytest -q`（串行）全绿；`cd connector && uv run pytest -q` 全绿（除已确认的基线上无关失败）；ruff 全绿。
- 迁移链 v2_42→…→v2_46 往返测试过。

## 难点 Category B（隔离泄漏）—— 已定位样本
- `test_timeline_message_identity.py`：**单跑全绿（9 passed）；文件内跑 → 1 挂**（`KeyError: 'conn_...'`，`connectors.py:434` 查不到刚建的 connector）。
- 现象＝**共享库跨测试状态泄漏**：前一个测试留下的状态影响后一个。
- 待查方向：autouse `_isolate_shared_database` 的 TRUNCATE 是否对**异步连接池**生效；`Store`/`app.state` 单例（`_connector_lifecycle_factory`、publisher、缓存）是否跨测试复用；事件循环/连接是否复位。
- **这一层必须我（主）来攻**，否则子代理批量转会复制同一坑。

## 🔑 Category B 真相（已实测确认）——不是 TRUNCATE 失效
- 探针证明：autouse `_isolate_shared_database` **每次都跑了，reset 后 projects=0**。
- 真因：**共享库下，同一测试内第二次 `create_session_with_project` 会再建一个默认名 `"Timeline"` 的项目** → 撞 `create_project` 的用户名唯一约束 → `ProjectNameConflictError`。sqlite 时代每测试独立库，不存在此问题。
- **通用修法**：凡 helper（`_store_with_session` 等）在**同测试内被调多次**，给 `create_session_with_project(..., project_name=...)` 传**唯一名**。
- 样本：`test_red_r2_janitor_attack.py::_store_with_session` 加 `project_name=f"P-{tag}"` → 该文件 **24/24 全过**。

## 子代理批次（机械重构 B）：给重复建项目的 helper 唯一名
规则：凡**同一测试内多次**建"默认项目"（= `create_session_with_project` 未传 `project_name`，默认 `Timeline`），
给 helper 的 `create_session_with_project(...)` 传 `project_name=<唯一>`（如按 helper 参数 tag 拼接）。
- 只改 helper 定义里的调用；不改 `session_fixtures.py`（保持通用）。
- 不引入无关改动；改完跑该文件确认绿。
批次文件（含多处调用的）：
test_red_r2_janitor_reachability(4), test_repair_stranded_running_items(2), test_snapshot_active_agents(2),
test_timeline_intra_message_order_paths(2), test_red_r2_janitor_guard(2), test_repair_reasoning_parent_attribution(2),
test_timeline_message_identity(2), test_events(3), test_red2b_janitor_reverify(3), test_red_r2_janitor_stranding(3),
test_timeline_intra_message_order(2), test_timeline_agent_orphan_prune(2), test_timeline_janitor(2),
test_timeline_repack_pagination(2), test_timeline_message_group_order(2), test_timeline_write_buffer(20),
test_timeline_reconciliation(4), test_timeline_lock(2), test_session_create_title(2),
（test_red_r2_janitor_attack 已修）

## 进展（2026-10-16）
- 机械转换（18 server + 1 connector）+ 子代理唯一项目名（A组5 + B组9）+ 迁移重编号修正 + 补回 v2_42/43 测试（10个 PG 版）后：
  **全量串行：2 failed / 1188 passed / 11 skipped / 1 xfailed**（原 130 failed / 1060 passed）。
- 剩余 2 个：`test_backend_mvp.py::test_sessions_sort_by_latest_timeline_item_not_session_update`、`::test_connector_turn_end_after_read_rearms_unread`。
  根因：**环境时序敏感**——测试内 `wait_for(attempts=20, interval=0.01)`＝0.2s 轮询窗，PG 子层比 sqlite 慢，窗内没等到 `status==idle`。
  证据：日志显示 turnEnded 已处理、status 确到 idle（晚于窗）；把窗临时放宽→2 个全过。**非合并缺陷**。
  待决：是否把该测试的轮询窗口放宽（or 调 conftest 的 RPC timeout 0.2s）作为 PG 子层的稳定性修复。

## ✅ 块 2 完成（2026-10-16）
- **connector**：2073 passed / 2 skipped / 0 failed；ruff 过。
- **server**：全量 1199 passed + 补回测试（迁移文件 116 passed/0 failed）；ruff 过。起始 130 failed 全部消除。
- 最后 1 个 DDL 测试（`test_v2_42_upgrade_keeps_ddl_out_of_the_chain_transaction`）失败是我转写笔误：假 `_Op` 缺 `execute`（真迁移 `_bound_lock_wait` 调 `op.execute`）→ 已补。
- 时序敏感：`test_backend_mvp.py` 的 `wait_for` 轮询窗 0.2s→5s（`100×0.05`），治"共享 PG 比 sqlite 慢"的假红；行为本身正确。
- 改动文件：server/tests 19 个 + connector/tests 1 个（e2e）。仍在 worktree，未提交。
