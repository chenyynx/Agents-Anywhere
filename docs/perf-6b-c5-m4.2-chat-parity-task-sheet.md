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

## 7. 验收

- M4.2 gate 全绿；旧 SwiftUI 路径回归不变。
- 揭示时序/视觉/行高/滚动/震动按本单参数。
- 未覆盖：工具平铺、per-block cell、完整滚动状态机、选择/附件/DT/RTL、真机/出包/合并。
- **不碰 dev、不合并、不出包**；测试包只从 `feat/textkit2-assistant-body` 出。
