# Code 页「思考块 + 工具分组」任务单（2026-10-25）

> **级别：L**（核心用户流程 + 跨进程字段；工具分组部分为 iOS 单端）。
> **依据**（全部只读，未改代码）：
> - 官方 Code 思考块反编译：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round23/code-thinking-row.md`
> - 官方 Chat 思考行/弹层反编译：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round23/chat-thinking-summary-ui.md`
> - AA 思考链路审计：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round23/aa-thinking-audit.md`
> - AA 工具分组审计：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round23/aa-tool-grouping-audit.md`
> - 官方工具分组规则：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round21/tool-group-label.md`
> - 生产库快照：2026-10-25 17:00 CST（`timeline_items`，只读 SELECT）
> **证据标记**：[E] 指令/类型/数据库直读；[I] 结构推断（写明依据）；[U] 未验证。
> **铁律**：`dev` 不碰不合；只从 `feat/code-profile-beta` 出包；不 force push；先任务单后代码。
>
> **实现状态（2026-10-25，分支 `feat/code-profile-beta`）**：P1 思考行 + 详情 `fe0a086c`；关闭按钮与长 Read 输出 `98f23368`；运行态思考文案 + 工具文案四项 `277002d6`；思考态截图门禁 `d7ae6bbb`；跨回合思考防串 `e4a37829`；`thought_process` 官方文案 `37255002`；wire 时间戳解析 `489ccde1`。`code-profile` 门禁新增 settled thinking 行高矩阵与 24K/298 行 Read 高度检查。`fileWriteKind` 改由 Write 结果文案推导（create/update，未知保持旧行为），同时驱动 diff 跳过与 `Updated / 已更新` 动词；运行中的 update Write 无提前信号，仍显示 Creating。

---

## 0. 给 pp 的一屏结论

### 思考块：官方有两个代码路径，但持久层只有一套

- **tag 3 `Block.thinking(WorkingStatus?, activity, turnStartedAt)` → `CodeThinkingView`**（每 turn 一条，实时行）[E]：
  - 思考进行中：5 档递增文案，阈值直读 `0x102a89080`：0–14s `thinking…` / 15–29s `still thinking…` / 30–44s `thinking more…` / 45–59s `thinking some more…` / ≥60s `almost done thinking…`；
  - 闭合：`thinking_status_thought_for_duration` = `thought for %@` / `思考了 %@`（构造点 `0x102cda6dc`）；
  - 无思考时间戳：退回 20 动词工作行（R20 已实现）。
- **tag 4 `Block.thinkingContent(String)` → `ThinkingContentRow`**（每个**连续 thinking run** 一条，持久行）[E]：固定图标 `anthropicon.extendedThinking`（渲染 `.medium`，基准 20pt）+ `thought_process`（`Thought process` / `思考过程`）+ caret；点击 → **sheet（中/大两档 `.presentationDetents` + 内部 NavigationStack）** 的详情页，正文是完整思考 markdown，页头同为 `思考过程`。**多段思考会合并**：`0x1027365f0` 从尾部跳过 toolCalls（tag2）后若找到已有 tag4，就用「旧文本 + 新文本」合并替换，否则追加——所以同一 run 里被工具调用隔开的多段 thinking 只有一条「思考过程」行；被 text 等其它块隔开才新起一条（round24 `synthetic-thinking-lifecycle.md` §6.3）。
- **原始思考正文不在 transcript 内联**，只在详情页 [E+INFERENCE-high]。
- `_transcriptShowsThinkingRow` **已闭合，且与思考行无关**：字段 42，ivar offset slot `0x105a90d40`，**默认 false**（init `0x102932628` @`0x1029329d8` `strb wzr`）；getter `0x102930f00`、setter `0x102930f14`（唯一调用者闭包 `0x102c4e968`，由 `SessionTranscriptPane` 挂到 `SessionMessageList.onStagedThinkingRowChange`）。**它不门控 tag 3/4**：唯一非 keypath 读点在 `SessionMessageListFooter.body`（`0x102c2bad8`），谓词 `0x102934e54` 返回 `!transcriptShowsThinkingRow`，条件性多构建一个 footer 子视图。全 App 35 个 bundle 无用户可见“显示思考”设置 [E]。⇒ AA 不依赖它，思考行默认显示。
- **“会不会出现两套思考”已闭合：不会。** tag 3 的承载者是一个**合成 DisplayMessage，id 固定为 `"thinking"`**（`0x10272d40c` 把 8 字符小字符串 `thinking` 写进 DisplayMessage 第一字段 `id`；role=assistant；`DisplayMessage.id` 字段序见 `swift_types.csv:49347`）。固定 id 在按 id 索引的消息列表里**最多只能存在一条**，所以它是运行态合成行，不是每 turn 持久化的历史行；多个 transcript 构建函数对 `id == "thinking"` 做特判（比较函数 `0x102559b18`，4 个 caller；`0x1027a6efc` 在命中时跳过该消息）[E]。**settled transcript 的持久思考行只有 tag 4**（每个连续 thinking run 一条「思考过程」，多段合并见 §1.1）。
- **AA 落码因此改成严格官方**：持久行 = `思考过程`（tag 4 形态）+ 点击看全文；`思考了 X` 只在运行态工作行出现（tag 3 形态，客户端计时），回合结束随合成行消失。**不需要 connector 补时长**；历史里官方本来就不显示“思考了 X” [E]。
- 时长格式化照官方 `Duration.UnitsFormatStyle`（h/m/s、`.narrow`、最多 2 段、零值/小数隐藏、locale `autoupdatingCurrent`、最小 1 秒、闭合四舍五入）——63s → `1分钟3秒` / `1m 3s`，与 pp 截图一致 [E]；只用于运行态行。
- 官方详情是 **sheet（`.presentationDetents` medium/large + 内部 NavigationStack）**，不是全屏 push；AA 现有页面级 sheet（`TimelineChatTimelineView.swift:193`）正好同形态。思考/工具详情共用一个 `.sheet(item:)`，避免同页双 sheet；补 detents 即可。

### 工具分组

- **官方 NO-MERGE（EVIDENCE，round24）：不同 API assistant 消息 = 不同 `DisplayMessage`，串行工具不会被跨消息并成一行。** 依据：assistant 行 id = SdkMessage payload `uuid`（`0x101e208f8` → 构造器 `0x10272b7c4`）；一条 `SdkAssistantMessage` 只含一条 `APIAssistantMessage`；`processedRawMessages` 按同一 uuid 去重；`apiMessageIds` 只在构造时写成单元素 Set，全镜像无 insert/union 写点；块合并 `0x102734e80` 只作用于本条消息自己的 blocks。
- 因此：**并行工具（同一 API 消息里多个 `tool_use`）合并是官方行为，AA 现有的 `nativeMessageId` 分组已经 1:1**；串行工具官方也各自一行。**不做 B/A/C，不改工具分组。**
- 同批只补**文案差距**：失败后缀 `(N failed)`/`（N 项失败）`、分隔符改官方 `", "`、单目标判定（all-same-target）、diff 聚合规则 [E]。
- 思考合并只在**同一个消息组内**（同一 `nativeMessageId`）：多个 reasoning item 中间只隔工具行 → 合并成一个 thinking 块；text 断开；跨消息不合并（官方 tag4 合并发生在单条消息的 blocks 内，`0x1027365f0`）。

---

## 1. 官方事实

### 1.1 思考（Code 页）

| 项 | 结论 | 证据 |
|---|---|---|
| 实时行视图 | `CodeThinkingView`，Body `0x102a83210`；每 turn 一条 | `code-thinking-row.md` §2.1 |
| 实时行三态 | 闭合 → `thought for %@`；进行中 → 5 档文案；无时间戳 → 20 动词 | `0x102a88dfc`、`0x102a89080`；§2.2/§2.3 |
| 进行中阈值 | 15 / 30 / 45 / 60 s（截断取整） | `0x102a89118–58` |
| 5 档文案 key | `thinking_status_thinking` / `still_thinking` / `thinking_more` / `thinking_some_more` / `almost_done_thinking` | `code-page-strings.csv:516-520` |
| 持久行视图 | `ThinkingContentRow`，Body `0x102c6ba54`；每个连续 thinking run 一条。**真渲染臂 = `DisplayBlockView.body 0x102b185d0` 的 tag4 → `0x102b19c30`**（R23 的 `0x102b1bfc8` 实为 `ToolCallSegment` 分派/threadSessionCard，已更正） | round24 `thinking-row-detail-and-style.md` |
| **思考合并规则（本轮新增）** | `0x1027365f0`：从 blocks 尾部跳过 tag2（toolCalls），遇到 tag4 就用 **`[old, new].filter{!isEmpty}.joined(separator: "\n\n")`** 合并替换，否则追加。⇒ 被工具调用隔开的多段 thinking 合并成一条 tag4；被 text 等其它块隔开才新建。`redactedThinking`（tag5）**不产出** tag4；Set 键是 **block index**（`narrationBlockIndexes`），命中时改产 `Block.narration`（tag5）。合并函数内无去重（重复帧上游处理 UNKNOWN） | round24 `tag4-merge-text.md`、`synthetic-thinking-lifecycle.md` §6 |
| 持久行内容 | `extendedThinking` 图标（**渲染 `.medium`，基准 20pt**，不是 large/24）+ `Thought process`/`思考过程` + caret；文本 15/400/21 默认 label 色；图标/caret 动态灰 light ≈ #7B7974 / dark ≈ #97958D；`IconFrame` style `.plain` / size `.regular` / isFramed=true；`CollapsedRowButton` minHeight 24 + padding 6 + contentShape(Rectangle) | round24 `thinking-row-detail-and-style.md` §4 |
| 点击 | 逐指令坐实：`0x102b19c30` 捕获 String → `ThinkingContentRow.onTap` → `0x102b38d74` → `0x102b1f23c` → `presentDetail(.thinkingText(text))`；详情页 = **sheet（`.presentationDetents` medium/large + 内部 NavigationStack）**，正文 `RichMarkdownView` 原文，标题 `思考过程`；sheet 挂载点 UNKNOWN | round24 `thinking-row-detail-and-style.md` §2/§3 |
| 正文内联 | **没有**任何路径在 transcript 内联 raw thinking | 同上 §5 |
| **实时行承载（本轮新增）** | tag 3 属于一个**合成 DisplayMessage**，`id` 固定为小字符串 `"thinking"`（8 字符，`0x10272d40c` 写入 `DisplayMessage.id`；role=assistant）。固定 id ⇒ 按 id 索引的消息列表里最多一条；transcript 构建器对 `id == "thinking"` 特判（比较函数 `0x102559b18`，4 个 caller；`0x1027a6efc` 命中时跳过） | 本轮新增，EVIDENCE |
| **持久/运行结论** | settled transcript 的持久思考行只有 tag 4（同一消息内每个连续 thinking run 一条；跨消息各自一条）；tag 3 是运行态合成行，不是历史行 | EVIDENCE-high |
| 时长格式化 | `Duration.UnitsFormatStyle`：allowed `{h,m,s}`、width `.narrow`、max 2 段、zero/fractional `.hide`、`Locale.autoupdatingCurrent`；`max(1, round(Δ))`。**只用于运行态行**（持久行固定 `思考过程`，不带时长） | `0x102a891bc`；§2.4 |
| 用户开关 | 不存在（35 个 bundle 全扫） | §1.4 |
| `_transcriptShowsThinkingRow` | 字段 42；offset slot `0x105a90d40`；**默认 false**；getter `0x102930f00` / setter `0x102930f14`（唯一写者 `0x102c4e968` ← `SessionTranscriptPane` 的 `onStagedThinkingRowChange`）。**不门控 tag 3/4**，只影响 `SessionMessageListFooter.body` 的一个条件子视图（`0x102934e54` → `!flag`） | round24 `flag-transcriptShowsThinkingRow.md` |

### 1.2 思考（Chat 页，仅作文案/交互对照）

- 行是 `CompactTimelineGroup.Item.Kind.thinking(summarized:)`，三态文案同 Chat 键；点击开 **sheet**，正文优先完整 thinking，为空才用 summaries 以 `"\n\n"` 连接 [E]。
- Code 页**不复用** Chat 行组件，只共享 working mark 与 `thought_process` 键 [E]。

### 1.3 工具分组（round21 已闭合）

- 同一 `Block.toolCalls` 内连续普通调用合成一个 span；**text 断组，`thinkingContent` 不断组**；`ExitPlanMode`/`AskUserQuestion` 跳过但不断组；special 段先 flush；无数量阈值；恒折叠、点击全屏 [E]。
- 摘要：类别首次出现序、`", "` 连接、无上限；文件类按去重路径计数，其余按调用 id；失败逐类内联 `(N failed)` / `（N 项失败）`；单条是动词+目标；`serverSummary` 非空整行替换（AA 无此数据）[E]。
- **跨 API assistant 消息合并：NO-MERGE [E，round24]**。assistant 行 id = SdkMessage payload `uuid`；一条 `SdkAssistantMessage` 只含一条 `APIAssistantMessage`；`processedRawMessages` 按同一 uuid 去重；`apiMessageIds` 只在构造时写成单元素 Set（全镜像无 insert/union 写点）；块合并 `0x102734e80` 只作用于本条消息自己的 blocks。⇒ 只有同一消息内的并行 `tool_use` 会合并；串行工具各自一行。

---

## 2. AA 现状

### 2.1 思考

| 环节 | 现状 | 证据 |
|---|---|---|
| connector 产出 | 实时流发布 reasoning 行 `running→done`；回合结束与历史导入共用 projector | `connector/.../timeline/stream.py:146-232`、`timeline/messages.py:367-514` |
| 持久化字段 | `content`: `kind/blockType/text/signature/parentItemId/usage`；**无 duration/summaries/startedAt/endedAt**（55.4k 行，0 命中） | 生产库；`aa-thinking-audit.md` §3 |
| 时间戳 | `createdAt/updatedAt` 持久化后几乎总相等（7,668/7,670）→ 不能算时长 | 同上 |
| Chat 页 | 折叠行显示完整正文（caption2、secondary、leading 24，可展开/双击收起） | `Views/Chat/SessionTimelineEventView.swift:108-121` |
| Code 页 | 四处丢弃：`renderRows` 239-240、`blockView` 159-163、adapter `hasVisibleBlock` 1362-1375、`planRows` 72/91；`CodeRowHeightPlan` 无 thinking 类型 | `aa-thinking-audit.md` §1.3 |
| 行 chrome 可复用 | `CodeCollapsedToolRow` 已是官方 `CollapsedRowButton` 形态：可选 `.large` 图标 + 15/400/21 文本 + caret + 垂直 padding 6 + minHeight 24 | `Views/Chat/Code/CodeCollapsedToolRow.swift:55-94` |
| 图标资产 | AA **没有** `anthropicon.extendedThinking`；官方资产在 `ClaudeDesignSystem_ClaudeIcons.bundle/Assets.car`，点尺寸 14/16/19（small/medium/large） | `anthropicon-map.tsv:140`、`claudeicons-assets.csv:146` |
| 性能副作用 | reasoning 每个 delta 改 wire revision → Code 组签名每帧变化 → 整行 reconfigure（画的是 EmptyView） | adapter:1660-1688 [I] |

### 2.2 工具分组

- 客户端分组键：`source.nativeMessageId ?? source.itemId`（`Models/Chat/TimelineGrouping.swift:108-164`、`CodeMessageTimeline.swift:54-56`）。
- connector `native_message_id` = 每条 API assistant message 的 `message.id`；并行工具共享，串行每次换新 id（`timeline/messages.py:2291-2354`、`2394-2409`）[E]。
- 服务端只做**单条消息内部**的 RBT 排序（`core/timeline.py:62-89`、`infra/repositories/timeline.py:2631-2681`），不做跨消息视觉分组 [E]。
- 生产库（17:00 快照）[E]：
  - 相邻 tool 行之间只有：reasoning 3,689 / assistant text 368 / user 160 / marker 4；
  - 全局时间线只有 tool 89,559 / system(reasoning) 55,427 / message 27,510 / marker 61；
  - `blockIndex` 在消息内连续 0..k-1（2,297/2,297、745/745、656/656）；
  - 跨消息合并已证伪（round24），scheduled-turn 的跨 turn 误合并风险随之消失。
- 生产数据的两类形态：WQo 88% 的消息只有 1 个 tool（串行，官方也各自一行）；QAhb 72% 的消息含 2+ tool（并行，同一消息内合并成一行）[E]。AA 现有 `nativeMessageId` 分组与官方一致。

---

## 3. 实施

### 3.1 思考块

**P1（iOS）：持久思考行 + 详情页（不依赖 connector）**

1. 模型：`CodeMessageRow.Block.reasoning(id:text:)` 加 `status`（done 才显示），并按官方合并规则把**同一消息组内**连续的多段 reasoning 合成**一个** thinking 块：文本用 `[old, new].filter{!isEmpty}.joined(separator: "\n\n")`（官方 `0x1027365f0`）；跳过 toolCalls 合并、text 等块断开；跨消息不合并；`redacted_thinking` 不产出。合并由 `CodeMessageBuilder.messageRow` 在消息组内完成。
2. 视图：新 `CodeThinkingRow`，视觉照官方 `CollapsedRowButton`：`anthropicon.extendedThinking`（**渲染 `.medium`，基准 20pt**）+ **固定标签 `思考过程`** + caret；文本 15/400/21 默认 label 色；图标/caret 动态灰 light ≈ #7B7974 / dark ≈ #97958D；`IconFrame` style `.plain` / size `.regular` / isFramed=true；垂直 padding 6、minHeight 24。可复用 `CodeCollapsedToolRow` 的常量，但用独立视图（无 verb/target/diff 语义）。
3. 详情：新 `CodeThinkingDetailView`（NavigationStack + ScrollView + `ChatMarkdownView`，标题 `思考过程`）。官方是 **sheet（`.presentationDetents` medium/large）+ 内部 NavigationStack**，AA 现有页面级 `.sheet(item:)` 正好同形态；把思考/工具详情统一成 `CodePageDetail` enum（`TimelineChatTimelineView.swift:193-198,225,244-246`），避免同视图双 sheet，并补 `.presentationDetents([.medium,.large])`。
4. `CodeMessageRowView`：`renderRows` 不再过滤 `.reasoning`；`blockView` 的 `.reasoning` 换成 `CodeThinkingRow`；新增 `onThinkingDetail` 回调（照 `onToolDetail` 机制，`CodeMessageRowView.swift:57-72,234-250`）。
5. 高度：`CodeMessageHeightMeasurer.planRows` 不再跳过 reasoning；`CodeRowHeightPlan.Block` 加 `.thinking`，按 `toolLineHeight + 2*toolButtonPadding` 计一行（`CodePageTheme.swift:51,71`）。
6. 签名/性能：adapter `groupSignature` 的 reasoning 行改用 `id + status`，不用 wire `revision`；`hasVisibleBlock` 对 reasoning 返回 true；`codeHeightDigest` 纳入 thinking 行的存在性。
7. 思考行只在 `status == done` 时显示；running 期间由 turn 级 working 行负责（避免流式行反复出现/消失）。

**P2（iOS，官方运行态对齐，可与 P1 同批）**：工作行的思考态文案。

1. 现状：`CodeWorkingStatusRow` 用 20 动词轮换（R20）。官方 tag 3 在**有思考时间戳**时改走 5 档思考文案（`0x102a89080`，阈值 15/30/45/60s），闭合后显示 `思考了 X`（`0x102cda6dc`）。
2. 已闭合的字段对位（round24）：进行中 elapsed = **now − turnStartedAt**（截断取整、`max(x,0)` 钳零），不是 blockStartedAt；5 档 `≤14/≤29/≤44/≤59/else`。AA 用 working 行的回合开始时刻做锚点，检测到 running reasoning 时进思考态。
3. 闭合：duration = **lastBlock.endedAt − lastBlock.startedAt**（不是 turnStartedAt→endedAt），四舍五入（half away）后 `max(1,n)`；**只有 now < endedAt + 2 秒才显示「思考了 X」**，超过 2 秒回退普通工作行（官方 `0x102a88f20-f50` 的 2 秒窗）。
4. 时长格式化：`Duration.UnitsFormatStyle` 照官方参数（allowed `{h,m,s}`、width `.narrow`、`maximumUnitCount=2`、zero/fractional `.hide`、locale `autoupdatingCurrent`）；中文预期 `1分钟3秒`（iOS ICU 是否带空格以真机为准）。
5. 这是**运行态合成行**，不持久；不要在历史行上显示时长。

**P3（可选扩展，非官方）**：若 pp 要在历史持久行也看到 `思考了 X`，才需要 connector 在 reasoning content 补 `durationMs`（content 自由 JSON，server/契约零改动；实现点见旧稿：`stream.py` 记录 monotonic 起止、`messages.py::reasoning_item` 写入、`system_items_for_message` 重投影同步）。官方不做，默认不做。

**开关**：官方无用户设置 [E]。**不新增开关**，默认显示；若 pp 日后要，按 `@AppStorage("aa.code.thinkingRow")` 两态（`full`/`compact`，不提供完全隐藏）。

### 3.2 工具分组（官方 NO-MERGE：不改分组，只补文案）

- 工具分组逻辑**不改**：`TimelineGrouping`/`CodeMessageBuilder` 继续按 `nativeMessageId ?? itemId` 分组；同一消息内的并行 `tool_use` 已经合并成 span，串行工具各自一行——与官方 EVIDENCE 一致。
- 不做跨消息 planner / `toolGroupKey` / 服务端重打包；scheduled-turn 风险消失。
- **唯一与工具相关的改动**是文案差距（下面四条）。
- **思考合并只在一个消息组内**：`CodeMessageBuilder.messageRow` 把同一 `nativeMessageId` 下、中间只隔工具行的多个 reasoning item 合并成一个 thinking 块（官方 `0x1027365f0` 跳 tag2 合并；text 断开；跨消息不合并）；`redacted_thinking` 不产出。

**同批文案修复（iOS PATCH）**：

- 失败后缀 `(N failed)` / `（N 项失败）`：`CodeToolLabelPlan.Phrase` 加 failed 字段、`CodeCollapsedToolRow` 加 failed 参数、补本地化 key；计数语义按 round21 §1.11。
- 分隔符：`ccr_summary_separator` 的中文值从 `，` 改回官方硬编码 `", "`（`CodeMessageRowView.swift:390`；round21 §1.5）。
- 单目标判定：从“同一文件/同一路径”放宽到官方“所有 call 的 target 相同”（`CodeToolLabelPlan.swift:90-93,182-194`）。
- diff 聚合：跳过 failed 与 `fileWriteKind==update`；任一 call 不是 diff/失败/更新 → 整组不显示（round21 §2.6）。AA wire 无 `fileWriteKind`，用 Write 结果文案推导：`File created successfully at:` → create、`The file … has been updated successfully` → update（生产库实测 1110/24，2026-10-25）；不匹配一律 nil，维持 Created/计入徽标。同一 kind 也用于 Write 动词 `Updated / 已更新`（`ccr_write_updated`，官方 IPA 1.261019.51 `ModuleStrings2.strings` 直读）。运行中的 update Write 无提前信号，仍显示 Creating。
- Write 动词：create → `Created / 已创建`（沿用 `ccr_verb_created`），update → `Updated / 已更新`（`ccr_write_updated`）；kind 推导同 diff 聚合。官方运行态 update 用 `ccr_running_editing`，但 AA 只有结果文案这一个信号，运行中仍为 Creating。
- `serverSummary` / `receivedMessages` **不做**：AA 无数据源，伪造违反“宁缺勿假”。

### 3.3 关闭按钮（pp 2026-10-25 指出的顺带修复）

- 现状：`CodeToolDetailView.swift` 自绘 `Image(systemName: "xmark")`（13pt semibold）+ 30pt 圆底（`primary.opacity(0.08)`），非官方件。
- 官方详情 sheet 的关闭按钮是 `ClaudeCoreUI.DismissButton`（toolbar）——iOS 26+ 直接用**系统 `Button(role: .close)`**（圆形玻璃 X），不是 `DismissXButton.floating` 自绘件。
- AA 部署目标已是 **iOS 26.2**，仓库已有 `SheetCloseToolbar` / `SheetCloseButton`（`Views/Components/SheetCloseButton.swift`，`Button(role: .close)`）。⇒ 工具/思考详情统一改用 `SheetCloseToolbar { dismiss() }`，删掉自绘按钮与 30pt 圆底常量；不需要 `anthropicon.x` 资产。
- 注意：官方详情是 sheet + 内部 NavigationStack（思考已证；工具详情同形态），sheet 形态才需要这个关闭按钮。

### 3.4 官方图标资产

- 已提取：`/home/ubuntu/aa-test/probe-round24/official-svg/extendedThinking.A.svg`（2020 B，md5 `286ae7ac45f6f0112d1b4c710ec61b4f`，viewBox `0 0 12.0797 12.0797`，ink-tight；A 变体与 AA 现有 21 个资产同风格）。来源 build 1.261005.20；与 1.261019.51 的同名 A SVG md5 完全相同。
- 已加入 `Assets.xcassets/anthropicon.extendedThinking.imageset/`（Contents.json + SVG，vector/template）与 `AnthropiconAssets.swift` 尺寸表：`14x14 / 16x16 / 19x19`（small/medium/large）；官方渲染 `.medium` → 16×16 artwork。
- 不再需要 `anthropicon.x`（关闭按钮走系统 close role）。

### 3.5 长 Read 输出空白（pp 2026-10-25 真机）

- **现象**：打开 Read 详情（`EVIDENCE/round21/chrome-verify.md`），输入正常，输出卡片一大块空白；重开仍空（不是运行中快照）。
- **数据已排除**：生产库 `sess_qosBVhTaWaxUeQ` 的该行 `content.output` 完整（24,753 字符、298 行、无 NUL）；`timeline?mode=history` 同样返回完整 output；不是数据丢失、不是 deferred stub。
- **定位**：同一个 `CodeToolCodeCard` 渲染短 Input 正常；长输出卡片高度按 298 行撑开但无字形 → 长文本渲染路径问题。AA 的通用 `.text` 输出走横向 `ScrollView` + `Text.fixedSize(horizontal: true)` + `.textSelection(.enabled)`；官方 Read 走专用 `FileReadDetailView`（`CANONICAL/04` §3、`EVIDENCE/round14/tool-output.md` §4.3；Body `0x102c817e4`），分支含 `CodeBlockContent` / `RenderedMarkdownView` / `PagedDiffRows(readDiff)`。
- **修法**：为 `kind == .read` 新增 `CodeFileReadOutputView`（纵向文本阅读器：等宽、可滚动/可复制；不再用横向 fixedSize + textSelection），先保证长文本可见；官方 `readDiff` / renderMarkdown / loadFullFile 分支后续补齐。非 Read 的 `.text` 输出暂不动。
- **门禁**：`CodeProfileAutoRun` 增加 24K/298 行 Read output fixture（断言输出视图非空、高度有限）；真机复测同一条 Read。

---

## 4. 测试与验收

### 4.1 自动门禁

- `CodeMessageBuilder` 单测（`ios/Tests/ClientCoreTests/CodeProfileModelTests.swift`）新增矩阵：
  - **三条不同消息的 tool-only 行 → 3 行**（守卫：绝不跨消息合并）；
  - 同一消息内 3 个并行 tool → 1 行/1 span，call 顺序 = `blockIndex`；
  - 同一消息内多段 thinking、中间只隔工具调用 → 合并成 1 个 thinking 块/1 条「思考过程」行；
  - thinking 被 text 隔开 → 2 个 thinking 块/2 条行；跨消息的 thinking → 各自 1 个（不合并）；`redacted_thinking` 不产出行；
  - 工具行/思考行的文案矩阵（失败后缀、分隔符、单目标判定、diff 聚合）。
- 思考行：`CodeProfileAutoRun` 新增 fixture——done（显示 `思考过程`）/ running（不显示）；断言 `expectedBlocks`、标签文案、行高。
- P2 运行态：注入时钟的纯函数单测（0/14/15/29/30/44/45/59/60s 档位、闭合 `思考了 X`、zh/en 输出）；`CodeProfileAutoRun` 加一条 working 行 fixture。
- **长 Read 输出**：`CodeProfileAutoRun` 加 24K/298 行 Read fixture，断言输出视图非空、高度有限；短输出仍走同一路径。
- `code-profile` gate（`.github/workflows/ios-build.yml`，`code_profile: true`）新增 fixture：同一消息 3 个并行 tool → 1 span；三条串行消息 → 3 行；thinking row 文案。
- 本地：`swift test --package-path ios`（相关用例）；CI 为权威门禁。

### 4.2 真机验收判据（pp）

1. 工具分组：同一消息的并行 3 个工具 → **1 行**；串行 3 次工具（不同消息）→ **3 行**（与官方一致）；点击各行详情正确。
2. 思考行：思考中工作行显示思考态文案（P2）；闭合后工作行短暂显示 `思考了 X`（运行态合成行，随回合结束消失）；持久行始终是 `思考过程`，点击显示完整思考正文，标题也是 `思考过程`。
3. 滚动/流式：工具行合并增长时不跳位、文字不闪；底部跟随正常。
4. 失败工具：label 带 `(N failed)` / `（N 项失败）`。
5. 深色/大字号/中英文：思考行与工具行不破版。

---

## 5. 风险与未决

| # | 风险/未决 | 级别 | 处理 |
|---|---|---|---|
| 1 | ~~`_transcriptShowsThinkingRow`~~ **已闭合**：默认 false，只影响 footer 子视图，不门控思考行 | — | 不需要开关/适配 |
| 2 | “tag 3 是固定 id `thinking` 的合成行”是静态证据（id 写入 + 构建器特判），未做运行时观察 | P1 | 若真机出现两条持久思考，按本行回退为“只保留 tag 4 持久行”；当前按 [EVIDENCE-high] 执行 |
| 3 | ~~官方详情是全屏 push~~ **已更正**：官方是 sheet（`.presentationDetents` medium/large + 内部 NavigationStack），AA 现有页面级 sheet 同形态；sheet 挂载点 UNKNOWN | P2 | 补 `.presentationDetents([.medium,.large])`；真机对照 |
| 4 | P2 的 `turnStartedAt` 在 AA 侧的对应（working 行需在回合开始记锚点；重进/后台会丢） | P2 | 客户端在回合开始记锚点；官方同样只在运行态显示，可接受 |
| 5 | P2 运行态时长在刷新/重进后不可重现（客户端计时） | P2 | 官方同样只在运行态显示；持久行固定 `思考过程`，可接受 |
| 6 | 官方 `Block.thinking`/narration 在 AA 无对应行，断组语义有差异 | P2 | 现有数据无样本；记录，不猜 |
| 7 | 其它 runtime：思考行对 Codex 也会开始显示（connector 有 reasoning 投影）；DSH 无数据不受影响 | P1 | 有意通用；用 Codex fixture 验证文案/高度 |
| 8 | tag4 合并的上游**重复帧去重** UNKNOWN（合并函数本身只滤空串、不查重） | P2 | 现有 connector 不重发同一 thinking 文本；真机若出现 `x\n\nx` 再追上游 |

---

## 6. 文件清单（预计改动）

**iOS（P1 + B + 文案）**

- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeMessageTimeline.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeRowHeightPlan.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeToolLabelPlan.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMessageRowView.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeToolDetailView.swift`（关闭按钮）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeToolOutputViews.swift`（长 Read 输出）
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeToolOutput.swift`（Read 输出分类）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeThinkingRow.swift`（新）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeThinkingDetailView.swift`（新）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeCollapsedToolRow.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMessageHeightMeasurer.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeWorkingStatusRow.swift`（P2）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatTimelineView.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Components/AnthropiconAssets.swift`
- `ios/Agents Anywhere/Agents Anywhere/Assets.xcassets/anthropicon.extendedThinking.imageset/`（新）
- `ios/Agents Anywhere/Agents Anywhere/Resources/Localization/Localizable.xcstrings`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeProfileAutoRun.swift`
- `ios/Tests/ClientCoreTests/CodeProfileModelTests.swift`

**不做**：connector/server/contracts/其它端（P1/P2 纯 iOS；思考时长只在运行态，由客户端计时）。P3（历史时长）若 pp 要，另开 connector 项。
