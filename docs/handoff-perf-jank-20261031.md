# AA 性能线交接（卡顿/掉帧，2026-10-31 晚）

> 给新会话：先读本文件 → `docs/diagnostics-and-performance-task-sheet.md` → `docs/handoff-code-timeline-20261031.md`。
> 目标：把「聊天上下看历史」和「侧滑抽屉」的卡顿掉帧真正解决；诊断工具已在 b794 齐备。

## 1. 仓库与包

- 工作区：`/home/ubuntu/aa-wt-attachments`，分支 `feat/local-timeline-store`
- 代码 head：`324c0a57`（b794）；b793=`e61c3491`，b792=`f164651f`，b791=`f222d12`
- 构建：dispatch `ios-build.yml`（title/build=true/probe=true），产物在 `ipa-feat-local-timeline-store`
- 最新包：`AgentsAnywhere-feat-local-timeline-store-b794-324c0a5-probe.ipa`
- 下载页：https://github.com/chenyynx/Agents-Anywhere/releases/tag/ipa-feat-local-timeline-store
- 构建/运行：`server` 在本机 Docker（可查 `moonveil-cloud-server-1`/`moonveil-cloud-postgres-1`）；connector 服务 `moonveil-connector.service`（journalctl）

## 2. 诊断工具（b794 起）

- 入口：会话右上角「···」→「诊断浮窗」（可拖动、半透明；点卡片展开完整面板）；设置 → 开发者 → 诊断也可以打开
- HUD：fps / 卡顿次数 / 整页重排峰值 / 严重度圆点；右侧相机按钮 = 打点+截图（最近 3 张，可单张删除/清空）
- 面板：实时指标（含**抽屉时长/抽屉卡顿**）→ FINDINGS 自动聚合（`footer_churn`/`footer_transfer`/`offset_jump`/`apply_spike`/`measure_spike`/`frame_hitch`/`drawer_hitch`/`blank_frame`）→ 现场打点 → 原始日志（时间线/锚点，默认折叠）
- 取证流程：复现 → 点相机打点 → 更多 → 导出（txt+png）→ 附件发回；报告顶部先看 FINDINGS，再看对应 t 段
- 探针记录按 attach 窗口隔离（`t=0.00` 旧缓冲已修）；`sidebarDrawer` 会把过渡窗口报给探针

## 3. 已确认的性能证据（真机）

**b788 15:57 报告（13 分钟窗口）**
- `applyMsMax=1139ms`：`t=194.07 apply-begin` → `t=195.21 apply-end`，中间 `apply-measure n=2 ms=0` → 时间全在 diffable apply + 单元格重配
- 同一条 881pt 长消息 `g:msg_a428e10f` 8 秒内被 re-key **7 次**（rev 每次变），高度 29→180→363→410→387→443→592→625→881；每次高度修正都重配整段 markdown 单元格
- `frameRateHitches=50`、`slowFrames=227`、`maxFrameMs=117`

**b788 16:14 报告（长会话）**
- `applyMsMax=1185`、`frameRateHitches=42`、`maxFrameMs=958`、`keyChanges=2212`、`measureMsMax=108`
- 页脚慢 1.56s（已在 R20 修复：消息段 done 就挂页脚，见 timeline 任务单）
- 8KB/100 行粘贴未触发长消息阈值 → 7916pt 巨型气泡、offset +7061、tail 错位 210pt（阈值已改 2,000 字符/60 行）

**抽屉**
- 旧探针只按 collection view 的 tracking/decelerating 计帧，抽屉滑动不是滚动相位 → 卡顿漏记；b794 已让 `SidebarDrawer` 发布过渡窗口并记录 `drawer_hitch`

## 4. 下一步（按优先级）

1. **收集 b794 真机数据**：pp 开合抽屉 10–20 次 + 历史快速滚动 15s，各打点；读取 `drawer_hitch`、`apply_spike`、`frame_hitch`
2. **A 线定位（长消息 re-key）**：给探针补「apply 时哪些 item 被 reconfigure、group 签名的哪个分量变了（rows revision/updatedSeq/reveal/turnAction/contextRevision/hasActionBar）」，复现 1139ms 后先钉死是 wire revision churn 还是 reveal/completed snapshot
3. **A 线修复方向**（按证据取用）：
   - 高度变化不重配整个 cell（内容 revision 与高度 key 分离）
   - 合并连续测量 apply；流式/大行按帧边界提交
   - 离屏测量限定视口 + 预取预算；滚动中取消低优先级测量
   - 长行 markdown 解析缓存（revision+width），避免重配时重解析
4. **B 线（抽屉）**：拿到 `drawer_hitch` 数据后定位（过渡期时间线仍在测量/apply、侧栏首帧构建、尺寸变化）；优化方向：过渡前预构建侧栏、过渡期暂停时间线采样/测量/apply（`sidebarDrawerIsTransitioning` 已有）
5. **验收指标**（同一设备，Release/probe 双跑）：hitch（>33ms）率 <0.5%，单帧 ≤50ms，apply p99 <50ms / max <100ms；抽屉 20 次开合 hitch ≤2；无视觉跳页/空白

## 5. 开放事项

- **官方 Code 页发送/停止按钮（逆向已闭合，2026-10-31 18:02）**：由 `ClaudeCode.ProjectConversationStore.TurnState`（idle/working/stopping）+ 活动标志决定，经 `SendButtonState` → `SendChatButtonMode` 落到按钮；**不是 `TurnStatus.Phase`，也不是 `EngineTurnStatus`**。回切 send 在回合结束/活动清空——与当前行为（`39ef2268` 回滚后）一致，**不要**再按「消息写完」提前切。
  - 证据：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round22/composer-send-stop.md`（`SendChatButton.body 0x100d472ec`，mode producer `0x103e1fcbc`，mode 落位 `0x103e32184`，`SessionInputBar.init 0x103550254`）
  - U：属性名/图标名/部分谓词语义未解（报告 U1–U4），不影响上述判定
- b793/b794 待 pp 真机反馈：发送键时机、震动、诊断浮窗、抽屉卡顿、打点删除
- 输入栏占位偶发不居中（自愈，未修，台账在 timeline 任务单末尾）

## 6. 恢复提示词（新会话直接贴）

```
继续 AA iOS 性能线（卡顿掉帧）。仓库 /home/ubuntu/aa-wt-attachments，分支 feat/local-timeline-store，代码 head 324c0a57（b794 probe 包）。
先读 docs/handoff-perf-jank-20261031.md、docs/diagnostics-and-performance-task-sheet.md、docs/handoff-code-timeline-20261031.md。
重点：A 线=长消息反复 re-key + apply 1139ms（b788 15:57 证据）；B 线=侧滑抽屉卡顿（b794 已加 drawer_hitch 记录）。
诊断入口：会话「···」→「诊断浮窗」；复现→打点→导出 txt+png。报告在 /home/ubuntu/.agents-anywhere-moonveil/attachments/sess_*/，直接读最新文件。
先收 sbx 逆向 R-AA-COMPOSER-STOP-SEND 的报告（scp 命令见交接 §5），按结论决定是否回滚发送键改动。
不要重做已修项；先量后改，一假设一提交，每项带真机证据。
```
