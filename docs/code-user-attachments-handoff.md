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
- HEAD：`afb8ed0a`（docs 任务单）
- 历史包含：`6fa985de`（附件链路审计）、`b160c90f`（Merge `feat/drawer-fullscreen-swipe` → 实验分支，侧栏改动）、`ae2ea037`（动作条 medium）
- 另有 `/home/ubuntu/aa-ring-work` 处于 detached `b2f13f1a`（未动）；composer 线在 `/home/ubuntu/aa-ring-work-composer`（独立分支）
- 工作区当前有阶段 1/2A 的**未提交**实现改动，不要回退

## 2. 实现进度

### 阶段 1（已完成，未提交）

- 新增 `Models/Chat/Code/CodeAttachmentLayout.swift`、`Tests/ClientCoreTests/CodeMessageTimelineTests.swift`
- 修改 `CodeMessageTimeline.swift`：`Block.attachments(id:files:clientMessageID:)`；builder 读 `V2MessageContent.attachments`、按 `fileId ?? raw` 去重、多 body 顺序、纯附件保留
- 修改 `CodeRowHeightPlan.swift` / `CodeMessageHeightMeasurer.swift`：附件高度公式
- `CodeMessageRowView` / `TimelineChatContentAdapter` / `CodeProfileAutoRun` / `CodeProfileModelTests` 只加枚举占位分支
- 10 个文件 `swiftc -parse` 全过；本机 Swift 6.0.3 不能跑 6.2 包测试

### 阶段 2A（进行中）

视图子代理正在写：
- `CodeAttachmentTiles.swift`（图片网格 + `+N` + 状态遮罩）
- `CodeFileTile.swift`（成功文件格）
- `CodeArtifactPreviewCard.swift`（失败卡）
- `CodeAttachmentRow.swift`（图片块 + 文件块组合）
- `CodeMessageRowView.swift`（`.attachments` 真正渲染，附件在气泡外）
- `CodeUserBubble.swift`（删空 `attachments` 槽位）

完成后不要重复它的文件。

### 阶段 2B（下一步）

- Adapter 接线：`CodeMessageRowView` 传 `onAttachment` / `model.thumbnail` / resolver（`model.session.attachmentPreviews.resolve(contents, clientID:)`）
- Code group signature / `codeHeightDigest` / `heightKey` / `hasVisibleBlock` / `officialEstimateHeight` / `measuredCodeGroupHeight` 纳入附件
- pending 统一：`.code` 不再回退 Chat 气泡；抽共享 `CodeUserMessageRow`
- `CodeProfileAutoRun` fixtures：`bubble-attachment`、纯附件、3 图、5 图 +N、大字号
- 然后 L 级独立审查（reviewer 子代理）→ commit → push → CI（test/build/code-profile）→ 出包（构建号进文件名）→ 真机验收

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
> 工作副本 `/home/ubuntu/aa-wt-attachments`，分支 `feat/code-profile-beta`，HEAD `afb8ed0a`（含 `b160c90f` 侧栏 merge），dev 不碰不合。
> 当前阶段 1 已完成未提交；阶段 2A 视图子代理可能仍在跑或已完成（看通知/工作区）。不要重复和回退它的文件。
> 下一步：阶段 2B（adapter 接线/签名/高度/pending 统一/gate fixture）→ L 级审查 → commit/push → CI test/build/code-profile → 出包（包名带构建号）→ 真机验收。
> 所有视觉值严格照 CLOSURE.md，不编；出包/交流带构建号；不要 force push、不要合 dev。
