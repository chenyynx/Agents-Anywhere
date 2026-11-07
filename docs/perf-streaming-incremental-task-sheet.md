# 流式增量刷新 · 任务单（2026-11-08）

> 状态：待开工。设计依据来自 2026-11-07/08 三轮真机探针（b1045/b1051/b1053）。
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
