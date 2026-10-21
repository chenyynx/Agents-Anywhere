# C5 / M4.2 任务单：官方 Chat 页流式效果（2026-10-21）

> 分支：`feat/textkit2-assistant-body`（**不碰 dev、不合并、不基于 dev 出包**；测试包只从本分支出）
> 级别：**L**（流式渲染核心、逐帧行高、滚动跟随、震动、视觉/行为 gate）
> 参数真源：`/home/ubuntu/aa-test/part-ag-official-parameter-inventory.md`（四路逆向汇总；草稿：`part-ag-*-params-draft.md`）
> 约束：视觉/行为按官方 **Chat 页**；保留 AA「一条消息一个 cell」与 A 形态工具调用；不改 `ChatMetrics`/`ChatPalette` 的既有视觉值（除本单明确列出的官方参数）。
> 前置：M4.0 基线、增量文档构建器、稳定块复用、完成帧路径已验证（见 `docs/perf-6b-c5-m4-handoff.md`）。

## 0. 一句话

把流式正文从「稳定块 TextKit + 尾部 SwiftUI host」改成**官方 Chat 页的单引擎揭示**：TextKit 文本 + 逐行 mask、三段时间线、逐帧 `clampedHeight`、底部 Spring 跟随、块入场与开始/结束震动；保留 AA 的行粒度和工具 A 形态。

## 1. 范围

**做**：
1. 揭示数据层：三段时间线（320/640/2.0s + 最后 640 字 320/s 线性）、字符游标、`floor(pos+1e-9)`。
2. 揭示视觉：24–64 字符 run、0.35s patience、逐行 CGRect mask、opacity 0→1 / 0.6s ease-out、旧层保留、收口摘 mask。
3. 行高：`clampedHeight = maxY(当前揭示行)`；揭示期 `min(fit, clamped)+1.0`；收口恢复完整高度。
4. 底部跟随子集：`.end` 贴底、拖动切 `.reading`、1 物理像素阈值、2 屏 catch-up、Mover `ease Spring(0.4,0)` / `fly Spring(0.36,0.15)`、帧率 `[maxFPS/2, maxFPS]`、离屏/Reduce Motion/VoiceOver 瞬移。
5. 块入场：`opacity=min(4×progress,1)`、0.25s、`fadeRise` 5pt、easeOut。
6. 震动：开始流式 `.selection`；结束流式 `writing→idle` `.impact(.light,1.0)`；每相位一次；无逐字/逐批震动。
7. Gate：纯时间线单测 + 逐帧 mask/高度断言 + 滚动跟随/打断/恢复断言 + 帧截图 + 震动触发测试。

**不做**（明确留后）：
- 工具调用平铺/官方 B 形态；per-block cell 结构；完整官方 `TranscriptListCore` 状态机（历史锚点、发送贴顶、状态栏回顶等）；选择/链接/复制（M4.4）；附件/特殊块（M4.3）；DT/RTL/无障碍（M4.5）；合并 dev/出包。

## 2. 关键接入点

### 2.1 原始文本源（最关键）

官方揭示吃的是**完整接收文本**，不是 AA 现有 `ChatTimelineRowModel.text`（会藏尾字、按 0.24s 批次显示）。M4.2 必须：

- 对走 TextKit 揭示的行，用 `row.value.displayText`（原始接收文本）构建文档和揭示时间线；
- **绕过 AA 现有的 0.24s reveal 批处理/藏尾字**：新增一个「renderer-owned reveal」模式，让 `SessionTimelinePresentation.flush` 对该行不 withhold 最后 glyph、不等待 `batchInterval`；原始文本到达即交给揭示层，由 RevealTimeline 自己控制显示位置；
- 旧 SwiftUI/Textual 路径保持原样（不改 `ChatMarkdownView` 的行为）。

### 2.2 一条消息一个 cell 内的块级揭示

- 保留 `AssistantMarkdownCell`（一条消息一个 cell）；文档仍由 `AssistantStreamingDocumentBuilder` 增量构建。
- 揭示是**全局字符游标**（`total = Σ 块字符数`），但 mask 按块应用：
  - 已稳定的块：无 mask，全文可见；
  - 当前开放的文本块：逐行 mask + fade；
  - 新出现的代码/表格块：走块入场（0.25s opacity/fadeRise），不做字符级 mask（官方 Chat 的 code/table 走 block entrance）。
- 移除现有 tail `UIHostingController<ChatMarkdownView>`；尾部改为 TextKit 块视图 + mask。

### 2.3 逐帧行高与底部跟随

- 揭示驱动每帧计算 `clampedHeight`，cell 通过回调把当前高度上报 controller；
- controller 只在流式行、且 `placement == .end`（AA 现有 bottom-pin 状态）时更新行高并调整 `contentOffset`；
- 拖动/减速立即解除跟随；接近底部（1 物理像素阈值）重新武装；离屏/Reduce Motion/VoiceOver 直接 place；
- 不重写 AA 的历史/发送/键盘逻辑；只加「流式逐帧跟随」这一层。

## 3. 参数（冻结值，来自 inventory）

### 3.1 揭示时间线

```
cps=320, maxCps=640, drain=2.0
remaining = total - head; elapsed = now - event.time
if remaining<=0 or elapsed<=0: position=min(head,total)
elif remaining<=640:
    advance=min(elapsed*320,remaining); position=total-(remaining-advance)
else:
    tail=min(1280,remaining); bulk=remaining-tail; tBulk=bulk/640
    if elapsed<=tBulk:
        advance=min(elapsed*640,remaining); position=total-(remaining-advance)
    else:
        Δ=elapsed-tBulk; K=2.0*ln(tail/640)
        tailRemaining = Δ<K ? tail*exp(-Δ/2.0)
                            : 320*(2.0*(1+ln(tail/640))-Δ)
        position=total-clamp(tailRemaining,0,remaining)
shownThrough=floor(position+1e-9)
```

- 新文本到达时重锚定：`time=now`、`total=Σ块字符数`、`head=max(旧total, 当前shownThrough)`。
- `settleSeconds=0.6` 不参与公式（官方也未使用）；不要自行加。

### 3.2 视觉

- `runLength` 24–64 字符（每 run 重抽）；`runPatience` 0.35s。
- 淡入：`opacity 0→1`、`0.6s`、`ease-out`、`fillMode backwards`、key `"reveal"`；旧 run 不重放。
- mask：`CALayer.mask` + 每次新 run 新建 `CAShapeLayer`，path = 新露出区间与排版行求交的逐行 CGRect，黑色不透明；重排清层（`setSublayers:nil`）；收口 `mask=nil`。
- `seatedAt` 漂移容差 0.5pt；漂移时按 `[0,released)` 重建 mask。
- 行高：`rowHeight = min(fit, clampedHeight)+1.0`；收口 `clampedHeight=nil`。
- 块入场：opacity=`min(4×progress,1)`、`5pt` fadeRise、`0.25×(1−opacity)` easeOut；Reduce Motion 关闭位移。
- VoiceOver/Reduce Motion：VoiceOver 走直接全量；Reduce Motion 不跑 mask 揭示。

### 3.3 滚动跟随

- no-op 阈值 **1 物理像素** = `1/displayScale`。
- catch-up 距离 **2 × visibleHeight**；飞行 >2 屏时先预置一屏再 fly。
- `ease = Spring(duration 0.4, bounce 0)`；`fly = Spring(duration 0.36, bounce 0.15)`；`ω=2π/duration`、`ζ=1−bounce`。
- 帧率 `[maxFPS/2, maxFPS]`，maxFPS=屏幕 `maximumFramesPerSecond`。
- `.end` 目标 = `max(starts[n]+anchorPad+bottomInset−height, −topInset)`；anchorPad=visibleHeight（有 anchor 时）。
- 事务外落地：`contentOffsetAdjustment = 目标 − 当前`、`contentSizeAdjustment = 新高 − 旧高`。

### 3.4 震动

- 开始流式：通用相位变化 `.selection`（`thinking/idle → writing`）。
- 结束流式：`writing(2) → idle(0)` → `.impact(weight:.light, intensity:1.0)`，每相位一次。
- 无逐字/逐批震动；错误/中断若也走 `writing→idle`，同一 impact。

## 4. Gate

1. **纯时间线单测**（确定性时钟）：
   - 三段边界：`remaining=640`、`Δ=K` 两侧连续；最后 640 字 2.0s 线性到 0；
   - `shownThrough` 的 `floor(+1e-9)`、Int 裁剪；重锚定语义；
   - 随机 run 24–64 的边界与错误种子。
2. **视觉/几何**：
   - 每个 run 的 mask rect 数 = 新露出字符覆盖的行数；
   - 旧 mask 层保留、收口 `mask=nil`；
   - 每帧 `rowHeight = min(fit,clamped)+1`；收口恢复完整高度、误差 ≤1pt；
   - 帧截图（中途 2 帧 + 完成）与静态/参考对比。
3. **滚动**：
   - `.end` 下逐帧跟随；拖动立即解除；回到底部 1 物理像素内重新武装；
   - ease/fly 参数、2 屏 catch-up、离屏/Reduce Motion/VoiceOver 瞬移；
   - 无重叠、无锚点跳动。
4. **震动**：
   - 开始流式 1 次 `.selection`；结束 1 次 `.impact(light,1.0)`；流式过程中 0 次。
5. **CI**：feature 分支 dispatch `timeline_autorun=true`；M4.2 结果单独判读；已知 C3 flake 只记录。

## 5. 风险

- **原始文本源改造**：绕过 AA 的 0.24s reveal 批处理，可能影响旧 SwiftUI 路径；必须用显式模式隔离，旧路径逐字节不变。
- **逐帧行高**：AA 的 layout 原本按 apply 批处理；逐帧更新需要新的回调路径，注意重叠、锚点、键盘、滚动中更新。
- **TextKit mask**：plain `UITextView` 的 `layer.mask` 与 TextKit 2 排版行 rect 必须一致；`seatedAt` 漂移要按官方 0.5pt 重建。
- **块边界**：一条消息多块，揭示是全局字符游标；块内 mask、块间 spacing、stable/tail 边界要统一。
- **官方参数与 AA 视觉常数冲突**：blockSpacing 16 / interMessageSpacing 10 等会改变现有视觉；按用户“官方 Chat 一样”执行，但需在 gate 里明确记录这些差异。
- **真机未验**：模拟器 gate 只能证明几何/时序；滚动/手势/字体需真机（后续）。

## 6. 交付顺序

1. 纯 `RevealTimeline` 模型 + 单测（三段曲线/边界/重锚定）。
2. 原始文本源 + renderer-owned reveal 模式（旧路径不变）。
3. TextKit 逐块 mask 渲染 + 块入场。
4. 逐帧行高 + 底部跟随子集。
5. 开始/结束震动。
6. Gate + CI + 交接。

## 7. 进展（2026-10-21）

- **阶段 1**：`0e09c0dd` 时间线模型 + 单测，CI 绿（run `39541811227` 的 `test` job）。
- **阶段 2**：`10a807f0` renderer-owned 原始文本源 + 单测，CI 绿。
- **阶段 3 前置验证**：mask spike（`a46e7b2a`，编译修复 `5a01f1a2`）CI 绿（run `39542856355` 的 `textkit-mask-spike.json`）：TextKit 2 layout manager 存在；`layoutHeight 336.725` vs `measuredHeight 337`（Δ0.275）；160 字覆盖 3 条行 rect，`lastMaxY 61.401` ≤ layout；mask 安装成功；动画 `0.6 / backwards / easeOut`。设备 iPhone Air / iOS 26.5 / scale 3。
- **阶段 3 集成**：`9ce81bad` 移除 tail host，尾部改 TextKit 块视图 + `StreamingRevealDriver`（逐行 mask、24–64 run、0.35 patience、0.6 fade、clamped 行底、cell 版块入场）；`isRevealPending` 让 done 行留到游标追平 + 0.6s 淡出；逐帧高度走 layout 的 display override（不写测量缓存）。CI run `39544101166` 验证中。
- **阶段 4**：`TimelineSpringFollow`（纯模型 + 单测）：1 物理像素 no-op / 2 屏 catch-up / 1 屏预置 / `ease(0.4,0)` `fly(0.36,0.15)` 解析解 / 到达双阈值 / `.end` 重武装；controller 用独立 display link 逐帧跟随（`[maxFPS/2, maxFPS]`，`dt ≤ 2/maxFPS`），拖动立即停，Reduce Motion/VoiceOver 直接 place。逐帧高度仍走 layout display override（不污染测量缓存）。
- **阶段 5**：`ChatTurnPhase`（官方 tag 0/1/2/3）+ `TurnPhaseHaptics`：`writing→idle` 唯一 `.impact(.light,1.0)`，其余相位变化 `.selection`，流式过程 0 次；`TimelineChatTimelineView` 用 `.sensoryFeedback` 接线。
- **阶段 6**：M4 gate 增加 M4.2 断言：至少一次 mask run（`revealedCharacters > 0` + mask 安装）、至少一次 clamped 行高、跟随 offset 单调、delegate 级拖动解除底部、完成帧贴底且无 clamp 残留；workflow 对 `follow` 字段逐项判红。**已验证**（run `39545641056`）：`textkit-m4.json` `failures: []`；`sawReveal/sawClamp/dragDisarmed/offsetAtBottom` 全 true；`finalOffset 194 == endTarget 194`；完成帧 `sameCellAsDoneRevealing: true`、`overlaps: 0`、`stored 616 == measured 616`。该 run 唯一红是 C3 gate 的已知 flake（`longGroup cell 200 vs content 1471`，异步 Markdown 未及时 settle），与本改动路径无关。
- **截图**：gate 上传 `m42-mid1.png` / `m42-mid2.png` / `m42-final.png`（run `39546806791`）。首轮两张 mid 帧在 220ms 采样点拍摄，揭示已追平；已把截图时点前移到批次后 80ms（run `39548449460` 的 `m42-mid2.png` 已可见按字符截断的半揭示帧）。
- **独立审查修复（2026-10-21）**：
  - P1：揭示收口不交接静态 body（footer 缺失）。改为 `StreamingRevealOwnership`（ClientCore，含单测）作为“揭示仍拥有该行”的唯一真相：adapter 的签名把它计入 `revealingRowIDs`；driver 在最后一次淡出结束后经 `streamingRevealDidFinish` 清除并强制一次 apply；控制器在静态测量分支丢弃逐帧 override，使 footer 高度在同一 apply 生效。
  - P2：去掉不可达的 0.7s 宽限（由 ownership 取代）；gate 增加 `follow.starts > 0`、`debugMaskLayerInstalled`（读真实 layer.mask）、done 帧 `revealedCharacters > 0` 断言；`fly` 曲线在预置前按原始距离选择；显式底部动画/键盘期间不启动 follower；外部 offset 写入时重锚弹簧相位；揭示块按字符游标选择（不再只看最后一个块，文本后跟列表/代码时仍遮罩）；run 区间按块长裁剪。
  - 残余：adapter 的交接/ownership 接线仍靠 gate 与代码审查（SwiftPM 测试目标不含 Views）；`thinking` caption 谓词仍 UNKNOWN；手势仅 delegate 级。
- **第二轮窄核验修复（2026-10-21）**：
  - P1 残余（回复以非文字块结尾不交接）：非文字游标按块底 clamp；纯时间线轮询在追平后上报 caught-up（不依赖新的 SwiftUI 更新）；轮询任务随 cell 复用/移除取消。
  - 新 P2（后续块被裁/硬弹）：游标后的块 `isHidden` 到游标到达；非文字块入场改在首次可见时播放；游标跨块时在 display-link 回调里重配 mask。
  - 真实 artifact 抓到的行高塌陷：未布局视图 `bounds.maxY=0` 被报成 1pt → 加 8pt 下限（cell + controller 双层）；gate 增加 `stored >= 8` 断言。
  - gate 判定口径：`stored`（clamp+1）与 content 的舍入差放宽到 2pt；跟随断言改为 `eligibleFrames > 0`（内容短于一屏时 `starts` 合法为 0，instant repin 已满足目标）；done 诊断在完成重配前快照。
- **已验证** run `39559608529`（`2b2499ca`，gateVersion 5）：**test + timeline-autorun 全绿（含 C3 gate）**；`textkit-m4.json failures: []`；done 帧 `streamingConfiguration: true`、`revealedCharacters: 494`、`stableViews: 7`、`tailViews: 1`、sameCell、stored 616 == measured 616；`frameCalls: 10`、`eligibleFrames: 9`、`dragDisarmed: true`、`offsetAtBottom: true`（194=194）。artifact 同时暴露 batch 4 的 1pt 塌陷。
- **已验证** run `39561154042`（`996cd564`，gateVersion 6）：**M4 gate 绿**（`failures: []`，batch 4 `stored 251` 不再塌陷，新增 `stored >= 8` 断言通过）；唯一红是 C3 gate 已知 flake（`longGroup cell 200 vs content 1471`，hosting 异步 Markdown 未及时 settle，与本改动路径无关）。
- **第三轮窄核验（2026-10-21）**：发现 P1——artifact `starts: 0`，弹簧 follower 从未启动：`repinIfArmed` 每次内容高度变化即时钉底，而 follower 读到的 `layout.contentHeight` 目标恰好等于已钉位置，形成自锁；`eligibleFrames` 断言掩盖了它。修复：
  - `repinIfArmed` 在揭示期（`streamingRevealActive`）先尝试启动弹簧（此时 prepare 已更新 `contentHeight`、offset 尚未钉），失败才回退即时 pin；gate 恢复 `follow.starts > 0`。
  - 非文字游标在流式中途停顿：轮询 ticker 不再要求 `isTextComplete`，持续推进游标/解隐藏块；追平且未完成时停表，下一批重启。
  - 跨块同一帧：游标落在块首时 clamp 归 0；rebuild 后不转发 nil（由非文字异步上报接管）。
  - Q：`rowHeight = min(fit, clamped)+1` 在 cell 内实现；`onFrame` 回调后检测 driver 已 reset 则不再写状态；`updateBlockPresentation` 加 `blockIDs` 越界保护。
  - 待验证：run（本轮提交）的 `follow.starts`、offsets 与 gate 全绿。
- **已验证** run `39565998390`（`f656f096`，gateVersion 6）：**M4 gate 绿（`failures: []`）**；`follow.starts: 1`、`frameCalls: 13`、`eligibleFrames: 12`，offsets `[-68, -68, -68, -68, -68, -46.67, 140, 145]` 单调、`finalOffset 194 == endTarget 194`、`dragDisarmed: true`；done 帧 `streamingConfiguration: true`、`revealedCharacters: 494`、sameCell、stored 616 == measured 616；batch 7 由单调下限保住 567（未被重解析拉回）。唯一红是 C3 gate 的另一形态已知 flake（`measurement: no cell for reasoning`）。
- **无障碍旁路**：VoiceOver / Reduce Motion 时揭示关闭（官方 pacing provider 返回 nil / 不建 driver），行直接全量；底部跟随在两种情况下直接 place。已实现。
- **已知取舍**：稳定块在游标尚未到达其末尾时即整块显示（官方逐叶 mask）；只在快速突发时可见，后续按游标推进可细化。`thinking` 进入时的 caption 谓词官方 UNKNOWN，AA 保留 `.selection`。相位 haptic 在整页生命周期内触发，不随 footer 是否在屏。手势只做 delegate 级验证（simctl 不能合成触摸）。AA 现有 `measuredAtBottom` 判定是 **8pt**（官方 1 物理像素 = 1/displayScale）；本次复用该判定以免影响 pull/回底/胶囊等既有行为，`TimelineSpringFollow.shouldRearmEnd` 的 1px 规则仅由单测覆盖。

## 7.1 C3 gate flake（2026-10-21 处理）

C3（`TimelineAutoRun`）在 CI 上间歇性失败，三种形态：`no cell for reasoning`、`longGroup cell 200 vs content 1471`、`inline notice expanded == collapsed`。根因是 gate 用固定等待采样，异步 Markdown 解析与 controller 的 preferred-height 补偿在 CI 负载下会晚于固定时点；另有 longGroup 测量缓存已更新但 cell 仍沿用旧 frame 的时序。

修复（均为 gate 侧，断言未放宽）：
- `cabe89fd`：把固定等待改为轮询产品自身的 settle（async Markdown 10s、其它 3s；fold/notice/tail 用高度谓词 3s），变化时重新 `remeasure`，被修正移出可见区的 cell 重新居中。
- `d822c0f5`：当测量缓存已 settle 但 cell frame 仍旧时，强制一次完整 layout re-apply；样本记录 `attributes`/`frame` 便于诊断。
- `59256e3d`：缺失 cell 改为 top 对齐 + 10s 重试；失败信息附原因（no index path / no cell at index / width）。

已验证：run `39573714858`（`59256e3d`）**test + timeline-autorun 全绿（C3 与 M4）**；C3 `failures: []`，11 个样本 `attributes == cell == measured`（longGroup 1471/1471/1471）；M4 `failures: []`、`follow.starts: 1`。另派两轮复核 run `39575693162` / `39575701977`。

## 8. 验收

- M4.2 gate 全绿；旧 SwiftUI 路径回归不变。
- 揭示时序/视觉/行高/滚动/震动按本单参数。
- 未覆盖：工具平铺、per-block cell、完整滚动状态机、选择/附件/DT/RTL、真机/出包/合并。
- **不碰 dev、不合并、不出包**；测试包只从 `feat/textkit2-assistant-body` 出。
