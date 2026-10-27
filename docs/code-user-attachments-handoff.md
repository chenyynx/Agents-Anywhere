# 交接 · Code 页用户附件实现（2026-10-27）

> 新会话先读本文件 + `docs/code-user-attachments-task.md` + `/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round25/CLOSURE.md`。
> 铁律：`dev` 不碰不合；只从分支出包；不 force push；证据不编；出包/交流带构建号。

## 0. 目标与现状

**目标**：Code 页用户消息附件（图片 tiles / 成功文件 FileTile / 失败上传卡），并修复“发送后附件消失”。

**根因（已闭合）**：`CodeMessageBuilder` 只读 `.text`，`CodeMessageRowView`/`CodeUserBubble` 没有附件分支；pending 带附件时回退 Chat 气泡，echo 后 pending 删除 → 附件消失。wire 数据正常（`V2MessageContent.attachments`）。

**证据已闭合**：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round25/CLOSURE.md` 判定“附件默认视觉所需数值全部闭合，无阻塞项”。跨轮修正在 `CANONICAL/CORRECTIONS.md` #70–#90。

## 1. 分支 / 工作区（当前）

- 工作副本：`/home/ubuntu/aa-wt-attachments`
- 分支：`feat/code-profile-beta`
- HEAD：`0d727e7b`（docs 交接；其前为 `afb8ed0a` 任务单）
- 历史包含：`6fa985de`（附件链路审计）、`b160c90f`（Merge `feat/drawer-fullscreen-swipe` → 实验分支，侧栏改动）、`ae2ea037`（动作条 medium）
- 另有 `/home/ubuntu/aa-ring-work` 处于 detached `b2f13f1a`（未动）；composer 线在 `/home/ubuntu/aa-ring-work-composer`（独立分支）
- 工作区当前有阶段 1/2A/2B 的**未提交**实现改动，不要回退

## 2. 实现进度

### 阶段 1（已完成，未提交）

- 新增 `Models/Chat/Code/CodeAttachmentLayout.swift`、`Tests/ClientCoreTests/CodeMessageTimelineTests.swift`
- 修改 `CodeMessageTimeline.swift`：`Block.attachments(id:files:clientMessageID:)`；builder 读 `V2MessageContent.attachments`、按 `fileId ?? raw` 去重、多 body 顺序、纯附件保留
- 修改 `CodeRowHeightPlan.swift` / `CodeMessageHeightMeasurer.swift`：附件高度公式
- `CodeMessageRowView` / `TimelineChatContentAdapter` / `CodeProfileAutoRun` / `CodeProfileModelTests` 只加枚举占位分支
- 10 个文件 `swiftc -parse` 全过；本机 Swift 6.0.3 不能跑 6.2 包测试

### 阶段 2A（已完成）

- `CodeAttachmentTiles.swift`（图片网格 + `+N` + 状态遮罩）
- `CodeFileTile.swift`（成功文件格）
- `CodeArtifactPreviewCard.swift`（失败卡）
- `CodeAttachmentRow.swift`（图片块 + 文件块组合）
- `CodeUserMessageRow.swift`（气泡 + 附件 + 交付指示器）
- `CodeMessageRowView.swift`（`.attachments` 真正渲染，附件在气泡外）
- `CodeUserBubble.swift`（删空 `attachments` 槽位）

### 阶段 2B（已完成；CI build 561 全绿）

- Adapter 接线：`CodeMessageRowView` 传 `onAttachment` / `model.thumbnail` / resolver（`model.session.attachmentPreviews.resolve(contents, clientID:)`）
- Code group signature / `codeHeightDigest` / `heightKey` / `hasVisibleBlock` / `officialEstimateHeight` / `measuredCodeGroupHeight` 纳入附件
- pending 统一：`.code` 不再回退 Chat 气泡；`CodeUserMessageRow` 共用气泡/附件组件；delivery 进入 pending 签名
- `CodeProfileAutoRun` fixtures：`bubble-attachment`、纯附件、3 图、5 图 +N、大字号；并直接断言 3 项的三条排布
- L 级独立审查已跑（两份 reviewer），P1/P2 已按证据修正；复验后 commit → push → CI（test/build/code-profile）→ 出包（构建号进文件名）→ 真机验收

## 2.5 阶段 2A/2B 落地状态（2026-10-27 更新）

- 阶段 2A 已完成：`CodeAttachmentTiles.swift`、`CodeFileTile.swift`、`CodeArtifactPreviewCard.swift`、`CodeAttachmentRow.swift`、`CodeUserMessageRow.swift`；`CodeMessageRowView` 渲染 `.attachments`；`CodeUserBubble` 去掉空槽位与旧 pending 指示器（指示器移到 `CodeUserMessageRow`/`CodeDeliveryGutter`）。
- 阶段 2B 已完成（未提交）：
  - adapter 接 `attachmentResolver` / `model.thumbnail` / `onAttachment`；settled 行 `attachmentState = .complete`。
  - `codeHeightDigest` / Code group signature 纳入附件身份与解析像素；`attachmentPixelSize` 用 `ChatAttachmentStore` 的 preview 尺寸，measurer 与视图共用。
  - `officialEstimateHeight` 加附件结构高度 [I]；pending 高度改用 `CodeRowHeightPlan`，不再用 Chat 的 180/附件。
  - pending 统一：`PendingMessageRow(.code)` 走 `CodeUserMessageRow`，上传成功=complete、发送中=inFlight、发送失败且未上传=failed。
  - `CodeProfileAutoRun` 加 `bubble-attachment`、纯附件、3 图、5 图+N 四组 fixture。
  - 新增 6 个官方 Anthropicon imageset（folder/image/chart/slides/spreadsheet/code），1.261005.20 vs 1.261019.51 md5 全同（`EVIDENCE/round25/asset-version-check.md`）。
  - 失败卡图标修正：始终 UTType 6 类；`anthropicon.warning` 只属于 tile 的 failed 遮罩（CORRECTIONS #91）。
- 审查后修正（2026-10-27）：
  - 3 项排布补齐官方三条分支：wide 在上 / wide 在下 / 2+1；谓词语义仍 U，当前用“横向 pixelSize（width>height）” [I]；文件无 pixelSize → 2+1。
  - 失败卡前导框改为只有宽度 `min(ScaledMetric,84)`，默认卡高 6+8+(21+18.2)=53.2；旧 98 作废（CORRECTIONS #93）。
  - 单文件 large 槽位改为 200×150（无 pixelSize → 4:3；CORRECTIONS #94）。
  - TileCountOverlay 改为 `VStack(spacing:4){状态子视图; +N}`，覆盖格不再另叠状态遮罩；非 inFlight 图标 U（CORRECTIONS #95）。
  - pending 失败文档现在按卡高计入，delivery 进入 pending 签名/heightKey；`measureSynchronously` 为 pending 新 key 写 `.precalc` 估算，优先于 `TimelineHeightCache` 的已显示旧高度，失败时真正采用新高度（不再依赖不可能发生的 `.interactive` 自纠；pending 实际是 `.measured`）。
  - 3 项 fallback 的单个 square 加 leading `Color.clear` filler，贴右；`isWide` 抽成纯函数并进 gate 三断言（横向/纵向/nil）；3 项形状 gate 断言 `filler,square`。
  - `attachmentPixelSize` 用 merge 后的 content 回退；空白文本 pending 不画气泡；失败卡/图片格 a11y 保留文件名。
- 已知非阻塞残余：
  - echo 若 wire 完全不回附件，尚无 clientID fallback；当前证据显示 connector 三条 lifecycle 都带附件。
  - FileTile 底色用 `userBubbleFill` [I]；图标 tint 用 primary [I]（官方 white 在浅底不可见）。
  - +N 覆盖格非 inFlight 的状态子视图（官方 Anthropicon 具体值）U。
  - 3 项 wide 谓词 `0x101895bf4` 的精确语义 U（当前横向 = wide [I]）。

## 2.6 CI 与包（2026-10-27）

- 分支 `feat/code-profile-beta`，head `762edc6f`（`4d46ed2c` 实现 + `762edc6f` 文档）。
- Actions run `40441663226` / **build 561**：`test` ✅、`build` ✅、`code-profile` ✅（`failures: []`）。
- `code-profile` 新增 4 组 fixture 全部通过：`bubble-attachment` 399/399（361 large）、575/575（361 accessibility3）、634/634（320 accessibility3）；纯附件 160/160；3 图 352/352；5 图 352/352；delta 全 0；`attachmentLayout` 7 条形状断言通过。
- IPA：`AgentsAnywhere-feat-code-profile-beta-b561-762edc6.ipa`
  `https://github.com/chenyynx/Agents-Anywhere/releases/download/ipa-feat-code-profile-beta/AgentsAnywhere-feat-code-profile-beta-b561-762edc6.ipa`
- **待 pp 真机验收**；dev 未合、未 force push。

## 3. 官方数值（压缩后也别丢）

### 图片 AttachmentTiles
- Grid 间距 **8**；square **140×140**；wide **288×140**；large **200×200 上限框内等比（aspect 2/3–3/2）**；圆角 **14 continuous**
- 排布：1→large；2→2 square；3→wide+2 square；4→2×2；>4→前 4 + 第 4 格 +N（**N=总数−4**）
- +N：白色，**20pt/500/28pt**，AnthropicSansMobileVariable-TextRegular；无自身暗层
- 图片：resizable stretchy + aspectRatio + Rectangle 裁剪，center，fill
- 遮罩：inFlight/failed/unopenable 黑 0.5；failed 加 `anthropicon.warning`；complete/displayOnly 无

### 成功文件 FileTile
- 纯色底 + 顶部图标 overlay + 底部单行文件名
- 图标：`.fileExtension`→`anthropicon.file`；`.folder`/nil→`anthropicon.folder`；`.large` **24×24 frame**，aspect-fit
- 图标 overlay：`Color.black.opacity(0.1)`，上两角 4pt continuous，shadow
- 文件名：inset 10；lineLimit 1；truncationMode **.middle**；**13pt relative / 550 / 18.2 / AnthropicSansMobileVariable-TextRegular / .callout**；默认 primary label；无边框/chip/角标

### 失败卡 ArtifactPreviewCard
- `.frame(maxWidth: 520)`；圆角 14 continuous；padding **leading20 / trailing16 / bottom8 / top6**；HStack spacing **20**
- 前导 84 box：`min(ScaledMetric,84)`，Color.clear + accessibilityHidden
- 背景：light `#0B0B0B` α0.2 / dark `#FFFFFF` α0.2；阴影 radius2/x0/y1/5%
- name：15/400/21.0；light `#0B0B0B` / dark `#F0EFEC`
- artifactType：13/400/18.2；light `#52514E` / dark `#C3C2B7`
- 第三行状态色 `#898781`
- 图标 6 类：image/chart/slides/spreadsheet/code/file；DOCX/PDF/TXT/未知→file；`.large` 24×24；tint `#FAFCFF`
- 失败态 opacity 0.5 + `anthropicon.warning` + a11y `upload_failed`；无可见文案

### 用户行
- 顺序：文本气泡 → 图片 AttachmentTiles → 文件 SendUserMessageAttachmentRow（内部先失败卡、后成功 FileTile）
- 附件在气泡外；右缘与气泡共享行内容右缘；附件无 36pt 槽位；块间距默认 8 [I]
- 纯附件不渲染气泡；pending 与 settled 同 block 结构

## 4. 剩余非阻塞 U（已在 CLOSURE 列明）

- TypeBadge `(0,0)` 是 `.folder` 还是 nil：两者都显示 folder 图标，只影响 badge 文本
- `ReadingFontPreferences` 默认 prose/mono：Typography 环境无代码级注入，附件默认字体固定
- 1.261019.51 可执行文件加密；pp 明确旧版 1.261005.20 为准
- 个别 ABI/私有实现细节

## 5. 恢复提示词（下个会话直接粘贴）

> 继续 AA Code 页用户附件实现。先读 `/home/ubuntu/aa-wt-attachments/docs/code-user-attachments-handoff.md`、`/home/ubuntu/aa-wt-attachments/docs/code-user-attachments-task.md`、`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round25/CLOSURE.md`。
> 工作副本 `/home/ubuntu/aa-wt-attachments`，分支 `feat/code-profile-beta`，HEAD `0d727e7b`（含 `b160c90f` 侧栏 merge），dev 不碰不合。
> 当前阶段 1 已完成未提交；阶段 2A 视图子代理可能仍在跑或已完成（看通知/工作区）。不要重复和回退它的文件。
> 下一步：阶段 2B（adapter 接线/签名/高度/pending 统一/gate fixture）→ L 级审查 → commit/push → CI test/build/code-profile → 出包（包名带构建号）→ 真机验收。
> 所有视觉值严格照 CLOSURE.md，不编；出包/交流带构建号；不要 force push、不要合 dev。
