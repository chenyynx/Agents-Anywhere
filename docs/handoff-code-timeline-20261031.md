# Code 页时间线交接（2026-10-31）

> 给新会话：先读本文件，再读 `docs/perf-6b-batch5-localdb-task-sheet.md` 的 P5.2/P5.3/0.7。
> 当前不需要重新调研官方机制，结论和证据都在下面。

## 1. 当前状态

- 分支：`feat/local-timeline-store`
- 最新提交：`137cc887`（窗口修复）；上一笔 `248cd9b5`（latest 守卫 + 回顶全距离）
- 工作区：应无未提交改动（交接时确认）
- b744 CI：run `41090668183`，`test` 正在跑；`build/probe + timeline-autorun + code-profile` 待跑
- 预期包（build 成功后确认）：
  `https://github.com/chenyynx/Agents-Anywhere/releases/download/ipa-feat-local-timeline-store/AgentsAnywhere-feat-local-timeline-store-b744-137cc88-probe.ipa`
- 探针说明：左边缘两个按钮「探针」「锚点日志」；「锚点日志」的复制内容包含完整 `=== TIMELINE PROBE ===`

## 2. 这轮已经改了什么

### b741（`2ccef9c2`）

- 用户发送/排队时，文本 ≥12,000 字或 ≥300 行自动转 `.txt` 附件（`LongMessageAttachmentPolicy`）。助手长回复不转（pp 选「保持正文完整显示」）。
- 历史页 600ms 稳定窗：apply 后继续按 reading anchor 补偿高度修正。
- latest 加载方向拆开：顶部 older 不再点亮底部 spinner。

### b742（`694898bb`）

- 历史锚点/偏移越界钳制：
  - `beginHistoryPaging` 把视口 top clamp 到内容范围，请求锚点越界时回退当前视口下的行。
  - `reanchor` 发现存储偏移越界就重新按当前视口锚定。
  - `TimelineAnchorDriver.writeOffset` 把目标 clamp 到真实可滚范围 + 一屏余量。
- 探针按钮移到左侧可点区域。
- 真机 23:02 报告曾是 `offset=-4612 contentH=102992 visible=0`，b742 后不再空白。

### b743（`248cd9b5`）

- 历史加载开始设置 `latestAutoLoadNeedsNewBottomVisit`：必须真正离开底部再回来，或手动点 latest 提示，才允许自动 latest。
- 状态栏回顶（`scrollToTop`）跳过官方的一屏 pre-place，改成 full-distance 动画。

### b744（`137cc887`，等待 CI/包）

- 根因：会话有 **3962 行（3522 主行）**，1000 行硬窗口在加载历史时裁掉约 3000 行新侧，列表缩到 4 个 visible group / 202pt，latest 提示反复出现。
- 修复：有 `windowAnchor`（浏览历史）时保留两侧，最多 10,000 行；只有回最新边才裁回 1000。
- 测试已更新：历史浏览保留 `461...500`，不再丢 far-newest；benchmark 的窗口断言改为 browse budget。

## 3. 仍待处理（按优先级）

1. **latest 提示行仍可能出现**：b743 只是禁止自动跳，`hasNewerItems` 为 true 时底部仍有「继续上拉加载更新的记录」文字。下一步按官方形态改成 following / 「N 条新消息」胶囊，不再常驻 loading 行。
2. **1.5s apply / stale cell / 巨型行**：b743 真机报告有 `applyMsMax=1484`、`staleSamples=93`、`maxStaleDelta=92894`。巨型行（助手长回复，单 cell 46k pt）与 cell 复用/高度修正仍未根治。pp 要求正文完整显示，不能折叠正文；只能从 cell 布局/复用、测量范围、增量 grouping 方向修。
3. **connector 事件循环 stall**：`moonveil-connector` 日志每分钟 `connector event loop stalled drift_ms=3000~4500`，独立性能项，会拖慢同步/补发。
4. **recovery/hydrate 可能替换历史窗口**：本轮 4-item 收缩已确认是 1000 行窗口裁剪，不是 snapshot；但 `V2SessionRepository.runRecovery` 的 `snapshotRequired -> hydrate` 仍会无条件替换 projection。若新报告出现无 `loadOlder` 的窗口替换，查这里。
5. `tail flap` gate 偶发 flake：同 run rerun 一次，不改代码。

## 4. 真机验包清单（b744）

1. 顶部加载历史：不跳到底、不自动 latest；列表不应缩成几个组。
2. 状态栏点回顶：应看到整段列表滚动，不是瞬移。
3. 回底：不应反复出现「正在加载更新的记录」；手动点 latest 可以加载。
4. 3962 行会话翻历史：记录是否还卡、错位、空白。
5. 发超长文本：应变成 `.txt` 文件卡，不是巨型用户气泡。
6. 复现后：点左侧「锚点日志」→「复制」，整段发回；超过 12k 会自动变文件。

## 5. 日志/取证入口

- 探针报告：左边缘「锚点日志」；报告含 `HISTORY / APPLIES / ISSUES / driver clamp / reanchor reset / settle`。
- 探针附件目录（pp 发回的长报告会落在这里，可直接读最新 `long-message-*.txt`）：
  `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_ZrF0RZMxna0J7g/`
- connector：
  `sudo journalctl -u moonveil-connector.service --since '...' --no-pager`
- server：
  `sudo docker logs moonveil-cloud-server-1 --since '...' --until '...'`
- 会话行数：
  `sudo docker exec moonveil-cloud-postgres-1 psql -U moonveil -d moonveil -c "select count(*) from timeline_items where session_id='sess_ZrF0RZMxna0J7g';"`
- 官方 RE 证据：
  `/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/UPSTREAM/part-z-textkit-height.md:33-39/134-145/218`
  `/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/UPSTREAM/layout-scroll.md:162-163`

## 6. 不要重复做的事

- 不要再给 latest 加自动触发；b743 的「新底部访问」守卫是刻意行为。
- 不要把助手长回复自动转文件；pp 明确选「保持正文完整显示」。
- 不要再改回 1000 行浏览硬裁；b744 的 browse budget 是这轮根因修复。
- 不要再把 `.olderPrompt` 当阅读锚点；`TimelineHistoryAnchorRows.isAnchorable` 已排除 prompt/tail。
- 不要用全局 `contentChanged` 重解析 reading placement；gate 的 async-markdown 会漂 124pt，已回退。

## 7. 恢复提示词（新会话直接贴）

```
继续 AA iOS Code 页时间线修复。仓库 /home/ubuntu/aa-wt-attachments，分支 feat/local-timeline-store，交接文档 docs/handoff-code-timeline-20261031.md，任务单 docs/perf-6b-batch5-localdb-task-sheet.md。
当前 head 137cc887，b744 CI run 41090668183；先确认 build 与包，不要重做已完成的窗口/锚点/长消息转附件。
等待 pp 用 b744 探针复测；报告在 /home/ubuntu/.agents-anywhere-moonveil/attachments/sess_ZrF0RZMxna0J7g/ 的最新 long-message-*.txt，直接读文件，不要让 pp 贴长文。
下一步优先：1) latest 提示改官方 following/新消息胶囊；2) 1.5s apply/stale cell/巨型行（保持正文完整显示）；3) connector event loop stalls。改前先读代码和日志，不盲改、不叠补丁。
```
