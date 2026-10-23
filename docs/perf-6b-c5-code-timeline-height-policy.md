# Code 页时间线高度策略治根（任务单）

> 状态：阶段 0–3 已实现（2026-10-23，`386f1eb8` / `69065485` / `cd217f8e` / `80956196`），待 CI 全绿与真机探针复测；阶段 4 未做。分支：`feat/code-profile-beta`。不合并 dev。
> 依据：2026-10-23 15:51:36 真机探针（app 2.1.1(395)，会话 `sess_Ub_FQIoh-F3N8w`）+ 官方契约（`CANONICAL/05-layout-scroll.md`）。
> 关系：与 `docs/perf-6b-c5-code-working-status-row.md` 并行；状态行任务先落地（它移除 `showsWorkingStatus` 这个 re-key 源）。

## 1. 缺陷
一次 22 秒采样：
- applies=28、heightChanges=91（tracking 46 / decelerating 22）、offsetJumps=13、fitMismatch=9、maxStaleDelta=1384pt、maxFrameMs=47ms、slowFrames=67/317、measureMsMax=4ms、applyMsMax=25ms。
- 同一行高度震荡：`b18258bd` 56↔1557.7；`c2262d41` 66↔745.7；`e9204e77` 446.3↔42.0；`7ad1d409` 222.3↔103.3。
- 换窗：`t=14.08 A items=46 changed=17 contentH=2948 off=0` → `offsetJump 0→1384`，5 个可见 cell `dy=1384`。
- 可见行 `37b2b2b6`：`est=139 / exact=126 / fit=125`（crude 估算 139；结构化精确 126；真实渲染 125）。

## 2. 官方契约（对照）
- 宿主：UICollectionView + 自研 layout + 全部 `UIHostingConfiguration`；行内容 `fixedSize(vertical)` + 几何回报（`05:27-53, 83-104`）。
- 行高只有估算/实测两档；估算只服务「从未测过的行」，缓存键 = ID + 宽度（`05:85-100`）。
- 首次自测只在 `isMeasured()==false`，`systemLayoutSizeFitting(1000,50)`，全局关闭自动自测失效（`05:101`）。
- 几何回报：内容 size + 竖直 margins → Layout，变化才接受 → 写 Row.height/isMeasured → 重算后续前缀和（`05:102-105`）。
- 补偿：事务外 `setContentOffsetAdjustment` + `setContentSizeAdjustment` + invalidate 可见项；事务内只写 `offsetOwedToUpdate`（`05:104`）。
- 宽度变化：只清 `isMeasured`，**保留旧高度**（`05:108`）；同宽度内容变化：reconfigure + 几何回报（`05:109`）。
- Code 页 `opensAtTop=false`、`scrollAnchor=nil`（`05:203-214`）；行边距 `(5,16,5,16)`、行底 padding 0（`05:117-149`）。

## 3. 根因（含对抗审查修正）
- **RC-1**：内容 revision 变化时 `setCurrentKey` 删除旧键条目（`TimelineHeightCache.swift:64-70`）；新键上的结构化预测量（写在 `.estimate` 档，`TimelineCollectionController.swift:1029-1038`）压过 displayed 高度（`TimelineHeightCache.swift:101-110`）。实跑缓存逻辑：新键 estimate=56、displayed=1557.7 → resolved=56。
- **RC-2**：滚动中不写结构化预测量，`prepare` 退到 crude 估算（`TimelineListLayout.swift:174-177` + `TimelineChatContentAdapter.swift:222-243`），误差可达 2.3×；gate 从未覆盖这条生产路径。
- **RC-3**：Code 组签名含 `updatedSeq/revision`（`TimelineContentSignature.swift:5-9, 66-110`），线务字段变化也 rekey；服务端重排会以新 revision 重写行（`server/agent_server/infra/repositories/timeline.py:770+`）。
- **RC-4**：`prepare` 用 `resolvedHeight`，delta 基线用 `displayedHeight(for:)`（`TimelineListLayout.swift:183 vs 1017-1022`），两边可能不同 → 补偿量错。
- **RC-5**：换窗 `discardParkedHeights` + 高度重建；`resolveWindowReplacementBottom` 设 offset 后未 `layoutIfNeeded`（`TimelineCollectionController.swift:743-773`），stale 帧可能是时序而非双重补偿（未确认）。
- **RC-6**：手势中仍有可见行高度变化（探针 tracking 46 / decelerating 22）；真机冻结未证明。
- **RC-7**：apply 成本/帧预算：`applyMsMax=25ms`、`maxFrameMs=47ms`；`TimelineMeasurementPipeline` 预算全为 0（`TimelineCollectionController.swift:1122-1128`），"设上限"目前是空转。

**对抗审查修正（必须遵守）**
1. `.estimate` 档装的是结构化精确预测量（`measured: true`），不是 crude 模型；crude 只是 `fallback`，今天不可能覆盖 displayed。不要把 resolved 顺序简单改成 displayed-first——会降级唯一的 apply 前预测量，并让状态行收缩在手势中变成空带。
2. 不能把 `codeHeightDigest` 直接当 reconfigure 签名：它不含 paced 流式文本/revision，会吞掉流式尾巴。**拆成两件事**：高度 key 用绘制内容摘要；reconfigure 签名保留 revision/updatedSeq 并加入 paced 流式文本。
3. 不能删掉新行的结构化预测量（那是新行唯一的精确来源）；只禁止它对“已显示过的行”覆盖 displayed。新行写 `provisional`（不算 measured、不抑制自测）。
4. 若把旧 measured 带成新键 `.measured`，`hasMeasuredOrPrecalcHeight` 会永久抑制 cell 自测；不要这样做。
5. `prune(keeping:)` 现状正确（只清离窗 item），不要改成跨窗保留高度。
6. 现有 gate 阈值 text=1 / bubble=2 / tool=2，不得放宽。
7. 先确认 56↔1558 的写入者（结构化预测量测到短内容 vs cell 上报解析前占位），再决定占位 guard。**更新（2026-10-23）**：探针已具备 writer/tier/exact/keyRevision 字段（`386f1eb8`），但真机日志尚未回传；guard 先按“所有低于 floor 的上报一律丢弃”实现，覆盖 parked self-measure 与 live group（用 estimate 作 floor），不依赖写入者结论。

## 4. 不变行为
1. 拖拽/惯性中可见行高度不变、可见内容不移动。
2. 加载更早 prepend 锚点不跳；加载最新/换窗后回底部。
3. 开屏落底；发送后新行贴顶。
4. Code 组一行、流式只在尾行、子代理/隐藏行过滤不变。
5. 任何高度变化有等价 offset/size 记账。
6. 已测行拒绝二次自测；未测行只自测一次。
7. Chat 行保持现有轮询路径。
8. 现有 gate 全绿（timeline-autorun / code-profile / gestureFreeze / loadLatestReturn / collapseGap）。
9. 视觉常数不变。

## 5. 阶段

### 阶段 0：诊断与门禁（无行为变化）
- 修探针标签：`tier=` 输出实际 tier + 写入者 + displayedHeight + structuralExact + crudeEstimate + resolved（`TimelineProbe.swift:507-510`）。
- 记录每次高度写入（writer）与每次 apply 的 key 变化列表；记录静态行 30 秒内 key revision 是否变化。
- 新增 controller 级 gate：cell-reported Code 行先报解析前占位、再报真实高度；rekey 后再报。断言：手势中可见行不变；每键一次自测；最终 frame == cell 报值；占位值不触发补偿。
- 新增 rowHeight fixture：真实 markdown（多段/行内代码/列表/代码块）与长用户提示；比较**布局将采用的值**与真实渲染；阈值 text=1 / bubble=2 / tool=2。
- 验证：同会话复现，报告能定位 `b18258bd` 的 56 写入者；新 gate 在当前代码上红。
- 回滚：独立 commit；无行为变化。

### 阶段 1：止血
1. 新增 `provisional` 档：布局可用、不算 measured、不抑制自测；只写“从未显示过”的新行（结构化精确值）。
2. 已显示过的行 rekey：保留 displayed 高度，不写新值；等 cell 上报。
3. `prepare`、`displayedHeight(for:)`（补偿基线）与 `projectedHistoryLayout` 用同一个 resolver。**修正（对抗审查）**：prepend 投影若对变更行改用“新测量”，而布局本身仍显示旧高度，锚点会移动两次（target 一次、cell 上报补偿一次），因此投影必须与 prepare 同源。
4. `layoutEstimateKind` 只读 apply 期缓存的 provisional；禁止在 prepare/滚动路径现场算 crude。
5. 拆分 key 与 reconfigure（见 §3 修正 2）。
6. 不保留离窗高度（prune 不动）。
- 验证：`TimelineHeightCacheTests`（保留“新 revision 不继承旧测量”用例）；controller gate；探针无非内容变化 |delta|>50。
- 回滚：单 commit；provisional 不改变外部契约。

### 阶段 2：占位上报防护（含对抗审查修正）
- 在三条写入路径**任何 cache 写入之前**校验：`applyHostedHeight`、`applySelfMeasuredHeight`、以及手势中被停泊的 self-measure（`shouldInvalidateLayout` 的 park 分支）。
- 判据：`height < max(24pt, exact × 0.35)` 才拒绝；**一律丢弃，不再“第二次接受”**（否则 SwiftUI 的 20→56 两个中间值仍会漏进来）。合法矮行的 exact 也矮，floor 随之下移；结构测量若高估，行停在 provisional 上而不是被占位覆盖。
- live group（streaming/revealing）没有 settled exact：用 `estimateKind.height` 作 floor（粗估即使高估 2.3×，35% 仍高于 20–56pt 的占位）。
- 新行结构化预测量写 provisional（不写 measured）；已被 cell 物化过的行不再收到新预测量（`everDisplayed`）。
- 验证：controller gate（含 at-rest 占位腿）；探针 fitMismatch=0、staleCell=0、手势中可见行变化=0。
- 回滚：guard 可独立移除。

### 阶段 3：换窗/开屏
- ✅ 换窗插入行由 `measureSynchronously` 写 provisional（不碰旧窗口内容）。
- ✅ `resolveWindowReplacementBottom` 设完 offset 后 `layoutIfNeeded()`，同 runloop 同步 cell 帧。
- ⏳ 给 4 个 `setContentOffset` 调用点打 source 标签，确认是否双重补偿（未做，留待真机探针判定）。
- 验证：换窗后 contentH 在 apply 时即最终值；offsetJump 只剩有意定位；loadLatestReturn gate 绿。

### 阶段 4：性能
- 填 `TimelineMeasurementPipeline` 真实成本或 deadline；两条测量循环纳入同一 deadline。
- 先证明重复 apply 存在再合并（`isPerformingSnapshot` 已串行化）。
- 验证：同场景 slowFrames < 5%、maxFrameMs < 25ms、measureMsMax < 8ms。

## 6. 验证计划（总）
- 模拟器/单测：阶段 0 gate、rowHeight fixtures（阈值不放宽）、流式尾块完整性、换窗、全量单测 + 现有 gate。
- 真机探针（同一会话同一段滚动）：staleCell=0、maxStaleDelta≤2pt、fitMismatch=0（已沉淀可见行）、手势中可见行变化=0、offsetJump 只剩有意定位、apply 时 contentH 即最终值、slowFrames<5%、maxFrameMs<25ms。
- 对照：修复前后各存报告；开屏/加载更早/加载最新/发送/流式/旋转/大字号各跑一次。

## 7. 风险
- 手势中状态行收缩的空带：由独立状态行任务（C）消除；本任务不再处理。
- 长用户气泡的结构化预测量是否准确未验证（1681 是 crude 值）；阶段 0 fixture 先确认。
- 新行 provisional 的准确性依赖结构化测量；若长气泡偏差大，新行暂时回退到 0 高/保守值（需 pp 确认）。
- 不改 Chat；resolver 需 Code-only 隔离并加单测。
- 性能目标为建议值，需 pp 认可。

## 8. 未决
- 官方 `estimatedRowHeight` 开关线上取值（未证）。
- 换窗 offsetJump 是帧同步晚还是双重补偿（`layoutIfNeeded` 已加，需真机探针确认 staleSamples 是否消失）。
- 56↔1558 的写入者：探针已能在真机报告 `writer/tier/exact/keyRevision`，**等待下一份真机报告**；guard 已覆盖三条路径（含 live group），不依赖该结论。
- 加载更早状态需要**顶部**探针报告（`prompt:older` 是否在 items 里）。
- 气泡直角（`CodeUserBubble` 的 24pt continuous 在真机截图里呈直角）与本线无关，需单独截图/视图层级定位。
- 阶段 4（测量预算/deadline）未做；等真机复测后的帧数据再定。
