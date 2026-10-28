# 时间线跟手手感：内容增长 0.2s + Pace（2026-10-28）

> 触发：pp 真机反馈——「在底部，工具调用这类的往上弹，感觉轻飘飘的，没质感没力气，太慢；官方都不这样」；
> 后续追加「发送后键盘收完列表还在滑」「删掉动画反而不像官方」。
> 关联待办：`docs/composer-official-alignment-task.md` §15.12。

## 现象与范围

- Code 页（collection timeline）停在底部时：工具行/状态行/思考块出现、发送气泡插入、流式正文生长，内容高度变大 →
  列表用 **0.4 s** ease 弹簧去追新底，观感「软、慢、没劲」；流式结束再补最后一段（尾摆）。
- 范围仅 Code 页时间线引擎；手指拖动的减速/回弹参数未改，仍走 UIKit 默认（与官方一致）。

## 根因

1. **内容增长用了错的弹簧**。`contentChanged` 一律走 Mover 的 `ease`（0.4 s，官方用于"跟随追赶"）。
   官方 Code 页的插入/测量走集合视图更新（`offsetOwedToUpdate` / `setContentOffsetAdjustment`），观感约
   **0.25 s**（UIKit 插入默认时长），不是 0.4 s 追，也不是硬跳。
   （官方 `part-ag-scroll-params-draft.md:134`、`:136`；`CANONICAL/05-layout-scroll.md` §13：Code 页发送不发 `sending`/`sent`，placement 恒 `.end`。）
2. **Mover 缺官方的 Pace 目标位移补偿**。官方 Mover 每帧重问目标，目标变化 ≥1 物理像素才改写，并按目标位移推进 pace
   （`part-ag-scroll-params-draft.md:107-108`、`:124`、`:176`；`Ease.Pace` 字段与常量 EVIDENCE，接线语义 INFERENCE）。
   AA 的 `retarget` 只换弹簧、不搬位置：临界阻尼追匀速目标的稳态滞后 = `v·duration/π ≈ 0.127·v`
   （仿真：300 pt/s 时 35.7 pt；按目标位移平移后为 0.00 pt）。
3. **发送路径叠了第二个弹簧**。产品层在 pending/队列 id 变化时调 `requestBottom(animated: true)`；
   发送同时收键盘、输入框收起（0.24 s inset 弹簧）正在移动 offset，回底请求看到的间隙常 >1px → 再起一个 0.4 s Mover。

## 改动

| 文件 | 改动 |
|---|---|
| `ios/.../Models/Chat/TimelineCollection/TimelineSpringFollow.swift` | 新增内容增长专用弹簧 `content = Spring(duration: 0.2, bounce: 0)` |
| `ios/.../Models/Chat/TimelineCollection/TimelineAnchorMover.swift` | Pace 可开关（`usesPace`）；目标本帧移动时不判到达；`start`/`reseed` 重置基线，避免把已由外部写入的位移再叠一次 |
| `ios/.../Views/Chat/TimelineCollection/TimelineAnchorDriver.swift` | 内容增长：**新建运动**用 `.content`（0.2 s）且不走 Pace；**连续增长的重定向**回到 `.ease`（0.4 s）并关掉 Pace（pp 反馈 b614 的正文流式更顺）。显式运动（回底/回顶）一律 `fly`（0.36 s / bounce 0.15，官方 `0x1019df668`；>1 屏先预置一屏、不再按距离退回 ease），并保留 Pace；placement 变化时重新起飞 |
| `ios/.../Views/Chat/TimelineCollection/TimelineChatTimelineView.swift` | 删掉 pending/队列 id 变化时的显式回底（插入本身是内容变化；避免与 keyboard/composer 收起叠弹簧） |
| `ios/Tests/ClientCoreTests/TimelineAnchorMoverTests.swift` | 增长目标 ≤1 物理像素滞后；停止后无过冲/尾摆；初始间隙仍由弹簧收敛；reseed 不双移；fly 不跟随平移 |

## 试过并回退的（留档）

- **更新事务内答新 `.end` 底**（`targetContentOffset` + finalize 兜底）：实现过、门禁也绿，但真机 pp
  反馈「工具行现在没这动画了」「删了反而还没官方那感觉」——官方是短动画（~0.2-0.25 s），不是瞬时。
  已整体回退，连 `bottomFollowTracksInPlace` 一起删除。
- **内容增长直接落底（瞬时）**：同上，b627 修好了发送余滑，但工具行/流式全都瞬跳，手感偏离官方。

## 明确不做（回退）

- **safe-area 自起 0.24 s 弹簧保留原样**。b558 探针实测：输入框展开段 `inherited=0.000s`，安全区 60↔109 没有系统动画事务，
  直接写 offset 是 49 pt 硬跳；`499b3e3f` 用 0.24 s 弹簧与 composer 的 `.smooth(0.24)` 对齐，b559 真机确认空/有字都顺滑。
  本次曾按「官方不自建动画」尝试去掉，红队以这条设备记录驳回，已回退。

## 探针结论（b625/b626，pp 真机日志）

- 收键盘、输入框收起都正常（`inh 0.383` 随键盘、`inh 0.000` 的 49pt 是输入框收起）。
- 气泡的高度在快照 apply **之前**就变了 → `contentChanged` 先起弹簧；等 apply 的 `prepareForUpdates` 跑时 `motion` 已是
  `.easing`。这条链决定了"更新内答新底"在真机上经常来不及，最终改为「内容弹簧 0.2 s + Pace」。
- 探针日志代码（`AnchorDeviceProbe.recordMover/recordLayout`）留在 `#if AA_TIMELINE_PROBE` 下，正常包不编译。

## 判据

- 单测：Pace 开启时 300 pt/s 增长稳态 `|target − position|` < 1 物理像素；关闭时保持 b614 的跟随滞后但**不得中途到达**；停止后 2 帧内到位且无反向过冲。
- 门禁：`timeline-autorun` / `code-profile` 全绿（拖动/惯性中仍不写 offset，可见行不移动）。
- 真机：工具行出现时页面短促上顶（≈0.2 s，不是 0.4 s 慢追、也不是瞬跳）；发送后键盘收完不再余滑；流式贴底无尾摆。

## 未覆盖

- 官方 `Ease.Pace` 的精确权重是 INFERENCE；本实现取「目标差值等量平移」。若真机觉得过硬，再按官方 `steady` 平滑速度重做。
- 内容弹簧 0.2 s 是按 UIKit 插入默认时长与 pp 手感定的，不是官方实测值。
- 未改 CADisplayLink → UIUpdateLink（官方 before-commit + continuous），留作后续候选。
- 门禁没有断言「插入行后 offset == 新底」；`movesPerTick` 的既有断言恒假（见顺带发现），本次未改门禁。
