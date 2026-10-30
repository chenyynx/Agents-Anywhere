# 子代理入口与面板：圆形玻璃 + 胶囊列表 + 对话详情（AA 魔改版）

> 级别：**L**（入口 + 面板两个面，视觉重做 + 详情渲染面替换）
> 基线：`feat/code-profile-beta @ bae413aa`（2026-10-30）
> 分支：`feat/subagent-session-card`
> pp 2026-10-30 定：**不对齐官方 ChildSessionCard**；视觉全部用 Claude 官方资产（图标/字体/颜色/思考与工具行），布局按本单魔改。
> 参考图：`/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_4Dkq5-AjhKdM7A/file_Yks099C4i7nfrQn-Photo-3F574DAF.png`（列表）、`file_Yh3zGKsJKSoAd2gi-Photo-2A88A9EC.png`（详情）

---

## 1. 目标 / 非目标

### 1.1 目标

1. **悬浮入口**：现有长条玻璃胶囊 → **圆形液态玻璃按钮**，位置移到输入框上方**靠右**；去掉文字与 chevron，只留官方资产图标。
2. **点开永远先出列表**：即使只有一个子代理，也先显示图 1 的胶囊列表。
3. **列表页**：每个子代理一个大圆角胶囊行（圆形官方图标 + 标题 + 状态副标题），多个往下排。
4. **详情页**：点某一行 → 图 2 的对话式内容（提示词气泡 + 正文 + 思考结果行 + 工具行 + 底部停止）。
5. **保留现有功能**：stats（tokens/耗时/工具数）、多任务停止控件、运行中实时更新、失败状态、点击工具行进入的详情。
6. Code + Chat 两个 profile 共用同一套入口与面板。

### 1.2 非目标

- 不参照官方 `ChildSessionCard` 的卡片布局、圆角、阴影、状态 glyph（前一轮已撤）。
- 不改 connector / server wire；不新增字段。
- 不删除旧 Chat 容器（步骤组任务单 §10 另开单）。
- 不改主时间线里 `agent_call` 工具行本身的渲染（Code 页保持现状）。

---

## 2. 现状（基线 `bae413aa`）

- `SubAgentCapsule`：36pt 玻璃长条，图标 + 标题 + chevron，作为 composer dock 第一行、水平居中（`Views/Chat/SubAgentCapsule.swift`；`SessionChatView.swift:92-95`）。
- `SubAgentPanelSheet`：NavigationStack sheet；`statsRow`（phase 徽章 + tokens/耗时）+ chip strip（多卡切换）+ prompt 段 + 活动列表（`SessionTimelineRow`，旧 Chat 行）+ 最终输出；停止控件在 stats 行尾部（`Views/Chat/SubAgentPanelSheet.swift`）。
- 胶囊显隐：顶层活跃卡（`running/starting`）才显示；卡片结束即退场（`SubAgentProgress.capsuleState`）。
- 主时间线的工具调用行仍显示该 agent 调用；**当前主时间线不提供从工具行打开面板的入口**（entry B 路由保留，但只有旧 Chat 容器/兜底会调用）。这是既有缺口，本单不扩范围。

---

## 3. 目标设计

### 3.1 悬浮圆形按钮

**位置**
- 仍在 composer dock 内，作为 composer 上方第一行；改为 **HStack + Spacer + 按钮**，右对齐。
- 视觉圆 40×40，点击区 44×44；右侧内边距与 composer 同步（`controls.horizontalInset(expanded:)`，收拢 18 / 展开 9）。
- 不悬浮覆盖时间线；占用自己一行（和现在一样），键盘弹起随 dock 上移。

**材质与图标**
- `.glassEffect(.regular.interactive(), in: .circle)`（液态玻璃；沿用现有 iOS 26 API）。
- 图标：**官方 `anthropicon.agent`**（从官方 1023 IPA 提取；见 §5）。按官方 `.large` 美术尺寸 18×19 绘制，居中。
- 无文字、无 chevron。

**状态**
- 运行中（1 个）：玻璃圆 + 官方 agent 图标（静态；不加自定义动画）。
- 失败（最新一批）：玻璃/图标红色 tint（沿用现有 `SubAgentPalette.failure`）。
- 多个运行中：右上角小数字角标（14pt 圆，数字 9pt semibold），显示运行中数量。
- 多个且有失败：红色 tint + 数字角标。
- 完成后：按钮消失（与现在一致）；已完成的子代理仍作为工具调用行留在时间线（当前不能从该行打开面板，见 §3.0）。

**可访问性**
- label「子代理运行中」；value = 标题 + phase（沿用 `SubAgentCapsuleState.accessibilityText`）；hint「查看详情」；identifier `chat.subagent.roundButton`。

### 3.2 列表页（点圆形按钮后）

**容器**：沿用 `SubAgentPanelSheet` 的 sheet + NavigationStack；入口态 `.list`。

**布局**
- 导航标题：「N 个智能体正在运行」（N = 当前活跃卡数；0 时显示「子代理」空态）。
- 内容：`ScrollView` + `LazyVStack(spacing: 12)`，水平内边距 20，顶部 12。
- 每卡一行 `SubAgentListRow`：
  - 容器：大圆角矩形，圆角 24，填充官方 `userBubble` 底色（light `#F0EFEC` / dark `#2C2C2A`），内边距 16。
  - 左侧：40×40 圆形底 + 官方 agent 图标（`.large` 18×19）；图标/底随 phase 变色（`SubAgentPalette.phase`）。
  - 中间：标题 17pt semibold `textPrimary`，1 行截断；副标题 15pt `textSecondary`：有 `lastToolName` 时「正在运行 `<tool>`」，否则 `phase.word`；第三行 stats 用现有 metrics 的 glyph+数字（锤子/时钟/上下箭头，13pt）。
  - 右侧：若该卡**恰好 1 个活跃 task** → 26pt 圆形停止按钮（44pt 命中区）；多 task → 不显示行内停止（进详情逐个停）；已完成 → 无停止。
  - 整行可点 → push 详情页；行内停止按钮独立命中，不触发进入详情。
- 行高随 Dynamic Type；不固定。

**行为**
- 列表只显示活跃卡（与胶囊一致）；打开期间某卡完成 → 该行退场；详情页若开着，内容保留可读（现有语义）。
- 空态：没有活跃卡时显示一行「当前没有运行中的子代理」。

### 3.3 详情页（点列表行 / 工具调用行）

**容器**：同一 sheet 的 NavigationStack push；导航标题 = 子代理标题；返回回到列表（从圆形按钮进入时）或无返回（从工具行直接进入时，保留 sheet 关闭按钮）。

**布局（自上而下）**
1. **stats 行**：沿用现有 `statsRow`（phase 徽章 + 锤子/时钟/箭头 metrics），固定在详情顶部，不随内容滚动；保留现有功能与样式。
2. **对话内容**（`ScrollView`，水平内边距 20）：
   - 提示词气泡：官方 user bubble 底色、圆角 24、内边距 16、正文 17/27.2 `textPrimary`；长提示词超过 300 字可折叠（沿用现有阈值）。
   - 助手内容：**按现 Chat 页（渲染方式=聊天）的样式**渲染，不切 Code 页组件：
     - 用 `TimelineChatGrouping.units` 把子代理活动行分成聊天 profile 的 units；
     - 连续思考/工具 → `CodeStepGroupRowView`（行首三点 + 运行中实时文案 / 结束汇总）；
     - 正文 → `CodeMessageRowView`（chat profile 的消息行）；
     - 其他单行 → 现有 `SessionTimelineRow` 兜底；
     - 点步骤组 → 复用 `CodeStepGroupDetailView`（按顺序列出步骤；传入 `liveGroups`，运行中继续追加/更新）。
   - 实时更新：activity store 的 live rows 继续驱动；流式中正文/步骤组实时跟随；最后一个单位是步骤组且卡仍在运行时，`isLiveTail` 与主 Chat 页同规则。
   - 最终输出：沿用 `finalOutputSummary` 规则，避免与活动流重复。
3. **底部停止**：
   - 固定在 sheet 底部安全区上方，居中；不随滚动。
   - 0 个活跃 task：不显示。
   - 1 个活跃 task：一枚 44pt 高胶囊「停止智能体」，底色 `userBubble`，文字 17 semibold `textPrimary`。
   - 多个活跃 task：每个 task 一枚胶囊，纵向排列，文字「停止 <label>」（label 沿用 `SubAgentTask.label`）；点哪枚停哪个（保持“一控件一任务”）。
   - stopping 中禁用并显示「正在停止…」。

**从工具调用行进入**
- 直接显示该卡详情（作为 sheet 的根视图，不经过列表），导航标题 = 该卡标题；无返回列表（关闭 sheet 即可）。
- 已完成卡同样可读；底部无停止。

### 3.4 图标 / 字体 / 颜色

- 图标：官方资产（`anthropicon.agent` 优先；详见 §5）。
- 字体：`AnthropicSansMobileVariable-TextRegular` / `JetBrainsMono-Regular`（AA 已注册）。
- 颜色：`CodePageTheme` 既有官方 token：
  - `textPrimary` light `#0B0B0B` / dark `#F0EFEC`
  - `textSecondary` light `#52514E` / dark `#C3C2B7`
  - `textDisabled`（U：官方 token 未逐字解出；先用 secondary 的 0.6 alpha）
  - `userBubble` light `#F0EFEC` / dark `#2C2C2A`
  - `danger00` light `#8E2626` / dark `#F4ABAB`（现有）
  - 页面背景 `#F9F9F7` / `#151515`
- 圆角：列表行 24；提示词气泡 24；停止胶囊 22。
- 不新增第三方依赖。

---

## 4. 接线点 / 文件

### 4.1 入口

- `Views/Chat/SubAgentCapsule.swift`：保留 `SubAgentCapsuleState` 计算；`SubAgentCapsule` 改为 `SubAgentRoundButton`（圆形玻璃）或新增文件；`SubAgentCapsuleSlot` 改为右对齐单按钮。
- `Views/Chat/SessionChatView.swift`：
  - `composerDockArea` 第一行改为 `HStack { Spacer(); SubAgentRoundButton(...) }`；
  - sheet 路由：圆形按钮进入 list-first；列表行经 `NavigationStack(path:)` push 详情；工具行 entry B 路由保留（当前主时间线不调用）。

### 4.2 面板

- `Views/Chat/SubAgentPanelSheet.swift`：
  - 入口态 `.list` / `.card(id)`；
  - 列表页 `SubAgentListPage`（新）；
  - 详情页 `SubAgentDetailPage`（新）替换现有 body；
  - stats/stop 逻辑复用 `SubAgentProgress.metrics`、`SubAgentProgress.stopTasks`、`chat.stopSubagent`、`chat.stoppingSubagentTaskIDs`；
  - 活动行按现 Chat 页渲染：`TimelineChatGrouping` + `CodeStepGroupRowView` / chat 消息行，不做第二套模型。
- 新增：`Views/Chat/SubAgent/SubAgentListRow.swift`（列表行）
- 入口按钮 `SubAgentRoundButton` 落在 `SubAgentCapsule.swift`
- 列表页/详情页落在 `SubAgentPanelSheet.swift` 的 `listPage` / `detailPage`；活动转录 `chatTranscript` 同文件
- 主题：`CodePageTheme` 增加 `textPrimary/textSecondary/textDisabled/userBubble` 的 Accessor（已有 `text100/text300` 等，按需映射，避免重复）。

### 4.3 数据

- 不新增 wire 字段；全部读 `SubAgentCard` / `SubAgentProgress` / `SubAgentActivityStore`。
- 列表顺序：现有 `sessionCards` 的 dispatch 顺序（orderSeq）。
- 活跃卡集合：现有 `activeCards`。

---

## 5. 官方图标提取（anthropicon.agent）

- 来源：官方 1023 IPA `Payload/Claude.app/ClaudeDesignSystem_ClaudeIcons.bundle/Assets.car`。
- 现有 `EVIDENCE/anthropicon-map.tsv` 给出 `agent` 的资产名与 rendition offsets；需要 BOMStore + LZFSE 解析（本地已有 `lzfse` Python 模块；Assets.car 已复制到 `/home/ubuntu/aa-test/claude-ios-re/assets/ClaudeIcons-1023.car`）。
- 交付：`anthropicon.agent.imageset`（SVG 优先；取不到 SVG 时取 300% PNG rendition，保持官方像素）。
- 兜底：若解析失败，先用 AA 已有 `anthropicon.agentSimple`（同属官方资产）落地，并在汇报中标注；不得用自绘图标冒充官方。
- 新增资产后运行 `AnthropiconAssets.table` 校验（与现有 21 个资产同一注册表）。

---

## 6. 实施阶段

- **P1 入口**：圆形玻璃按钮 + 右对齐 + 状态/角标 + 无文字；胶囊显隐逻辑不变。
- **P2 列表页**：sheet 路由改为 list-first；列表行 + 行内单任务停止 + stats。
- **P3 详情页**：对话式渲染（Code 组件）+ 顶部 stats + 底部停止；工具行点击进详情。
- **P4 图标**：官方 `anthropicon.agent` 提取与接入（可与 P1 并行；失败则 fallback 并汇报）。
- 每阶段一个提交，均可单独回滚。

---

## 7. 测试 / 门禁

- 单测：
  - `SubAgentRoundButtonStateTests`：可见性/计数/失败 tint（提取自现有 capsuleState）。
  - `SubAgentListModelTests`：活跃卡排序、行内停止仅单任务、stats 文案。
  - `SubAgentDetailModelTests`：activity → 聊天 units 的顺序/过滤/步骤组；prompt 折叠阈值；最终输出去重。
  - 现有 `SubAgentProgressTests` / `CapsuleActivityWindowTests` 保持绿。
- 门禁：
  - `code-profile`：新增列表页/详情页截图（light/dark、运行中/失败/完成）。
  - `timeline-autorun`：入口不改变时间线滚动与高度不变量。
- 真机（pp）：
  - 圆形按钮位置/尺寸/玻璃手感；键盘弹起随动。
  - 单个/多个子代理列表；行内停止；详情对话滚动/流式；底部停止；完成后退场；工具行回看。
  - 深色/大字号/Reduce Motion。

---

## 8. 待确认 / 风险

- `textDisabled` 官方 token 未逐字解出（前一轮 R-SA4 U6）；先用 0.6 alpha 近似，真机再校。
- `anthropicon.agent` 的 SVG 可能只能取到 PNG rendition；优先官方像素，不冒充自绘。
- 详情页改用聊天 profile 的步骤组/消息行后，`onFile`/附件预览/步骤组详情 sheet 的接线要与主 Chat 页逐项对照；步骤组详情是嵌套 sheet，注意关闭返回。
- 列表行“当前活动”副标题依赖 `SubAgentTask.lastToolName`；无该字段时只显示 phase 词。
- 旧 Chat 容器清理仍按步骤组任务单 §10 另开单，本单不动。
