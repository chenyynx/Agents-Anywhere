# C5 / Code 展示 profile 任务单（2026-10-22）

> 依据：`/home/ubuntu/aa-test/claude-ios-re/`（官方 build 1.261005.20 / 2026-10-05）CANONICAL 00–23 + DATA/tokens.json；AA 现状另做代码走查。
> 取代：`docs/perf-6b-c5-code-page-parity-task.md` §4（2026-10-20 pp 决定“先保持 AA 胶囊聚合”）。本单按 pp 2026-10-22「全面对标 Code 页」重开。
> 原则：**行为对标官方（EVIDENCE 优先），实现走“一套引擎 + profile”**；视觉常数改动单独确认；dev 不碰不合，测试包只从分支出。
> 证据标记：**[E]** 指令/类型/字节直读；**[I]** 结构或视频推断；**[U]** 静态未闭合，不得当事实用。

## 0. 结论（这是什么）

官方 Code 页的形态（均为 [E]，除注明外）：

- **一条 `DisplayMessage` = 一行**；行内 `DisplayMessage.blocks: [Block]` 按数组顺序放进一个 VStack；正文（`.text`）与工具调用（`.toolCalls`）是**同一行的兄弟块**，不拆行（`CANONICAL/01-architecture.md` §2；`02-transcript-model.md` §1.2）。
- 行 ID 与高度键是**同一个** `SessionTranscriptEntry.ID`；一条消息内所有块共享一个高度（`01-architecture.md` §2）。
- **工具调用在 `Block.toolCalls` 内成组**：连续普通调用收成一个 `span`；遇到专属段（workflow / writingDraft / backgroundTask / threadSessionCard / artifactCard）先 flush 再发专属段；**无数量阈值、不跨 block**；`ExitPlanMode` / `AskUserQuestion` 跳过不产段；**单次调用 = `span` 的 `calls.count == 1`**（`04-tool-calls.md` §1.3/§3）。
- **折叠行只有一行摘要**（icon + label + 可选 DiffIndicator + shimmer + caret），**不显示输出正文**；transcript **没有卡内展开态**，点击**一律进全屏详情**（NavigationStack + ScrollView + TimelineRows）（`04-tool-calls.md` §2.1/§2.2/§4）。
- 单调用详情 = `ToolCallDetailSections`（输入区 38 路 + 五路输出：text / todos / diff / submittedAnswers / approvedPlan）；`Read` 有专用 `FileReadDetailView`；全屏 diff 每页 **300 行**（`04-tool-calls.md` §2.3–§2.5）。
- 流式：数据层 **0.1 s 前沿节流 + 全量快照**；外观为块追加（视频观察 4–8 词 / 50–100 ms / 30–50 ms 淡入，[I]）；**无逐字揭示**、无 `RevealDriver`（`03-streaming.md` §3）。
- 流式行用独立固定 ID `.streamingText`；落库后**删除 + 插入** `.message(id)`，不原地改 ID（`03-streaming.md` §3.2）。
- 布局：`rowMargins=(5,16,5,16)`、`interMessageSpacing=10`、`segmentVerticalPadding=4`、行底 padding 0（[E]，`05-layout-scroll.md` §4.2）；底部跟随 ease `Spring(0.4,0)` / fly `Spring(0.36,0.15)`、1 物理像素阈值、catch-up 2×visibleHeight（`05-layout-scroll.md` §4.3）。

AA 现状（代码走查）：

- 正文与工具是**两个顶层 item**（`.single` group + `.tools` group），工具行就地双层 disclosure；没有全屏工具详情入口（`Models/Chat/TimelineGrouping.swift:46-76`、`Views/Chat/SessionTimelineEventView.swift:126-133, 202-288`）。
- 流式走 `rendererOwnedReveal` + 逐字揭示；有前缀增量解析与稳定块晋升，但**没有 chunk 队列接口**（`Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift:237-252, 388-442`；`Views/Chat/TextKit/AssistantMarkdownDocument.swift:934-1029`）。
- 高度三档缓存但生产只写 `.measured`；工具详情不计入估算，靠 `.interactive` cell 自报（`TimelineChatContentAdapter.swift:139-181`）。
- 设置页已有 `@AppStorage` 模式，无 `timelineStyle`（`Views/Settings/AccountSettingsSheet.swift:89-105`）。

## 1. 范围

**做**：Code 行模型、runtime-neutral 工具段、折叠行、全屏工具详情、五路输出视图、chunk 流式、working mark、高度/滚动接入、`timelineStyle` 开关、Code gate、Claude Code / Codex / DSH 三 runtime 适配。

**不做**：整页 shell（导航/抽屉/输入框/键盘/开屏遮罩）、本地消息库、Settings/Connectors/Dispatch、Chat profile 默认行为、服务端与 wire 契约。

## 2. 阶段 0：模型与身份（前置，风险最高）

1. **Code 行身份**：`CodeTimelineItem.id = DisplayMessage.ID`（AA 侧对应一条 assistant 消息 + 其工具调用的合并单元）；`blocks` 按服务端 blockIndex 顺序；高度键 = 同一 id（对齐 `01-architecture.md` §2）。
2. **`ToolSegment`（runtime-neutral）**：`span(calls, summary?, settledTasks, outputImages)` / `workflow` / `writingDraft` / `backgroundTask` / `threadSessionCard` / `artifactCard` / `other`。字段对齐官方 `ToolCall` UI 子集：id、name、status(running/complete/failed)、input(展示原文)、toolInput、output、fileWriteKind、subagentToolCalls、artifactId/taskReference（`02-transcript-model.md` §1.3；`04-tool-calls.md` §1.3）。
3. **成组器（纯函数，先写单测）**：按官方算法；用例矩阵：普通×1 / 普通×N / 特殊段夹在中间 / 连续特殊段 / 跨 block 不合并 / ExitPlanMode+AskUserQuestion 跳过 / 空数组不产段。
4. **runtime 适配层**：每个 runtime 一个 mapper（Claude Code / Codex / DSH），把原始 tool 调用映射成 `ToolSegment`；**未知工具一律 `other`，仍参与成组**；各 runtime 的特殊段/跳过集是配置表，不在分组算法里写死。
5. **迁移策略**：Code profile 下 `TimelineGrouping` 不把 assistant 正文与工具拆成两个 item；Chat profile 保持现状。切换由 style 决定，**不做两套数据模型**。

## 3. 阶段 1：折叠行 + 全屏详情（交互骨架）

1. 折叠行单行渲染：icon + label + 可选 DiffIndicator + 运行中 shimmer + caret；`Typography.monospaced` 15pt / lineHeight 24 / weight 400；按钮 padding 6（[E]，`04-tool-calls.md` §2.1、`DATA/tokens.json`）。
2. 点击 → 全屏详情（NavigationStack + ScrollView + 行列表）；**不做就地展开**（官方 transcript 无展开动画，[E]）。
3. 详情页骨架：列表级 title（呈现方式 [U]，先按导航标题）；行 = received / run；单调用 sections（DetailSection / following calls / 主内容 / 尾部）。
4. 复用 AA 既有件：`TimelineCodePanel`（行内代码/diff 面板）与 `ChatCodeFullScreenView`（全屏文本阅读器）；TextKit 代码卡补复制/全屏交互后可作为 Code 行内代码块。

## 4. 阶段 2：输出视图

- `text → CodeBlockContent`（先纯文本/代码块；Prettify 状态机后置）
- `todos → TodoListView`（pending/inProgress/completed；两态颜色 [U]，先不区分）
- `diff → PagedDiffRows`（每页 300 行）；**不做卡内 10 行 diff**（官方 transcript 不用，`CORRECTIONS #45`）
- `submittedAnswers / approvedPlan` 先按条件容器占位（[I]，真机比对后再定）
- `Read` 专用 `FileReadDetailView` 放第二批

## 5. 阶段 3：chunk 流式

1. 流式 item 用独立固定 id；落库时删除 + 插入，不原地改 id。
2. 发布节拍按官方 0.1 s 前沿节流（[E]），无定时器、下一事件补发。
3. 外观参数按 `DECISIONS.md:19`：4–8 词 / 50–100 ms / 30–50 ms 淡入，**无逐字揭示**（[I]，CI 标 observed）；粒度做成参数，细粒度（逐 token）作为 Beta 开关默认关。
4. 行更新包 `performWithoutAnimation`；Code profile **不启用** reveal ownership / `RevealDriver`。
5. 同帧双行（`.message` 与 `.streamingText` 并存）按官方“可能一帧重复”接受，不额外做兜底（官方兜底 [U]）。

## 6. 阶段 4：working mark

- `Block.thinking` 状态行（不是独立行）：20×20 flipbook、30 fps、think `0.53 s in / 3.67 s loop / 0.50 s out`、Spring(0.5,0)、Reduce Motion 单帧、退出 0.4 s（scale→0.01 + opacity）（[E]，`20-working-mark.md`）。
- 文案三态：server 原样 / compacting 本地化 / connecting 20 动词每秒轮换。
- `ShownWords`（显示当前 live 工具行）先不做（[U]）。

## 7. 阶段 5：高度 / 滚动 / LoadOlder

- 高度两档 estimate → measured；宽度变化清 measured 但保留旧高当估计（[E]）。
- 官方 Code 估高公式 [U]：先用自己的估算，**不照搬 Chat 的 `insets + 44`**；`interBlockSpacing` 的系统默认值 blocked（206 无 iOS SDK），AA 显式给设计值并标注。
- 行边距/间距按 §0 的 [E] 值；若与 AA 视觉冲突，单独拍板。
- 底部跟随按 [E] 参数接入现有状态机；LoadOlder 先做“顶部哨兵 + 自动加载观察器”骨架，视觉后置（[U]）。

## 8. 设置与切换

- 新增 `ChatTimelineStyle = chat | code` + `@AppStorage` key；默认 `chat`，`code` 标 Beta。
- 切换必须使高度键失效（走 `applyTypography` 的 generation 杠杆或把 style 并入高度键/签名），否则行高沿用旧缓存。
- 落点：`TimelineCollectionSwitch.swift`、`SessionChatView.swift:61-69,137`、`TimelineChatTimelineView.swift:30-37,208-215`、`TimelineChatContentAdapter.swift:91-102`、`AccountSettingsSheet.swift:89-105`。

## 9. 验收（Code gate）

新增 DEBUG launch arg `aa-code-profile` + `code-profile.json`：

- 分组矩阵（§2-3 的全部用例）+ 三 runtime fixture（每 runtime 至少：单调用、多调用连组、特殊段、未知工具）
- 折叠行不展开、点击进详情、返回不跳位
- 详情五路输出渲染 + 300 行分页
- 流式：块追加、无逐字、流式→落库不闪双行、同帧重复可接受
- 高度：首次估计 → 实测收敛，切换 style 后高度失效
- 与 Chat gate 并行跑、互不阻塞

## 10. 明确不做（第一批）

- 不做工具卡就地展开动画（官方 transcript 没有，[E]）
- 不把 `ToolCallSpanView` 的 10 行 diff 卡搬进 transcript（只在欢迎页，[E]）
- 不按工具调用拆行（[E]）
- 不做逐字揭示（[E]）
- 不照搬 Chat 的 `stableId` / `opensAtTop` / `workingMark` 配置（Code 页不设，[E]）

## 11. 未闭合项（施工时按“暂定”处理，不得当官方事实）

`interBlockSpacing` 系统默认值 blocked；Code 估高公式 [U]；详情页呈现方式（push/sheet/fullScreenCover）[U]；30–50 ms 淡入实现 [U]；`CollapsedToolCallList.title` 呈现 [U]；ToolInput 38 tag 完整标题表 [U]；todos 两态颜色 [U]；`submittedAnswers/approvedPlan` 视图绑定 [I]；`stopFollowingTail/askedToStay` 在 Code 的触发路径 [U]。完整 34 条见两份调研报告（会话内）。

## 12. 需要 pp 拍板

1. **形态**：按官方 B 形态（消息内平铺工具、一行一消息）改分组（推翻 2026-10-20 的“先保持胶囊”）？
2. **视觉常数**：Code profile 采用官方 [E] token（15pt mono 折叠行、rowMargins 5/16、10pt 消息间距），还是保持 AA 现值？
3. **出包节奏**：完成阶段 0–1 先出一包验证交互骨架，还是一次性做到阶段 3（含 chunk 流式）再出包？

## 13. 分支与门禁

- 从 `feat/textkit2-assistant-body`（head `fae943c5`）拉 `feat/code-profile-beta`，复用现有 TextKit/collection 引擎。
- 每个阶段独立提交；style 开关默认 `chat`，Code 不达标不影响 Chat。
- 不合 dev、不碰 ipa-dev；测试包只从 feature 分支出。
