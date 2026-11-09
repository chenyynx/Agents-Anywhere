# 流式增量刷新 · 任务单（2026-11-08）

> 状态（2026-11-09）：P1 已回退（diffable 下直接 reconfigure 崩溃，b1067/b1068）；**P2 已完成并真机验证**（见下）；
> P3/P4 未开工。设计依据来自 2026-11-07/08 三轮真机探针（b1045/b1051/b1053）。
> 目标：稳态流式从 1–6 次/秒提升到 10 次/秒（对齐官方 0.1 s），且每次成本 <5 ms。

## 现状（b1053 实测）

| 项 | 值 |
| --- | --- |
| `adapter.refresh` | avg 18.0 ms（group 9.3 + signature 1.1 + 其余 ~7.6） |
| `apply` | avg 21 ms，470 项里通常只有 1 项变化 |
| 稳态发布频率 | 1–6 次/秒（受上面两项成本限制） |
| 滑动 | 已用"挂起 apply/refresh"解决（hitch 129 → 16），代价是滑动中文字冻结 |

官方对照：`MarkdownTextView` 只失效"上一段起点到文末"；列表按 block id 逐块 diff（`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md` §1.9、`docs/perf-6b-c5-m4-handoff.md:73-77`）。

## 阶段

### P1 apply 只处理变更行
- 位置：`TimelineCollectionController.apply`（`Views/Chat/TimelineCollection/TimelineCollectionController.swift:610+`）
- 做法：沿用上次 items/entries，逐项比签名；只对变化项算 heightKey、同步测量、`reconfigureItems`
- 验收：apply avg <8 ms，applyMsMax <100 ms
- 风险：历史分页/锚点路径（`applyingHistoryPage`）依赖完整 items，改动只能落在"测量与重配"这一段，不得动快照与锚点计算

### P2 refresh 增量分组
- 位置：`TimelineChatContentAdapter.refresh`、`TimelineChatGrouping.units`
- 做法：保留上次 units/items，找第一处差异，从最近的 turn 边界往后重建；未变项复用签名
- 验收：refresh avg <6 ms
- 测试（必须）：随机序列下"增量结果 == 全量结果"逐字段对拍；含 turn 边界、代码块、interaction target、子代理子行

**结果（2026-11-09，真机 b1080，时间线 1160 行 / 218 items）**

| 阶段 | b1053 | b1078（只做了分组） | b1080（分组+复用） |
| --- | --- | --- | --- |
| `adapter.refresh` | 18.0 | 7.1 | **6.5**（last 5.2 / max 11.9） |
| `adapter.group` | 9.3 | 2.4 | **2.3** |
| `adapter.buildGroups` | — | （含在“其余 4.2”里） | **0.1** |
| `adapter.index` | — | — | **2.7** |
| `adapter.signature` | 1.1 | 0.5 | 0.5 |
| 稳态 flush 峰值 | — | — | **11 次/秒** |
| frame hitch | — | 46 次 / max 165 ms | **9 次 / max 82 ms** |

- 提交：`402cef8e`（增量分组 + turn 游标修复 + 对拍测试）、`e2a63345`（未变 unit 复用 + `adapter.buildGroups`/`adapter.index` 探针）。
- CI：run 42505386582（1332 tests 绿）、42518535770（1333 tests 绿）；包 b1078、b1080（探针）。
- **偏差**：refresh 6.5 ms 未达 <6 ms（差 0.5 ms）。剩余为 `adapter.index` 的 O(行数) 簿记（identity/字典/过滤器）与 `adapter.group` 的逐行指纹构建；已在报告里定位，按“收口”处理，不在 P2 继续抠。
- 结论：P2 的结构收益已拿到（refresh −64%，group −75%，buildGroups 0.1 ms），发布峰值已到 10 Hz 量级；真正卡 10 Hz 的是 P1 对应的 `apply`（b1080：`apply.commitWait` 9.3 ms / `apply.snapshot` 3.9 ms，apply ≈ 15 ms/次），P1 要用 `snapshot.reconfigureItems` 重做。

### P3 发布提到 0.1 s（依赖 P1+P2）
- 位置：`SessionTimelinePresentation` 的发布节拍
- 注意：`NativeChatTests` 三条契约（renderer-owned 立即发布、`nextBatchAt` 不变）不得破坏；节拍应放在 UI 更新侧
- 验收：稳态 10 Hz 下 frameRateHitches <3%

### P4 渲染增量
- 让流式行只重排尾部 TextKit 区间
- 验收：稳态流式下 codeStack.build / leaf.prebuildLead <1 ms

### P5 测量尖峰（单独）
- 427 ms 整段重测，先在 measure 里带 item id 定位

## 通用要求
- 每阶段单独提交；不改变视觉
- 提交前跑 `swift test --package-path ios`
- 每批真机探针验证后再进下一批
