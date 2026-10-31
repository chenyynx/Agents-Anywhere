# 时间线：开屏位置与历史翻页根治任务单（2026-10-31）

> 依据 b750/b752/b753 三份真机探针报告（02:24 / 02:38 / 02:54 / 03:10）与代码核对。
> 原则：每个用户可见问题对应唯一根因，一处修复；不在同一 bug 上叠补丁。
> 相关历史：`docs/handoff-code-timeline-20261031.md`、b741–b744 的窗口/锚点工作。

## 用户可见问题

| # | 现象 | 证据（探针） |
|---|---|---|
| U1 | 重新进入后停在页面中间，几秒后才到底部 | 03:10 报告：t=0.13 `auto-older fire top=0`；t=3.71 才被拉到底；t=4.27 才触发 latest 对账 |
| U2 | 自动加载有时失效（停在顶部不加载，只能手点） | 02:24 报告：58.31 最后一次 fire 后视口一直停在 -96.67，直到报告结束无新 fire |
| U3 | 翻页后位置"跳一下" | 02:24：apply 时 anchorY 320→540（上方增长 220pt）但 offset 不动；t=53.99 settle 一次 +497 瞬时写 |
| U4 | 底部"加载新消息"提示行出现（产品决定：不要） | 03:10：t=4.30/4.34 `prompt:latest` |
| U5 | 偶发整屏一帧错位 26pt | 02:54：t=51.93 批量 staleCell dy=26 dh=0 |

## 根因与修法

### R0 开屏落底未被保护（U1）
- 根因：冷开屏前几帧内容为空、视口在顶部；`maybeAutoLoadOlder` 只看"接近顶部"，立即触发历史加载，`beginHistoryPaging` 把驱动 placement 从 `.end` 改成 `.reading`，落底意图被顶掉。
- 修法：`beginOpeningBottom` 设置 `openingBottomPending`（2s 兜底），落底被观测到（`measuredAtBottom`）或读者拖动时清除；期间禁止 near-top 触发。

### R5 删除"加载新消息"提示行（U4，产品决定）
- 根因：`TimelineItemIdentity.build` 按 `hasLatestPrompt`（= `session.hasNewerItems`）插入 `.latestPrompt` 行。
- 修法：identity 不再产出该行（参数一并删除）；回底由滚动/手势触发，不靠行。

### R1 回底武装不校验读者意图（U3 的跳变来源之一，02:54 的 +31,005）
- 根因：`beginWindowReplacementReturn` / `armWindowReplacementReturn` 武装后，窗口 apply 时 `resolveWindowReplacementBottom` 只挡 tracking/decelerating；状态栏回顶既不是 tracking 也不是 decelerating，且不置 `readerTookOver`。
- 修法：`readerIntentGeneration`（拖动起始 / 状态栏回顶 / 历史分页开始 +1）；武装时记录，执行时不一致即作废；`pendingGestureBottomRequest` 同样校验；状态栏回顶经 `onReaderScrollToTop` 置 `readerTookOver`。

### R2 自动加载闩是位置驱动（U2）
- 根因：`olderAutoLoadArmed` 只在视口离顶 >320pt 时重新上膛；页面落点恰在顶部时闩永久死亡。
- 修法：每次新的读者手势（`scrollViewWillBeginDragging`）重上膛一次。一个手势最多一页；停在顶部不会链式加载。

### R3 晚期测量修正瞬时写（U3 的"跳"半）
- 根因：历史页落点后，上方行的测量结果延迟到达（布局对"锚点上方整行"给出 correction），补偿在 settle 窗口内以 `setContentOffset` 一次写；官方模型由 Mover 应答 `rowMeasured`（`EVIDENCE/UPSTREAM/part-z-textkit-height.md:81`）。
- 修法：settle 走"重绑锚点 + `easeSettledHistoryPlacement()`"（内容弹簧），不再瞬时 `enforce`；保留一屏漂移上限，读者已离开则不拽回。

### R4 一帧 cell 错位（U5，调研先行）
- 未定位：staleCell dy=26 dh=0 的批量出现说明 apply 后那一帧 cell 未随 layoutAttributes 重配。
- 计划：先读 `scheduleVisibleCellFrameSync` / `scheduleVisibleCellSettle` 与 apply 的先后关系，再单独提交；不并入 R0–R3。

## 排期与提交
1. R0（独立）
2. R5（独立，更新 identity 测试）
3. R1（独立；含 `onReaderScrollToTop` 接线）
4. R2（依赖 R1 的代际基建，仅一行语义）
5. R3（含 settle 探针一行）
6. R4 调研（另行）

## 验证
- 红先绿后：timeline-autorun 门禁加场景（顶部武装回底→窗口替换→offset 不变；停在顶部→不链式 fire；上滑一次→fire 一次）；撤销实验在临时 worktree 做。
- 真机清单：后台切回直接落底；顶部连续上滑一页一次；停在顶部不自动连翻；翻页无离散跳；无"加载新消息"行；启动无中间态。
- CI：test + build + probe；L 级完成后派独立 reviewer（链路/时序、测试有效性）。

## R6 开屏后页脚从分隔行跳走（2026-10-31 05:40 报告，"打开页面怎么乱跳一下"）

**证据（b764 探针，`long-message-20261031-054051.txt`）**
- `g:claude_compact_2391…`（压缩分隔行）在 t=4.14 由 121pt 收到 30pt，contentH 32928→32837、offset 32131→32079，0.18s 动画；t=4.12 同时新增 `g:steps:msg_23963b14`。
- 121.5 = 30（分隔行）+ 4 + 44（review 卡）+ 4 + 39.5（copy/时间行）→ ceil 121（`AssistantFooterMetrics` / `SessionTurnActionsRow.rowHeight`）。
- 结论：121 不是错误测量；是 `TimelineTurnActions.build` 把该回合的页脚挂在了"压缩分隔行"这个 Chat 渲染的 group 上。新 step group 到达后 host 迁走（或页脚被抑制），分隔行掉了 91pt，被 `animateRowHeight` 动画成可见跳动。

**根因**
- `TimelineTurnActions.build` 对回合内每个 group 都推进 `endGroupID`；分隔行（marker/system）和 Code 的 step group（`CodeStepGroupRowView` 不画页脚）都可能成为 host。host 不渲染页脚时会消失/迁移，每次迁移都让可见行改变 39.5–91pt。

**修法（一处根因，一处修复）**
- `build` 增加 host 资格：全为 marker/system 行的 group 不作 host（Chat/Code 通用）；新增 `footerHostEligible` 谓词参数，Code adapter 传入 `stepGroupsByID[group.id] == nil`。
- 非 host 的 group 仍累计 replies/changes/active（抑制规则不变）；页脚固定落在回合内最后一个可渲染的回复 group 上。
- 不改高度模型、布局或动画：分隔行不会再拿到 121pt。

**测试（红先绿后，ClientCore）**
- 回合 = user → assistant → compact 分隔行：页脚 key 必须落在 assistant group（当前实现落在分隔行）。
- 注入谓词排除 step group：页脚落在最后一个有资格的 group；无资格 group 则不产出。
- 既有用例（tool 结尾、file-change 结尾、steering）保持绿。

**验证与未覆盖**
- CI test + build（Views 不在 test target，必须看 build job）。
- 真机：打开"最后事件是压缩分隔行 + 稍后 step group"的会话，分隔行高度不得变化，页脚应位于最后一条回复下。
- 未覆盖：开屏 179 行 apply 的 258ms 主线程尖峰（步骤 7）；窗口替换瞬间的屏外 staleCell（步骤 5 证据包）。

## R7 加载历史后可见 cell 错配 → 大片空白（2026-10-31 05:56 报告）

**证据（b764 探针，`long-message-20261031-060408.txt`）**
- t=18.23 apply：`items 239→238`、`changed=0`（顶部 prompt 行被移除，整窗索引平移）。
- t=18.24 `[staleCell]` + `[fitMismatch]`：可见 cell `g:090732b8…` `frameH=1821 fit=53`（1768pt 空白），另一 cell `g:msg_e6ead750…` `frameH=44 fit=1821`——两个 cell 的内容/行高互换；`visible=1`，`maxStaleDelta=1777`。
- 现有 `syncVisibleCellFrames` 在 50ms 后才跑，且对 `usesCellReportedHeight` 的 hosted 行直接 `continue`，所以这条 1768pt 空白带没被修；下一次 apply（t=18.40）才恢复。用户看到的就是“加载页面空白”。
- 同报告的 ±30k/47k 位移不是缺陷：21.95 与 24.43 的落点 56836 精确等于 `57481 − 645`（右下角回底按钮的 one-viewport pre-place），20.4–21.3 是 `askedForStart` 的整距弹簧；均为显式滚动请求。

**根因**
- 结构性快照（窗口替换 / prompt 行增删）会改变全部 index path；UIKit 可能把 cell 移到新 index path 但没有重新绑定内容。`TimelineHostingCell` 没有记录自己配置的是哪个 item，controller 的可见校正又跳过 hosted 行，于是 cell 以旧内容 + 旧 frame 留在屏幕上，短行内容被拉进 1821pt 的 frame，剩余区域全空。

**修法**
- `TimelineHostingCell` 记录 `itemID`（configure 时写入，reuse 清空）。
- `syncVisibleCellFrames(forceHosted:layoutNow:)`：可见 cell 的 `itemID` 与当前 item 不符（含 nil）→ `reconfigureItems` 重新绑定；force 模式下同时检查 hosted 行 frame，失配即 invalidate 并同步 `layoutIfNeeded`。
- 结构性 apply（`windowReplaced || items.count != oldItems.count`）在 apply completion 内立即 `layoutIfNeeded` + 强制 reconcile，不再等 50ms。
- 探针新增 `cell reconcile rebind=N frame=N force=N` 一行（H 区），下次真机报告可直接验证。

**验证（待做）**
- CI test + build（Views 不进 test target，看 build job）。
- 真机：翻历史触发顶部 prompt 增删，页面不得出现空白带；probe 应出现 `cell reconcile` 且不再有对应 `staleCell/fitMismatch`。
- 未覆盖：t=2.88 历史页 apply 后 offset 从 6833.67 掉到 -97（锚点被顶到窗口顶部）——同一报告的第二个独立问题，见 R8，不在本修复里混改。

## R8 回到最新时整窗被最新页替换（2026-10-31 06:12 报告，"加载了全量消息又自动缩减窗口"）

**证据（b764 探针，`long-message-20261031-061439.txt`）**
- t=385.17：`offsetJump -48227.7`，offset 48114.7→-113，contentH 48865→334（约 5 行）——读者在已加载的历史底部，窗口被一次 latest 应用缩成 5 行；随后 loadOlder 又把窗口补回（28→68）。
- 计数器：`applies=2384`、`applyCount=2384`（7 分钟持续更新）；用户描述“全量消息→自动缩到 200 多”。
- 机制：`V2SessionRepository.loadLatest` 先应用本地 latest 页（可能只有 5 行），再后台对账网络页（约 200 行）；两步都走 `V2SessionProjection.applyLatest`，而 `applyLatest` 用 `replaceTimeline(page.items)` 整窗替换，丢掉了读者已加载的旧行。

**根因**
- `applyLatest` 把 latest 页当作“整窗定义”，而不是“更新最新侧”；本地优先页/网络对账页都比已加载窗口小，替换即缩窗。

**修法**
- `applyLatest` 先判断 latest 页与当前窗口是否重叠（`pageFirst <= windowLast && pageLast >= windowFirst`）：
  - 重叠：以 server-selected 语义 merge（`history: true`）进现有窗口，清 `hasNewerItems` 后合并页外 socket 行；保留旧行（内存上限仍由 `maximumItems`/`applyWindow` 约束）。
  - 不重叠/空页：保持原 `replaceTimeline`，避免留下无法回填的中间空洞。
- `hasOlderItems` 保留旧值再并上页的 `hasMore` 与 trim 结果。

**测试**
- 修改 `boundedHistoryWindowAndReturningToLatest`：回到最新后保留 `["1","2","3","4"]`，仅清 newer 标记。
- 新增 `aLatestPageKeepsTheHistoryTheReaderAlreadyLoaded`：12 行窗口，本地 3 行页 + 网络 6 行页，窗口必须仍是 1…12（旧实现会缩到 3/6 行）。

**未覆盖**
- 超过 `maximumItems`（1000）的窗口回到最新仍会裁到 1000（内存上限，见 `applyWindow` 的 latest 规则）；本次不放大上限。

## R9 键盘收起后页面悬在半空（2026-10-31 06:26 真机反馈，回归）

**现象 / 证据**
- 截图：键盘收起后，最新内容停在键盘上方约一个键盘高度处，下方整块空白，页面不跟随到底。
- 发生条件："有时候"——键盘交互式收起（拖拽/布局更新）与流式 apply 同时发生时。

**根因**
- 键盘/输入条 inset 收缩时，`TimelineAnchorDriver.applyInsets` 只在 `state.placement == .end` 时跟随新底；键盘交互式收起期间的滚动/布局事件会把 placement 改成 `.reading`（`readerLifted/coastingEnded` 的 atEnd 在动画中间计算），于是收缩不再跟随。
- f911dc97 的可见 cell 重绑在普通 50ms 同步里也会 `reconfigureItems`，并在 apply completion 里强制 layout；落在 inset 动画事务里会改 offset、让驱动采到 `.reading`，放大该问题。

**修法**
- `applyInsets`：底部 inset 收缩且视口在收缩前停在旧底（`bottomTarget(oldInsets)`，官方一像素容差）时，即使 placement 是 `.reading` 也改为 `.end` 并跟随新底；正在拖动/滑行时不抢。
- 可见 cell 重绑收窄：普通同步不再 reconfigure（恢复原契约）；结构性 apply 的强制重绑只在 placement != .end（阅读/历史态）执行，`.end` 跟随态跳过。

**验证**
- CI run 772（head `1e7678c9`）test + build 绿，包 `b772`。
- 真机复测：底部状态下点空白/拖拽收起键盘、发送后收起键盘，最新行应贴着输入条；历史翻页后的空白带在阅读态仍应被重绑修复。

**未覆盖**
- 旋转/分屏等其它 bottom inset 收缩走同一跟随规则（停在旧底时跟随，符合预期）；`.end` 状态下的结构性 cell 重绑被跳过，极端情况下底部的错配 cell 仍可能短暂存在，留待视频/探针复现后再设计不干扰 inset 动画的延迟重绑。

### R9 补充（2026-10-31 06:44 报告与 b773 验收）
- 06:44 报告显示：键盘弹起后列表 offset 停在 50376，而弹起后的底部是 50678（少 302pt），前几次弹起不跟、之后分 +49/+302 两步补上——"动画慢"实为跟随丢失。
- b772→b773 的 diff 无任何动画 duration/curve 改动（0.24s 输入框弹簧保持）；修复改为：`viewSafeAreaInsetsDidChange` 把**变化前**视口的 `measuredAtBottom` 交给驱动，驱动在该次 inset 变化（弹起或收起）中即使 placement 已被改成 `.reading` 也采纳 `.end` 跟随；替换了原先只处理收缩的旧底算术。
- pp 真机验收 b773：键盘升/降正常。

## R10 发送/回复期间页面小范围上下乱跳（2026-10-31 07:10 报告，b773）

**证据**
- 回复行 `g:msg_b9516a39…` 的高按块到达：44→29（t=4.28）→190→246→281→327→357（4.66/4.83/4.94/5.05/6.31）。
- 内容高度 6.32s 后稳定在 46015，底部目标 46015−852+94=45257，但 offset 仍在其上下摆动：45258/45254/45265/45256/45269/45242/45274/45218/45257（6.35–6.83s），振幅最大 ±56pt，并越过真实最大 offset（45274 > 45257）。
- 探针：slowFrames=15、frameRateMaxGapMs=46（掉帧窗口）；insetBottom 恒为 94，本次切片不含键盘/发送动作。

**根因**
- **A（主因）Mover 离散积分不稳定**：内容跟随弹簧 `Spring.content` = 0.2s / bounce 0（ω≈31.4）；`TimelineAnchorMover.step` 把 dt 夹到 1/30s 后单步半隐式欧拉积分。ω·h≈1.047 时状态矩阵特征值为 0.63 / −1.82（|λ|>1，符号交替）——连续域临界阻尼不会过冲，离散后反而逐帧放大振荡。60/120fps（ω·h≈0.52/0.26）稳定，所以只在流式布局掉帧时出现。explicit ease/fly（0.4s/0.36s）不在该失稳区，故显式滚动从未出现。
- **B（放大器）越界写入 + 回弹**：Mover 的过冲位置（45274）被 `writeOffset` 写入；其 clamp 故意保留一屏 slack（bottomLimit+containerHeight），于是 offset 落在真实最大之外，UIScrollView 回弹/夹紧，下一帧 tick 又因 live offset 与积分位置差 >1 而 `reseed`（velocity=0）重启弹簧，产生二次摆动。slack 是为陈旧锚点的空白兜底，不应作用于正常内容跟随写入。
- **C（内容本身分块）**：Code 页无逐字 reveal，行按收到的整段文本重排，高度一次 +56/+161/+35/+46/+30；跟随只能平滑 offset，文本本身仍分块出现。行高动画 `animateRowHeight`（0.18s）只服务 `policy == .interactive`，Code 行是 `measured`（cell-reported），不走它。
- **D（首测收缩）**：新回复行第一次几何报告 29pt（估计 44），产生一次 15pt 的可见收缩，与 C 同族；29 是真实首帧壳高，不是缓存错误。
- **E（发送瞬间未覆盖）**：报告从发送之后开始（用户消息已在列表、键盘已收起），发送时"故意收键盘 + 插入 pending 行 + 开始流式"与 b773 的新 inset 跟随可能叠加；不能凭本日志判断，需单独从发送点击开始的探针切片。

**修改方案**
1. **Mover 积分子步化（根治 A，先做）**：`step()` 内把一帧拆成若干子步，保证 `h ≤ min(1/120, 0.25/ω)`（内容弹簧约 125Hz 子步）；Pace、目标每帧重读、到达判定语义不变。纯模型改动。
   - 测试：内容弹簧从 30pt 误差、dt=1/30 起步，位置不得越过目标 >0.5pt 且必须到达；连续 20 帧 dt=1/30 单调不振荡；ease/fly 到达帧数不变；dt=1/120 行为不变。旧实现应红（写出会过冲/振荡）。
2. **跟随写入限真实范围（根治 B）**：正常 Mover/内容跟随写入 clamp 到 `bottomLimit`（不含 slack）；一屏 slack 只保留给直接放置/陈旧锚点的兜底。测试跟随态 step 提交的位置不超过 bottomLimit。
3. **（待复核）C/D 的平滑**：1+2 落地并重新探针后，若"上下"消失但"分块"仍在，再评估让 Code 的 cell-reported 行增长也走 0.18s 高度动画（或专用跟随），需处理 hosted 几何报告与布局的竞态。
4. **（不修）D 的 29pt 首测**：首帧真实壳高，不作为错误高度修。
5. **（取证）发送瞬间**：探针增加"发送点击起算"的切片（keyboard inset + offset + 行高），pp 复测一次；不猜。

**验证**
- 单测红先绿后（Mover）+ CI test/build；真机复测发送→流式回复：内容高度稳定后 offset 不得再上下摆动，跟随只向一个方向。
- 未覆盖：C 的逐字平滑与 E 的发送瞬间，待 1+2 后按新报告决定。

### R10 实施结果（2026-10-31 07:5x）
- 红测 run 774（head `66a6bb89`，test-only）：`theContentSpringDoesNotOvershootOnADroppedFrame` 失败——`overshoot → 5.1e51`、`backtracks → 100`、`arrived` 为假，证实旧单步积分在 dt=1/30 发散，而非估计误差。
- 修复（head `9a3db391`）：`TimelineAnchorMover.step` 按 `h ≤ min(1/120, 0.25/ω)` 子步积分（内容弹簧每帧约 4–5 步）；`TimelineAnchorDriver.writeOffset` 增加 `allowSlack`，Mover tick 写入 clamp 到真实 `bottomLimit`，一屏 slack 仅留给直接放置/陈旧锚点。0.2s/bounce 0 参数、Pace、到达判定均未改。
- 单测：30fps 与 60fps 两个新用例要求“不过目标 0.5pt、不回退、必须到达”；既有 ease/fly/Pace 用例全绿。
- CI run 775（head `9a3db391`）test + build 绿；包 `b775-9a3db39-probe`。
- 待真机复测：发送→回复流式期间内容高度稳定后 offset 不再上下摆；正常跟随仍为单向 0.2s 缓动。未覆盖：C（行内文本分块）与 E（发送瞬间）仍需新探针判断。

## R11 状态/步骤行在回复开头插入-移除（2026-10-31 08:05 报告，b775，"状态行有点抢"）

**证据**
- 弹簧修复已验证：08:05 报告里内容高度不变时 offset 不再来回摆；所有负向 offset 都对应内容增删或键盘（-302/-49 是键盘收起）。
- 回复开头 1.3 秒内三次 item 增删：
  - t=177.64 `items 167→168`，contentH +53（≈46pt 步骤/状态行 + 7 spacing）
  - t=178.91 `items 168→167`，contentH 43040→42957（-83）
  - t=178.95 `items 167→169`，contentH 42957→43078（+121）
- 可见行同时存在 `g:steps:msg_73212f19`（46pt）和 `g:msg_73212f19`（回复正文）；这些行的自身高度没有变化（heightChanges 里没有它们），所以是**插入/移除**，不是测量或弹簧。
- 场景：每条回复都是"先思考、后正文"；思考行先形成临时步骤组（状态行），正文到达后并回消息组，临时步骤组被删——步骤行出现/消失各推/拉正文一次。

**根因（待代码确认）**
- `CodeMessageBuilder.units` 对 reasoning 采用 pending 策略：思考行先独立成组，正文行到达后按 message key 合并；组的 id/组成变化导致 diffable 删除+插入，而不是同一 item 的 reconfigure。
- 临时步骤组的 46pt + spacing 每次增删都改变 contentHeight，底部跟随把整页推/拉一次。

**修改方案（先读 unit 规划后落最小改法）**
1. 让 live turn 的步骤组身份稳定：思考行从一开始就并入其 message key 的消息组（正文未到时该组以思考行/工作行渲染），正文到达只是加行，不创建/删除顶层 item。
2. 或保留临时步骤组直到回合结束（期间只更新内容），避免正文到达时删除它；需要确认回合结束后官方是否保留该行。
3. 红绿测试：一段 reasoning→text 的流式序列，`TimelineItemIdentity`/group 列表在正文到达前后 item 数量与 id 不变（只内容变化）。
4. 验证：真机发送→回复，状态行/步骤行不得再产生插入-移除；offset 只随正文高度单调增长。

**未覆盖**
- 思考行与正文的官方分组语义（是否允许临时独立步骤组）需按 `EVIDENCE/round29` 再核对，避免为了稳定身份改变官方展示。

## R12 发送后 pending→echo 分两次刷新，页面先沉后弹（2026-10-31 08:26 报告，b776）

**证据（b776 探针，08:26:54 报告）**
- t=23.70 `A added=[p:4F746187-1D0B-4AEB-8073-A083EB5D4AEF]`：发送后乐观气泡入列。
- t=24.95 `A removed=[p:4F746187…]`；t=24.97 `A added=[g:f38a3d63-1ef5-4aeb-8c72-f43020ca419f, working:status]`——入列和出列相隔 20ms、两次独立 apply。
- t=24.99 `I [offsetJump] delta=-70.7 24224.0→24153.3`，随后 +31.3/+29.3/+19.7/+8.7/+7.3/+5.3/+3.0/+2.3 弹回 24260.3。
- pp 现场更正：**气泡没有可见消失**，看到的是页面先沉后弹。中间态只存在于布局高度表约 20ms（约一帧），快照替换落在同一帧内，视觉上气泡连续。

**根因（代码位置）**
- `V2SessionModel.confirmEcho`（`/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Models/Session/V2SessionModel.swift:694`）在 echo 进入投影后立刻把 pending 从 `session.pendingMessages` 删除；`delivery` 先置 `.confirmed`。
- `SessionTimelinePresentation.synchronizePending`（`/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Models/Chat/SessionTimelinePresentation.swift:249`）只在 flush 循环里用 `session.pendingMessages` 刷新 pending 列表；循环的 60Hz idle tick 可能落在“模型已删 pending、presentation 还没收到 echo observation”之间，于是先发布了空 pending 列表——布局高度表少掉用户行（约 70.7pt），echo 20ms 后到达再补回，底部跟随先沉后弹。
- 原 `synchronizePending` 只按“入参是否包含”过滤，已删除的 pending 无法保留；这正是 08:26 的中间态。

**修改（方案 1，原子替换）**
- `synchronizePending` 保留已 `.confirmed` 但 `rows` 里还没有对应 `clientMessageId` 行（role=user）的 pending；等 flush 把 echo 行发布进 `rows` 后，在同一次同步里移除 pending。pending 的 `.confirmed` 状态让 `PendingMessageRow` 的 `isPending` 为 false，转圈立即停止，气泡保持原样直到被 echo 行替换。
- 非确认移除（用户 dismiss、队列 supersede）不保留，避免把用户主动删掉的气泡钉在列表里。
- 发送队列行在 tail 视图内（`TimelineCollectionTailRow`），不走 item 替换，不存在同一空洞，未改。

**测试**
- `/home/ubuntu/aa-wt-attachments/ios/Tests/ClientCoreTests/NativeChatTests.swift`：
  - `aConfirmedPendingStaysUntilItsEchoRowIsPresented`：confirmed 后先 `synchronizePending([])` 必须仍保留（旧实现第一处断言即红），echo 入 rows 后同一次同步移除。
  - `aDismissedPendingThatNeverEchoedLeavesImmediately`：未确认的移除必须立即消失。
  - 既有 `echoAndOptimisticMembershipChangeInOneTick` 保持通过。

**状态**
- 代码与测试已落工作区；按 pp 要求与其他 bug 合并后再统一提交、跑 CI，本项尚未有 CI 结果。
- 待真机验证：发送后转圈结束到状态行出现的过渡不再先沉后弹；正常情况页面只随状态行/正文高度平滑上移。

## R13 新回复在历史窗口里不出现，切会话回来才有（2026-10-31 08:31 报告，b776）

**证据（b776，08:31:58 报告）**
- 读者在历史窗口顶部，新回复到达（pp 收到震动）；窗口带 anchor，live 事件按 `mergeSingle` 的 `orderSeq > end` 规则被挡在窗口外，`hasNewerItems=true`。
- 点回到底部后 `auto-latest fire off=74077` → `bridge loadLatest auto=1`；本地旧页先替换窗口（408→189）。
- 替换落地时 `bridge viewport bottom=1->0 off=74077 contentH=74548 visH=294` —— 这是替换自身造成的内容/偏移过渡翻转。
- `TimelineChatTimelineView.viewportChanged` 在该翻转上无条件调用 `cancelLatestReconcile()`，把刚启动的后台网络 reconcile 取消；之后去顶部又触发 auto-older 加载历史页。
- 整个 pre-switch 窗口里没有 `msg_573d505f` 这条回复；切换会话重开后（t=1.67）网络最新页才把它带回。与 pp 现场描述一致。

**根因**
- 用“视口离开底部”这个被动边沿代表“读者主动进入历史”。窗口替换/布局过渡也会翻这个边沿，但读者并没有离开阅读位置；reconcile 被误杀后，陈旧本地页缺的最新行（就是新回复）永远补不回来。

**修改**
- `V2SessionProjection.applyLatest`（`/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Repositories/V2SessionProjection.swift`）新增显式 `keepingAnchor`，只由后台 reconcile 传入：重叠合并时保留读者的 history anchor，最新页只补窗口缺的行；`newer` 回填也按 history 合并，避免 anchor guard 把窗口自己的行挡掉。**用户主动回最新仍走默认路径**（清 anchor + idle ceiling 截断），不改变 `boundedHistoryWindowAndReturningToLatest` 与 `LocalPageCacheTests` 已定义的契约（run 777 首版改动太宽，被这 4 个用例拦下后改为显式参数）。
- `V2SessionRepository.startLatestReconcile` 调用 `applyLatest(page, keepingAnchor: true)`。
- `TimelineChatTimelineView.viewportChanged`（`/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatTimelineView.swift`）：只有真正的读者滚动（`isReaderScrolling`，drag/decelerating）才取消 reconcile；被动翻转与状态栏回顶（`.animating`）不再取消。
- `TimelineCollectionController` 新增只读 `isReaderScrolling`（仅 `phase.userIsScrolling`）。
- 历史分页不再取消 reconcile（锚定合并已安全）；保留的取消只保护“读者在很小的本地最新页里主动滚动、网络页会在上方补行”的边缘场景。

**测试**
- `/home/ubuntu/aa-wt-attachments/ios/Tests/ClientCoreTests/SessionProjectionTests.swift` 新增 `aLatestReconcileKeepsTheAnchoredHistoryWindow`：`maximumItems=20`、锚定窗口 1...40，`keepingAnchor: true` 的最新页 31...41 到来后窗口必须是 1...41（旧实现清 anchor 后退化成最新 20 行，第一处断言即红）。
- 默认路径（用户主动回最新）的 idle ceiling 行为由既有 3 个 LocalPageCache 用例 + `boundedHistoryWindowAndReturningToLatest` 继续守护。
- Views 层分支无 ClientCore 单测，由 build job 编译 + 真机探针验证。
- 待真机：在历史顶部收到新回复 → 回到底部 → 回复应由 reconcile 补上；即使随后去顶部触发 auto-older，reconcile 也应继续落地且不裁掉历史页。

## R14 窗口替换缩小时 offset 越界 → 空白页（2026-10-31 08:31 报告，b776）

**证据**
- `H apply-begin oldN=408 newN=189 off=74077 contentH=74548` → 替换过程中 `bridge viewport bottom=0->1 off=74077 contentH=46157 visH=294`：新内容高度已经是 46157，offset 仍是旧的 74077，视口在新内容之外，可见行 0。
- apply 完成后才落到 45750（`apply-end off=74077->45750 d=-28327`）。之间就是空白页。

**根因**
- diffable 替换把 contentSize 换成新高度，但 offset 要等 apply 完成/下一次布局才被 clamp；缩小替换时这段窗口所有可见行都不在内容范围内。R7 修的是 cell/attribute 错配，不覆盖 offset 越界。

**修改**
- `/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineCollectionController.swift`：
  - 新增 `projectedContentHeight(items:)`：用 layout 同一套 `heights.resolvedHeight`/spacing 预算替换后的高度。
  - `apply` 在 `dataSource.apply` 之前，若 `resolveWindowBottom`（窗口替换 + 已武装的底部返回 + 非历史 prepend），用 `TimelineOffsetTarget.bottomOffset` 预先把越界的 offset 放到新范围内。完成回调仍按实际布局解析精确底部。
- 只在缩小替换且需要回底时生效；普通 apply、阅读态替换不动 offset。

**测试**
- 同样在 Views 层，无 ClientCore 红绿单测；build job + 真机探针验证。
- 待真机：历史窗口 → 回到底部/加载最新发生窗口替换时不再出现空白帧；页面直接落在最新页底部。

**顺带观察（未修，单独线索）**
- 切会话回来时有一次冷开：adapter 先只有 tail（`oldN=0 newN=1`）、随后 189 行 apply 时 `contentH=0.0 visible=0`，同步测量 105ms 后才显示（t=0.09→0.25）。这是“空 adapter 冷开”路径，与本次 R14 的缩小替换不是同一根因；本次报告未直接把它归为 pp 指的空白，先记录，等复现证据再定修法。

## R15 加载历史页后视口停在新页顶部，原内容被顶走（2026-10-31 13:46 报告，b778）

**证据（b778，13:46:44 报告）**
- 页 2（37→57 行）：请求 t=5.17 发出（reader 在 off=139），页面 t=6.68 到达并 prepend 约 47k；`apply-begin ... applying=1 anchor=g:steps:msg_35118234 anchorY=327` → `apply-end off=-97->-97 d=0.0 anchorY=327->49859`，**没有 `driver enforce` 行**；锚点行被顶到视口下方 49,859pt，offset 一点没补。此后 settle 因 drift>2000 主动跳过（设计上交给 apply-time 修正），最终 view offset=-97（顶部）。
- 页 3（57→73 行）：请求 t=10.14 发出，页面 t=17.11 才到（7.0s）。adapter 的 `pendingHistoryRequest` 5 秒超时先执行 `cancelHistoryRequest()` → `endHistoryPaging()`；到达时 `hist=0`、`anchor=-`，按普通 prepend 处理，同样无修正。

**根因**
1. 请求期间 reader 滚动/布局回调会改写 driver 的 reading placement；页面 apply 时 `enforceReadingPlacement` 已不是请求锚点，target 与当前 offset 相近（≤0.5）时静默 no-op。请求锚点只保证等待期间的位置，没有保证“页面到达时按读者当前看到的内容补插入高度”。
2. adapter 的 pending 标记 5s 超时短于 controller 的 15s history-paging 上限；慢页面（本机 7s）在到达前丢掉 history 模式，apply 失去锚点修正。

**修改**
- `TimelineAnchorDriver.scrolledWithoutAHand`：`isHistoryPaging` 期间不重新绑定 placement（mover 运行中仍 reseed），防止等待期被动滚动改写页面锚点。
- `TimelineCollectionController.apply`：`applyingHistoryPage` 时用 `anchor(at: 当前 offset)` 把 reading anchor 重新钉到**读者当前看到的内容**（跳过 prompt/tail），再交给 apply 后的 reanchor/enforce；读者请求后滚到别处也不会被拉回请求时刻，页面插入只改变上方内容。
- `TimelineChatContentAdapter`：当 controller 仍处于 historyPaging 时，pending 标记超时放宽到 20s（比 controller 的 15s 上限长，放弃权归 controller）；无 paging controller 的 legacy 路径维持 5s。

**测试**
- 三处都在 Views/controller 层，无 ClientCore 红绿单测；`TimelineHistoryAnchorRows.isAnchorable` 已有单测保证 prompt/tail 不作锚点。
- 待真机：滚动到历史顶部触发加载，页面到达后视口应保持原内容不动（新消息在上方，由读者自己上滑）；慢页面（>5s）也应保持锚定。若仍复现，下一步在 enforce 无条件打印 placement/target/motion 再定位。

## R16 历史窗口里发送时整页延后替换（pp 2026-10-31 14:00 报告，b778；产品决策=方案 1）

**证据**
- b778 13:49:35 报告：用户在 450 条窗口底部（offset 79917）发送带附件消息；`t=136.61` pending 入列，附件预览在 `t=140.31` 把气泡抬高 150pt；`t=140.41` 整窗变成 152 条（contentH 80889→32372），offset 80067→31614。跳变发生在发送/上传过程中。
- 窗口不是真正最新（最新页未落地）；文字测试那几条都在 152 条最新页落地之后发送，所以不跳。pp 澄清“我当时是在底部的吧”——是已加载页的底，不是会话最新。

**产品决策**
- pp 选择方案 1：**发送时若当前窗口不是真正最新，就先切到最新页**，再做转圈/上传；不要在几秒后由最新页落地被动替换。

**修改**
- `TimelineChatTimelineView` 监听 `model.session.pendingMessages` 的新增项（delivery 为 `.sending`/`.accepted`，排除队列降级产生的 `.uncertain`），调用 bridge 的 `noteComposerSend()`。
- `TimelineChatBridge.noteComposerSend()`：`hasNewerItems` 时走与回底按钮相同的 `loadLatest()`（武装窗口替换返回 + 本地优先最新页）；已在最新窗口时不动。
- 队列自动 drain 不产生 `pendingMessages` 项，不会因此拉读者回最新。

**测试**
- Views 层，无 ClientCore 单测；build job + 真机验证。
- 待真机：历史窗口里发文字/附件，跳变应在“按发送”那一刻完成；随后 pending、状态行、回复都在最新页内平滑出现。

## R17 回合中途工具调用把上一段回复的页脚撤掉 → 页面下跳 30pt（2026-10-31 14:25 报告，b781）

**证据（b781，14:25:04 报告；pp 现场：最新页时后台脚本工具调用，“往下跳一点”）**
- `t=148.75` 上一条回复 `g:msg_fbe3af45` 测到 164（含回合页脚）。
- `t=167.45` 新一段（工具调用后的回复）开始时，该行 key 重新移动；`t=167.46` 高度 **164→134（-30）**，`src=rowMeasured`，同一 revision 回退。
- 同一拍 `contentH 28412→28382`、`offset 27654→27624`，都是 -30：底部跟住了，但 30pt 是瞬间落的。
- `t=167.73` 新回合步骤组 `g:steps:msg_eeb05ec2` 才插入，`t=168.49` 正文才到。

**根因**
- `TimelineTurnActions.build` 在 `suppressLatest` 下整回合不 commit。工具调用继续的是**同一个回合**（中间没有用户消息），回合重新打开后，前面已完成段的页脚被收回；页脚约 30pt，行高瞬间减少，底部跟随同拍写 offset → 视觉下跳。
- 既有单测只覆盖“上一个已结束回合保留页脚”（用户消息分隔）；同一回合内 text→tool→text 的连续段未覆盖。

**修改**
- `/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Models/Chat/TimelineTurnActions.swift`：
  - 记录最后一个“已完成的 footer host”（settled host + 当时的 replies/changes）。
  - 回合仍在运行、但已越过该 host 继续产生内容时，把页脚留在 settled host；当前流式段依旧不挂页脚。
  - 回合结束（`suppressLatest=false`）仍按原规则 commit 到最终 host；若最新段自己就是最后内容（没有后续），保持“运行中不显示页脚”的既有契约。

**测试**
- `/home/ubuntu/aa-wt-attachments/ios/Tests/ClientCoreTests/TimelineTurnActionsTests.swift` 新增 `aToolSegmentKeepsTheFinishedReplysFooter`：`[user, reply(done), tool(running)]` + `suppressLatest=true` + step 组不可托管 → 必须在 reply 上保留 action（旧实现返回空，第一处断言即红）；工具完成后（done + suppressLatest=false）仍在 reply。
- 既有 6 个用例（含 `activeLatestTurnHasNoFooterButPreviousCompletedTurnRetainsOne`）保持通过。

**状态**
- 代码与测试已提交；CI 待跑。待真机：最新页时后台工具调用/工具结果到达，上一条回复不再掉 30pt，页面只有正常的底部生长。

## R18 服务端 timeline.snapshot 整窗替换本地历史 → 发送后跳页（2026-10-31 14:43 报告，b782）

**证据（b782，14:43:31 报告；pp 现场：发送后跳页）**
- `t=106.57` pending `p:EBCB144F…` 入列（496→497），窗口 498 条，offset 88779（底部）。
- `t=108.14` apply `oldN=498 newN=199`，contentH 89654→40903；`t=108.23` apply-end offset `88831→40145`（**-48,686**）。
- 整个 H 段没有 `bridge loadLatest` 行——不是 R16 的发送切最新，而是 `V2SessionProjection.apply` 的 `timeline.snapshot` 分支直接 `replaceTimeline(items)`，把本地已加载的 498 条历史窗口换成服务端最新页 199 条。

**根因（首版修错一次，CI 783 拦下）**
- 服务端契约：`timeline.snapshot` = **完整时间线**（`replace_timeline_snapshot`，缺的行就是删除；空快照必须清空视图；>100 行走 refetch），不是“最新一页”。首版把它当最新页做 overlap merge，破坏了 reset 契约（`aSnapshotFrameDropsOnlyTheMalformedRow` 红）。
- 真正丢历史的是替换实现：`replaceTimeline` 清掉 `windowAnchor` 并按 idle `maximumItems`（1000 行）取最新尾巴；快照本身携带全部 3962 行，读者浏览中的旧行却被裁掉 → 498 items→199、视口大跳。

**修改**
- `/home/ubuntu/aa-wt-attachments/ios/Agents Anywhere/Agents Anywhere/Repositories/V2SessionProjection.swift`：
  - `timeline.snapshot` 改走 `applySnapshot`：内容只取快照行（`data.items=[]` 后 `merge(history: true)`，删除语义保留）；**保留替换前的 `windowAnchor`**，让截断按浏览预算（10k）围绕读者进行，而不是 idle 最新 1000 行；空快照清空并清 anchor。
  - 裁剪后的 `droppedOlder/droppedNewer` 回写 `hasOlderItems/hasNewerItems`。

**测试**
- `/home/ubuntu/aa-wt-attachments/ios/Tests/ClientCoreTests/SessionProjectionTests.swift` 新增 `aSnapshotReplacementKeepsTheAnchoredBrowseWindow`：锚定窗口 1...40，完整快照 1...41 到达后必须是 1...41（旧实现清 anchor 后裁成最新 20 行 22...41，第一处断言即红）。
- 既有 `aSnapshotFrameDropsOnlyTheMalformedRow`（缺行删除、坏行丢）与 `resetReplacesTimelineAndUnknownEventsRemainAccessible`（空快照清空）保持通过。

**状态**
- 首版 `ab8ad0b1` CI 783 test 红（reset 契约），已改为 anchor 保留 + 完整替换；新提交 CI 待跑。待真机：历史窗口里发送（含附件），服务端 snapshot 到达后不再整窗缩小/跳页，已加载历史仍在。

**追加（2026-10-31 14:55 报告，b782）**：页脚在 `146↔176` 之间反复切换。根因是 `suppressLatest` 随 runtime 状态在 running/idle 间抖动：抖到 false 时走 `commit()`，但工具活跃（`hasActiveItems`）使 commit 拒绝 → 页脚消失；抖到 true 时 settled 分支又挂回。修：`commit()` 因活跃项拒绝时回退 settled host 页脚。新用例 `aRunningToolKeepsTheFooterWhenTheTurnLooksIdle`（旧实现返回空，红）。
