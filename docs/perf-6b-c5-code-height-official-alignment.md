# C5 · Code 行高对齐官方：单一确定性测量

> 状态：已确认方向（pp 2026-10-23「我早就说了对齐官方 所以请你不要再打补丁了」「可以」）。
> 本文替代 `perf-6b-c5-code-timeline-height-policy.md` 阶段 1–3 里"多写者 + 占位守卫 + 滚动停车"的部分；那份文档保留作为历史与下游验证记录。

## 0. 一句话

行高的唯一来源改为**确定性测量**（`contentView.systemLayoutSizeFitting`，与官方 `preferredLayoutAttributesFittingAttributes` 同义），只在**首次物化**和**静止 settle** 两个时刻读取；几何回报只作为"该重测了"的触发，不再把它的数值写成行高。删除滚动停车、占位守卫、hosted 数值上报等官方没有的路径。

## 1. 官方证据（CANONICAL/05，EVIDENCE）

- 首次自测：`TranscriptListCell.preferredLayoutAttributesFittingAttributes`（`0x101a39244`）只在 `isMeasured()==false` 时 `systemLayoutSizeFitting(1000, 50)` 并向上取整；`setSelfSizingInvalidation:0`（`0x101a3b368`）。
- 后续变化：`_GeometryActionModifier`（`0x100b7d97c`）→ `0x1019edf08` → `0x1019ece34` → Surface `0x101a3b660` → Layout `0x101a3fbb4` → `0x101a4081c`（`fcmp; cset ne`，变了才接受）。
- 同宽内容变：reconfigure（`performWithoutAnimation`）→ 重新测量；宽度变：只清 `isMeasured`，旧高度当估计（`0x101a3ff20`）。
- 补偿：事务外 `setContentOffsetAdjustment`（`0x101a40ebc`）+ `setContentSizeAdjustment`（`0x101a40f4c`）+ invalidate 可见项；事务内只写 `offsetOwedToUpdate`。
- 官方高度路径里**没有**占位比例判据、**没有**滚动停车；`isFingerOnTheList` 字段存在但用途静态未打通（UNKNOWN），不作为依据。

## 2. 现状偏差（设备证据，2026-10-23 20:49:35）

- 我们把几何回报的**数值**当行高：probe `fitChecks` 里 `fit=187` 而帧 `107.3`；同一行 187↔107.3、656↔261.3 反复。
- 为压住这些数值，先后加了 park/flush、`provisional`、35% 占位守卫、`visibleFit`，彼此覆盖。
- `heightChanges=152` / `applies=2`；手势期可见行变化 `changesTracking=49`、`changesDecelerating=93`。

## 3. 目标模型（不变量）

1. **唯一来源**：Code 行（`usesCellReportedHeight == true`）的高度只来自 `cellFit`（`contentView.systemLayoutSizeFitting`）。
2. **唯一时机**：首次物化（`preferredLayoutAttributesFitting` 一次）与静止 settle（apply 完成 / 滚动结束后的 settle 轮次）。
3. **几何只触发**：cell 的几何变化回调不再携带高度；它只调度一次 settle。
4. **唯一提交**：所有落高都走 `TimelineListLayout.applyMeasuredHeight`（缓存 + frame + invalidation + 补偿一体）。
5. **内容变化**：key 变 → reconfigure → 首次物化自测一次；宽度变 → 清 `measured`、旧高当估计（现有逻辑）。
6. **手势中不测量、不落高**：settle 在 `isTracking || isDecelerating` 时返回；滚动结束再 settle（现状保留）。
7. **唯一适配项（不是守卫）**：settle 对 hosted 行要求**同一 fit 连续两次轮次一致**才提交，抵消 SwiftUI 异步渲染的中间态；只比较"当前 fit"，不携带历史数值。

## 4. 删除清单

- `TimelineHostingCell` 的数值回调 `onContentHeightChange: (CGFloat) -> Void` → `onContentChanged: () -> Void`。
- `TimelineListLayout.applyHostedHeight` 及其调用点。
- `pendingHostedHeights` / `flushParkedHeightsAfterGesture` / `pendingHostedUpdates` / `discardParkedHeights` 里的 hosted 部分。
- `isPreParsePlaceholder` 及三处调用（`shouldInvalidateLayout`、`applySelfMeasuredHeight`、`applyHostedHeight`）。
- `shouldInvalidateLayout` 里的 park 分支（保留 `!isMeasured` 的首次自测接受/拒绝）。
- 探针 writer 里的 `hosted` / `hostedDeferred` 标签（保留 `selfMeasure` 与 `visibleFit`→改名 `cellFit`）。

## 5. 保留清单

- `estimate`（仅未测行，按宽度命中缓存）与 `provisional`（apply 前用结构计划写的好估计，不抑制首测）。
- `displayedHeights`（补偿基线与 re-key 保留）——它不再被任何回报数值污染。
- 宽度变化清 `measured`、事务内外两套补偿、prepend/换窗/回底的 owed target。
- Chat 行（`usesCellReportedHeight == false`）的 `visibleFit`/交互行动画路径不变。

## 6. 实施步骤

1. **A（cell）**：回调改为无值触发。— ✅ 已实现
2. **B（controller）**：触发 → `scheduleVisibleCellSettle()`；settle 循环去掉 `usesCellReportedHeight → continue`，统一 `cellFit`；hosted 行要求两轮一致后提交。— ✅ 已实现（`pendingCellFits`）
3. **C（layout）**：删 `applyHostedHeight`/park/flush/placeholder/StructuralHeightHost；`applySelfMeasuredHeight` 保留首次自测。— ✅ 已实现
4. **D（probe）**：`source` 标签收敛为 `cellFit`/`visibleFit`/`selfMeasure`。— ✅ 已实现（中间态确认次数待真机报告验证）
5. **E（gate）**：重写 `codeHostedHeight` 为对齐契约：首次=fit；内容变化只变一次；手势中锚点不动、松手不二次落地；`gestureFreeze` 改为屏幕坐标断言。— ✅ 已实现，待 CI
6. **F（tests）**：删除 `hostedHeightChange` 及其测试；`TimelineHeightCache` 用例保留。— ✅ 已实现

## 6.1 2026-10-24 收尾：手势 388pt 偏移的根因与门禁语义

- **根因不是高度存储**。offset trace 里 13 次高度应用全部没有 `correction`，`applyHeightUpdates` 只出现过一次 −0.67 的首次自测；而 `scrollViewDidScroll` 的调用栈每一帧都是
  `repinIfArmed → layoutDidChangeContentHeight → prepare`。
- **触发条件**：`gestureFreeze` 的列表太短，`scrollToItem(.top)` 实际停在内容底部；测试 seam 只设了 `testGestureState`，没有搬 `scrollViewWillBeginDragging` 的 `mode = .reading`，于是 `noteBottomArrival` 在每次内容变高时重新上膛 bottom target，`repinIfArmed` 每帧把 offset 钉到新的底部，行被拖出屏幕 388pt。真机拖拽会设 `.reading`，不会走这条。
- **修复**（`d79f925f`）：DEBUG seam 完整镜像 `scrollViewWillBeginDragging` / `scrollViewDidEndDragging`（phase、mode、disarm、settle 调度）；两处 settle 守卫改读 `isUserScrolling`，与真机一致。Release 行为不变。
- **门禁语义修正**（`5fc444d9`）：产品在手指下不做测量，内容变更在松手时落地。断言改为可见契约——手势中零位移、松手后变更行到达 `cellFit` 一次、变更行自身顶部不动、其下方行被推开；夹具补足一屏内容，避免底部钳制造成的 0.67pt 假位移。

## 7. 验证

- CI：`test` + `timeline-autorun` + `code-profile` 三轮绿。
- Gate 断言：物化后高度 == `cellFit`（±0.5）；一次内容变化只产生一次高度变化；手势期 `vis=1` 变化 = 0。
- 真机判据：`fitMismatch=0`；同一行翻转=0；`maxStaleDelta<2`；`offsetJump` 仅剩用户主动操作；`slowFrames<5%`。

## 8. 影响面

- 行为：所有 Code 行（消息组 + workingStatus）。Chat 行不动。
- 首帧：未测行仍用 estimate/provisional；物化后一次 fit。
- 图片/附件：几何触发 → 静止 settle 重测（不再即时落值）。
- 补偿/换窗/prepend：路径不变，但触发时机从"回报即落"变为"静止落"。
- 文件：`TimelineHostingCell`、`TimelineCollectionController`、`TimelineListLayout`、`TimelineProbe`、`TimelineAutoRun`、相关单测、本文档。
- 回滚：A–F 各自独立 commit。

## 9. 不做

- 气泡直角/底部空白、加载更早触发、工具行合并（独立缺陷）。
- 估算表校准（P4）与性能预算（P5）——等本模型真机复测后再排。
