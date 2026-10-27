# 时间线跟手手感：事务内贴底 + Pace + 去自起弹簧（2026-10-28）

> 触发：pp 真机反馈——「在底部，工具调用这类的往上弹，感觉轻飘飘的，没质感没力气，太慢；官方都不这样」。
> 关联待办：`docs/composer-official-alignment-task.md` §15.12（空输入框「荡」、回复结束尾摆）。

## 现象与范围

- Code 页（collection timeline），停在底部时：工具行/状态行/思考块出现，内容高度瞬间变大，列表用约 0.4 s 的 ease 弹簧追新的底 → 观感「软、慢、没劲」。
- 流式正文生长同样：列表始终落后内容，流结束再补最后一段（尾摆）。
- 范围仅 Code 页时间线引擎；手指拖动的减速/回弹参数未改，仍走 UIKit 默认（与官方一致）。

## 根因（代码 + 官方证据）

1. **插入行没有在更新事务里答新底**。官方对行插入/删除在 `prepareForCollectionViewUpdates` / `invalidateLayoutWithContext` 里
   `answer(ids, arriving)`，结果写 `offsetOwedToUpdate`，由布局 `targetContentOffset(forProposedContentOffset:)` 在同一更新里应用
   （`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/UPSTREAM/part-ag-scroll-params-draft.md:134`、`:136`）。
   AA 的布局只答历史前插（`insertionOwed`）与高度修正（`heightOwedToUpdate`），底部追加新行不答 → 只能等 `contentChanged` 起弹簧。
2. **Mover 缺官方的 Pace 目标位移补偿**。官方 Mover 每帧重问目标，目标变化 ≥1 物理像素才改写，并**按差值平移、不重新起飞**
   （`part-ag-scroll-params-draft.md:107-108`、`:124`、`:176`；我们自己的任务单 `/home/ubuntu/aa-test/beta-integration/docs/perf-6b-m1-task-sheet.md:551` 同述）。
   AA 的 `retarget` 只换弹簧，不搬位置：临界阻尼追匀速目标的稳态滞后 = `v·duration/π ≈ 0.127·v`
   （300 pt/s 时实测 35.7 pt；同一积分器仿真实测，见下）。
3. **safe-area 非系统事务时自起 0.24 s 弹簧**。官方 inset 路径只直接写（`part-ag-scroll-params-draft.md:79`），不自建动画。

## 改动

| 文件 | 改动 |
|---|---|
| `ios/.../Models/Chat/TimelineCollection/TimelineAnchorMover.swift` | ease（bounce==0）时按目标差值平移位置（Pace），保留速度；`start`/`reseed` 重置基线，避免把已由外部写入的位移再叠一次 |
| `ios/.../Views/Chat/TimelineCollection/TimelineAnchorDriver.swift` | 运动跨越 placement 变化时重新起飞（不把大跳当 Pace 平移）；inset 分支去掉自起 0.24 s 弹簧 |
| `ios/.../Views/Chat/TimelineCollection/TimelineListLayout.swift` | `targetContentOffset` 在更新事务内、且驱动处于「`.end` + `.resting`」（已静止贴底）时，答新的 `.end` 底；任何弹簧/手势运动都不答，避免截断回底动画 |
| `ios/Tests/ClientCoreTests/TimelineAnchorMoverTests.swift` | 增长目标无稳态滞后；停止后无过冲/尾摆；初始间隙仍由弹簧收敛 |

## 判据

- 单测：目标以 300 pt/s 增长 1 s 后 |target − position| < 1 物理像素；停止后 0.2 s 内到位且无反向过冲。
- 门禁：`timeline-autorun` 全绿（拖动/惯性中仍不写 offset，可见行不移动）。
- 真机：底部工具行出现时页面同帧上移；流式正文贴底无拖尾；键盘/输入框跟随不再「荡」。

## 未覆盖

- 官方 `Ease.Pace` 的精确权重是 INFERENCE（字段/常量 EVIDENCE，接线语义 INFERENCE）；本实现取「目标差值等量平移」这一支，真机手感 A/B 后再定是否加平滑。
- 未改 CADisplayLink → UIUpdateLink（官方 before-commit + continuous），留作后续候选。
