# 时间线行高上报修复方案（2026-11-01）

> 症状：长消息在流式/滚动期间内容变高，行仍按旧高度显示（内容被裁），
> 且高度修正落盘时下方 `tail` 不跟随，出现 142pt 重叠。
> 复现补充（pp）：把该行滑出屏幕再滑回来即恢复正常。
> 关联：`docs/handoff-perf-jank-20261031.md`（A 线：长消息 re-key / apply 尖峰）。

## 1. 证据（b815 探针，2026-11-01 10:18:09）

| 时间 | 记录 |
|---|---|
| t=32.68 | `contentMismatch`：该行文本 `1. 2.` → `1. 2. 3.`，高度 **269 → 269**（未变） |
| t=33.39 | `fitMismatch`：同帧 fit 应为 **411**，frameH=269，delta=142 |
| t=32.86 | apply：`changed=3`，diffs 含 `g:msg_28923c06…:rows+actionBar`；`apply-measure n=10 ms=0`（无新测量） |
| t=30–48 | 日志有持续 decelerating / tracking 样本（用户正在滑） |
| t=48.65 | 才出现 `rowMeasured 269→411`（滚动停下后的 settle 轮询） |
| t=48.78 | `staleCell ×17`：tail cell y=31100，attribute y=31242，dy=142 |
| t=48.78 | `cellOverlap`：上行 h=411 与 tail 重叠 142pt（截图症状） |

滑出屏幕再滑回即好：cell 被回收重建 → 首次 fit 重新测量。

## 2. 根因

1. **聊天行没有实时高度上报通道。**
   `TimelineHostingCell.swift:94-109` 仅在 `reportsContentHeight == true` 时装
   `onGeometryChange`；而 `TimelineChatContentAdapter.swift:548-552` 的
   `usesCellReportedHeight` 只对 `explicitID != nil` 的组（Code/手势行）返回 true，
   普通消息行走控制器轮询。
2. **轮询在滚动中被明确跳过。**
   `TimelineCollectionController.swift:1073` `if isUserScrolling { return }`。
   因此滚动期间内容变高的行没有任何测量落到它身上，保持旧高度、内容溢出被裁。
3. **高度落盘时下方 cell 不在同一布局帧归位。**
   `TimelineListLayout.applyHeightUpdates(..., reusing: context)`（1115-1174）在
   复用 invalidation context 的分支里只改 context，不触发新的 layout pass；
   被 invalidate 的 tail 要等下一次布局（实际等到 t≈48.87 的滚动）才移动。

## 3. 目标 / 非目标

**目标**

- 可见行内容变高/变矮后，高度在同一轮布局内收敛（不再等 settle）。
- 高度修正落盘时，其下方可见 cell（含 tail）同帧归位，不出现 staleCell / cellOverlap。
- 不劣化流式帧率与 apply 耗时（对比 b823 baseline）。

**非目标**

- 不改折叠/展开动画、不改 tail 语义、不改窗口裁剪。
- 不改 A 线 re-key 逻辑（本方案只动高度上报与布局失效）。

## 4. 方案总览

| 阶段 | 内容 | 风险 | 回滚 |
|---|---|---|---|
| P0 | 探针补拒绝/延迟计数 | 无行为变化 | 关探针 |
| P1 | 高度落盘后同帧重排下方 cell | 低 | 单提交回退 |
| P2 | 聊天行启用 geometry 高度上报（开关控制） | 中（布局开销/写入时序） | `defaults write …TimelineRowHeightReporting.enabled -bool NO` |
| P3 | 真机验收 + 回归 | — | — |

每阶段独立提交，可单独回滚。

## 5. 详细设计

### P0 探针增强（先量后改）

新增（`TimelineProbe.swift` + 调用点，仅 `#if AA_TIMELINE_PROBE`）：

- `heightReportRejected[reason]`：`hostedContentHeightReported` 与
  `applySelfMeasuredHeight` 每个 guard 的拒绝原因计数
  （`noCurrentKey` / `staleKey` / `staleSignature` / `noAttributes` / `staleAttributesKey`）。
- `staleHeightMs`：可见行 `frame.height + 0.5 < fit` 的持续时间累计与最大值。
- `tailDelayMs`：高度变更落盘 → 下方 cell frame 与 attributes 一致之间的延迟。

FINDINGS 增加 `height_stale` / `tail_delay` 两条聚合，用于验收对比。

### P1 高度落盘后同帧重排（修 tail 重叠）

`TimelineListLayout.applyHeightUpdates` 复用 context 分支：

- 现状：`existingContext != nil` 时不调用 `invalidateLayout(with:)`。
- 改法：仍把 `contentSizeAdjustment` / `contentOffsetAdjustment` 写在被复用的 context 上，
  但**额外**构造一个只含 `invalidatedItemIndexPaths` 的
  `UICollectionViewLayoutInvalidationContext` 并调用
  `collectionView.collectionViewLayout.invalidateLayout(with:)`，
  或在该分支末尾调用 `collectionView.setNeedsLayout()`。
- 二选一依据：先在 P0 数据上比较「同一帧归位」与「重复布局」；默认取
  `setNeedsLayout()`（不重复应用 size/offset 调整，风险最低）。
- 风险：滚动中多一次布局 → 用 P0 的 `tailDelayMs` 与帧 hitch 对比确认收益大于成本。

### P2 聊天行启用 geometry 高度上报（修根因）

1. 新增开关（沿用 `CodeStreamingIncremental` 模式）：
   `TimelineRowHeightReporting.enabled`，默认 `true`，可用 `defaults write` 关闭。
2. `TimelineChatContentAdapter.usesCellReportedHeight(for:)`：
   开关开启时，聊天组行（`case .group`）一律返回 `true`；`workingStatus` 维持 `true`。
3. seed 路径复核：`TimelineCollectionController.swift:423-437`
   `!isMeasured && reportsContentHeight` 时 seed 取 `displayedHeight`
   （聊天行无 `measuredCodeGroupHeight`），需验证不会把流式行压成小高度
   （历史回归 461 probe：44→18）。
4. 首次 materialization 路径不变：`shouldInvalidateLayout(forPreferredLayoutAttributes:)`
   仍只接受未测量 cell 的首测（`TimelineListLayout.swift:908-927`）。
5. 轮询不再接手：`settlePreferredHeights` 第 1081 行已 `continue` 跳过
   cell-reported 行，两套写入不会打架。
6. 上报节流：`hostedContentHeightReported` 已有 key/signature 双重校验与 0.5pt 变更门
   （`applyMeasuredHeight` 内）。若 P3 数据显示流式每帧上报成本明显，
   在 `onGeometryChange` 闭包内加「同帧合并」（每 displayLink tick 最多一次）。
7. 风险与对策：
   - 每可见 cell 一个 `onGeometryChange`：只在几何变化时回调；用 P3 的 frameHitch /
     applyMsMax 对比 b823，超出 10% 则回滚开关。
   - 上报 → 改高 → 再布局 → 再上报的回环：由 0.5pt 变更门与 key 相等短路。

### P3 验收与回归

真机（同一设备，probe 包）：

1. 复现场景：流式长回复 + 持续滚动 + 停手，连续 3 次。
2. 探针判据（全部满足）：
   - `contentMismatch(text changed, height did not)` = 0
   - `staleCell` / `cellOverlap` = 0
   - `staleHeightMs` max < 50ms，`tailDelayMs` max < 50ms
   - `applyMsMax` ≤ baseline × 1.1；`frameRateHitches` 不高于 b823 同场景
3. 回归：`TimelineAutoRun` 的 `tailFlap` / hosted gates 全绿；滚动到底、跳转历史、
   折叠展开三条路径手测。

## 6. 提交划分

1. `probe: count rejected height reports and stale-height time`（P0）
2. `fix(ios): reposition cells below a landed height in the same layout`（P1）
3. `feat(ios): report chat row content height through the hosting geometry`（P2，带开关）
4. 数据与验收记录：提交到本文件末尾（真机报告摘要 + 对比数字）

## 7. 未解 / 风险

- 官方对 Chat 行是否也走 `rowMeasured`：`CANONICAL/05-layout-scroll.md` §2.2 表述为全行适用，
  但本仓库 Phase 1 只迁移了 Code 行（`TimelineListLayout.swift:911-915` 注释），需要真机数据确认
  打开后无写放大。
- `rowMeasured` 在滚动中的 offset 补偿策略沿用 `pendingMeasurement` 现有决策，不在本方案改动范围。
- P1 的 `setNeedsLayout` 若在流式每帧触发，可能增加布局次数；以 P0 指标判定是否改为
  「仅当变更行下方有可见 cell 时」才触发。
