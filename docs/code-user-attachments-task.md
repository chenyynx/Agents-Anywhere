# Code 页用户附件（图片 tiles / 文件格 / 失败卡）任务单（2026-10-27）

> 2026-10-27 实现后证据修正（以 `CANONICAL/CORRECTIONS.md` #92–#95 为准）：
> 3 项排布有 wide 在上 / wide 在下 / 2+1 三条分支；失败卡前导框只有宽度
> `min(ScaledMetric,84)`，默认卡高 53.2（不是 98）；单文件 large 槽位是
> 200×150（无 pixelSize → 4:3）；`TileCountOverlay` 是
> `VStack(spacing:4){状态子视图; +N}`。
>
> 分支 `feat/code-profile-beta`（worktree `/home/ubuntu/aa-wt-attachments`），dev 不碰不合。
> 级别：**L**（数据链路 + 视图 + 高度/签名 + pending 统一；跨多个文件）。
> 证据：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round25/CLOSURE.md`（闭合判定）+ 各分报告；二进制 1.261005.20（pp 明确旧版为准）。
> 铁律：不编数值；所有视觉值来自 CLOSURE.md 的 E/I 表。

---

## 0. 结论

附件在 Code 页消失的根因：`CodeMessageBuilder` 只读 `.text`，`CodeMessageRowView`/`CodeUserBubble` 没有附件分支；pending 因带附件回退 Chat 气泡，echo 后 pending 删除，附件随之消失。

本任务按官方结构实现：
- 文本气泡 → 图片 `AttachmentTiles` → 文件 `SendUserMessageAttachmentRow`（先失败卡、后成功 FileTile）
- 附件在气泡外，右缘与气泡对齐
- pending 与 settled 共用同一 Code 用户行，不再回退 Chat 气泡

---

## 1. 官方数值（实现直接照抄）

### 1.1 图片 tiles

- Grid 间距 8；`.frame(maxWidth:.infinity, alignment: trailing/leading)`；Grid `.center`
- square **140×140**；wide **288×140**；large **200×200 上限框内等比**（aspect 钳 2/3–3/2）
- 圆角 **14 pt `.continuous`**
- 排布：1→large；2→2 square；3→wide+2 square；4→2×2；>4→前 4 + 第 4 格 +N（N=总数−4）
- 图片：`resizable(.stretchy)` + aspectRatio + Rectangle 裁剪，`.center`，`.fill`
- +N：白色，Typography **20pt/500/28pt**，AnthropicSansMobileVariable-TextRegular；`IntegerFormatStyle` + `SignDisplayStrategy.always`
- 上传态：ProgressView 24pt/线宽3/轨道0.3/白色 + 黑 0.5 遮罩
- 状态遮罩：inFlight / failed / unopenable 各自黑 0.5；failed 加 `anthropicon.warning`；complete/displayOnly 无

### 1.2 成功文件 FileTile

- 纯色底 → 顶部图标 overlay → 底部单行文件名
- 图标：`.fileExtension` → `anthropicon.file`；`.folder`/nil → `anthropicon.folder`；`.large` 24×24 frame，aspect-fit
- 图标 overlay：`Color.black.opacity(0.1)`，圆角 (4,4,0,0)=上两角，shadow
- 文件名：inset 10；`lineLimit(1)`；`truncationMode .middle`；13pt relative / 550 / 18.2 / AnthropicSansMobileVariable-TextRegular / `.callout`；默认 primary label
- 无边框/chip/角标

### 1.3 失败上传卡 ArtifactPreviewCard

- `.frame(maxWidth: 520)`；圆角 14 continuous；padding leading20/trailing16/bottom8/top6；HStack spacing 20
- 前导 84 box：`min(ScaledMetric,84)`，Color.clear + accessibilityHidden
- 背景 light `#0B0B0B` α0.2 / dark `#FFFFFF` α0.2；阴影 radius2/x0/y1/5%
- name 15/400/21.0，light `#0B0B0B` / dark `#F0EFEC`
- artifactType 13/400/18.2，light `#52514E` / dark `#C3C2B7`
- 第三行状态色 `#898781`
- 图标 6 类：image/chart/slides/spreadsheet/code/file；DOCX/PDF/TXT/未知→file；`.large` 24×24；tint `#FAFCFF`
- 失败态 opacity 0.5 + `anthropicon.warning` + a11y `upload_failed`；无可见文案
- 多卡间距默认 8 [I]

### 1.4 用户行

- 顺序：text bubble → image tiles → file row
- 附件在气泡外；右缘与气泡共享行内容右缘；附件无 36pt 槽位
- 块间距默认 8 [I]
- 纯附件不渲染气泡
- pending 与 settled 同 block 结构

---

## 2. AA 数据链路（审计结论）

- wire 附件在 `V2MessageContent.attachments`（`V2TimelineItem.swift:213-225`）；connector 正常发（messages.py:273-275；lifecycle 三条路径）。
- `ChatAttachmentStore.resolve(contents, clientID:)` 负责本地 preview/openUrl 补全；Code 页必须带 `clientMessageId`。
- pending 行当前带附件时回退 Chat 气泡（`SessionTimelineRow.swift:126-138`）；echo 后 `confirmEcho` 删 pending（`V2SessionModel.swift:559-575`）。

---

## 3. 实现步骤

### 3.1 模型 / builder

- `CodeMessageRow.Block` 加 `case attachments(id: String, files: [V2AttachmentContent], clientMessageID: String?)`。
- `CodeMessageBuilder.messageRow`：每条 body 先 `.text`，`body.content.attachments` 非空则追加 `.attachments`；按 `fileId ?? cacheKey` 去重；纯附件消息保留。
- `hasVisibleBlock` 加 `.attachments: true`；`renderRows` 过滤加 attachments。
- 可选 clientID fallback：wire 附件为空时用 `attachmentPreviews.resolve([], clientID:)` 补。

### 3.2 视图

新增：
- `CodeAttachmentTiles`（图片网格 + `+N` + `AttachmentStateOverlay`）
- `CodeFileTile`（成功文件格）
- `CodeArtifactPreviewCard`（失败上传卡）
- `CodeAttachmentRow`（组合：图片块 + 文件块；用户行 trailing）

`CodeMessageRowView`：
- `userRow` 的 `others` 渲染 `.attachments`，位置在 `CodeUserBubble` 之后（气泡外）
- 传入 `onAttachment`、`loadThumbnail`、`attachmentResolver`
- 纯附件：不画气泡，只画附件
- `CodeUserBubble.attachments` 空槽位删除（避免误导）

### 3.3 Adapter

- `CodeMessageRowView` 构造传 `onAttachment`、`model.thumbnail`、resolver（`model.session.attachmentPreviews.resolve`）。
- Code group signature：`attachments: []` 改为该组 user row 的 `attachmentSignatures`（wire 或 fallback），预览尺寸变化触发重配。
- `codeHeightDigest` 加 `.attachments` 身份/尺寸；`heightKey` 同步；`hasVisibleBlock` 加附件。
- `officialEstimateHeight` / `measuredCodeGroupHeight` 传附件高度。

### 3.4 高度

- `CodeRowHeightPlan.Block` 加 `.attachments(height:)`；`height` 按 blockSpacing 累加。
- `CodeMessageHeightMeasurer.planRows` 计算：
  - 图片：1→large 框（aspect 200 内）、2→2 square、3→wide+2 square、4→2×2、>4→前4 + +N；square 140、wide 288×140。
  - FileTile：同 tile 尺寸；内部固定布局（icon 24 + 文件名 18.2 + inset 10）。
  - 失败卡：宽 = min(可用宽, 520)，高按 HStack 内容（84 box / 两行文字 + padding 6/8）计算；若实现时采用固定高度，必须标 [I] 并在 fixture 锁住。
- 附件尺寸来源：`previewPixelSize ?? serverPixelSize`；缺省用官方 fallback（large 200 框、其他固定）。
- 高度公式抽 `CodeAttachmentLayout` 纯函数，view 与 measurer 共用。

### 3.5 Pending 统一

- 抽 `CodeUserMessageRow`（text + attachments + pending 指示器），`PendingMessageRow(.code)` 与 `CodeMessageRowView.userRow` 共用。
- 去掉 `.code && attachments 非空 → Chat UserMessageBubble` 的回退；pending 与 echo 样式/位置一致。
- 纯附件 pending 的行级指示器放在 row overlay，不依赖气泡。

### 3.6 点击

- 复用 `SessionChatView.openAttachment`：图片 viewer / QuickLook；Code row 只传 `onAttachment`，不新建路由。
- 文件卡点击同样的 `onAttachment`；失败卡点击可无动作（官方失败态无可见文案，点击行为 U）。

### 3.7 本地化

- 复用官方 key：`upload_failed` 等；文件名/类型使用现有 `AppSymbol`/UTType 映射。
- 不新造文案。

### 3.8 测试 / 门禁

- ClientCore 单测：
  - builder：text+附件、纯附件、多 body 顺序、去重、clientID fallback。
  - `CodeRowHeightPlan`：图片 1/2/3/4/5+、FileTile、失败卡、大字号。
  - group signature：附件列表/像素变化 → contentRevision 变化。
- `CodeProfileAutoRun`：
  - `bubble-attachment` fixture（user text + 1 图 + 1 文件），宽 361/320、large/accessibility3，delta ≤2pt。
  - 纯附件 fixture；3 图；5 图 +N。
- 真机清单：发送 text+1图、text+多图、text+文件、纯图、纯文件；echo 后仍在；滚动加载；失败重试；暗色/大字号；点击预览。

### 3.9 范围外

- 官方 `showAttachmentPreview` 的完整视觉（AA 继续 QuickLook / 图片 viewer）。
- `ReadingFontPreferences` 用户自定义字体路径（默认视觉不依赖）。
- TypeBadge 具体文本（图标规则已定）。

---

## 4. 验收判据

1. Code 页发送带附件消息：发送前/echo 后附件都在，位置在文本气泡下方、右对齐、不在气泡背景内。
2. 1/2/3/4/5+ 张图片排布符合 §1.1；+N 数字 = 总数−4。
3. 成功文件格显示 file/folder 图标（按 badge）、单行文件名（middle 截断）、13pt/550/18.2。
4. 失败上传卡按 §1.3 渲染，opacity 0.5 + warning。
5. 行高首帧正确（delta ≤2pt），回合结束/预览到达不跳。
6. 纯附件消息不消失；pending→echo 样式不变。
7. 暗色/大字号/RTL 不裁切；点击预览正常。
