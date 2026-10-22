# Code 页复刻 · 执行方案（2026-10-22）

> 目标：**100% 复刻官方 Claude iOS Code 页**（行为 + 视觉 + 动效），时间线全部换成官方形态，不保留 AA 现有视觉。
> 非目标：Chat 页与揭示效果（以后单独改）、双 profile 开关、整页 shell、本地库、Settings/Connectors/Dispatch、服务端与 wire 契约。
> 分支：`feat/code-profile-beta`（从 `fae943c5` 拉出，head 含任务单提交）。dev 不碰不合。
> 依据：`docs/perf-6b-c5-code-profile-task.md` + `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/`。

## 1. 已确认的架构事实（不得再猜）

- 一条 `DisplayMessage` = 一行；正文/推理/工具是一个行内 block 栈（`01-architecture.md` §2）。
- 工具调用在一个 `Block.toolCalls` 内成组：连续普通调用 → 一个 span；特殊段 flush；无数量阈值、不跨 block；`ExitPlanMode`/`AskUserQuestion` 跳过；单调用 = span(count 1)（`04-tool-calls.md` §1.4）。
- 点击折叠行 → **全屏详情**，transcript 无就地展开（`04-tool-calls.md` §2.1/§4.2）。
- AA wire 已声明分组真值：`source.nativeMessageId ?? source.itemId`；组内顺序 **RBT**（reasoning → body → tools 按 `source.blockIndex`）（`server/agent_server/core/timeline.py`）。
- 流式：0.1 s 前沿节流 + 全量快照；独立 `.streamingText` 行；落库删除+插入；无逐字揭示（`03-streaming.md` §3）。
- WorkingMark：20×20 flipbook、30 fps、think `0.53/3.67/0.50 s`、Spring(0.5,0)、退出 0.4 s（`20-working-mark.md`）。

## 2. 工作包（文件域白名单）

| 包 | 内容 | 文件（只允许这些） | 依赖 |
|---|---|---|---|
| W0 | 官方视觉 token 唯一出口 | `Views/Chat/Code/CodePageTheme.swift`（新） | 无 |
| W1 | 模型层复核+补强+单测 | `Models/Chat/Code/*`（新，3 份草稿可改）、`Tests/ClientCoreTests/CodeProfileModelTests.swift` | 无 |
| W2 | 三 runtime 适配表 + fixtures | `Models/Chat/Code/CodeRuntimeAdapters.swift`（新）、`Tests/ClientCoreTests/CodeRuntimeAdapterTests.swift`（新） | W1 |
| W3 | 折叠工具行视图 | `Views/Chat/Code/CodeCollapsedToolRow.swift`（新） | W0 |
| W4 | 全屏详情 + 五路输出 | `Views/Chat/Code/CodeToolDetailView.swift`、`CodeToolOutputViews.swift`（新） | W0/W1 |
| W5 | WorkingMark 运行中动画 | `Views/Chat/Code/WorkingMarkView.swift`、`WorkingMarkRenderer.swift`（新） | W0 |
| W6 | chunk 流式纯逻辑 | `Models/Chat/Code/CodeStreamingPublisher.swift`（新）、`Tests/ClientCoreTests/CodeStreamingPublisherTests.swift`（新） | 无 |
| W7 | 引擎接线（共享文件，串行） | `TimelineChatContentAdapter.swift`、`TimelineGrouping.swift`、`TimelineItemIdentity.swift`、`TimelineCollectionController.swift`、`TimelineChatTimelineView.swift` | W1/W3/W4/W5/W6 |
| W8 | Code gate + CI | `Views/Chat/Code/CodeProfileAutoRun.swift`（新）、`.github/workflows/ios-build.yml` | W7 |
| W9 | 修红/出包 | 按 CI 结果 | W8 |

**硬规则**：W0–W6 代理**只准动自己白名单内的文件**；共享文件只有 W7 一个代理可动；代理不 commit，由主会话按包提交。

## 3. 波次（并行度最大 + 质量约束）

- **Wave 1a（4 并行，零共享）**：W0（主题）、W1（模型）、W2（runtime 表）、W6（流式纯逻辑）。
- **Wave 1b（3 并行，依赖 W0/W1）**：W3（折叠行）、W4（全屏详情）、W5（WorkingMark）。
- **Wave 2（串行，1 代理）**：W7（引擎接线）。此步前后必须跑现有 C3/M4 gate 回归。
- **Wave 3（串行，1 代理）**：W8（Code gate + CI）。
- **Wave 4**：CI 修红（W9）→ 阶段验收 → 出包。

## 4. 每个包的验收

- W0：token 全部有来源注释（[E] 章节 / [I] 截图）；无散落魔法数；`swiftc -parse` 通过。
- W1/W2/W6：单测覆盖矩阵（span 1/N、特殊段、跳过不 flush、跨 block、空、未知工具、三 runtime 隔离；RBT 排序、无 key 行、sub-agent 排除、缺 blockIndex；节流 0.1s、chunk 4–8 词、独立行 id、无逐字）；`swiftc -parse`。
- W3/W4/W5：视图结构与官方参考一致；DEBUG 预览入口；只用已存在 API（grep 确认）；`swiftc -parse`。
- W7：现有 C3/M4 gate 全绿 + 新 Code gate 能启动；行 id/高度键变更后无 stale cell 回归。
- W8：`aa-code-profile` gate 产出 `code-profile.json` + 三张组件截图；CI job 挂上。
- 全部：不合 dev、不碰 ipa-dev；报告区分 已验证/推断/未验证。

## 5. 质量门

1. 纯逻辑层必须有单测（CI 跑；本机 Swift 6.0.3 无法编译 6.2 包，禁止声称本地验证）。
2. 现有 gate（`timeline-autorun` 的 C3/M4/M4.3）必须保持全绿——这是回归门。
3. 视觉以组件级截图对比为准（逆向侧 exact 0，不设像素判据）。
4. CI 红：贴 `timeline-autorun.json`/`code-profile.json` 的具体 failures，不靠重跑掩盖。
5. 真机包：首包验折叠条/详情/WorkingMark；第二包验 chunk 流式/五路输出。

## 6. 已知风险

- 分组改共享模型 → 行 id 变更、高度缓存失效、滚动锚点抖动：W7 必须复用现有高度键纪律，先跑回归。
- 流式删除+插入同帧双行（官方允许一帧重复）：gate 接受一帧并记录。
- 工具行变长 → 估算更不准：保持 interactive 自报高度，不默认展开。
- 视觉 [U] 项：集中主题文件、截图取色、真机再收敛。
- 官方资产不可分发：WorkingMark/图标按形状自绘或 SF Symbols 复刻。
