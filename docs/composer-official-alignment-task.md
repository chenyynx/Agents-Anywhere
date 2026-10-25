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
2. **尺寸不一样（E，截图实测）：**
   - Code 折叠态：左右 **32 pt**、高 **48 pt**、卡底距安全区 **+10 pt**、胶囊圆角 24；
   - Chat 折叠态：左右 **16 pt**、高 **52 pt**、卡底贴安全区（+0）、胶囊圆角 26；
   - Code 展开态（旧版截图）：左右 **16 pt**、高 ~**96–98 pt**、卡底贴安全区、圆角 **24 continuous**。
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

| 项 | Code 折叠 | Chat 折叠 | Code 展开（旧版截图） |
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
- Code 折叠：`file_rcaDbU2vZNsfPqlP-Photo-9BC9389E.png`，卡 bbox `x 96–1082, y 2280–2423`；黑圆 `x 957–1064, y 2298–2405`；`+` ink `x 147–188`；`⌘` ink `x 860–898`。
- Chat 折叠：`file_deRg7JiV1gUeI1yY-Photo-5672AFF7.png`，卡 bbox `x 50–1128, y 2298–2453`；黑圆 36 pt；`回复 Claude` placeholder。
- Code 展开（旧版）：`REFERENCES/device/code_session_light_cleared_1320x2868.jpg`（1320×2868，x 48–1271，高 98）与 `REFERENCES/round2/device/code_session_dark_de_1170x2532.png`（1170×2532，x 48–1121，高 96）。
- **状态差异提醒：** Code 折叠截图处于“运行中”（停止方块），Chat 折叠处于“空闲”（语音圆）；尺寸差异与状态无关（多张同组截图一致），但仍按 **I** 处理页面归属。

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

## 6. 文件清单

### 新增
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/ComposerMetricsProfile.swift`（纯模型）
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/ComposerKeyboardDriver.swift`（纯逻辑 + 通知）
- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/Composer/EarlyKeyboardPadding.swift`（ViewModifier）
- `ios/Tests/ClientCoreTests/ComposerMetricsProfileTests.swift`
- `ios/Tests/ClientCoreTests/ComposerKeyboardDriverTests.swift`

### 修改（composer 域）
- `Views/Chat/Composer/ChatComposer.swift`（profile、placeholder、控件可见性、动画来源）
- `Views/Chat/Composer/ComposerLayout.swift`（profile 驱动布局）
- `Views/Chat/Composer/ChatControlMetrics.swift`（profile 化）
- `Views/Chat/Composer/ChatComposerDock.swift`（profile 传递、placeholder 状态、Code 控件）
- `Views/Chat/SessionChatView.swift`（Code profile 选择、early keyboard 挂载；**共享页壳，需列出**）

### 共享文件（尽量少动；必须动时只追加 composer 内容并单独汇报）
- `Views/Chat/ChatPageToolbar.swift`（方案 A/C 需调整 `.ignoresSafeArea(.keyboard)`）
- `Views/Components/SidebarDrawer.swift`（方案 A/C 需卡片忽略键盘）
- `Resources/Localization/Localizable.xcstrings`（只追加 composer 文案）
- `Agents Anywhere.xcodeproj/project.pbxproj`（新增文件登记）

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
| 1 | 页面归属（32/48 vs 16/52）来自截图 + 会话壳识别，不是二进制 | I | 需真机/多截图复核；若 Code 空闲态也变 16/52，则属状态而非页面差异 |
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

1. **键盘结构方案 A / B / C**（推荐 A；B 风险最低但不保证官方手感）。
2. **是否同时对齐 Chat 页**（官方 Chat 折叠是 16/52/0；AA 现在 32/48/10——即 AA 当前更像 Code 折叠）。
3. **功能范围**：只做 UI+键盘，还是把模型胶囊/权限/语音/notice 一并补齐？建议分两批：先 UI+键盘，再功能。
4. **Code 新会话页**（`NewSessionView`）是否同一套 composer 一起对齐。
5. 是否允许改 `SidebarDrawer.swift` / `ChatPageToolbar.swift`（共享壳层）。
