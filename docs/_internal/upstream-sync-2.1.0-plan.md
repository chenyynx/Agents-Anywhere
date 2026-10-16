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
