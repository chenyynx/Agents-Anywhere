# C5 / M4.2 交接（2026-10-21）

> 给下一个会话：先读本文件，再读任务单 `docs/perf-6b-c5-m4.2-chat-parity-task-sheet.md`。
> 分支：`feat/textkit2-assistant-body`。**dev 绝对不碰、不合；测试包只从本分支出；未明确说“合 dev”前绝不合并。**

## 0. 一句话现状

官方 Claude Chat 页风格的流式正文（三段揭示 + 逐行 mask + 逐帧行高 + 底部弹簧跟随 + 相位震动）已在分支上实现并通过 C3/M4 gate；C3 gate 的 flake 已处理并连续 3 轮全绿。**M4.2 代码完成，等真机验收；M4.3（图片/Git badge/公式/文件变更 footer）尚未开始。**

## 1. 分支与提交

- 分支 head（本文件提交前）：`cf130b18`（docs）；代码 head：`59256e3d`。
- 关键提交（按时间）：
  - `9ce81bad` 阶段 3：tail 改 TextKit + `StreamingRevealDriver`（逐行 mask/run/patience/fade/clamped/块入场）
  - `1d78bcb9` 阶段 4/5：`TimelineSpringFollow` + controller 跟随；`ChatTurnPhase` + 震动映射
  - `df49aba1` 审查修复：`StreamingRevealOwnership` 交接、签名、footer 重测、fly 曲线、`.animating`、外部 offset 重锚、游标块选择
  - `644e6e73` 非文字游标交接（块底 clamp、后续块隐藏、ticker）
  - `2b2499ca` gate 诊断（attributes/frame、follow starts/eligible）
  - `996cd564` 行高 8pt 下限 + `min(fit,clamped)`
  - `f656f096` 流式行高单调不回退
  - `cabe89fd`/`d822c0f5`/`59256e3d` C3 gate settle 修复（见 §4）
- 另有 docs 提交至 `cf130b18`。
- 全部已 push 到 `origin/feat/textkit2-assistant-body`。

## 2. 测试包（已构建）

- 构建 run：`39582106040`（commit `cf130b18`，`build=true`）——**test + build 均 success**。
- release（分支专属，未碰 `ipa-dev`）：
  - 页面：`https://github.com/chenyynx/Agents-Anywhere/releases/tag/ipa-feat-textkit2-assistant-body`
  - 直连：`https://github.com/chenyynx/Agents-Anywhere/releases/download/ipa-feat-textkit2-assistant-body/AgentsAnywhere-feat-textkit2-assistant-body-cf130b1.ipa`
  - 大小 15,438,923 bytes；unsigned，需 KSign/全能签。
- **构建只从分支出**；不要为测试包触碰 dev。

### 真机验收清单

1. 设置 → 打开「会话时间线（实验）」；回到设置应显示「上次生效」时间（证明新容器真的跑了）。旧 SwiftUI 路径没有新揭示。
2. 长回复（含列表/代码/表格）：揭示节奏、最后一行按字符断字、行高逐行长、不闪、无整块提前出现。
3. 底部跟随：在底部时新行带来弹簧跟随；上滑/拖动立即停；滑回底部恢复；结束不跳。
4. 震动：开始流式 selection；结束 light impact；过程无逐字震动。
5. 流式结束：copy/时间戳 footer 出现，行高不跳。
6. Reduce Motion / VoiceOver：直接全量，无遮罩揭示。
7. 中断/停止：页面不坏，收口后 footer 正常。

## 3. 方案（简要）

- 数据 → 文档 → 测量 → 视图全部单引擎：`V2TimelineItem` → `ChatTimelineRowModel`（renderer-owned 原文）→ `AssistantMarkdownDocumentParser`（复用 Textual 解析管线）→ `AssistantMarkdownTextLayout`（独立 TextKit 2 栈测量）→ `AssistantMarkdownCell`（块视图）。
- 流式：增量文档（`AssistantStreamingDocumentBuilder`，稳定块复用、尾部重解析、晋升延迟一批）；时间线纯模型 `StreamingRevealTimeline`（320/640 cps、2.0s drain、最后 640 字 320/s 线性、`floor(+1e-9)`、重锚定）；视觉驱动 `StreamingRevealDriver`（CADisplayLink、逐行 rect、`CAShapeLayer` mask、0.6s ease-out、clamped 行高、seated 0.5pt 重建、游标跨块切换）。
- 行高：逐帧 `min(fit, clamped)+1`，走 layout 的 `streamingHeights` display override，不写测量缓存；同一条消息内单调；收口后静态重测（含 footer）。
- 滚动：`TimelineSpringFollow`（ease 0.4/0、fly 0.36/0.15、1 物理像素 no-op、2 屏 catch-up、1 屏预置）；controller 独立 display link；拖动/`.animating` 让位；Reduce Motion/VoiceOver 直接 place；`repinIfArmed` 在揭示期让位给 follower（否则 follower 永远启动不了——这是审查抓到的 P1）。
- 交接：`StreamingRevealOwnership`（ClientCore）是“揭示仍拥有该行”的唯一真相，哈希进 `revealingRowIDs`；driver 淡出结束后清除 ownership 并强制 apply；静态测量带 footer。
- 震动：`ChatTurnPhase`（idle=0/thinking=1/writing=2/usingTool=3）+ `TurnPhaseHaptics`：`writing→idle` 唯一 `.impact(.light,1.0)`；其余相位 `.selection`；无逐 token。
- 准入：`TimelineStreamingEligibility`（单行组、助手文本、无 notice/附件、footer 纯文本、非 fallback）；不支持整行回退 hosting（宁缺勿假）。

## 4. 验证（全部为已跑过的 CI）

- **M4 gate（gateVersion 6）**：run `39565998390`（`f656f096`）`failures: []`；`follow.starts 1`、`frameCalls 13`、`eligibleFrames 12`、offsets 单调、`finalOffset 194 == endTarget 194`、`dragDisarmed true`；done 帧 `streamingConfiguration true`、`revealedCharacters 494`、`stored 616 == measured 616`。
- **C3 gate 修复后**：
  - run `39573714858`（`59256e3d`）：**test + timeline-autorun 全绿**；C3 `failures: []`，11 个样本 `attributes == cell == measured`（longGroup 1471/1471/1471）；M4 `failures: []`、`starts 1`。
  - run `39575693162`、`39575701977`：**均全绿**（C3 连续 3 轮绿）。
- 早前阶段：`39545641056`（M4 首次绿）、`39559608529`（全绿）。
- 截图（最新全绿）：`/home/ubuntu/aa-test/m42-art-59256e3d/m42-mid1.png`、`m42-mid2.png`、`m42-final.png`；`mid2` 可见按字符截断的半揭示帧。
- C3 gate 修复内容：固定等待 → 轮询产品 settle（async 10s、其它 3s、fold/notice/tail 高度谓词）；缓存 settled 但 cell frame 旧时强制 layout re-apply；缺 cell 时 top 对齐 + 10s 重试并附原因。

## 5. 已知残余 / 取舍（不要重新发现成新问题）

- 稳定块在游标未到其末尾时整块显示（官方逐叶 mask）；只在快速突发时可见。
- 非文字块结尾：游标在 code/table/list 内时无字符 mask（块入场 + 块底 clamp）；中途停顿由 ticker 推进。
- `thinking` 进入的 caption 谓词官方 UNKNOWN；AA 保留 `.selection`。
- 相位 haptic 在整页生命周期触发，不随 footer 是否在屏。
- AA 的 `measuredAtBottom` 仍是 **8pt**（官方 1 物理像素）；复用现有判定，`shouldRearmEnd` 的 1px 规则只由单测覆盖。
- 手势只做 delegate 级验证（simctl 不能合成触摸）。
- 适配器交接/ownership 接线无 SwiftPM 单测（Views 不进测试目标）；靠 gate + 代码审查。
- **待办补丁**：行在揭示中因 notice/文件变更 footer 变得不合格时会立即切 hosting，原文已全量发布 → 剩余文字一次性出现。建议在 M4.3 前加“揭示中不切引擎，收口后再交接”。
- 助手消息实际从不携带附件（connector 只给用户消息挂 `attachments`；助手 item 不传），所以“助手附件条”是死代码；“带附件截断”对 Claude 助手正文目前不会发生。
- 真实设备手感/震动/滚动手势未验证。

## 6. 关键文件

- 文档/任务单：`/home/ubuntu/aa-ring-work/docs/perf-6b-c5-m4.2-chat-parity-task-sheet.md`、本文件
- 交接上游：`/home/ubuntu/aa-ring-work/docs/perf-6b-c5-m4-handoff.md`
- 解析/文档：`/home/ubuntu/aa-ring-work/ios/Agents Anywhere/Agents Anywhere/Views/Chat/TextKit/AssistantMarkdownDocument.swift`
- 测量：`.../TextKit/AssistantMarkdownTextLayout.swift`
- Cell/块视图：`.../TextKit/AssistantMarkdownCell.swift`、`.../TextKit/AssistantMarkdownBlockViews.swift`
- 揭示驱动/mask：`.../TextKit/StreamingRevealDriver.swift`、`.../TextKit/AssistantMarkdownMaskRenderer.swift`
- 时间线纯模型：`.../Models/Chat/StreamingRevealTimeline.swift`
- 弹簧：`.../Models/Chat/TimelineCollection/TimelineSpringFollow.swift`
- 准入：`.../Models/Chat/TimelineCollection/TimelineStreamingEligibility.swift`
- ownership：`.../Models/Chat/TimelineCollection/StreamingRevealOwnership.swift`
- 相位/震动：`.../Models/Chat/TurnPhase.swift`
- adapter：`.../Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift`
- controller/layout：`.../TimelineCollection/TimelineCollectionController.swift`、`.../TimelineListLayout.swift`
- gate：`.../TextKit/TextKitM4AutoRun.swift`、`.../TimelineCollection/TimelineAutoRun.swift`
- workflow：`/home/ubuntu/aa-ring-work/.github/workflows/ios-build.yml`

## 7. 参数（冻结值）

- 揭示：320/640 cps，drain 2.0s；最后 640 字 320/s 线性；`floor(pos+1e-9)`；run 24–64，patience 0.35；fade 0.6s ease-out；`clampedHeight+1.0`；块入场 opacity 0→1 / 0.25s / 5pt rise（Reduce Motion 关位移）。
- 滚动：no-op 1 物理像素；catch-up 2×visibleHeight；预置 1×visibleHeight；ease Spring(0.4,0)、fly Spring(0.36,0.15)；帧率 [maxFPS/2,maxFPS]；dt≤2/maxFPS；到达=位置与速度双 1px。
- 震动：`writing→idle` = `.impact(.light,1.0)`；其余相位 `.selection`。
- 真源：`/home/ubuntu/aa-test/part-ag-official-parameter-inventory.md` 及 `part-ag-*-params-draft.md`。

## 8. CI 操作

- 跑 gate：dispatch `ios-build.yml`，`ref=feat/textkit2-assistant-body`，`inputs={"timeline_autorun":"true"}`。
- 出测试包：同一 dispatch，`inputs={"build":"true"}`；Release，发布到 `ipa-feat-textkit2-assistant-body`；不碰 `ipa-dev`。
- 后台 watcher：`python3 /home/ubuntu/aa-test/ci-watch-aa-m4.py <run_id>`，必须 `run_in_background=true`（前台 sleep 会阻塞）。
- 下载 artifact 注意：GitHub artifact 的 302 跳到 Azure，**重定向时要去掉 Authorization 头**，否则 401（本次会话已踩过）。
- 已知 C3 修复后应稳定；若再红，先看 `timeline-autorun.json` 的 `failures` 与样本 `attributes/cell/measured`。

## 9. 下一步

1. 查构建 `39582106040`，给用户直连 release 链接 + 真机清单（§2）。
2. 真机验收反馈（尤其揭示手感、震动、底部跟随、footer）。
3. **M4.3**：先写任务单（图片/Git badge/公式/文件变更 footer 正式块、异步尺寸防塌、准入与 gate；并入“揭示中不切引擎”的补丁），再实现。
4. M4.4 选择/链接/复制；M4.5 DT/RTL/无障碍；M4.6 真机/出包/合并（合并需 pp 明确点头）。
5. 工具平铺（官方 B 形态）与 per-block cell：等以上全部稳定后再议，不在当前关键路径。

## 10. 恢复用检查点

本地检查点（非 git）：`/home/ubuntu/aa-test/m4.2-session-checkpoint.md`。
最新截图/JSON：`/home/ubuntu/aa-test/m42-art-59256e3d/`（全绿 run `39573714858`）。
