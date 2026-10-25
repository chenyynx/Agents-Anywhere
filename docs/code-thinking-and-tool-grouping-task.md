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

---

## 0. 给 pp 的一屏结论

### 思考块：官方有两个代码路径，但持久层只有一套

- **tag 3 `Block.thinking(WorkingStatus?, activity, turnStartedAt)` → `CodeThinkingView`**（每 turn 一条，实时行）[E]：
  - 思考进行中：5 档递增文案，阈值直读 `0x102a89080`：0–14s `thinking…` / 15–29s `still thinking…` / 30–44s `thinking more…` / 45–59s `thinking some more…` / ≥60s `almost done thinking…`；
  - 闭合：`thinking_status_thought_for_duration` = `thought for %@` / `思考了 %@`（构造点 `0x102cda6dc`）；
  - 无思考时间戳：退回 20 动词工作行（R20 已实现）。
- **tag 4 `Block.thinkingContent(String)` → `ThinkingContentRow`**（每个 thinking block 一条，持久行）[E]：固定图标 `anthropicon.extendedThinking` + `thought_process`（`Thought process` / `思考过程`）+ caret；点击 → **全屏 push 详情页**，正文是完整思考 markdown，页头同为 `思考过程`。
- **原始思考正文不在 transcript 内联**，只在详情页 [E+INFERENCE-high]。
- `_transcriptShowsThinkingRow`：交接里的 accessor `0x10292dd9c` **是误读**（它是 `SessionModel` 的 type metadata accessor，24 个 caller 都是 metadata 消费者）；getter/setter、默认值、门控对象 **UNKNOWN**。全 App 35 个 bundle 扫描，**没有任何用户可见的“显示思考”设置** [E]。
- **“会不会出现两套思考”已闭合：不会。** tag 3 的承载者是一个**合成 DisplayMessage，id 固定为 `"thinking"`**（`0x10272d40c` 把 8 字符小字符串 `thinking` 写进 DisplayMessage 第一字段 `id`；role=assistant；`DisplayMessage.id` 字段序见 `swift_types.csv:49347`）。固定 id 在按 id 索引的消息列表里**最多只能存在一条**，所以它是运行态合成行，不是每 turn 持久化的历史行；多个 transcript 构建函数对 `id == "thinking"` 做特判（比较函数 `0x102559b18`，4 个 caller；`0x1027a6efc` 在命中时跳过该消息）[E]。**settled transcript 的持久思考行只有 tag 4**（每条 thinking block 一条「思考过程」）。
- **AA 落码因此改成严格官方**：持久行 = `思考过程`（tag 4 形态）+ 点击看全文；`思考了 X` 只在运行态工作行出现（tag 3 形态，客户端计时），回合结束随合成行消失。**不需要 connector 补时长**；历史里官方本来就不显示“思考了 X” [E]。
- 时长格式化照官方 `Duration.UnitsFormatStyle`（h/m/s、`.narrow`、最多 2 段、零值/小数隐藏、locale `autoupdatingCurrent`、最小 1 秒、闭合四舍五入）——63s → `1分钟3秒` / `1m 3s`，与 pp 截图一致 [E]；只用于运行态行。
- 官方详情是全屏 push；AA 现有工具详情是页面级 sheet（`TimelineChatTimelineView.swift:193`）。思考详情跟随 AA 现有工具详情用同一个 sheet，避免同页双 sheet——**有意偏离，标 [I]**。

### 工具分组

- 交接里的根因**需要修正**：不是“每条 tool 行 `native_message_id` 都不同”。并行工具（同一 API 响应多个 `tool_use`）共享 id，生产库 12%–72% 的消息含 2+ 工具，最多 12 个 [E]。真正缺口是**串行工具循环**：每次工具结果触发下一次 API 往返 → 新 message id → 客户端每组只有 1 个 call → 一次一行 [E]。
- **建议方案 B（纯 iOS，PATCH）**：按 `orderSeq` 的行序列合并连续 tool 行，reasoning 透明，text/user/marker/无 key 行断开；span id 取第一个 tool 的 `source.itemId`。估算 WQo 会话 2,297 个工具消息组 → 约 187 个 span [E]/[I]。
- 同批补齐官方文案差距：失败后缀 `(N failed)`/`（N 项失败）`、分隔符改官方 `", "`、单目标判定（all-same-target）、diff 聚合规则 [E]。
- **不做 A/C**：A（新增跨端 `source.toolGroupKey`）是 MINOR 契约、全端版本升级、live/history key 一致性成本高；C（服务端重打包）风险最大。B 的 planner 预留 `groupingKey` seam，将来若批准 A 只换数据源、不重写 UI [I]。
- **仍有一处官方未闭合**：官方是否跨多条 API 消息合并工具，目前是 [I]（约 60%）。RE-1 没有闭合消息级合并写点；若后续证伪，B 降级为“只补文案，不跨消息合并”。

---

## 1. 官方事实

### 1.1 思考（Code 页）

| 项 | 结论 | 证据 |
|---|---|---|
| 实时行视图 | `CodeThinkingView`，Body `0x102a83210`；每 turn 一条 | `code-thinking-row.md` §2.1 |
| 实时行三态 | 闭合 → `thought for %@`；进行中 → 5 档文案；无时间戳 → 20 动词 | `0x102a88dfc`、`0x102a89080`；§2.2/§2.3 |
| 进行中阈值 | 15 / 30 / 45 / 60 s（截断取整） | `0x102a89118–58` |
| 5 档文案 key | `thinking_status_thinking` / `still_thinking` / `thinking_more` / `thinking_some_more` / `almost_done_thinking` | `code-page-strings.csv:516-520` |
| 持久行视图 | `ThinkingContentRow`，Body `0x102c6ba54`；每个 thinking block 一条 | `code-thinking-row.md` §3.1 |
| 持久行内容 | `extendedThinking` 图标（`.large`）+ `Thought process`/`思考过程` + caret；无正文 | `0x102c6bad4`；`anthropicon-map.tsv:140` |
| 点击 | `presentDetail(.thinkingText(text))` → `NavigationStack` push 全屏页，markdown 正文，标题 `思考过程` | INFERENCE-high；§3.2/§3.3 |
| 正文内联 | **没有**任何路径在 transcript 内联 raw thinking | §5 |
| **实时行承载（本轮新增）** | tag 3 属于一个**合成 DisplayMessage**，`id` 固定为小字符串 `"thinking"`（8 字符，`0x10272d40c` 写入 `DisplayMessage.id`；role=assistant）。固定 id ⇒ 按 id 索引的消息列表里最多一条；transcript 构建器对 `id == "thinking"` 特判（比较函数 `0x102559b18`，4 个 caller；`0x1027a6efc` 命中时跳过） | 本轮新增，EVIDENCE |
| **持久/运行结论** | settled transcript 的持久思考行只有 tag 4（每 thinking block 一条）；tag 3 是运行态合成行，不是历史行 | EVIDENCE-high |
| 时长格式化 | `Duration.UnitsFormatStyle`：allowed `{h,m,s}`、width `.narrow`、max 2 段、zero/fractional `.hide`、`Locale.autoupdatingCurrent`；`max(1, round(Δ))`。**只用于运行态行**（持久行固定 `思考过程`，不带时长） | `0x102a891bc`；§2.4 |
| 用户开关 | 不存在（35 个 bundle 全扫） | §1.4 |
| `_transcriptShowsThinkingRow` | 字段存在（CSV 51024）；getter/setter/默认值/门控 UNKNOWN；不在 `DisplayBlockView`/`SessionMessageStyle` 内，若门控只能在上游 | §1.2–1.5 |

### 1.2 思考（Chat 页，仅作文案/交互对照）

- 行是 `CompactTimelineGroup.Item.Kind.thinking(summarized:)`，三态文案同 Chat 键；点击开 **sheet**，正文优先完整 thinking，为空才用 summaries 以 `"\n\n"` 连接 [E]。
- Code 页**不复用** Chat 行组件，只共享 working mark 与 `thought_process` 键 [E]。

### 1.3 工具分组（round21 已闭合）

- 同一 `Block.toolCalls` 内连续普通调用合成一个 span；**text 断组，`thinkingContent` 不断组**；`ExitPlanMode`/`AskUserQuestion` 跳过但不断组；special 段先 flush；无数量阈值；恒折叠、点击全屏 [E]。
- 摘要：类别首次出现序、`", "` 连接、无上限；文件类按去重路径计数，其余按调用 id；失败逐类内联 `(N failed)` / `（N 项失败）`；单条是动词+目标；`serverSummary` 非空整行替换（AA 无此数据）[E]。
- **跨 API assistant 消息是否合并**：`DisplayMessage.apiMessageIds: Set` + 块合并函数 `0x102734e80` 回扫跳过 `thinkingContent` 指向“会合并”，但消息级写点静态不可归因，仍为 [I]（约 60%）[U]。

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
  - 跨 turn 的相邻 tool 对之间都有 user 行（38/6/60 对），但 **scheduled turn 无 user 行**（`docs/claude-scheduled-tasks.md:24`、`turns/lifecycle.py:2754`）→ B 的残余风险。
- 根因不是“id 全不同”：WQo 88% 的消息只有 1 个 tool（串行），QAhb 72% 的消息含 2+ tool（并行）；视觉上“一次一行”来自串行片段 [E]。

---

## 3. 实施

### 3.1 思考块

**P1（iOS）：持久思考行 + 详情页（不依赖 connector）**

1. 模型：`CodeMessageRow.Block.reasoning(id:text:)` 不变（只加 `status` 用于“done 才显示”）；`CodeMessageBuilder.messageRow` 不动文案。
2. 视图：新 `CodeThinkingRow`，视觉照官方 `CollapsedRowButton`：`anthropicon.extendedThinking`（`.large`）+ **固定标签 `思考过程`** + caret，15/400/21，垂直 padding 6、minHeight 24。可复用 `CodeCollapsedToolRow` 的常量，但用独立视图（无 verb/target/diff 语义）。
3. 详情：新 `CodeThinkingDetailView`（NavigationStack + ScrollView + `ChatMarkdownView`，标题 `思考过程`）。页面级 `.sheet(item:)` 与工具详情统一成 `CodePageDetail` enum（`TimelineChatTimelineView.swift:193-198,225,244-246`），避免同视图双 sheet。
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

### 3.2 工具分组（方案 B，纯 iOS）

1. 新共享 planner（`CodeMessageTimeline.swift`）：按 `orderSeq` 的行序列产出 unit：
   - tool 行有分组键 → 并入 open span；
   - reasoning → 透明，不 flush；**保留它在 wire 中的位置**（span 锚定在第一个 tool 行的位置：R1, span(T1,T2), R2）；
   - assistant/user text、marker、非 stackable、无 key 行、interaction target → flush，自己成行；
   - 不跨 user 行；当前拿不到 `turnId`（生产库 0/172,707 行），scheduled turn 无 user 行是已知风险。
2. `TimelineGrouping.codeGroups` 复用同一 planner；span 的 `explicitID = "span:" + 第一个 tool 的 source.itemId`（tool_use id 全局唯一）；`messageHasContent` 按 unit 判断。
3. `CodeMessageBuilder.orderedToolRows`：跨消息时按 wire `orderSeq`，**不要**全局按 `blockIndex`（每条消息从 0 开始，会交错）；单消息内保持 blockIndex 规则。
4. `CodeMessageRowView`/`CodeMessageHeightMeasurer` 复用 builder，无需重写算法；`codeHeightDigest` 仍只哈希 segments 数（span 恒一行）。
5. 保留 `groupKey` seam：将来 A 方案只把 `source.toolGroupKey` 插到优先级最前。
6. **runtime 门控**：跨消息合并先只对 Claude 开启；`CodeRuntimeProfile` 加一个 `mergesToolRowsAcrossMessages`（Claude=true，Codex/DSH=false），关闭时完全保持现状。思考行不门控（有 reasoning 就渲染：Claude/Codex 生效，DSH 无数据自然不显示）。

**同批文案修复（iOS PATCH）**：

- 失败后缀 `(N failed)` / `（N 项失败）`：`CodeToolLabelPlan.Phrase` 加 failed 字段、`CodeCollapsedToolRow` 加 failed 参数、补本地化 key；计数语义按 round21 §1.11。
- 分隔符：`ccr_summary_separator` 的中文值从 `，` 改回官方硬编码 `", "`（`CodeMessageRowView.swift:390`；round21 §1.5）。
- 单目标判定：从“同一文件/同一路径”放宽到官方“所有 call 的 target 相同”（`CodeToolLabelPlan.swift:90-93,182-194`）。
- diff 聚合：跳过 failed 与 `fileWriteKind==update`；任一 call 不是 diff/失败/更新 → 整组不显示（round21 §2.6）。
- `serverSummary` / `receivedMessages` **不做**：AA 无数据源，伪造违反“宁缺勿假”。

### 3.3 关闭按钮（pp 2026-10-25 指出的顺带修复）

- 现状：`CodeToolDetailView.swift:232-247` 自绘 `Image(systemName: "xmark")`（13pt semibold）+ 30pt 圆底（`primary.opacity(0.08)`），非官方件。
- 官方：`ClaudeCoreUI.DismissXButton`（`title/appearance/action`；`Appearance.plain/.floating`；`DismissXButtonStyle` + `DismissXAppearance`；`swift_types.csv:13729-13735`）。
- 待 patch `dismiss-x-button` 反编译给出图标源/字号字重/圆底/阴影/尺寸后，按官方 `.floating`（或 sheet 场景对应的 appearance）1:1 替换。
- 注意：官方工具详情是 push 页（有返回箭头）；AA 用页面级 sheet 才需要这个 X，外观仍按官方 `DismissXButton`。

### 3.4 官方图标资产

- 从 `ClaudeDesignSystem_ClaudeIcons.bundle/Assets.car` 提取 `anthropicon.extendedThinking` 的 A 变体 SVG（方法同 `EVIDENCE/round20/code-card-icons.md` §3.2：LZFSE `bvxn` 解包，3 个 SVG 变体；用 A）。
- 新增 `Assets.xcassets/anthropicon.extendedThinking.imageset/`（Contents.json + SVG）与 `AnthropiconAssets.swift` 尺寸表：`14x14 / 16x16 / 19x19`（small/medium/large）。

---

## 4. 测试与验收

### 4.1 自动门禁

- `CodeMessageBuilder` 单测（`ios/Tests/ClientCoreTests/CodeProfileModelTests.swift`）新增矩阵：
  - 三条 tool-only 消息 + reasoning 中间 → 1 行/1 span，call 顺序 = orderSeq；
  - text/user/marker 中间 → 2 行；无 key 行 → 断开；interaction target → standalone；
  - skip 不 flush；special flush；A-B-A 交错 → 1 span 且顺序正确；同一 unit 再规划幂等。
- 思考行：`CodeProfileAutoRun` 新增 fixture——done（显示 `思考过程`）/ running（不显示）；断言 `expectedBlocks`、标签文案、行高。
- P2 运行态：注入时钟的纯函数单测（0/14/15/29/30/44/45/59/60s 档位、闭合 `思考了 X`、zh/en 输出）；`CodeProfileAutoRun` 加一条 working 行 fixture。
- `code-profile` gate（`.github/workflows/ios-build.yml`，`code_profile: true`）新增 fixture：`rowCount == 1`、`segments == ["span(t1,t2,t3)"]`、thinking row 文案。
- 本地：`swift test --package-path ios`（相关用例）；CI 为权威门禁。

### 4.2 真机验收判据（pp）

1. 串行 3 个工具：应逐步长成 **1 行**（不是 3 行），label 随类别更新；点击详情包含全部 calls。
2. 思考行：思考中工作行显示思考态文案（P2）；闭合后工作行短暂显示 `思考了 X`（运行态合成行，随回合结束消失）；持久行始终是 `思考过程`，点击显示完整思考正文，标题也是 `思考过程`。
3. 滚动/流式：工具行合并增长时不跳位、文字不闪；底部跟随正常。
4. 失败工具：label 带 `(N failed)` / `（N 项失败）`。
5. 深色/大字号/中英文：思考行与工具行不破版。

---

## 5. 风险与未决

| # | 风险/未决 | 级别 | 处理 |
|---|---|---|---|
| 1 | 官方是否跨 API 消息合并工具仍是 [I]（~60%） | P1 | 若证伪，B 降级为“不跨消息合并、只补文案”；本单先按 [I] 执行，真机对照官方 |
| 2 | scheduled turn 无 user 行 → B 可能跨 turn 合并 | P1 | 生产频率 [U]；先接受并记录；必要时后续批准 `source.turnId` 透传（小契约改动） |
| 3 | `_transcriptShowsThinkingRow` 默认值/门控对象 UNKNOWN | P1 | 不依赖它：AA 按 pp 要求默认显示；若后续证出官方默认隐藏，再加开关 |
| 4 | “tag 3 是固定 id `thinking` 的合成行”是静态证据（id 写入 + 构建器特判），未做运行时观察 | P1 | 若真机出现两条持久思考，按本行回退为“只保留 tag 4 持久行”；当前按 [EVIDENCE-high] 执行 |
| 5 | 官方详情是全屏 push，AA 用页面级 sheet | P2 | 跟随 AA 现有工具详情交互；若后续统一成全屏，工具/思考一起改 |
| 6 | P2 的 `turnStartedAt` 在 AA 侧的对应（working 行需在回合开始记锚点；重进/后台会丢） | P2 | 客户端在回合开始记锚点；官方同样只在运行态显示，可接受 |
| 7 | P2 运行态时长在刷新/重进后不可重现（客户端计时） | P2 | 官方同样只在运行态显示；持久行固定 `思考过程`，可接受 |
| 8 | 官方 `Block.thinking`/narration 在 AA 无对应行，断组语义有差异 | P2 | 现有数据无样本；记录，不猜 |
| 9 | A 方案（跨端 `toolGroupKey`） | 后续 | 需 pp 批契约；B 留 seam，不重写 UI |
| 10 | 其它 runtime：思考行对 Codex 也会开始显示（connector 有 reasoning 投影）；DSH 无数据不受影响 | P1 | 有意通用；用 Codex fixture 验证文案/高度 |
| 11 | 跨消息合并对 Codex/DSH 的形态未验证 | P1 | profile flag `mergesToolRowsAcrossMessages` 先只开 Claude，其它 runtime 保持现状 |

---

## 6. 文件清单（预计改动）

**iOS（P1 + B + 文案）**

- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeMessageTimeline.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeRowHeightPlan.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/TimelineGrouping.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeToolLabelPlan.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeRuntimeProfile.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeToolSegments.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMessageRowView.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeToolDetailView.swift`（关闭按钮）
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
