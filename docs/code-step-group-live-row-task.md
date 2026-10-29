# Code 页：步骤组实时行 + 汇总行（任务单）

> 目标版本：`feat/code-profile-beta` @ `e1623a40`（b673）之后，分支 `feat/code-step-group-live-row`。
> 官方依据：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round29/chat-thinking-tool-dots-1.261023.20.md` 与追加报告 `chat-thinking-tool-dots-addendum-1.261023.20.md`（冲突以追加为准）。
> 证据等级：官方行为为静态反编译（EVIDENCE/INFERENCE，未做真机验证）；AA 侧实现为本次设计。

## 1. 要解决什么

现在 beta 的 Code 页把一段思考合并成一整页（`appendReasoningBlock` 用 `"\n\n"` 拼接），用户看不出"哪段思考对应哪次工具调用"（pp 2026-10-29 反馈）。改成官方 Chat 页的模型：**一个步骤组只占一行，运行中这一行显示当前步骤，结束后这一行变成汇总，点开看完整步骤列表。**

## 2. 官方 Chat 行为（round29 追加报告 §J，EVIDENCE）

| 时刻（同一回合） | 独立三点行 | 三点位置 / 行内容 |
|---|---|---|
| 刚发出，回复还没 block | 有（opensReply=true） | 工作行行首；无 caption 时文字透明，只见三点 |
| 思考/工具正在跑（最后一个 block 是 `steps(withOutput:false)`） | **无** | 三点坐在该步骤组行的行首；行文字 = 组内**最后一项**的 `previewText` |
| 一组完成且有输出（`steps(withOutput:true)` 或 `other`） | 有（跟在组行之后） | 工作行行首 |
| 开始写正文（最后一个 block 是 `text`） | 无 | 三点离场 |
| 回合结束（`ClaudeTurn == nil`） | 无 | 无 |

- 运行中的组行只显示组内**最后一项**；已完成步骤不单独占行，只在详情里按顺序列出（`CompactTimelineGroup.items`）。
- 组结束时该行显示：有代表项 → `caption`；无代表项且 items ≥ 2 → `stepCount`（「N 个步骤」）（追加报告 §H）。
- 点击组行 → sheet（`StepSheetModel`），详情里按顺序列出所有步骤；思考步骤的详情是 markdown 全文。

## 3. 我们的一处替代（pp 定，2026-10-29）

官方运行中思考行显示的是**摘要**（`ThinkingContent.summaries`；AA 的 wire 没有摘要数据源）。**AA 用思考正文代替摘要**：实时行显示该段思考文本的单行预览（取最后一行非空文本，超出截断），其余规则照官方。

另外两处 AA 既有能力沿用，不改官方语义：
- 汇总行文案用现有 13 类工具统计：「思考 N 次 · 读取 X 个文件 · 运行 Y 个命令 · 编辑 Z 个文件 · …」（`CodeToolLabelPlan` 的分类与本地化）。
- 思考详情页沿用 `CodeThinkingDetailView`（markdown）。

## 3.1 两套渲染方式（pp 2026-10-29 追加）

- 设置项从「会话时间线（实验）」开关改为**渲染方式选择**：`聊天` / `代码`，不是 on/off。
- `代码` = 现在 beta 的 Code 页渲染，**一行不动**。
- `聊天` = 本任务单的新样式（步骤组实时行 + 汇总行）。
- 存储用 enum（`chat` / `code`），老 Bool key 做一次性迁移：原开着 → `code`，原关着 → `chat`，升级后行为不突变。
- 默认 `code`（pp 当前使用的形态）。
- 旧 Chat 容器（`ChatTimelineView` / `SessionTimelineEventView` 那套）**不再作为可选项**：Phase 1 先停止引用（保留文件以便回退），验收通过后统一删除。

## 4. 行为规格（AA 版）

一个"步骤组" = 一个回合内连续的思考/工具步骤（沿 wire 的 `orderSeq`；正文 `text` 断组、回合边界断组；**跨 assistant 消息不断组**，否则回合中途就会冒出汇总）。

1. 回合开始、组尚未出现：只剩一条工作行（三点）。
2. **组出现后，三点永远坐在最后一条组行的行首**（pp 2026-10-29 真机观察）：不再有独立的「三点行」。行文字随当前步骤切换：
   - 思考 → 该段思考正文的单行预览（实时更新，取最后一行）；
   - 工具 → 工具文案（如「正在读取 xxx」）。
3. 步骤之间停顿：这一行保持最后一次的实时文案 + 三点，**不提前定格成汇总**。
4. 下一条 assistant 消息出现：新开一条组行（三点移到新行），上一组的行定格为汇总。
5. 正文开始 / 回合结束：三点离场，最后一条组行定格为汇总（思考 N 次 · 读取 X 个文件 · 运行 Y 个命令 · 编辑 Z 个文件）。
6. 点击组行 → 详情页：按顺序列出该组所有步骤；思考步骤可看全文，工具步骤可看输入/输出。

> 与官方 round29 静态报告的差异（以 pp 真机为准）：报告说"组完成后在其下面插一条独立工作行"，pp 在官方 Chat 页观察不到这种独立行——三点始终在内容行行首，变的只是三点后面的内容。任务按 pp 的观察实现。

## 5. 实现分解

| 模块 | 文件 | 改动 |
|---|---|---|
| 渲染方式 | `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineCollectionSwitch.swift`、`SessionChatView.swift`、`NewSessionView.swift`、`Views/Settings/AccountSettingsSheet.swift` | 开关改成 enum `chat`/`code` 选择器；老 Bool 迁移；`SessionChatView` 恒走 collection，按 enum 选 profile；设置文案改为「渲染方式」 |
| 行模型 | `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeMessageTimeline.swift` | 组单位保留逐步骤（不再合并思考文本）；行种类新增 `.stepsGroup`（含有序 `Step` 列表 + 运行状态）；`appendReasoningBlock` 的 `"\n\n"` 合并删除 |
| 分组 | `ios/Agents Anywhere/Agents Anywhere/Models/Chat/TimelineGrouping.swift` | `codeGroups` 按新单位产出；组 id 用组内第一个稳定 id，组增长时不改名 |
| 组行视图 | `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeStepGroupRow.swift`（新） | 运行态单行（mark + 当前步骤预览）；完成态汇总行；整行可点 |
| 详情 | `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeToolDetailView.swift`、`CodeThinkingDetailView.swift` | 详情页接受混合步骤列表，按顺序渲染 |
| 工作行 | `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeWorkingStatusRow.swift` + `TimelineChatContentAdapter.swift` | 落座规则：组运行时隐藏独立工作行；组完成/无块时显示 |
| 高度 | `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMessageHeightMeasurer.swift` | 组行：运行态固定单行高度（不随思考文本增长）；完成态按汇总行测量 |
| 门禁 | `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeProfileAutoRun.swift` | 重写断言：思考不合并、组行单行、运行态/完成态切换、汇总计数、点开详情 |
| 单测 | `ios/Tests/ClientCoreTests/CodeProfileModelTests.swift`、`CodeToolLabelPlanTests.swift` | 同步新契约 |

**不动**：server/connector（`source.turnId` 继续用于断组）、流式增量机制（块级缓存与行身份无关）、Chat 页（dev 线）。

## 6. 关键风险

1. **实时行身份/高度稳定**：运行中行高固定为单行，文字更新不能触发 re-key；组增长时行 id 不变（沿用组内第一个稳定 id）。
2. **思考文本单行预览的取法**：取最后一行非空文本；文本里没有换行时按尾部截断。需要门禁固定这个规则。
3. **多个组**：一个回合可能出现多个组行（按消息块/正文断组），每组各自汇总；不要把整回合合成一行。
4. **与流式增量/跟手手感共存**：新行种类要接入现有的高度缓存与滚动锚定；真机验收必须覆盖长回合流式。

## 7. 验收标准

- `code_profile` 模拟器 gate 全绿（新契约断言）。
- `timeline_autorun` + `test` + `build` 全绿。
- 真机：一个回合内观察 思考→工具→思考→正文 的完整过程：
  - 同一时刻只有一条实时行在变；
  - 组行完成后变汇总，点击能看到完整步骤；
  - 长回合流式时页面不跳。

## 8. 分阶段

- **Phase 1**：渲染方式选择器（含旧开关迁移）+ chat profile 的组行（运行态单行预览 + 完成态汇总）+ 详情页 + 门禁重写；旧 Chat 容器停止引用但保留文件。
- **Phase 2**：独立工作行的落座规则细化（跟随官方 §4.1，含 awaitsUser / opensReply 边距）。
- **Phase 3**：验收通过后删除旧 Chat 容器文件。
- 每阶段单独出包验收。

## 9. 状态补充（2026-10-30 已提交）

- 详情页：行间竖线（与 Code 页 `CodeTimelineConnector` 同一实现）；打开后实时更新（`TimelineLiveStepGroups` 发布 adapter 每次刷新算出的分组），新步骤在尾部插入并滚到最新；点进的思考详情页流式更新（路由带步骤 id，实时取文本，点开时的快照兜底）。
- 工作状态行：chat profile 显示「正在处理中…」并挂工具行同款扫光（`CodeCollapsedRowShimmer`）；Code 页保持英文轮换与原视觉。
- 设置：删除「文字浮现」「思考球」「聊天文字颜色（比例方案/字号/颜色）」三个老 Chat 设置项及其设置页；底层键与模型保留，老渲染面维持默认。

## 10. 待办（pp 2026-10-30）

**先把 SubAgent 胶囊按官方样式重做，然后删除老 Chat 遗留。** 前置与顺序：

1. SubAgent 面板不再使用 `ChatMarkdownView`（当前 `ios/Agents Anywhere/Agents Anywhere/Views/Chat/SubAgentPanelSheet.swift:510` 仍在用）。
2. 欢迎页（`NewSessionWelcomeView`）与公告（`AnnouncementSheet`）改用 Code 渲染面后，`StreamingGlyphReveal` / `GlyphRevealLedger` / `ReplyPresentation` 的浮现参数可删。
3. 交互 target 行目前仍走 `SessionTimelineGroupView`（adapter 的 `.group` 兜底），先换渲染面。
4. 最后删除：`ChatTimelineView`、`SessionTimelineGroupView`/`SessionTimelineEventView`、`ChatMarkdownView`、`ChatMetrics`/`ChatTypeSettings`/`ChatColorSettings`/`ChatColorStore`、思考球（`ThinkingOrbView`/`OrbEngine`/`OrbSettingsKeys` 及相关单测）。每项删除前 grep 确认无引用。
