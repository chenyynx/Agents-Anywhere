# Code 页时间线交接（2026-10-31 晚 · b786 待验）

> 给新会话：先读本文件；逐条证据/红绿/包号在 `docs/timeline-open-and-history-root-fixes-task-sheet.md`（R6–R19）。
> pp 已下载 b786，下个会话会反馈“这些修过的 bug 是否断根”。不要重做已修项，先按反馈定位残余。

## 1. 当前状态

- 分支/worktree：`feat/local-timeline-store`，`/home/ubuntu/aa-wt-attachments`
- 代码 head：`dbbfba97`（幽灵气泡看门狗）；文档 head 以 `git log` 为准
- CI：
  - run **786**（head `dbbfba97`，test+build+probe）交接时仍在跑；**这是给 pp 的包**
  - run 785（head `08b2d2d9`，页脚防抖）、784（`a40ca030`，snapshot 锚点）同批
  - 绿后资产：`AgentsAnywhere-feat-local-timeline-store-b786-dbbfba9-probe.ipa`
  - 下载页：`https://github.com/chenyynx/Agents-Anywhere/releases/tag/ipa-feat-local-timeline-store`
  - 786 若红：用 API 拉 test/build job 日志（test job 不编译 Views，Views 编译错只在 build job）
- 探针报告目录（当前会话）：`/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_qosxGz-dnnK4jw/`
  最新 `long-message-*.txt` 直接读，不让 pp 贴长文；截图也会落这里。

## 2. b786 验收清单（下个会话按 pp 反馈逐条判）

1. **发送跟随（文字/附件）**
   - 发送后 pending 气泡连续；转圈结束→状态行不再先沉后弹。
   - 历史窗口里发送：跳变发生在“按发送”那一刻（R16 方案 1），不在上传结束几秒后。
2. **历史加载**
   - 顶部加载更早消息：原内容不动，新消息在上方，由读者上滑；不再跳到新页顶部。
   - 慢页（>5s）也保持锚定（不再 5s 丢锚）。
3. **历史窗口里收到服务端 snapshot**
   - 不再整窗从 498 缩到 199；已加载历史保留（浏览锚点跨完整替换）。
4. **回合中途工具调用**
   - 上一条已完成回复的复制/分享页脚不再消失/闪烁（原 30pt 下跳）；状态行在页脚下面。
5. **幽灵气泡**
   - 丢 echo 的 pending：~30s 内被读回并确认；仍无则 60s 进“发送结果尚未确认”，不再永久转圈。
6. **空白页**
   - 缩小窗口替换不再出空白帧（offset 预置）；历史页可见 cell 不错配。

判据：每条对应报告里的 item id/高度/offset 同拍变化；只要 pp 说“还在”，先用新报告确认是哪条路径，再改，不叠补丁。

## 3. 这轮修了什么（R6–R19，一行一条）

- R6 回合页脚不再落在分隔行（121→30 跳）。
- R7 结构变化后可见 cell 错配 → 同拍重绑。
- R8 latest 页不丢已加载历史（重叠合并）；idle 上限仍 1000。
- R9 键盘收起/弹起底部跟随（pre-change viewport 判定）。
- R10 底部弹簧掉帧失稳 → 子步积分（手感 0.2s 不变）。
- R11/R17 回合页脚：同回合 text→tool→text 保留已完成段页脚；runtime running/idle 抖动不再闪烁。
- R12 pending→echo 原子替换（confirmed pending 保留到 echo 行进入 rows）。
- R13 latest reconcile 存活：被动底边翻转不再取消；后台补页 keepingAnchor；用户主动回最新仍按 idle ceiling。
- R14 缩小窗口替换 offset 预置，消空白帧。
- R15 历史页锚定：paging 期间不被动重绑；apply 时按当前视口重钉；慢页标记 20s。
- R16 发送即回最新（pp 选方案 1）：pending 新增且 hasNewerItems 时走 loadLatest。
- R18 timeline.snapshot 是服务端**完整时间线**：只取快照行，但保留浏览锚点按浏览预算截断。
- R19 已 accepted 直发丢 echo：30s 读最新页、60s 转 uncertain，修幽灵气泡。

## 4. 仍未解决 / 独立线

1. **直播断流（独立，优先）**：14:50 实例——server 持续收到 connector 的 `timeline.itemUpsert`、DB 有用户消息，客户端漏 event 且没有读回来；切会话/发送才恢复。server→client 推送或客户端 socket 接收侧。下次中断时**不切会话/不清探针**立刻导出报告；R19 只是兜底。
2. **冷开空 adapter ~100ms 空白**：`oldN=0 → 189 行 apply 时 contentH=0`，同步测量 105ms。未修。
3. **>1000 行 idle 上限 / 离屏测量 / apply 尖峰 / 巨型行**：旧 backlog；正文完整显示是底线，不折叠、不自动转文件。
4. **connector event loop stalls**：独立性能项。

## 5. 不要重复做 / 已踩过的坑

- `timeline.snapshot` 是完整时间线（缺行=删除，空=清空），不要做 overlap merge；丢历史的原因是替换清了 windowAnchor。
- 不要用一个 flag 同时表示“读者意图”和“被动布局翻转”；取消后台工作用 `isReaderScrolling`/intent generation。
- 历史锚点跳过 `.olderPrompt`/`.tail`；不要全局 contentChanged 重解析 placement（会漂 124pt）。
- 回合页脚：同回合分段/工具活跃时不要撤已完成段页脚；`suppressLatest` 会抖。
- pending 不能只等 echo；丢帧要有读回/兜底。
- 不改回 1000 行浏览硬裁；不自动把助手长回复转文件。

## 6. 日志/取证入口

- 探针：左边缘「锚点日志」→复制；报告含 VISIBLE/HEIGHT/APPLIES/HISTORY/ISSUES。
- 服务端：`sudo docker logs moonveil-cloud-server-1 --since ...Z --until ...Z`（UTC；CST-8）
- 服务端 DB：`sudo docker exec moonveil-cloud-postgres-1 psql -U moonveil -d moonveil -c "select id,role,order_seq,payload_json from timeline_items where session_id='sess_qosxGz-dnnK4jw' and payload_json ilike '%<clientMessageId>%';"`
- connector：进程 `anywhere-cli start --config /home/ubuntu/.agents-anywhere-moonveil/connector.json`

## 7. 恢复提示词（新会话直接贴）

```
继续 AA iOS Code 页时间线修复。仓库 /home/ubuntu/aa-wt-attachments，分支 feat/local-timeline-store，代码 head dbbfba97；先读 docs/handoff-code-timeline-20261031.md 和 docs/timeline-open-and-history-root-fixes-task-sheet.md（R6–R19）。
pp 已下载 b786 探针包，会反馈这些修过的 bug 是否断根；按反馈逐条对证据，不重做已修项、不叠补丁。
报告在 /home/ubuntu/.agents-anywhere-moonveil/attachments/sess_qosxGz-dnnK4jw/ 的最新 long-message-*.txt，直接读文件，不要让 pp 贴长文。
若还有“新消息不加载/断流”，这是独立线：服务端已确认有数据，需中断发生时的探针（不切会话/不清探针）再查 socket 接收侧。
```
