# Code 页 turn action bar 任务单（2026-10-26）

> 分支 `feat/code-profile-beta`（工作副本 `/home/ubuntu/aa-ring-work`），dev 不碰不合。
> 级别：**M**（iOS 单端视觉+交互）。若本次包含服务端 feedback 落库，升级为 L 并单开跨端任务单。
> 依据：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round18/user-row-and-action-bar.md` §3（官方 1.261005.20 反汇编）、`EVIDENCE/code-page-strings.csv`、AA 当前代码。
> 证据标记：[E] 指令/类型直读；[I] 结构推断；[U] 未验证。

---

## 0. 一屏结论

- **官方 turn action bar 是独立 transcript 行**（`Content.turnActionBar` = tag 3，负载 `ClaudeCode.TurnActionBar`），不是消息尾部内嵌；挂在 turn 的 anchor 消息上 [E]。
- **4 个纯图标按钮，顺序 Copy / Speak / 赞 / 踩**（可选第 5 个 SendTo）；图标 20×20、最小点击宽 32、HStack 间距 12；**仅 Copy 有 `.selection` 触感**；无 padding / 无背景 / 无圆角，行 `frame(maxWidth:.infinity, alignment:.leading)` [E]。
- **官方有独立行 + 环境开关**：`Inputs.isActionBarEnabled`（+0x68）== 1 且 anchor 非空才建行；`+0x69` 作为 `canSubmitTurnFeedback` 传入 [E]。**置真时机 [U]**（推断：只在可操作的已完成 turn 上）。
- **AA 现在完全没有 Code action bar**（全仓 grep 0）。已有的只有代码块内的 copy 按钮（含 `anthropicon.copy` → `check` 2 s 切换与 `.selection` 触感）和 Chat 参考行的 `SessionTurnActionsRow`（copy/赞/踩/重生成 + 时间，非官方 Code 形态）。
- **P1 范围（pp 2026-10-26 拍板）：Copy 接功能 + 分享按钮占位不接功能**；不画 Speak / 赞 / 踩，不做 feedback，不伪造 TTS/服务端。
- 显示时机：只在 turn 结束后（`TimelineTurnActions.build(suppressLatest: model.isRunning)` 已有此语义）。

---

## 1. 官方事实（EVIDENCE）

### 1.1 行与创建

| 项 | 结论 | 出处 |
|---|---|---|
| 行类型 | `SessionTranscriptEntry.Content.turnActionBar` = tag 3 | `round18 §3.1`（CSV 47487） |
| 负载类型 | `TurnActionBar{anchorId, textRows:[DisplayMessage], apiMessageIds:Set<…>, feedback: MessageFeedbackType?}` | 同上 |
| 视图 | `SessionMessageActionBar{turn, context}` | CSV 52204–52205 |
| 创建门 | `Inputs+0x68 == 1` 且 anchor 非空 | `round18 §3.2`（`0x10253f794` / `0x1025400f8`） |
| canSubmitTurnFeedback | `Inputs+0x69` 作为第 4 参传给构建器 `0x10255c854` | 同上 |
| 内容为空时的门 | `textRows` 为空且 `canSubmitTurnFeedback == 0` → 不产可用 bar | 同上 |
| 环境总开关 | `__Key_showsCodeMessageActionBar`（`0x104eff128`）+ `SessionMessageList._isActionBarEnabled`（`0x104e89030`） | 同上 |
| 出现时机 | **未定位上游置真写点**；不能静态断言“完成后出现 / 流式中不出现” | `round18 §3.5`（[U]） |

### 1.2 按钮顺序 / 图标 / 状态

| # | 语义 | 默认图标 | 激活/选中图标 | 交互 |
|---|---|---|---|---|
| 1 | Copy | `anthropicon.copy` | `anthropicon.check` | 唯一带触感：`SensoryFeedback.selection` |
| 2 | Speak / Stop speaking | `anthropicon.play` | `anthropicon.pause` | 普通 Button，异步 Task 起停 TTS（TTS 实现 [I]） |
| 3 | 赞 | `anthropicon.thumbsUp` | `anthropicon.thumbsUp.fill` | 普通 Button |
| 4 | 踩 | `anthropicon.thumbsDown` | `anthropicon.thumbsDown.fill` | 普通 Button |
| 附加 | SendTo | — | — | 能力门为真才追加，不属 4 个主按钮 |

- 4 个主按钮**无条件构造**（没有按 Bool 隐藏单个按钮的分支）；变化的是图标/标签状态。`canSubmitTurnFeedback` 只在“无 textRows 时是否产 bar”上被观察到 [E 构造 / U 禁用语义]。
- 文案 key（`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/code-page-strings.csv`）：`copy` → 复制（:204）、`speak_message` → 朗读消息（:509）、`stop_speaking` → 停止朗读（:512）、`give_positive_feedback` → 提供正面反馈（:291）、`remove_positive_feedback` → 移除正面反馈（:412）、`give_negative_feedback` → 提供负面反馈（:290）、`remove_negative_feedback` → 移除负面反馈（:411）、`message_actions` → 消息操作（:297）。

### 1.3 尺寸 / 外壳 / 无障碍

- `IconButtonRow.Body`（`0x100bca7b0`）：`HStack(spacing: 12.0)` + `TapTargetButtonStyle(glyphSize: 20.0, minimumTapWidth: 32.0, hovers: true)` + `.labelStyle(.iconOnly)` + `.frame(maxWidth:.infinity, alignment:.leading)` [E]。
- 外壳 `0x102b49914`：`.accessibilityElement(children: .ignore)`、`.accessibilityLabel("Message actions"/"消息操作")`、`.accessibilityIdentifier("session-message-action-bar")`、`.accessibilityActions`；**无额外 padding / background / 圆角** [E]。
- 图标颜色、行与相邻消息的垂直间距、动作条背景色：**UNKNOWN**（round18 未给；需补反编译或真机像素对照）。

---

## 2. AA 现状（EVIDENCE，代码）

| 项 | 现状 |
|---|---|
| action bar | **不存在**：`ActionBar` / `thumbsUp` / `speak_message` 在 `ios/Agents Anywhere/Agents Anywhere` 全仓 0 命中（只有图标资产表） |
| Copy 资产与触感 | 已有：`anthropicon.copy` / `anthropicon.check` 资产；代码块 copy 已实现 copy→check 2 s 切换 + `UISelectionFeedbackGenerator`（`/home/ubuntu/aa-ring-work/ios/Agents Anywhere/Agents Anywhere/Views/Chat/TextKit/AssistantMarkdownBlockViews.swift:516`–`:529`） |
| TTS | 无：`AVSpeech` / `SpeechSynthesizer` / `TTS` 全仓 0 命中 |
| feedback 通道 | 无：`server/agent_server` 无 feedback 接口；iOS 无 `MessageFeedback` 模型 |
| 行模型 | `TimelineChatContentAdapter` 按 `ChatTimelineGroup`（一条 wire 消息一组）构建行；`CodeMessageRowView` 只渲染组内 blocks（`/home/ubuntu/aa-ring-work/ios/Agents Anywhere/Agents Anywhere/Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift:1003`–`:1015`） |
| 思考/工具行 | 已在同一条渲染链；action bar 需要新的顶层行类型，不能塞进 block 枚举（否则顺序/高度/签名都会被当消息内容） |

---

## 3. 行为与数据缺口

| # | 项 | 官方 | AA | 处理 |
|---|---|---|---|---|
| 1 | Copy 的载荷与拼接 | `TurnActionBar.textRows` 是 turn 的文本行集合；**具体拼接符/是否含 markdown 原文 [U]** | 无 | 先补反编译（`0x102b4a1f0` 的 action 闭包）再实现；候选：按 wire 顺序 `"\n\n"` 连接，但不先写死 |
| 2 | Speak 的 TTS | 有 `play`/`pause` + `speak_message`/`stop_speaking`；TTS 来源与语音 [I/U] | 无 | P1 不做；或先只做官方确认的按钮外壳 + 隐藏？**建议不做假 TTS** |
| 3 | 赞/踩的落点 | `MessageFeedbackType?`，提交到服务端（官方） | 无接口/无存储 | 选项：A 暂不显示（推荐）；B 仅本地态（违反宁缺勿假）；C 新增服务端契约（L，跨端） |
| 4 | SendTo | 能力门可选按钮 | 无能力 | 不做 |
| 5 | 出现时机 | `isActionBarEnabled` 上游 [U] | — | AA 建议：**turn 结束（无 pending/running）且该 turn 有非空正文** 才显示；流式中不显示，实现前在真机对照官方 |
| 6 | 行位置 | 独立 transcript 行，anchor 为消息 id | 消息组是顶层行 | 在 adapter 中作为新行插到该消息组之后；高度/签名/摘要键独立 |
| 7 | 图标颜色/行距/背景 | UNKNOWN | — | 实现前补：图标 `foregroundStyle` 构造点与列表 row spacing；无证据时按其他行图标同款 `toolRowSecondaryColor` 需标注为 [I] |

---

## 4. 实施方案（P1，建议）

1. **先闭环证据缺口**（sbx 只读）：Copy 拼接、图标颜色、行间距。已有地址：`0x102b49dac`（内容体）、`0x102b4a1f0`（Copy 构造）、`0x102b49914`（外壳）。官方 `isActionBarEnabled` 上游写点仍 [U]，AA 按“turn 结束后显示”实现。
2. **复用现有 turn 模型**：`TimelineTurnActions.build` 已给出每个 turn 的结束组与 `copyText`（replies 去空白后 `"\n\n"` 连接，已有单测 `TimelineTurnActionsTests`），不新造模型。
3. **视图** `CodeTurnActionBar`：
   - Copy + 分享占位两个按钮，`HStack(spacing: 12)`；glyph 20 pt（官方 `.large` Anthropicon）、最小宽 32 pt；
   - Copy：写剪贴板 → 图标切 `check` 2 s → `.selection` 触感；
   - 分享：`anthropicon.share`，无 action；
   - 无障碍：label「消息操作」、identifier `session-message-action-bar`、`accessibilityAction` 复制/发送到（对齐官方 `children: .ignore` 形态）。
4. **行接入**：复用 `TimelineChatContentAdapter.assistantFooter(for:)`（turn 结束组之后的既有 footer 位置）；Code runtime（`codeProfile.family != .generic`）用 `CodeTurnActionBar`，普通 Chat 保持 `SessionTurnActionsRow`；`FooterPlan` 按 profile 取对应 `actionRowHeight`。
5. **本地化**：新增「发送到」`Send to`、「消息操作」`Message actions`；「复制」已有。
6. **测试**：
   - `TimelineTurnActionsTests` 已有 copyText 拼接用例；新增 bar 高度常量的直测；
   - 真机：copy 触感、点击区域、与消息/工具行间距、流式中不出现、普通 Chat 会话不变成 Code bar。
7. **不做**：Speak、赞/踩、feedback、真实分享（P1）；如 pp 要，另开 P2/P3。

---

## 5. 风险与未验证

1. Copy 拼接若未按官方（例如漏了 markdown、或错误包含 reasoning）会复制出用户没看到的文本 —— 必须先取证，宁缺勿假。
2. Speak/feedback 若做成本地假状态，属于伪造能力 —— 默认不做。
3. 新行使列表行数变化，需同时改高度测量与签名，否则会出现高度跳动（本线历史踩过）。
4. 真机尚未对照过 action bar 的实际出现时机（官方视频那帧没有 bar，可能录制时总开关关闭）。

---

## 6. pp 决定（2026-10-26）

1. **P1 按钮范围 = Copy + 分享占位**：Copy 接功能；分享（官方 `SendToButton`）只画图标、点击无反应；Speak / 赞 / 踩不画。
2. **feedback**：不做（不显示赞/踩）。
3. **显示时机**：只在 turn 结束后。
4. 分享图标暂用官方 `anthropicon.share`（从官方 1.261019.51 `Assets.car` 提取；它与 `SendToButton` 的实际图标对应关系 [U]，先按最接近的官方分享字形占位）。

---

## 7. 复现取证明细（sbx，只读）

```bash
cd /home/ubuntu/wiring/scripts
python3 disas.py 0x102b49dac --no-decompile --count 260   # 内容体：按钮顺序/状态
python3 disas.py 0x102b4a1f0 --no-decompile --count 120   # Copy action 闭包（拼接载荷）
python3 disas.py 0x102b49914 --no-decompile --count 120   # 外壳：无障碍/布局
python3 disas.py 0x100bca7b0 --no-decompile --count 160   # IconButtonRow：20/32/12
python3 q.py --callers 0x10255c854 --exact-only           # TurnActionBar 构建器调用者
```
