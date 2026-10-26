# Code 页 composer 官方 1:1 对齐 · 任务单（取证先行，未开工实现）

> 分支：`feat/code-composer-official`（worktree `/home/ubuntu/aa-ring-work-composer`，基于 `feat/code-profile-beta@f09cbd3f`）
> 目标：AA iOS **Code 页输入框（composer）** 的 UI + 键盘弹起/收回动画与官方 1:1。
> 官方二进制：build **1.261005.20**（`/home/ubuntu/swift-recover/unpacked/Payload/Claude.app/Claude`，sbx `100.79.4.30:2222`）。
> 官方截图像素实测：pp 真机附件（1179×2556 @3×，即 393×852 pt），对应官方 **1.261019.51**（比二进制新一版；像素结论只用于几何，地址结论全部来自 1.261005.20）。
> 证据等级：**E** = 反汇编/类型表/截图直读；**I** = 由 E 推出；**U** = 静态不可达，写明差什么。
> 状态：**只有本任务单，没有改任何产品代码**。

---

## 0. 一屏结论

1. **Code 与 Chat 的 composer 不是同一套页面配置。** 两者共用 `ClaudeComposer.ChatInputBar`（卡片、`ScrollingTextField`、附件条、发送/停止键、玻璃、slash 补全）；但：
   - Code 外面套 `ClaudeCodeSessionFeature.SessionInputBar`（Code 工具栏、提醒、compact 形态、附件上传、diff 评论胶囊、prompt suggestion）；
   - Chat 外面套 `ClaudeChatFeature.ChatComposerTextBar` / `ChatTextComposer`（语音/听写、Chat 提醒、Chat 附件、Chat 专属焦点背景）。
2. **尺寸（E 截图实测；注意：Code 折叠的 32/48 是 AA 现状，不是官方基准）：**
   - AA 现状（Code 页收起）：左右 **32 pt**、高 **48 pt**、卡底距安全区 **+10 pt**、胶囊圆角 24；
   - 官方 Chat 折叠：左右 **16 pt**、高 **52 pt**、卡底贴安全区、胶囊圆角 26；
   - 官方 Chat 首页键盘弹起：左右 **9 pt**、高 **95 pt**、距键盘 ~8.7 pt；
   - 官方 Code 展开（旧版截图）：左右 **16 pt**、高 ~**96–98 pt**、卡底贴安全区、圆角 **24 continuous**；
   - **官方 Code 当前版本的收起/弹起：UNKNOWN（缺截图）**。
3. **键盘动画机制不一样（核心）：**
   - **Code 有专属 `EarlyKeyboard` 栈**：`EarlyKeyboardField` 探针读 `UIKeyboardFrameEndUserInfoKey` → `EarlyKeyboardPadding` 用 `.safeAreaPadding(.bottom, max(held−resting,0))` + **固定 `Animation.interpolatingSpring(mass:3, stiffness:1000, damping:500)`** 驱动；只监听 `UIKeyboardWillShow` / `UIKeyboardWillHide`；`IgnoresEarlyKeyboard` 关掉系统键盘安全区，避免双重动画。
   - **Chat 没有 EarlyKeyboard 引用**（全类型表负证据）→ 走系统键盘安全区 + `safeAreaBar` 的系统动画。
   - AA 现在既不是 Code 机制、也不是官方 Chat 机制：抽屉卡片随窗口安全区（含键盘）缩放，页面内再 `.ignoresSafeArea(.keyboard)`；composer 只在“展开”时用 `.smooth(0.24)` 补一帧（`ChatComposer.swift:119`、`ChatPageToolbar.swift:20-21`）。
4. **要复刻官方的丝滑，必须补 EarlyKeyboard 等价物，并先解决“抽屉卡片随键盘缩放 vs 页面自己管键盘”的结构冲突。** 只改 composer 内部曲线不够。方案见 §5，需要 pp 在 A/B/C 中拍板（推荐 A）。

---

## 1. 证据与来源

| 类型 | 内容 | 位置 |
|---|---|---|
| 官方类型/字段 | `ChatInputBar` / `SessionInputBar` / `ChatComposerTextBar` / `CodeComposer` 的字段与 `Body` 类型别名 | sbx `~/wiring/out/swift_types.csv`（行 86090/86396/83552 等），`~/wiring/out/witness.csv` |
| 官方调用/常量 | 玻璃、圆角、padding、spring、键盘通知 | sbx `~/wiring/cache/decomp/*.c`；地址见 §3/§8 |
| 官方截图 | Code 折叠、Code 展开、Chat 折叠的像素测量 | `/home/ubuntu/.agents-anywhere-moonveil/attachments/sess_WQoTRXZSQyPwkw/`（见 §2.2） |
| AA 现状 | 视图/模型/键盘链 | `/home/ubuntu/aa-ring-work-composer/ios/Agents Anywhere/Agents Anywhere/...`（见 §4） |
| 既有语料 | composer 玻璃/挂载/safeAreaBar 更正 | `EVIDENCE/round19/chrome-composer.md`、`EVIDENCE/round21/chrome-verify.md`、`CANONICAL/CORRECTIONS.md #64–66` |

> 截图归属：pp 真机附件；`file_rcaDbU2vZNsfPqlP-Photo-9BC9389E.png` 即 R20 的 `EVIDENCE/round20/official_bottom.png` 原图（逐像素 diff=0）。Code/Chat 归属依据：Code 组截图带 `Claude Code · Hong Kong · Linux` 会话壳 + `描述任务…` placeholder；Chat 组为 `回复 Claude` placeholder。均为 **INFERENCE-high**（EXIF 无 App 标识）。
>
> **更正（2026-10-25，pp 指出）**：`file_rcaDbU2vZNsfPqlP-Photo-9BC9389E.png`（含 `EVIDENCE/round20/official_bottom.png`、`aa_top.png`、`aa_bottom.png`、`file_LOCwmv9BH9ooSwLM…`）是 **AA 现状**，不是官方。判据：placeholder 是 `描述任务...` —— AA key `询问 Agents` 的中文值（`Localizable.xcstrings`）；官方 Code 用 `描述任务或提出问题…`（`code_project_conversation_composer_hint`）。因此 §2.2 的 **32 / 48 / +10 是 AA 现状**；**官方 Code 当前版本的收起/弹起基准仍缺**。
>
> **官方 Chat 首页实测（pp 2026-10-25 附件）**：`file_PFS5pCqr_337R3Y1-Photo-59C45F26.png`（收起）与 `file_tLWTLhJ_8o9-bteJ-Photo-B5C2BC11.png`（键盘弹起）——收起 16 / 52 / 贴安全区；弹起 9 / 95 / 距键盘约 8.7；圆钮 36。这是 **Chat 首页/新对话**，不是 Code 会话页。

---

## 2. Code vs Chat 逐项对比

### 2.1 组件组成（E，类型别名直读）

| 层 | Code 页 | Chat 页 |
|---|---|---|
| 页面壳 | `CodeComposer`（`Body` 0x104d8c6e0）：只读/访问拦截/计划搁置/初始化失败/拒答/离线/SetupBar → `SessionInputBar`；外含 `GlassGroup` + 各 notice/model picker/effort/permission/memory/attachment markup | `ChatComposer`（`Body` 0x104d929d0）→ `ChatComposer.Bar` → `VoiceSessionControls` / `ChatTextComposer` / `AskUserInputWidgetView` / `ChatComposerTextBar` |
| 输入条本体 | `SessionInputBar`（`Body` 0x104d9007f）：`ChatInputBar` + Code 工具栏 | `ChatComposerTextBar`（`Body` 0x104d92987）：`ChatInputBar` + Chat 附件/提醒/工具栏 |
| 卡片/输入框 | **共用** `ClaudeComposer.ChatInputBar` / `ClaudeCoreUI.ScrollingTextField` | 同左 |
| 前导控件 | `SessionInputToolbarLeading`：`SessionAddContextButton`（+）、`ChatInputModelPickerPill`、`SessionDiffCommentsPill` | `ChatInputLeadingControls`：`inlineTools`、`onAddContext`、`middleContent`、模型胶囊 |
| 尾随控件 | `SessionInputToolbarTrailing`：`ChatInputTrailingControls` + `SendChatButton` | `ChatComposerTrailingControls`：`ChatInputTrailingControls` + `SendChatButton` + 语音 morph |
| 发送/停止 | 共用 `SendChatButton`（`SendChatButtonMode{send,stop}` + `SendOrAudioSlot/Pose` 动画） | 同左，另有 voice↔send 形变 |
| 附件 | `AttachmentBar` + `PendingAttachmentUpload` + `CodePastedFileHandler` + `CodeAttachmentMarkupSheetModifier` | `ChatAttachment` + `ChatInputMenu` + 照片/文件/相机 |
| Slash/命令 | 共用 `InputAutocompleteController` / `SuggestionList`；Code 另有 `UltraKeywordRangesCache` + `tokenRanges/highlightRanges` | 共用补全；无 ultracode 高亮 |
| 模型/权限 | `ChatInputModelPickerPill` + `PermissionModePicker` + `EffortChangeConfirmationAlert` | 模型胶囊 + Options sheet |
| 语音/听写 | `showSpeechInputStart` + `SpeechInputInlineToolbar` | 语音会话按钮 + `ComposerDictation` + hold-to-talk |
| 提醒/notice | `SessionInputDisclaimer.Kind` 10 case（sendDisabled/bridgeOffline/rateLimit/refusal/composerNotice/enableNotifications/connecting/connectionFailed/upgradeRequired/unsavedWork） | `ChatDisclaimerView` + `ChatDisclaimerAction` + `ChatModel.ComposerStandIn` |
| 折叠行为 | `ChatInputBarCollapseBehavior{never, whenIdle}` + `useCompactComposer` | 同枚举；无 `useCompactComposer` 字段（Chat 走常规形态） |

**结论（E+I）：** 卡片/输入/发送是共享的；差异在**页面外框、工具栏、提醒、语音、compact 形态、键盘机制**。不能把 Code 对齐做成“只改 ChatComposer 的数值”。

### 2.2 尺寸（E，3× 截图像素实测，四舍五入到 0.1 pt）

| 项 | AA 现状（Code 收起） | 官方 Chat 收起 | 官方 Code 展开（旧版） |
|---|---:|---:|---:|
| 左右外边距 | **32.0** | **16.7**（≈16） | **16.0** |
| 卡片宽（393 pt 屏） | 329 | 359.3 | 361 |
| 卡片高 | **47.7（≈48）** | **52.0** | **96–98** |
| 卡底距屏幕底 | **44.0** | **34.0** | **34.0** |
| 距安全区线（34 pt） | **+10** | **0** | **0** |
| 圆角 | 24（=高/2，胶囊） | 26（=高/2，胶囊） | 24 continuous |
| 发送/停止圆 | **36** | **36** | 36（推断同） |
| 圆到卡边 | 6 | 6 | — |
| 可点槽位 | 44 | 44 | 44 |
| 前导 `+` | 裸图标，ink 14×14 | 灰底圆内，ink ~14 | `+` 裸图标（据旧图） |
| 占位文字 ink 高 | 12.7（≈17 pt 字号，I） | 12.7 | — |
| 命令 `⌘` ink | 13×13 | 无（语音 morph） | — |

**证据文件：**
- **AA 现状（Code 收起）**：`file_rcaDbU2vZNsfPqlP-Photo-9BC9389E.png`（= `EVIDENCE/round20/official_bottom.png` / `aa_bottom.png` 的原图），卡 bbox `x 96–1082, y 2280–2423`；黑圆 `x 957–1064, y 2298–2405`；`+` ink `x 147–188`；`⌘` ink `x 860–898`。placeholder `描述任务...` = AA key `询问 Agents`。
- **官方 Chat 收起**：`file_deRg7JiV1gUeI1yY-Photo-5672AFF7.png`，卡 bbox `x 50–1128, y 2298–2453`；黑圆 36 pt；`回复 Claude` placeholder；有麦克风/语音圆（AA composer 代码里没有麦克风，故判官方，I）。另 `file_PFS5pCqr…`（Chat 首页收起，16/52）与 `file_tLWTLhJ…`（键盘弹起，9/95）同属官方 Chat。
- **官方 Code 展开（旧版/待确认）**：`REFERENCES/device/code_session_light_cleared_1320x2868.jpg`（1320×2868，x 48–1271，高 98）、`REFERENCES/round2/device/code_session_dark_de_1170x2532.png`（1170×2532，x 48–1121，高 96）、`EVIDENCE/round20/official1022_full_small.png`（横屏运行中，有麦克风 + `Fable 5.1`，判官方 I）。
- **官方 Code 当前版本（收起 + 键盘弹起）：无截图，U。**
- **状态差异提醒：** AA 收起截图处于“运行中”（停止方块），官方 Chat 处于“空闲”（语音圆）；页面归属按 placeholder / 麦克风两个判据交叉，仍为 **I**。

### 2.3 功能对比（E，类型层）

| 功能 | Code | Chat | 备注 |
|---|---|---|---|
| 发送 / 停止 / 排队 | 三态：send / queueSend / stop（`SendChatButtonMode` + `ComposerQueueAffordance` 语义） | 同 | 共享 |
| 排队 placeholder | `mid_turn_queue_placeholder`=`Queue for after this turn…` / `排队至本轮结束后…` | 同串可用 | Code 截图确认 |
| 默认 placeholder | `code_project_conversation_composer_hint`=`Describe a task or ask a question…` / `描述任务或提出问题…` | `回复 Claude`（截图；字符串表待核） | 页面级差异 |
| 附件 | 照片/文件/相机 + 上传状态 + pasted file + markup | 照片/文件/相机 + ChatAttachment | 共享 `ChatInputMenu`，Code 多上传/标记 |
| 模型 | 模型胶囊（名称+effort+badge+tooltip+drag menu） | 同胶囊 + Options sheet | 共享 pill |
| 权限/模式 | `PermissionModePicker`、auto mode 二次确认、effort 确认 | Options sheet | Code 更细 |
| Slash 命令 | 补全 + 高亮（ultracode keyword ranges） | 补全 | 共享补全 |
| 语音 | `showSpeechInputStart` + inline toolbar | 语音会话/听写/hold-to-talk | Code 能力集取决于 runtime |
| Prompt suggestion | `NextPromptSuggestionPlaceholder`（ghost 文本 + 接受） | 无同名类型 | Code 专属 |
| Diff 评论 | `SessionDiffCommentsPill`（计数）+ `onShowDiffView` | 无 | Code 专属 |
| Draft | `ComposerPrompt{text,isFromUntrustedSource,isPrefillSeeded,seededText}`（E 类型） | `ChatStore` + `drafts` 表 + `DraftKeeping` | 机制不同 |
| 只读/访问/计划/离线/初始化失败 | 7 个页面级覆盖层（E） | Chat 对应 `ClosedSessionNotice` / `AccessBlockNotice` / `ToolApprovalCard` 等 | 页面级差异 |

### 2.4 动画对比（E 常量 + I 归属）

| 动画 | Code | Chat | 证据 |
|---|---|---|---|
| 折叠↔展开 | **共享** `Animation.spring(response: 0.22, dampingFraction: 0.77, blendDuration: 0)`（`ChatInputBar` body 0x10193442c；常量 0x1042cb238=0.22、0x1043bb598=0.77） | 同左 | E 常量；绑定的具体 Bool 为 I（`ComposerRows.animatableData` / `isCollapsed`） |
| 键盘弹起/收回 | **EarlyKeyboard 固定弹簧** `interpolatingSpring(mass:3, stiffness:1000, damping:500, v0:0)`；仅当通知里的 `UIKeyboardAnimationDurationUserInfoKey > 0` 时施加，否则 nil | 无 EarlyKeyboard → 系统键盘安全区动画 | E 常量/分支；I 归属 |
| 发送↔停止 | `SendOrAudioPose{sendOpacity,sendScale,audioOpacity,audioScale,shut,turned}` 可动画 + symbol replace | 同左（另有 voice morph） | E 类型 |
| 触感 | `SendChatButton` 的 send 用 `.selection`；stop 静音 | 同左 | `EVIDENCE/round19/motion.md` §P2-10 |

---

## 3. 官方 Code 键盘机制（取证结果）

### 3.1 事件与高度（E）

- `EarlyKeyboardPadding` body（`0x100d96370`，`ClaudeCoreUI/UIKitEarlyKeyboardPadding.swift`）：
  - 订阅 **`UIKeyboardWillShowNotification` + `UIKeyboardWillHideNotification`** 合并 publisher（`0x100d9619c`：两次 `NotificationCenter.publisher(for:)` + `Combine.Publishers.MergeMany`）。
  - 取 `userInfo[UIKeyboardFrameEndUserInfoKey]`（`0x100d95080`）→ `NSValue.CGRectValue` → `UIScreen.bounds`，算出键盘高度（`FUN_100999404`）。
  - 写入 `ClaudeCoreUIState.EarlyKeyboard._keyboardHeight`（模型字段 `0x104df1284`）。
- 高度写回后，`EarlyKeyboardPadding` 计算 `max(heldHeight − restingInset, 0)`（body 反编译 `local_a0 = dVar6 − local_98; if <0 → 0`），施加 `.safeAreaPadding(.bottom, insets: EdgeInsets(all: delta))`（`SafeAreaPaddingModifier`）。
- `restingInset` 来自 `GeometryProxy.safeAreaInsets` 的 geometry action（`FUN_100d96868` 把 `param_4` 写回）——即“键盘弹出前页面已有的底部安全区”。

### 3.2 动画曲线（E）

- 通知里读 `UIKeyboardAnimationDurationUserInfoKey`（`0x100d96a94`，`UIKitEarlyKeyboardPadding.swift:44`）：
  - 值为 **> 0** → 使用静态默认动画；值为 0/缺失 → nil（不施加动画）。
- 默认动画 = `Animation.interpolatingSpring(mass: 3.0, stiffness: 1000.0, damping: 500.0, initialVelocity: 0)`：
  - 工厂 `0x100d9633c`，常量 `0x4008000000000000`=3.0、`0x10422ea00`=1000.0、`0x1042ccdb0`=500.0。
  - 推导：ω=√(1000/3)≈18.26 rad/s，ζ=500/(2√3000)≈4.56 → **强过阻尼、无回弹**，收敛约 0.2–0.3 s（I）。
- **不读** `UIKeyboardAnimationCurveUserInfoKey`：全二进制该符号只被 GMS（Google Maps）函数引用，App 模块 0 处（E 负）。

### 3.3 系统避让的关闭（E/I）

- `IgnoresEarlyKeyboard`（`Body` 0x104d38c6c）= `_SafeAreaRegionsIgnoringLayout`，字段 `keyboard: EarlyKeyboard`。语义：在 early keyboard 生效时忽略系统键盘安全区（I，具体 region 值 U）。
- `HiddenWhileKeyboardOnScreen`：订阅键盘通知 + `.default` 动画，键盘在屏时隐藏某层 chrome（E 类型/动画；具体挂载 U）。
- `EarlyKeyboard` 模型字段：`_holdsFocus`、`_isRaisedByATap`、`_awaitsKeyboard`、`_typedAhead`、`_keyboardHeight`、`onHandOver`、`onPush`、`device`（E）。
- `ComposerKeyboardWait{isOwed, screenWasShown}`、`KeyboardResigning` / `LiveKeyboardResigner`（E 类型名）；Code 根 `CodeRootModel.keyboard: KeyboardResigning`（E）。
- `DebouncedTaskModifier<Bool>` 出现在 `EarlyKeyboardPadding` body 类型里（E），去抖值 **U**。

### 3.4 作用域（E 类型层）

- 只有 `ClaudeCodeFeature.CodeRootModel.earlyKeyboard`（0x104ea6528）与 `CodeRootContent.usesEarlyKeyboard`（0x104ea6974）引用 `EarlyKeyboard`；**Chat 全套类型无一处引用**（E 负）。
- 远程开关 `isNewSessionEarlyKeyboardEnabled`（`ClaudeFeatureFlagsInterface.RemoteFeatureValues._isNewSessionEarlyKeyboardEnabled`，0x104e275b4；`GrowthBookFeatures.isNewSessionEarlyKeyboardEnabled`）——名字指向“新会话”，因此**是否也覆盖已存在会话的 composer 尚未打通**（U；需要 View Debugger 或断点确认 `usesEarlyKeyboard` 的实际取值）。
- `.earlyKeyboardPadding` 的**构造挂载点**静态未定位（类型元数据只被自身 accessor 引用；泛型 View 扩展调用不可静态解析）——**U**，但已确认属于 ClaudeCoreUI 的 SwiftUI 扩展族（`UIKitEarlyKeyboardPadding.swift`）。

### 3.5 与列表/滚动的关系

- 官方列表层无键盘监听：`GeometryProxy.safeAreaInsets → TranscriptListInput.safeArea → contentInset = max(safeArea − scrollView.safeAreaInsets, 0)`（`0x101a3c820`，E）；`keyboardDismissMode = interactiveWithAccessory`（4，`0x101a3b344`，E）。
- 因此 Code 页的“丝滑”来自 **composer 自己的 early padding**：列表只吃最终安全区；键盘下滑交互由 UIKit 的 interactive dismiss 承担。

---

## 4. AA 现状（文件:行）

| 项 | 现状 | 位置 |
|---|---|---|
| 卡片玻璃 | `GlassEffectContainer(spacing:nil)` + `.glassEffect(.regular.interactive(), in: RoundedRectangle(radius,.continuous))` | `ChatComposer.swift:45,110-114` |
| 折叠/展开尺寸 | 折叠左右 **32**、展开左右 **12**；圆角 = diameter/2 / diameter/2+2；`diameter = max(48, lineHeight+12)`，send = touch−8（默认 36） | `ChatControlMetrics.swift:6-7,14-26` |
| 布局 | 折叠高 = diameter（48）；展开 = 16+text+10+44+8；折叠文字 x = inset+44+4 | `ComposerLayout.swift:9-15,19-20,38-41,49-50` |
| 外边距 | `.padding(.horizontal, expanded ? 12 : 32)`、`.padding(.top,8)`、`.padding(.bottom,10)` | `ChatComposer.swift:116-118` |
| 展开动画 | `.smooth(duration:0.24)`，仅 `draft.isExpanded` 变化 | `ChatComposer.swift:119` |
| 展开判定 | `isFocused || hasContent || !attachments.isEmpty` | `ComposerDraft.swift:60` |
| 焦点过渡 | 只有“展开”那一帧做动画；理由是 bar 高度会进入页面底部 inset，先长一帧会闪 | `ComposerDraft.swift:37-44` |
| 页面键盘策略 | drawer 模式 `NavigationStack{content}.ignoresSafeArea(.keyboard)`；页面不自己加键盘 padding | `ChatPageToolbar.swift:12-21` |
| composer 挂载 | iOS 26 `.safeAreaBar(edge:.bottom, spacing:0)`；列表 `.ignoresSafeArea(.container,[.top,.bottom])`；`bottomBarInset = composerBarHeight` | `SessionChatView.swift:82,220-225,75` |
| 键盘监听 | 时间线自己监听 willShow/willHide/willChangeFrame（transition window / 贴底 pin） | `ChatTimelineView.swift:298-307,382-403` |
| 发送/排队 | `ComposerQueueAffordance.resolve(isStreaming, hasText, canQueue, canStop, canSend)`；发送时键盘收起，排队时保留 | `ChatComposerDock.swift:54-61,134-139` |
| 代码页复用 | Code 页与 Chat/NewSession 共用 `SessionChatView` + `ChatComposerDock`；没有 Code composer profile | `SessionChatView.swift:94-124`、`NewSessionView.swift:50-75` |

**判定：** AA 的 composer 目前是“单一 Chat 样式 + 抽屉卡片随键盘缩放”。与官方 Code 的差距是**样式（32/48/10 与展开 16/0/24 接近但并非官方 token 来源）+ 控件集 + 键盘机制**三层叠加。

---

## 5. 方案（待 pp 拍板后实施）

### Phase 1 · 尺寸与状态模型（低风险，可先做）

1. 新增**纯模型** `ComposerMetricsProfile`（放 `Models/Chat/`，可被 `swift test` 覆盖）：
   - `codeCompact`：collapsed inset 32 / height 48 / bottom 10 / capsule / 展开 inset 16 / bottom 0 / radius 24 / 文字 inset 16；
   - `chatRegular`：保持现状（32/12）或按官方 Chat 改 16/0/52——**这是产品选择，需 pp 决定 AA 的 Chat 页是否也一起对齐**。
2. `ChatControlMetrics` / `ComposerLayout` 改为吃 profile；默认 Chat 行为不变，Code profile 显式打开。
3. Code 页 placeholder：默认 `描述任务或提出问题…`；运行中聚焦 → `排队至本轮结束后…`；接管/禁用 → 现有 takeover 文案。
4. Code 页折叠态控件：`+` 裸图标（当前 24 pt symbol 偏大，官方 ink 14 pt，建议 symbol 20 pt，待真机对照）；保留 `⌘`；不显示 context ring（当前仅在聚焦显示，折叠态已隐藏，符合）。
5. 展开态控件：`+`、模型胶囊、Spacer、麦克风（runtime 允许时）、发送/停止；圆角改 24、外边距改 16、底部 0。

### Phase 2 · EarlyKeyboard 等价物（核心，含结构决策）

**新增（Composer 域内）：**
- `ComposerKeyboardDriver`（@Observable，纯逻辑可测）：
  - 合并 `UIResponder.keyboardWillShowNotification` / `keyboardWillHideNotification`；
  - 读 `frameEnd` + `UIScreen.bounds` 算高度；暴露 `height`；
  - `duration = userInfo[UIKeyboardAnimationDurationUserInfoKey]`，>0 时返回 `spring(mass:3, stiffness:1000, damping:500)`，否则 nil；
  - 记录 `restingInset`（页面传入），输出 `bottomPadding = max(height − restingInset, 0)`。
- `EarlyKeyboardPadding` 等价 ViewModifier：`.safeAreaPadding(.bottom, padding)` + `.animation(driver.animation, value: padding)`；必要时加去抖（官方有 `DebouncedTaskModifier`，值 U，先按 0 或 80 ms 做真机对照）。
- `IgnoresKeyboardSafeArea` 等价：在 early keyboard 生效时 `.ignoresSafeArea(.keyboard)`（Code 页）。

**结构冲突（必须先解决）：**
- 现状：`SidebarDrawer` 在窗口根 `GeometryReader` 取 `safeAreaInsets`（含键盘）→ 卡片随键盘缩放；页面内再 `ignoresSafeArea(.keyboard)`。这是“卡片移动”，不是“页面内 padding 动画”。
- 官方：页面全屏，键盘安全区由页面自己吃掉，EarlyKeyboardPadding 是唯一动源。
- 三个方案：
  - **A（推荐，官方同构）**：drawer 主卡片对键盘 `.ignoresSafeArea(.keyboard)`；Code 页用 EarlyKeyboardPadding 驱动；Chat 页移除内层 `ignoresSafeArea(.keyboard)`，交回系统 safeAreaBar。影响：所有 drawer 页面的键盘行为（跨页），需真机全量回归。
  - **B（低风险）**：保留卡片缩放；只把 composer 自身“展开高度变化”用与键盘同曲线/同时长的动画包住（`ComposerFocusTransition` 扩展），消除一帧闪。不是官方机制，手感和官方可能仍有差。
  - **C（折中）**：仅 Code tab 激活时让卡片 ignore 键盘并启用 EarlyKeyboard；Chat tab 保持现状。改动局部化，但同一个 shell 两套行为，需要明确切换时机。
- **pp 决定点：A / B / C。**

### Phase 3 · 功能对齐（范围待定）

- 模型胶囊（名称/effort/badge/拖拽菜单）、权限模式、effort 二次确认、diff 评论胶囊、`NextPromptSuggestionPlaceholder`、附件上传状态、pasted file、markup sheet、7 个页面级 notice。
- 语音/听写（`showSpeechInputStart`、hold-to-talk）是否纳入本次，需 pp 明确（工作量大，且依赖 runtime 能力）。

---

### 5.1 实现状态（2026-10-26，真机反馈后修订）

- **已实现**（分支 `feat/code-composer-official`，commit `78c7dc0f` / `70a96c32` / `31c2c71c`）：
  - Code profile 尺寸：折叠 16 / 52 / 贴安全区、胶囊 26、leading 0 / trailing 2（文字起点 74）；展开 9 / 95 / 距键盘 8、圆角 24、text inset 11、content inset 3；`+` 灰底圆；队列 placeholder；展开 spring 0.22 / 0.77。
  - **键盘：不自绘**。真机截图证明系统已经把 `safeAreaBar` 顶到键盘上方；自绘 `safeAreaPadding` 等于第二次抬升，卡片和键盘之间多出约 107 pt。已删除 observer / modifier，回到系统键盘动画。
  - 官方 `3 / 1000 / 500` 弹簧：主时间常数约 0.5 s，键盘动画约 0.25 s，不适合整段位移；判定它属于 early-reservation 路径，暂不实现。
  - `NewSessionView` 使用同一 profile；Chat profile 保持现状（32 / 48 / +10、`.smooth(0.24)`、系统键盘）。
  - 未改 `SidebarDrawer.swift` / `ChatPageToolbar.swift`。
- **验证**：纯模型编译 + 断言；所有改动文件 `swiftc -parse`；CI run `40223624399` 的 test + build 绿（旧包）。
- **未验证**：本次修订（31c2c71c）尚未重新出包/真机。
- **待确认（按钮）**：官方展开排 = `+ / 模型胶囊 / 麦克风 / 发送`；AA 现在多了 `⌘` 和上下文圆环，缺模型胶囊/麦克风。尺寸本身 `+` 44、发送 36 与官方截图一致；“位置不对”可能指这两个多出的按钮，需 pp 确认是否移除或补齐。
- **2026-10-26 pp 决定**：没有官方 Code 截图，Code 基准采用官方 Chat 截图的 16/52、9/95；按此实现，后续有官方 Code 图再校准。
- **2026-10-26 更正（挖官方二进制）**：`+` 的**灰圆不是 44 pt**。官方每个控件都套 `ChatInputControlButtonStyle` → `ChatInputControlChrome.body`（`0x100b8d134`）把 chrome 钉死为 **36 pt**（`.small` 为 32 pt），`ChatInputControlTriggerStyle.body`（`0x100b8e8f0`）再给 **44 pt** 的 `MinimumTapTarget` 命中区；`SessionAddContextButton` 构造该 chrome 时是 `.circle` + `.regular`（`0x100b8eaa4`：kind tag=1、size=0）。官方 Chat 截图实测：卡片 52 pt、左右内缩 **18 pt**、圆直径 **36 pt**（屏上 24–60 pt，即距卡片边 6 pt）、加号笔画 13 pt、占位文字起点 74.7 pt。AA 旧实现把灰圆画成 44 pt 且 leading inset=0，所以圆贴着卡片圆角——这就是 pp 说的“圆环成什么样了”。

## 6. 文件清单

### 新增
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/ComposerMetricsProfile.swift`（纯模型）
- `ios/Tests/ClientCoreTests/ComposerMetricsProfileTests.swift`

### 修改（composer 域）
- `Views/Chat/Composer/ChatComposer.swift`（profile、placeholder、`+` 灰底圆、动画来源）
- `Views/Chat/Composer/ComposerLayout.swift`（profile 驱动布局、leading/trailing inset）
- `Views/Chat/Composer/ChatControlMetrics.swift`（profile 化）
- `Views/Chat/Composer/NativeComposerEditor.swift`（焦点展开使用 profile 曲线）
- `Views/Chat/SessionChatView.swift`（Code profile 选择、队列 placeholder；**共享页壳，已列出**）
- `Views/Chat/NewSessionView.swift`（同一 profile）
- `Resources/Localization/Localizable.xcstrings`（只追加队列 placeholder 文案）

> 键盘 observer / modifier（`ComposerKeyboard.swift`、`ComposerKeyboardLayout.swift`、对应测试）曾在 `78c7dc0f` 加入，`31c2c71c` 已删除；当前没有自绘键盘层，也不需要改 `SidebarDrawer.swift` / `ChatPageToolbar.swift`。新增文件由 Xcode 的同步目录组自动收录，未改 `project.pbxproj`。

### 不碰（另一条线正在改）
`CodeMessageRowView`、`CodeMessageTimeline`、`CodeRowHeightPlan`、`CodeToolLabelPlan`、`CodeToolDetailView`、`CodeCollapsedToolRow`、`CodeMessageHeightMeasurer`、`TimelineChatContentAdapter`、`TimelineChatTimelineView`、`CodeThinking*`。

---

## 7. 测试与验证

### 自动化
- `swift test --package-path ios --filter ComposerMetricsProfileTests`：折叠/展开 inset、高度、圆角、底部 padding、Dynamic Type 下的取值。
- `ComposerKeyboardDriverTests`：frame→height（含 home indicator/横屏/分屏）、duration 缺失/0/正数、spring 参数是否等于 3/1000/500、restingInset 扣减、去抖顺序。
- 现有 `ComposerQueueAffordance` / `ComposerGestureKinematics` / `ChatLayoutStability` 回归。
- 构建：本机 Linux 无 Xcode，**只能跑 SwiftPM 的 ClientCore 测试**；iOS 编译/真机需 macOS，按仓库纪律不擅自派 CI/出包。

### 真机（必须）
1. Code 页空闲/运行/聚焦/多行/附件/模型胶囊 6 态截图对照官方。
2. 键盘：点击聚焦、下滑 interactive dismiss、发送收起、切换会话、横竖屏、分屏、外接键盘；录屏逐帧对比官方（重点看首帧与末帧是否同帧、有无二次跳）。
3. 大字号/暗色/Reduce Motion。

---

## 8. 复现命令（sbx，只读）

```bash
ssh -p 2222 ubuntu@100.79.4.30
cd ~/wiring/scripts

# 组件组成（Body 类型别名）
python3 dump_ghidra.py --decompile 0x101933700   # ChatInputBar body（padding/圆角/玻璃/spring）
python3 dump_ghidra.py --decompile 0x100d96370   # EarlyKeyboardPadding body
python3 dump_ghidra.py --decompile 0x100d96a94   # 读 UIKeyboardAnimationDurationUserInfoKey
python3 dump_ghidra.py --decompile 0x100d95080   # 读 UIKeyboardFrameEndUserInfoKey + UIScreen
python3 dump_ghidra.py --decompile 0x100d9633c   # interpolatingSpring(3,1000,500)
python3 dump_ghidra.py --decompile 0x100d9619c   # willShow+willHide MergeMany

# 常量
python3 - <<'EOF'
import struct,sys; sys.path.insert(0,'.'); import aa
for a in [0x1042cb238,0x1043bb598,0x10422ea00,0x1042ccdb0]:
    print(hex(a), struct.unpack('<d',aa.image().read(a,8))[0])
EOF
```

---

## 9. 风险与未验证

| # | 项 | 等级 | 说明 |
|---|---|---|---|
| 1 | 截图归属：32/48 已被 pp 更正为 **AA 现状**；官方 Code 当前基准缺失 | 高 | 需 pp 提供官方 App 的 Code 页截图（收起 + 键盘弹起）。快速判据：placeholder AA 是 `描述任务...`，官方是 `描述任务或提出问题…`；AA composer 无麦克风，官方有 |
| 2 | `usesEarlyKeyboard` 是否覆盖已存在会话 | U | 只有新会话开关的证据；需 View Debugger/断点 |
| 3 | `.earlyKeyboardPadding` 挂载点 | U | 静态未定位；实现按等价行为，不追求同构挂载 |
| 4 | Debounce 值 | U | 官方 `DebouncedTaskModifier` 值未解出 |
| 5 | 当前 build 的展开高度/文字 inset | I | 96–98 来自旧版截图；当前 build 可能微调 |
| 6 | 字体/行高精确 token | U | 只能从截图 ink 推 ~17 pt；需 `ClaudeFonts` 逐 token 或真机 View Debugger |
| 7 | 方案 A/C 会改 drawer 壳层，影响 Chat/其他页面 | 高 | 必须真机全量回归；pp 批准后再动 |
| 8 | 双层键盘避让若处理不干净会出现“跳两下” | 高 | 需要 `IgnoresKeyboardSafeArea` 与卡片策略互斥，测试覆盖 |
| 9 | IME/中文输入、interactive dismiss、Reduce Motion | 中 | 官方 early keyboard 是否参与 IME 未验证 |

---

## 10. 需要 pp 决定

0. **先补官方 Code 页截图**（收起 + 键盘弹起各一张）：现有 Code 截图是 **AA 现状**，官方当前版本的视觉基准为空；没有它只能靠二进制 + 旧版图推断。
1. **键盘结构方案 A / B / C**（推荐 A；B 风险最低但不保证官方手感）。
2. **是否同时对齐 Chat 页**（官方 Chat 折叠是 16/52/0；AA 现在 32/48/10——即 AA 当前更像 Code 折叠）。
3. **功能范围**：只做 UI+键盘，还是把模型胶囊/权限/语音/notice 一并补齐？建议分两批：先 UI+键盘，再功能。
4. **Code 新会话页**（`NewSessionView`）是否同一套 composer 一起对齐。
5. 是否允许改 `SidebarDrawer.swift` / `ChatPageToolbar.swift`（共享壳层）。

---

## 12. 列表跟随键盘：官方路径 vs AA 现状（方案，2026-10-26，待 pp 批准）

### 12.1 现象

键盘弹起/收回时，AA 的消息列表（消息正文滚动区）跟不上输入框；官方是列表与输入框完全同步起落。

### 12.2 官方机制（EVIDENCE）

| # | 事实 | 证据 |
|---|---|---|
| 1 | 官方列表**没有任何键盘监听** | `keyboardWillChangeFrame:` / `keyboardWillShow` / `UIKeyboardFrameEndUserInfoKey` 在二进制零命中（`CANONICAL/05-layout-scroll.md:250`，负证据） |
| 2 | 安全区从 SwiftUI 传入列表 | `TranscriptList.body 0x1019fb120` 调 `GeometryProxy.safeAreaInsets`；`TranscriptListInput.safeArea`（字段 `0x104e3bdc8`）→ `TranscriptListSurface.safeArea`（字段 `0x104e3d1d8`）（`CANONICAL/05-layout-scroll.md:251`） |
| 3 | inset 公式 = `max(safeArea − scrollView.safeAreaInsets, 0)` | 设置点 `0x101a3c820`：`fsub` + `fcsel …, ge`（取 max 0），top/bottom 各一次（`CANONICAL/05-layout-scroll.md:455`） |
| 4 | 设 inset 时防回环 + 存/还原 offset | 同函数：`isSettingItsOwnInset`（字段 `0x104e3d208`）置 1 → `setContentInset`（`0x10418f920`）→ 置 0；之前用 `0x104155560` 取 `contentOffset`，之后按 `[obj+0x51] == 1` 用 `0x10418f9a0` 还原 |
| 5 | `contentInsetAdjustmentBehavior` 从未被设置 | 语料 §12.3：UIKit 默认 `.automatic`；键盘属于 UIKit 自己的安全区 |
| 6 | composer 挂载就是 `.safeAreaBar` | `SafeAreaContentModifier.body 0x100d75de0` → `.safeAreaBar(edge:.bottom,…)` `0x100d7620c`（语料 §12.1） |

**推论（INFERENCE，高置信）**：官方的“列表跟着输入框”不是它自己写的动画——键盘高度进的是 UIKit 自己的安全区，`adjustedContentInset` 在键盘动画里同步变化，UIScrollView 自动保持贴底；官方只额外补 composer 那一截（显式 `contentInset`），并在设置前后存/还原 `contentOffset` 防止二次位移。

**UNKNOWN**：SwiftUI 是否把键盘高度并入该页的 `GeometryProxy.safeAreaInsets`（语料 `05-layout-scroll.md:254` 标 INFERENCE，需真机打印）。这不影响方案：即使并入，公式里 `− scrollView.safeAreaInsets` 也会把键盘这一项抵消，键盘仍由 UIKit 负责。

### 12.3 AA 现状（EVIDENCE，代码行）

| 位置 | 现状 |
|---|---|
| `ios/Agents Anywhere/Agents Anywhere/Views/Chat/SessionChatView.swift:236` | composer 用 `.safeAreaBar(edge:.bottom)`（与官方一致） |
| `…/SessionChatView.swift:75` | `bottomBarInset: composerBarHeight` 手工把 bar 高度传给列表 |
| `…/TimelineCollection/TimelineCollectionController.swift:236,248` | `bottomBarInset` setter → `contentInset.bottom = max(0, bottomBarInset)` |
| `…/TimelineCollectionController.swift:281` | `contentInsetAdjustmentBehavior = .automatic`（与官方默认一致） |
| `…/TimelineCollection/TimelineChatTimelineView.swift:166,171,176` | **自己监听** `keyboardWillShow/Hide/ChangeFrame` → `beginKeyboardTransition` |
| `…/TimelineCollectionController.swift:2171` | 键盘过渡窗口 `keyboardTransitionActive` + 定时结束 |
| `…/TimelineCollectionController.swift:2203→2270` | `handleContainerHeightChange()` → `snapToBottom()`（`animated:false`，layout 回调里直接设到终点） |
| `…/TimelineCollectionController.swift:2282` | `pinBottomForKeyboardIfNeeded()` → 同一 snap |

**结论**：AA 在官方已有的系统机制之上，又自造了一套“键盘通知 + 每帧 snap + 过渡窗口”。二者同时改 `contentOffset` → 列表与输入框不同步（pp 看到的“跟随慢/跟不上”）。

### 12.4 方案（按官方，分四步）

**Step 1 · 拆掉自造链路（对应 §12.2 #1）**
- `TimelineChatTimelineView.swift`：删除 166–178 三个 `onReceive`、`keyboardTransitionBegan`，以及 `border`/`keyboard` 里仅为它服务的状态。
- `TimelineCollectionController.swift`：删除 `beginKeyboardTransition` / `endKeyboardTransition` / `keyboardTransitionTask` / `keyboardTransitionToken` / `pinBottomForKeyboardIfNeeded` / `keyboardVisible` 的键盘用途（`setKeyboardVisible` 若无其它消费方一并删）。
- `snapToBottom()` 保留，但只用于**非键盘**场景（内容增长、开屏落底、程序化回底）。

**Step 2 · inset 设置按官方加保护（对应 §12.2 #4）**
- `applyBottomBarInset()`：仅当 `bottomBarInset` 真的变化时写 `contentInset`；写之前存 `contentOffset`，写完还原，避免 UIKit 因显式 inset 二次重定位。

**Step 3 · 兜底：若系统不再贴底**
- 把 bar 高度按官方公式并入 SwiftUI 侧安全区：`contentInset.bottom = max(safeArea.bottom − collectionView.safeAreaInsets.bottom, 0)`（`safeArea` 从 `SessionChatView` 外层 `GeometryReader` 取，经 representable 传入），而不是现在的“只加 bar 高度”。
- 只在 Step 1 真机验证发现“完全不跟”时启用，不预先实现。

**Step 4 · 验证**
- CI：`test` / `build` / `code-profile` 三绿。
- 真机判据见 §12.6。

### 12.5 改动面

- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatTimelineView.swift`
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineCollectionController.swift`
- （Step 3 才涉及）`ios/Agents Anywhere/Agents Anywhere/Views/Chat/SessionChatView.swift`
- 不碰 composer 尺寸、不碰 `TimelineListLayout`、不碰流式跟随（`streamingFollowSpring`）。

### 12.6 验收判据（真机）

1. 点输入框：列表与输入框**同一帧**开始、同一帧结束，没有“先到/后到”。
2. 收起键盘：同上反向。
3. 交互式下滑收起：列表跟手，不跳。
4. 不在底部（正在读历史）时弹键盘：列表位置不变（官方 `.reading` 语义）。
5. 流式输出 + 键盘同时：不互相打架。

### 12.7 风险与回退

| 风险 | 处置 |
|---|---|
| 去掉自造 pin 后，UIKit 在这套 `UIViewControllerRepresentable` + `.ignoresSafeArea(.container)` 组合下不保持贴底 → 列表完全不跟 | 单 commit，`git revert` 即回到现状；随后按 Step 3 用官方公式接管 |
| 交互式下滑变差 | 官方同样不监听，属系统行为；若真机变差，按 Step 3 再评估 |
| `contentOffset` 存/还原引入抖动 | Step 2 单独一个 commit，便于单独回退 |

### 12.8 不做

- 不再调动画曲线/时长（官方没有可调参数，全是系统动画）。
- 不改 composer 尺寸/位置（已对齐）。
- 不引入新的键盘监听。

### 12.9 实施记录（2026-10-26）

| 步骤 | commit | 内容 |
|---|---|---|
| Step 1 | `d9e0dbd2` | 删除列表侧键盘监听链路：`TimelineChatTimelineView` 三个 `onReceive`、`keyboardTransitionBegan`、`TimelineKeyboardMonitor` 状态；`TimelineCollectionController` 的 `setKeyboardVisible` / `beginKeyboardTransition` / `endKeyboardTransition` / 过渡窗口 / `pinBottomForKeyboardIfNeeded` / 通知路径的 `anchorBottom`；连带删除 `TimelineKeyboardFollow` 与其测试。`snapToBottom()` 保留给非键盘场景。 |
| Step 2 | `360b4525` | `applyBottomBarInset()` 按官方 `0x101a3c820` 加保护：只写变化的 inset，写前后存/还 `contentOffset`（对齐 `0x104155560` / `0x10418f9a0`）。`bottomBarInset.didSet` 的贴底改由 `snapToBottom()` 承担（composer 增高，不是键盘）。 |
| Step 2b | `bfc28a1b` | `handleContainerHeightChange()` 不再对 **inset-only** 变化贴底：键盘就是这种 inset，UIKit 在键盘动画开始时已把值设成最终值并同步移动 offset，我们再 snap 等于第一帧就跳到终点。只保留容器高度变化（分屏/旋转）的贴底。 |

**未做**：Step 3（把 bar 高度并入 SwiftUI 安全区、按官方公式接管）—— 只有真机验证发现“完全不跟”时才启用。

### 12.10 视频逐帧比对（2026-10-26，60 fps）

方法：每帧取键盘顶边（键盘底色 #DCDDE1 的行占比 >55%）、正文区行边缘能量剖面（y 200–1050）的帧间互相关累计位移。

| 版本 | 键盘位移 | 列表位移 | 起止帧 | 中途相对键盘 |
|---|---|---|---|---|
| 官方会话页 | 2556→1551（Δ1005 px） | 875 px | f40→f62（0.37 s） | 与键盘同帧，误差 <10 px |
| AA `5bd96e7` | Δ1005 px | 917 px | f45→f67（0.37 s） | **领先 60–95 px**（约 20–30 pt） |

- 上一版（`360b452`）实测：键盘上升全程正文区帧间差恒为 17（无位移）→ 列表完全不动。
- 本版时序、总距离已对上；剩余差异是**曲线形状**：我把通知里的曲线 7（系统私有弹簧）映射成了 `.curveEaseInOut`，导致中段跑在键盘前面。改为按载荷原值放进 `UIView.AnimationOptions(rawValue: raw << 16)`，让动画直接用键盘自己的曲线。

### 12.11 8b16b09 逐帧定位（2026-10-26，60 fps）

| 帧 | t(s) | 键盘顶边 | 列表累计位移 | 输入框卡片顶边 |
|---|---|---|---|---|
| f62 | 1.034 | 2556（未起） | 0 | 2297 |
| f63 | 1.051 | 2556 | **76** | 2297 |
| f64–f67 | 1.07–1.12 | 2556 | 76（不动） | 2296 |
| f68 | 1.134 | 2503 | 126 | 2296 |
| f90 | 1.502 | 1551 | 909 | 上升中 |

- **列表先动、输入框没动**（卡片顶边 f58–f68 一直 2297/2296）→ 76 px 不是 composer 高度变化推动的。
- 76 px ≈ 1005 × 7.6%（键盘曲线起始段），随后 5 帧（83 ms）完全静止 → 预测式 `UIView.animate` 在 willShow 那帧被第一次布局取消并冻结，直到下一个键盘通知才重启。
- 中段位移/键盘位移恒为 0.90（f71 417/457、f74 686/757、settle 909/1005），曲线形状本身没问题。

**结论**：问题在"起手"，不在曲线。改用 `UIView.keyboardLayoutGuide`（键盘动画期间逐帧更新）+ `CADisplayLink` 每帧贴底：不再预测、无法被取消、拖动时主动停表。

### 12.12 真正的根因：列表 frame 被瞬间缩小（2026-10-26，含网页 Claude 的分析）

网页 Claude 对 8b16b096 的逐帧结论（截图核对）：键盘一开始动，列表底部的行（`python3` / `git add` / `nohup` / `Thinking…`）**整块消失**，列表与输入框之间出现 150–250pt 空白（正常 ~40pt），随后每帧多露出一行、约 5 帧补齐——即"卡一下"。消失位置固定在键盘弹起后输入框的高度，说明**列表被裁到终态尺寸**，不是内容在动。

代码层对应：
- `SessionChatView.timelineView()` 只写了 `.ignoresSafeArea(.container, edges: [.top, .bottom])`，**没有 `.keyboard`** → SwiftUI 在键盘出现的第一帧就把列表 frame 缩小（frame 变化不跟键盘动画）。
- `followKeyboard()` 只动 `contentOffset`，三套机制（composer 的 SwiftUI 动画 / 列表 frame 瞬时变 / 列表 offset 动画）各走各的 → 空洞 + 收起时领先。

修法（本版）：
1. 列表加 `.ignoresSafeArea([.container, .keyboard], edges: [.top, .bottom])` → frame 永远铺满全屏；
2. `contentInsetAdjustmentBehavior = .never` → UIKit 不再自动塞安全区，inset 全部由我们给；
3. `followKeyboard(endFrame:duration:curve:)` 在**同一个 `UIView.animate`（通知的 duration + 原始 curve）**里同时写 `contentInset.bottom = bar + max(resting, overlap)` 和 `contentOffset`（仅当贴底）；每次通知写一次，不逐帧写。

## 13. 根因与官方对齐方案（2026-10-26，只做分析，未改代码）

### 13.1 官方列表的完整形态（EVIDENCE）

```
TranscriptList.body (0x104eefbb0 类型串)
  GeometryReader { proxy in                    ← 安全区在这里读，含键盘
    TranscriptListBody(input.safeArea = proxy.safeAreaInsets)
      .ignoresSafeArea(…)                      ← 列表 frame 全屏 bleed
  }
TranscriptList.body 0x1019fb120 → TranscriptListInput.safeArea (0x104e3bdc8)
  → TranscriptListSurface.safeArea (0x104e3d1d8)
  → contentInset = max(safeArea − scrollView.safeAreaInsets, 0)   (0x101a3c820)
```

- 列表**不监听键盘**（`keyboardWillShow/WillChangeFrame/UIKeyboardFrameEndUserInfoKey` 零命中）。
- `contentInsetAdjustmentBehavior` 从未设置 = 默认 `.automatic`（语料 §12.3）。
- 贴底由锚点 `.end` 决定（`0x1019e2700`），阅读位置由 `.reading` 决定（`0x1019e2834`）。
- 实测（pp 的官方会话页录屏，60fps）：列表位移与键盘位移**逐帧 1:1**，误差 <10px（≈1.5pt）。

### 13.2 AA 现状与偏差（EVIDENCE，代码行）

| 环节 | 官方 | AA 现状 |
|---|---|---|
| 键盘来源 | GeometryProxy.safeAreaInsets（逐帧） | 键盘通知（`TimelineChatTimelineView.swift:172/176/180`） |
| 列表 frame | 全屏（ignore） | 全屏（ignore）——已对齐 |
| inset | `max(safeArea − sv.safeAreaInsets, 0)` | 手算 `bar + resting + overlap`（`TimelineCollectionController.swift:2256`） |
| offset | 锚点 `.end`，同一更新内重算 | 自己起 `UIView.animate` 写 offset |
| 输入框高度 | 包含在 safeArea 里 | 单独的 `bottomBarInset` 再加一次 |

⇒ 根因：**AA 把“安全区→inset→贴底”这一条链拆成了三条**（通知、输入框高度、offset 动画），任何一条时序不同步就表现为“跟不上/抢先/被遮/抖”。

### 13.3 对齐方案（三处，按官方形态）

1. `SessionChatView`：把 `timelineView()` 放进 `GeometryReader`（位置在 `.ignoresSafeArea` 之前），把 `proxy.safeAreaInsets.bottom` 传下去；
2. `TimelineChatTimelineView` → `TimelineCollectionController`：新增 `safeAreaBottom` 输入，`contentInset.bottom = max(safeAreaBottom − collectionView.safeAreaInsets.bottom, 0)`（官方公式原样）；
3. 删除：三个键盘 `onReceive`、`followKeyboard`、`keyboardOverlap`/`restingSafeAreaBottom`/`followDeadline` 等状态、以及 `bottomBarInset` 的加和（输入框已经在安全区里）。

贴底重算放在 `viewSafeAreaInsetsDidChange` / representable 的 `updateUIViewController` 里（同一次 SwiftUI 更新）。

### 13.4 唯一的未知（必须先证实再改）

**SwiftUI 在键盘动画期间是否逐帧把新的 `GeometryProxy.safeAreaInsets` 传给 representable。**
- 官方宿主里成立（上面的逐帧实测 + 它没有别的机制可以做到）。
- AA 的宿主（`.safeAreaBar` + ignores）是否一致，没有证据。

验证方式（先做，不改行为）：一个探针构建，在 `updateUIViewController` 里把 `safeAreaBottom`、`collectionView.adjustedContentInset.bottom`、`contentOffset` 打到屏幕上一行小字（或 os_log），pp 录一次键盘弹起。**若数值逐帧变化 → 方案成立；若只跳一次最终值 → 说明 AA 宿主不逐帧，方案作废，回到通知驱动并只修抖动。**

### 13.5 结论

- 根因已定位到“链条被拆成三条”，不是曲线、不是时序参数。
- 对齐官方只需要三处改动，且能删掉现有全部自造状态（净减代码）。
- 但开工前必须先证实 §13.4 的未知；在 pp 确认前不改任何代码。

## 14. 决定：走结构路（2026-10-26，pp 定）

**决定**：不再在现有五个写者上打补丁，改为按官方结构重做列表的滚动锚定层——“要弄就弄干净，底子好了后面改其他的才是根本”。

**纪律**：pp 压缩会话后，用 `sequential-thinking` 一块一块对照官方制定方案；**方案经 pp 确认前不写任何修复代码**。

### 14.1 需要逐块对照的官方部件（EVIDENCE 索引）

| # | 官方部件 | 证据 |
|---|---|---|
| 1 | 锚点 placement 三态 `.row(id,.top)` / `.reading(row,offset)` / `.end` | `05-layout-scroll.md §6.2`；`.reading` `0x1019e2834`、`.end` `0x1019e2700` |
| 2 | motion 五态 `resting/easing/flying/dragging/coasting` | §6.3 |
| 3 | reducer + 19 Event 事件跳表 | reducer `0x1019ddd30`、跳表 `0x1043c1570` / `0x1043c157c`，§6.4 |
| 4 | 贴底判定 `viewport[4] <= maxOffset − offset` | `0x1019e27bc` |
| 5 | 内容变高（流式）并入锚点（catch-up / `isFollowingCatchUp`） | §6.1 `0x45`、§6.4 |
| 6 | safe area → contentInset 公式 + 存/还 offset | `0x101a3c820`、`0x104e3d208`、`0x10418f9a0` |
| 7 | 键盘：零监听，只走安全区 | `05-layout-scroll.md:250` |
| 8 | 开屏落底 `viewportChanged → hasLanded` | `0x1019ee110`、`0x1019ddf70` |
| 9 | 回顶拦截 `scrollViewShouldScrollToTop → NO` | `0x101a3cb14`、`0x101a3d838` |
| 10 | 发送后新行 `.row(id,.top)` | `0x1019eb720`、`0x1019de554` |
| 11 | 列表形态：GeometryReader + ignores + representable | 类型串 `0x104eefbb0`、`TranscriptList.body 0x1019fb120` |

### 14.2 AA 需要被替换的五个写者（现状）

`armedBottom`（内容变高贴底）/ `streamingFollowLink`（流式跟随）/ `returnFollowLink` + `requestBottom`（回底动画）/ `readerRestsAtBottom` + `isScrollingToTop` + `bottomAnimationWatchdog`（开屏落底与阅读位置）/ 键盘通知链（本次新增）。

### 14.3 下一步（压缩后执行）

用 `sequential-thinking` 按 §14.1 的 1→11 顺序逐块产出：**官方行为 → AA 现状 → 差异 → 替换方案（文件:行号）→ 验证判据**，汇总成 §15 结构方案；pp 确认后再实施。

### 14.4 压缩后的恢复提示词

```
读 /home/ubuntu/aa-ring-work-composer/docs/composer-official-alignment-task.md 的 §13、§14。
任务：按 §14.1 的 11 个部件，用 sequential-thinking 逐块对照官方（证据在
/home/ubuntu/aa-test/claude-ios-re/CANONICAL/05-layout-scroll.md §6 与 sbx 反编译），
产出 §15 结构方案（官方行为/AA 现状/差异/替换方案/验证判据），pp 确认前不改代码。
分支 feat/code-composer-official，工作副本 /home/ubuntu/aa-ring-work-composer。
```

## 15. 结构方案：单写者锚点模型（2026-10-26，待 pp 批准，未改代码）

**结论**：把 AA 列表的滚动层换成官方同构的一条链——
`GeometryProxy.safeAreaInsets → contentInset 公式 → placement 三态 → 目标每帧现算 → 两条写路径`。
现有五个 `contentOffset` 写者与键盘通知链整体删除，`contentOffset` 只剩锚点层一个写者。
前置一个**只读探针包**解决唯一未证点（§15.7 U1）。**批准前不写实现代码。**

### 15.1 目标链

```
官方：GeometryReader(proxy.safeAreaInsets) → Surface: inset=max(safeArea−sv.safeAreaInsets,0)
      → reducer(placement 三态 + motion 五态) → target(每帧现算) → Mover / 直接 place
AA 新：SessionChatView 内层 GeometryReader → TimelineAnchorDriver
      → TimelineAnchorReducer（纯）→ TimelineAnchorTargetResolver（纯）
      → 安全区/容器变化：直接 place（halt Mover，同一事务写 inset+offset）
      → askedForEnd/Start、sent、内容增长：Mover（状态式弹簧）
```

两条写路径的分叉依据（INFERENCE，见 §15.7）：若键盘也走弹簧，临界阻尼
ω≈15.7 跟踪 2716px/s 会有约 300px 滞后，与官方实测逐帧误差 <10px 矛盾；
所以安全区变化必须直接 place。

### 15.2 逐块对照（官方行为 → AA 现状 → 差异 → 替换 → 判据）

**块 1 · placement 三态**
- 官方：`.row(id,.top)` 目标 `starts[idx]−topInset`；`.reading(row,off)` 目标
  `starts[idx]+off−topInset`（前插前缀和自动补偿，`0x1019e2834`）；`.end` 目标
  maxOffset（`0x1019e2700`）。
- AA 现状：无 placement 概念；贴底靠 `armedBottom`（`Models/Chat/TimelineCollection/TimelineArmedBottomTarget.swift:20`）+
  `readerRestsAtBottom`（`Views/Chat/TimelineCollection/TimelineCollectionController.swift:113`）；
  阅读位置靠 `visibleAnchorRowID()`（同文件 `:2508`）+ `adapter.pendingHistoryRequest`
  （`Views/Chat/TimelineCollection/TimelineChatTimelineView.swift:294-302`）。
- 差异：阅读位置只有「行」没有「行内偏移」，前插补偿靠一次性绝对锚，不是模型。
- 替换：新增 `Models/Chat/TimelineCollection/TimelineAnchorPlacement.swift`（三态 +
  `target(geometry:)`）；行身份用 `itemID`；`starts` 取
  `TimelineListLayout.attributes(for:)`（`Views/Chat/TimelineCollection/TimelineListLayout.swift:285`）；
  拖动开始/停止时由视口顶反推 `.reading(itemID, offsetIntoRow)`。
- 判据：单测——前插 N 行后 `.reading` 目标平移 N 行高度；`.end` 前插后仍贴底；
  `.row` 目标随 starts 变化。

**块 2 · motion 五态**
- 官方：resting / easing / flying / dragging / coasting。
- AA 现状：三套重叠语义——`TimelinePhaseMapping`（`Models/Chat/TimelineCollection/TimelinePhaseMapping.swift:17`，
  idle/interacting/decelerating/animating）、`TimelineScrollState.Mode`（reading/following/returning）、
  `armedBottom`（source/target 布尔）。
- 差异：`animating` 同时表示回底弹簧、系统回顶、UIKit 动画，无法区分 easing/flying。
- 替换：motion 进 reducer State；`TimelinePhaseMapping` 保留但仅作**派生视图**
  （dragging↔interacting、coasting↔decelerating、easing/flying↔animating），供现有 guard 读。
- 判据：motion 转移表单测；现有 phase 发布行为不变。

**块 3 · reducer + 事件**
- 官方：`0x1019ddd30`，19 事件（跳表 `0x1043c1570`），已命名 9 个（§6.4）。
- AA 现状：事件散落在 `UICollectionViewDelegate`（`Views/Chat/TimelineCollection/TimelineCollectionController.swift:2868-3005`）
  与产品回调里，直接改 offset 或改 phase。
- 差异：没有单一状态机，事件与副作用混在一起。
- 替换：新增 `TimelineAnchorReducer.swift`（State/Event/pure reduce）。事件集 =
  官方已命名 9 个 + AA 映射 5 个（`contentChanged` / `safeAreaChanged` /
  `windowReplaced` / `interactionPresentedChanged` / `navigationSuspendedChanged`）。
  控制器 delegate 只发事件；offset 只在 driver 的 `apply()` 写。
- 判据：事件序列表单测（拖动中 askedForEnd 忽略；已飞向 end 忽略；arrived 只从
  easing/flying 回 resting；sending 记 `heldTheEnd`，sent 改 `.row`）。

**块 4 · 贴底判定**
- 官方：`viewport[4] <= maxOffset − offset`（`0x1019e27bc`）→ 重新武装 `.end`，否则记 `.reading`。
- AA 现状：`viewport.measuredAtBottom` + `readerSettledAtBottom` 双布尔（`:118`、`:2390-2392`）。
- 差异：判定散在 settle 任务（`:2383`）与 `noteBottomArrival`（`:2334`），另有 64ms 窗口。
- 替换：`isAtEnd(offset,…) = offset >= maxOffset − 1/displayScale`，由 reducer 在
  `readerLifted`/`coastingEnded`/`scrolledWithoutAHand` 时调用；删 64ms settle 任务。
- 判据：边界单测（正好贴底 / 差 1px / 内容短于视口 / 内容长一屏）。

**块 5 · 内容变高 / 流式并入锚点**
- 官方：目标每帧现算，`.end` 随内容增长自动变大；Mover 每帧读最新目标
  （`0x1019f417c`）；>2 屏先 pre-place 一屏（`0x1019deecc`）；ease/fly 弹簧
  0.4/0、0.36/0.15。
- AA 现状：三条互斥机制——`armedBottom` 即贴（`:2436`）、`streamingFollowLink`
  解析弹簧（`:771-927`）、`returnFollowLink`（`:185`）。
- 差异：每个写者各自判目标、各自起动画，互相靠 nil 让路（`:2440`）。
- 替换：`contentChanged` → 若 `.end` 启动/继续 Mover（≤1 屏 ease，>1 屏 fly，
  >2 屏 pre-place）；`.reading` 不写。Mover 改**状态式弹簧积分**
  `v += (ω²(target−x) − 2ζω·v)·dt; x += v·dt`，阈值 1/displayScale；驱动用
  `UIUpdateLink`（phase `.beforeCATransactionCommit`、continuous、fps
  [max/2, max]；deployment target 26.2 可用）。复用
  `Models/Chat/TimelineCollection/TimelineSpringFollow.swift:11` 的常量与
  `shouldMove`/`preplacedOffset`。
- 判据：流式增长 500pt 跟随到底且无二次跳；距底 3 屏时先瞬移一屏再飞。

**块 6 · safe area → inset**
- 官方：`contentInset = max(safeArea − scrollView.safeAreaInsets, 0)`
  （`0x101a3c820`），写时 `isSettingItsOwnInset`（`0x104e3d208`），写前后存/还 offset
  （`0x104155560` / `0x10418f9a0`）。
- AA 现状：手算 `bar + resting + keyboard`（`Views/Chat/TimelineCollection/TimelineCollectionController.swift:263`、
  `:2256`、`:2296`）；`bottomBarInset` didSet 另触发 `snapToBottom()`（`:233-244`）。
- 差异：输入框高度与键盘各加一次，来源三条。
- 替换：控制器新增 `safeAreaInsets` 输入；inset 只按官方公式四边写
  （顶边一并由它供给，消除现在 top=0 的隐患）；删除 `bottomBarInset`/`restingSafeAreaBottom`/
  `keyboardOverlap` 的加和逻辑；`contentInsetAdjustmentBehavior` 改 `.never`。
- 判据：单测公式（home indicator / 键盘 / 旋转 / 负值 clamp）；真机 inset 与官方同值 ±1pt。

**块 7 · 键盘零监听**
- 官方：列表层零键盘通知（负面 EVIDENCE，`05-layout-scroll.md:250`）。
- AA 现状：三 `onReceive`（`Views/Chat/TimelineCollection/TimelineChatTimelineView.swift:170-181`）→
  `followKeyboard`（控制器 `:2236`）+ `retargetFollow`（`:2294`）。
- 差异：键盘被当成独立事件源，与安全区并行的第二个真值。
- 替换：整链删除；键盘只通过 `proxy.safeAreaInsets` 进入（块 6）。
- 判据：全仓 `keyboardWillShow|WillChangeFrame|UIKeyboardFrameEndUserInfoKey` 在
  timeline 域零命中；键盘起落逐帧 1:1。

**块 8 · 开屏落底**
- 官方：`opensAtTop=false` → 初始 `.end`；`viewportChanged` → `hasLanded=1`
  （`0x1019ddf70`）后首置（`0x1019df5f8`），首置直接 place。
- AA 现状：`beginOpeningBottom`（`:2108`）/`settleOpeningBottom`（`:2128`）/
  `snapToBottom`（`:2322`）+ bridge 四件套（`TimelineChatTimelineView.swift:332-372`）
  + 窗口替换 `reassertOpening`（`:378`）/`resolveWindowReplacementBottom`（控制器 `:935`）。
- 差异：开屏是独立命令，不是 placement 的初始态。
- 替换：reducer State 加 `hasLanded`；首个有效布局 → `viewportChanged` →
  直接 place 当前 placement（初始 `.end`）。窗口替换 = 未接管 → `askedForEnd(animated:false)`；
  已接管 → 不动。遮罩释放仍由 `onBottomArrived`/400ms 兜底。
- 判据：开屏无滚动动画落底；替换窗口后未接管者到底、接管者不跳。

**块 9 · 回顶拦截**
- 官方：`scrollViewShouldScrollToTop` → `askedForStart(animated:true)` → **返回 NO**
  （`0x101a3cb14` / `0x101a3d838`）。
- AA 现状：返回 true（`:2965-2993`），`isScrollingToTop` + 600ms watchdog +
  `.scrollToTopBegan/.scrollToTopEnded`。
- 差异：系统动画写 offset = 第六个写者。
- 替换：返回 false，发 `askedForStart`（placement=.reading(首行,0)，Mover 驱动）；
  删 `isScrollingToTop`/watchdog/token 与两个 phase 事件。
- 判据：状态栏点按一次弹簧到顶，无系统动画叠加。

**块 10 · 发送后新行**
- 官方：`sending` 记 `anchor=onItsWay(heldTheEnd: placement==.end)`；`sent(RowID)`
  → placement `.row(id,.top)`（`0x1019eb720` / `0x1019de554`）。
- AA 现状：无发送事件；靠 `TimelineChatTimelineView.swift:125/137` 监听 pending/
  response 变化 → `requestBottom(animated:true, forced:false)`（贴底）。
- 差异：行为不同——官方是新行贴顶，回复向下展开；AA 是始终贴底。
- 替换：adapter 发送路径发 `sending`/`sent(itemID)`；pending→confirmed 换 ID 时
  由 adapter 提供映射迁移锚点，找不到退化 `askedForEnd`。**这是可见行为变化，按官方执行**（§15.8-3）。
- 判据：发送后新行贴视口顶；回复流入不抢滚动；键盘弹起仍 1:1。

**块 11 · 列表形态**
- 官方：`GeometryReader → TranscriptListBody → _SafeAreaRegionsIgnoringLayout`（类型串
  `0x104eefbb0`），代理安全区在 ignores 之外读。
- AA 现状：`SessionChatView.swift:221` 的 GeometryReader 在 `.safeAreaBar`（`:241`）**外面**，
  读不到 composer bar；列表 `:87` 已 ignores container+keyboard；控制器
  `contentInsetAdjustmentBehavior = .automatic`（`:308`）。
- 差异：安全区读取点位置不对，bar 高度靠单独参数补。
- 替换：`timelineView()`（`:65-87`）内加 GeometryReader（在 safeAreaBar 修改过的安全区内、
  ignores 之外），`safeAreaInsets` 下传；`TimelineCollectionView.swift:16/26/38` 的
  `bottomBarInset` 参数删除。
- 判据：探针显示 proxy 含 bar+home+keyboard（U1）；旋转/分屏数值正确。

### 15.3 新增文件

| 文件 | 职责 |
|---|---|
| `Models/Chat/TimelineCollection/TimelineAnchorPlacement.swift` | 三态 + 目标解析（纯） |
| `Models/Chat/TimelineCollection/TimelineAnchorReducer.swift` | State/Event/pure reduce（纯） |
| `Models/Chat/TimelineCollection/TimelineAnchorMover.swift` | 状态式弹簧积分 + arrived（纯） |
| `Views/Chat/TimelineCollection/TimelineAnchorDriver.swift` | 唯一写者：inset/offset、UIUpdateLink、事件入口 |

### 15.4 删除清单（净减代码）

- 控制器：`armedBottom` 全族、`streamingFollowLink` 全族（`:158-177`、`:765-927`）、
  `returnFollowLink` 全族（`:178-190`、`:1099-1135` 部分）、`bottomAnimationWatchdog`
  （`:2402-2434`）、`readerRestsAtBottom`/`readerSettledAtBottom`/`mode`/`isScrollingToTop`
  与相关 settle（`:2334-2400`、`:2178-2182`）、键盘链（`:145-155`、`:2219-2320`）、
  `applyBottomBarInset` 的加和版（改为官方公式）、`handleContainerHeightChange` 的 snap。
- 视图层：`TimelineChatTimelineView.swift:170-181`、`:208-216`、`:18/:37/:104` 的
  `bottomBarInset`；`TimelineCollectionView.swift:16/:26/:38`。
- 模型层：`TimelineArmedBottomTarget`（整个文件）；`TimelinePhaseMapping` 保留但只派生。
- 布局层：`TimelineListLayout.swift:413-433` 的 `applyOffsetFallback` 直接
  `setContentOffset` 改为发 `readingReplaced` 事件（`contentOffsetAdjustment`
  的 `:642/:876/:1147` 保留——那是 UIKit 布局失效机制，不是独立写者）。

### 15.5 实施顺序（每步可编译、CI 绿）

1. **C1 纯模型 + 单测**（不接线）。
2. **C2 探针包**（只加诊断显示，不改行为；pp 录一次键盘起落）→ 依据 U1 结论二选一。
3. **C3 列表形态 + inset 归属**（GeometryReader / `.never` / 官方公式）——必须与
   **删除键盘链同一步**，否则双写。
4. **C4 锚点接线**：先接 driver 与事件，禁旧写者；再按家庭删旧代码
   （armedBottom → streaming → return → opening/scrollTop → layout fallback），
   每个家庭一个 commit。
5. **C5 门禁/TimelineAutoRun 适配 + 全量回归**。

### 15.6 验证判据（真机，60fps 录屏 + 逐帧脚本）

- 键盘起落：列表位移/键盘位移每帧 1.00±0.02，无首帧跳跃、无结束 snap。
- 发送：新行贴顶、回复增长不抢滚动。
- 回顶：一次弹簧到顶。
- 前插/加载更早：阅读位置零位移；开屏：无动画落底。
- 抽屉、审批卡、Reduce Motion、旋转/分屏：零回归。
- 自动化：Models 单测（placement/reducer/mover/公式）全绿；CI `ios-build.yml` 绿。

### 15.7 风险与未证点

- **U1（UNKNOWN，施工前必须证实）**：AA 宿主里 `GeometryProxy.safeAreaInsets` 是否
  逐帧动画、是否包含 `safeAreaBar` 的 composer 高度。探针解决。
  - R1 不逐帧 → 退回通知驱动，但只保留「inset+直接 place」单写者，其余不变。
  - R2 不含 bar → `safeArea + composerBarHeight`（仍零键盘监听）。
- **R3**：`.never` 曾与键盘链同改导致启动卡死 → C3 单独改，探针包先验启动；
  异常则保持 `.automatic`（公式减 `sv.safeAreaInsets`，双计为 0）。
- **R4**：`updateUIViewController` 每帧调用 → update 里只写幂等 inset/place，
  快照由 `contentGeneration` 守护；探针记录每帧耗时。
- **R5**：安全区与 Mover 同帧竞争 → `safeAreaChanged` 先 halt 再直接 place。
- **R6**：pending→confirmed 换 ID → 锚点迁移映射，失败退化 `askedForEnd`。
- **R7**：门禁/测试绑定旧 API → 保留兼容门面，最后删。
- **R8**：回顶改由 Mover → 拖动/减速中忽略 `askedForStart`（官方 askedForEnd 同规则）。

### 15.8 需要 pp 决定

1. **先出探针包**（只加一行诊断显示，不改行为）录一次键盘起落 —— U1 唯一未证点。
2. **`contentInsetAdjustmentBehavior = .never`**（上次与键盘链同改导致启动卡死，这次单独验证）。
3. **发送后行为按官方改为 `.row(id,.top)`**（新消息贴顶、回复向下展开，不再贴底）——
   可见行为变化，按官方证据执行，需 pp 知情确认。

方案批准后按 §15.5 实施；批准前不改任何实现代码。
