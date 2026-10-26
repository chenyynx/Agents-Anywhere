# Code 页用户附件链路审计（只读）

- 工作区：`/home/ubuntu/aa-wt-attachments`（git worktree）
- 分支 / HEAD：`feat/code-profile-beta` / `ae2ea037`
- 方式：只读代码 + 官方逆向证据对照；**未构建、未跑 iOS 测试、未上真机、未抓 wire/DB**。所有结论按下述三档标注：
  - **已验证（静态）**：代码/契约/schema 直接可读出的确定事实。
  - **推断**：由完整代码链路推出，但没有运行时观测。
  - **未验证**：需要真机、wire 抓包、长会话或官方二进制补证。
- 本文只讨论"用户消息附件"；助手消息附件在 connector 侧不产生（`docs/perf-6b-c5-m4.2-handoff.md:74` 亦有同结论），不在主链路。

---

## 0. 一屏结论

**根因（已验证，静态）**：Code 页的消息行模型和视图从不消费 `V2MessageContent.attachments`。

1. `CodeMessageBuilder.messageRow` 把 `type == .message` 的 item 只映射成 `.text` block（`ios/Agents Anywhere/Agents Anywhere/Models/Chat/Code/CodeMessageTimeline.swift:110-143`）；`V2MessageContent.attachments` 在 `ios/Agents Anywhere/Agents Anywhere/Domain/Session/V2TimelineItem.swift:213-225` 已解码，但 builder 不读。
2. `CodeMessageRowView` 的用户行只把 `.text` 交给 `CodeUserBubble`，其余 block 走 `blockView`，而 `blockView` 没有附件分支（`ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeMessageRowView.swift:150-207`）。
3. `CodeUserBubble.attachments` 是**从未被赋值的空槽位**，body 里也不渲染（`ios/Agents Anywhere/Agents Anywhere/Views/Chat/Code/CodeUserBubble.swift:16-18,28-65`）。
4. 发送前 pending 行**故意回退到 Chat 气泡**：`PendingMessageRow` 在 `bubbleStyle == .code && pending.attachments.isEmpty` 才用 `CodeUserBubble`，否则用能画附件的 `UserMessageBubble`（`ios/Agents Anywhere/Agents Anywhere/Views/Chat/SessionTimelineRow.swift:126-138`）。echo 到达后 `V2SessionModel.confirmEcho` 删除 pending（`ios/Agents Anywhere/Agents Anywhere/Models/Session/V2SessionModel.swift:559-575`），settled 行走 Code renderer，于是"发送后附件消失"。
5. 附件**没有**独立的 `type == .attachment` 行可用：connector 的 `TimelineItemType`（`connector/connector/runtime_protocol/timeline.py:13-21`）和 server 的 `TimelineType`（`server/agent_server/core/models.py:58-64`）都不含 `attachment`。用户附件只能随 `message.content.attachments` 到达。

**这不是 wire 丢数据（正常 Claude 路径，代码 + connector 测试源码验证；本次未运行测试）**：connector 在 user message content 里发附件（`connector/connector/runtimes/claude/timeline/messages.py:273-275,293`；`connector/connector/runtimes/claude/turns/attachments.py:21-33`），现有 connector 测试断言 live 和 history 的 user item 都带 `content.attachments`（`connector/tests/test_claude_runtime.py:643-667`），server 原样存/广播（`server/agent_server/core/models.py:1061-1074`），Chat 页能画（`ios/Agents Anywhere/Agents Anywhere/Views/Chat/SessionTimelineRow.swift:27-31`）。Code 页是唯一不画的 renderer。

**根因对 wire 的依赖很小**：即使 echo 的 wire attachments 为空，Code 页也没有 Chat 页的 `clientID` fallback；即使 wire 有 attachments，Code builder 也不读。因此"Code 页不显示"在两种 wire 情况下都成立，区别只是"丢的是 wire 数据还是本地 fallback"。

**最小接入点**：
- 模型：给 `CodeMessageRow.Block` 加 `attachments` case，builder 在每条 body 的 `.text` 之后追加（`CodeMessageTimeline.swift:18-30,120-143`）。
- 视图：`CodeMessageRowView.blockView` 渲染附件（放在 `CodeUserBubble` 之后、气泡背景之外，符合官方 `UserMessageCell` 结构），`renderRows` 保留该 block（`CodeMessageRowView.swift:177-207,252-269`）。
- Adapter：把已有的 `onAttachment` / `model.thumbnail` / `attachmentPreviews` 传进 Code row（`TimelineChatContentAdapter.swift:22,1029-1048`），并把附件预览签名纳入 Code group signature（当前写死 `attachments: []`，`:1747`）。
- 高度：`CodeRowHeightPlan.Block` 加附件高度 case；`CodeMessageHeightMeasurer.planRows` 计算图片/文件卡高度（`CodeRowHeightPlan.swift:19-29,58-88`；`CodeMessageHeightMeasurer.swift:61-122`）。
- Pending：附件可见后，`.code` 不再回退 Chat 气泡，统一用 Code 用户行（`SessionTimelineRow.swift:126-138`）。

**官方证据（Code 页复刻线必须遵守）**：附件不是气泡内容，而是 `UserMessageCell` 下文本气泡之后的兄弟块；图片是 `AttachmentTiles`（结构 [E]；"每组最多 4 个、溢出折叠成 +N" 语义 [I]），文件是 `SendUserMessageAttachmentRow`（`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round19/bubble-layout.md:17,66-70,180`；`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round18/user-row-and-action-bar.md:24,160-177,290-315`；`/home/ubuntu/aa-test/claude-ios-re/CANONICAL/02-transcript-model.md:183,188,191`）。因此**不要把附件塞进 `CodeUserBubble` 的气泡背景里**；填槽位也只能放在文本气泡之后的同一 trailing 列。

---

## 1. wire 数据与 pending/echo

### 1.1 V2 wire 形状

| 事实 | 证据 | 置信度 |
|---|---|---|
| `V2TimelineItemType` 有 `.attachment` case | `ios/.../Domain/Session/V2TimelineItem.swift:27-39` | 已验证（静态） |
| `.attachment` 会被解成 `V2AttachmentContent` | `ios/.../Domain/Session/V2TimelineItem.swift:179-211`（`.attachment` 在 `:186,205-206`） | 已验证（静态） |
| 但 connector 不会发 `type == "attachment"` | `connector/connector/runtime_protocol/timeline.py:13-21`（无 attachment） | 已验证（静态） |
| 且 server 也不接受 `type == "attachment"` | `server/agent_server/core/models.py:58-64`（`TimelineType` 只有 message/tool/artifact/marker/system） | 已验证（静态） |
| 用户附件实际走 `message.content.attachments` | `ios/.../V2TimelineItem.swift:213-225`（`V2MessageContent.attachments`，`:222`） | 已验证（静态） |
| `V2AttachmentContent` 字段：`fileId/name/mediaType/size/openUrl/downloadUrl` + raw | `ios/.../Domain/Attachment/V2AttachmentModels.swift:33-50` | 已验证（静态） |
| `serverPixelSize` 只认正数 number 的 `width/height` | `ios/.../V2AttachmentModels.swift:52-60` | 已验证（静态） |
| `isImage` 由 mediaType 前缀或名称后缀判定 | `ios/.../Models/Chat/ChatAttachmentStore.swift:133-137` | 已验证（静态） |
| 附件图片缓存键：`sha256` 优先，否则 `fileId` | `ios/.../Models/Chat/AttachmentImageCache.swift:53-61,241-245` | 已验证（静态） |

**结论**：Code 页若想显示附件，唯一可靠载体是 `V2MessageContent.attachments`（或 `V2TimelineItemContent.attachment` 的单条形式，但当前无 producer）。不存在"附件作为独立 timeline item"的现状。

### 1.2 connector 侧发射路径（Claude）

| 环节 | 证据 | 置信度 |
|---|---|---|
| `ClaudeMessageProjector.message_item` 接收 `attachments`，塞进 `content.metadata["attachments"]` | `connector/connector/runtimes/claude/timeline/messages.py:242-296`（`:254` 参数，`:273-275` 写入） | 已验证（静态） |
| `MarkdownMessageContent.to_mapping()` 把 metadata 平铺进 content | `connector/connector/runtime_protocol/timeline.py:138-165`（`:157-163`） | 已验证（静态） |
| `ClaudeTurnAttachment.to_mapping()` 实际字段：`fileId/name/path/mediaType/byteSize` + 可选 `width/height` | `connector/connector/runtimes/claude/turns/attachments.py:11-33` | 已验证（静态） |
| **没有 `openUrl` / `downloadUrl`；大小字段叫 `byteSize` 不叫 `size`** | 同上 `:21-33` | 已验证（静态） |
| 用户 item 的三条发布路径都带 `attachments=attachment_mappings`：早期发布、SDK replay、fallback | `connector/.../turns/lifecycle.py:2830-2849`、`:3931-3948`、`:4011-4028` | 已验证（静态） |
| 附件物化失败会静默跳过该文件（只 log，不阻断消息） | `connector/.../turns/attachments.py:36-70`（`continue` 在 `:52-58`） | 已验证（静态） |
| 历史重建用 pending registry 的 `client_message.attachments` | `connector/.../sessions/reader.py:618-653`（`:651-653`） | 已验证（静态） |
| pending registry 持久化 attachments，匹配上限 1000/session | `connector/.../domain/pending_messages.py:13,60-90,252-300,530-570` | 已验证（静态） |
| **现有 connector 测试已断言 live 和 history 的 user item 都带 `content.attachments`**（同 item id；含 `name/width/height`） | `connector/tests/test_claude_runtime.py:643-667`（history 同 id 在 `:664-667`） | 已验证（测试源码；本次未运行） |
| **现有 connector 测试已断言 `byteSize`/`path`/`mediaType` 的实际 wire 字段** | `connector/tests/test_claude_runtime.py:4302-4342`（`:4336-4342`） | 已验证（测试源码；本次未运行） |
| **Codex 的 pending→echo 也会保留 `content.attachments`（含 `size/width/height`）** | `connector/tests/test_codex_runtime.py:5074-5144` | 已验证（测试源码；本次未运行） |
| **Codex 的纯附件 user message echo 也保留 attachments** | `connector/tests/test_codex_runtime.py:5146-5202` | 已验证（测试源码；本次未运行） |
| DSH 图片探针断言 user message content 里有 `attachments` | `connector/tests/dsh_image_probe.py:72-74` | 已验证（测试源码；本次未运行） |

**形状差异（关键）**：

- pending（本地）：`ChatAttachment.content` 带 `fileId`、`name`、`mediaType`、`size`（data.count）、`openUrl`/`downloadUrl`（uploaded 后）、`width/height`（原图尺寸）；预览 bytes 在 `ChatAttachmentStore`（`ios/.../Models/Chat/ChatAttachmentStore.swift:37-49,146-159`）。
- echo（wire）：`fileId`、`name`、`path`、`mediaType`、`byteSize`、可选 `width/height`；**没有 `openUrl/downloadUrl`，也没有 `size`**。
- iOS 的 `V2AttachmentContent.size` 只读 `"size"`（`V2AttachmentModels.swift:46`），所以 Claude 用户附件的 `size` 为 nil；`ChatMessageFileAttachment` 的文件大小行因此不显示（`ios/.../Views/Chat/ChatMessageAttachments.swift:87-92`）。这不是"消失"，但是一个已存在的契约字段错位，见 §9 顺带发现。
- `ChatAttachmentStore.resolve(contents, clientID:)` 在 wire contents 非空时只把本地 sent 条目当作"补缺元数据"，不会用 fallback 替换（`ios/.../ChatAttachmentStore.swift:51-66`）；wire contents 为空时才整体回退到 `sent[clientID]`（`:52-53`）。这行是 Chat 页"echo 暂时没有 wire attachments 也不丢"的关键。

**wire 形状示例（Claude，代码推断）**：

```json
// message.content
{
  "kind": "markdown",
  "text": "看这个图",
  "format": "markdown",
  "attachments": [
    {
      "fileId": "file_...",
      "name": "Photo.jpg",
      "path": "/.../.agents-anywhere-moonveil/attachments/...",
      "mediaType": "image/jpeg",
      "byteSize": 123456,
      "width": 3024,
      "height": 4032
    }
  ]
}
```

**pending 本地形状（`ChatAttachment.content`，`ChatAttachmentStore.swift:146-159`）**：

```json
{
  "fileId": "file_... 或 local:<uuid>",
  "name": "Photo.jpg",
  "mediaType": "image/jpeg",
  "size": 123456,
  "openUrl": "...",          // 仅 uploaded 后
  "downloadUrl": "...",      // 仅 uploaded 后
  "width": 3024,
  "height": 4032
}
```

注意字段名差异：wire 用 `byteSize`，本地用 `size`；wire 没有 URL，本地 uploaded 后有 URL。

### 1.3 pending / echo 两条路径

**发送前（pending）**

1. `SessionChatModel.send`（`ios/.../Models/Chat/SessionChatModel.swift:587-609`，上传闭包在 `:596-609`）→ `V2SessionModel.sendDraft` 构造 `V2PendingMessage`，带 `attachments: [ChatAttachment]`，并 `attachmentPreviews.remember(..., clientID: pending.id)`（`ios/.../Models/Session/V2SessionModel.swift:417-447`）；pending 列表在 `V2SessionModel.pendingMessages`（`:181`）。
2. `PendingMessageRow` 渲染时 `chat.session.attachmentPreviews.resolve(pending.attachments.map(\.content), clientID: pending.id)`（`ios/.../Views/Chat/SessionTimelineRow.swift:134-137`）。
3. 在 Code 页（collection timeline）里，`TimelineChatContentAdapter.rowView(.pending)` 固定传 `bubbleStyle: .code`（`ios/.../Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift:1058-1064`）。
4. 因为 `pending.attachments` 非空，`PendingMessageRow` 走 **Chat 的 `UserMessageBubble`**，附件可见，但气泡是 Chat accent 风格、且"附件在文本上方"（`SessionTimelineRow.swift:129-138`；`UserMessageBubble` 附件在文本前：`:80-93`）。

**发送后（echo）**

1. connector 发布 `type=message, role=user` 的 item，`content.attachments` 非空（§1.2）。
2. server `upsert_timeline_item` 原样保存 content（`server/agent_server/core/models.py:1061-1074`；`server/agent_server/services/connector_notifications.py:907-949`）。
3. iOS `V2SessionModel.confirmEcho` 只按 `type/role/clientMessageId` 匹配，然后 **无条件删除 pending**（`ios/.../V2SessionModel.swift:559-566`）；它不检查 echo 是否带 attachments。
4. 同一批 `items` 已更新 timeline；Code 页的 `TimelineGrouping.codeGroups` 把这个 user message 归成带 `explicitID` 的 group（`ios/.../Models/Chat/TimelineGrouping.swift:108-164`）。
5. `TimelineChatContentAdapter.rowView(.group)` 因 `group.explicitID != nil` 走 `CodeMessageRowView`（`ios/.../TimelineChatContentAdapter.swift:1029-1048`）。
6. `CodeMessageBuilder` 只产出 `.text`，`CodeMessageRowView` 只画文本 → 附件不再出现。**这就是"发送后消失"的完整机制。**

### 1.4 历史重建与 binding 丢失（次要、条件性）

- 历史重建只有在 `client_message` 匹配到 pending registry 时才带附件（`connector/.../sessions/reader.py:618-653`）。
- 匹配不到时：文本会被 `attachment_echo_base_text` 去掉 "Attached files:" 尾巴（`reader.py:620-623`；`connector/.../domain/pending_messages.py:508-516`），`attachments=()`（`reader.py:651-653`）。
- item id 仍由 `stable_message_item_id(session, native_id)` 生成（`reader.py:640`；`connector/.../timeline/messages.py:2878-2883`），与 live item id 相同；server 的 `sync_timeline_items` 对同 id 的 changed item 采用 last-writer content（`server/agent_server/services/connector_notifications.py:838-875`；`server/agent_server/infra/repositories/timeline.py:900-911,980-988`）。
- 因此：**如果 binding 丢失/被 trim（`MAX_MATCHED_PER_SESSION = 1000`，`pending_messages.py:13`），一次 history sync 可以用"无附件"的同 id item 覆盖已有 item**，把附件从 server 持久化里抹掉。Chat 页可能靠本地 `sent[clientID]` fallback 继续显示，Code 页不会。
- 置信度：**代码推断**；未在长会话/断线重连/connector 重启场景验证，也没有 DB 证据表明 pp 的环境发生过。这是 secondary risk，不是本次 Code 页必现根因。

### 1.5 "附件会不会在 echo 后从消息行消失"——分场景回答

| 场景 | wire 是否带附件 | Chat 页 | Code 页 |
|---|---|---|---|
| 正常 Claude 发送，live echo | 是（代码链路 + connector 测试；本次未运行测试） | 显示 | **不显示（本 bug）** |
| echo 暂时缺 attachments，但本地 `sent[clientID]` 有 | 否 | 显示（`resolve` fallback，`ChatAttachmentStore.swift:51-53` + `SessionTimelineRow.swift:28`） | **不显示（Code 无 fallback）** |
| binding 丢失后的 history rebuild | 否（被覆盖） | 可能靠本地 fallback 显示；换设备/清缓存后也不显示 | 不显示 |
| Codex / DSH 的 user message | 取决于各 runtime 的 mapping；Codex 有 `fileId/path/name/mediaType/size`（`connector/.../codex/timeline/typed_events.py:477-565`），DSH 由插件 content 决定 | Chat renderer 同链路 | 同 Code 问题；且宽高可能缺失 |

---

## 2. Chat 页现有可复用组件清单

| 组件 | 位置 | 输入 / 行为 | 复用判断 |
|---|---|---|---|
| `ChatMessageAttachments` | `ios/.../Views/Chat/ChatMessageAttachments.swift:4-66` | `files: [ChatMessageAttachment]`、`onOpen: (V2AttachmentContent, UIImage?) -> Void`、`loadThumbnail: async throws -> Data?`、`alignment`、`isOutgoing`；outgoing 时按连续图片 run 分组，图片走单图/2 列网格，非图片走文件卡（`:13-53`） | **可直接复用**（Code 用户行用 `isOutgoing: true`）；但官方 `AttachmentTiles` 的 4 格 +N、tile 尺寸/圆角不同（§8） |
| `ChatMessageFileAttachment` | `ChatMessageAttachments.swift:68-93` | 非图片文件卡；`AppSymbol` + 名称（`lineLimit(2)`）+ 扩展名/大小 + 右上箭头；点击 `onOpen(file, nil)`；maxWidth 320 | private，不能直接引用；只能通过 `ChatMessageAttachments` 使用 |
| `ChatMessageImageGrid` | `ChatMessageAttachments.swift:95-113` | 2 列 `LazyVGrid`，cell = `ChatImageThumbnail.gridCellSize()` = 118，spacing 4，maxWidth 240 | private；行为与官方 4 格 +N 不同 |
| `ChatMessageImage` | `ChatMessageAttachments.swift:121-261` | 单选/网格图片；`previewPixelSize ?? serverPixelSize ?? imagePixelSize` 决定尺寸（`:135-150`）；本地 `previewData` 立即用，远端等 `visible`（`:225-238`）；失败显示"轻点重试预览"并可重试（`:218-223`）；点击把已解码缩略图传给 viewer（`:222`） | private；有"未知尺寸时 decode 后改尺寸"的风险（§7） |
| `ChatAttachmentStore` | `ios/.../Models/Chat/ChatAttachmentStore.swift:16-124` | session/account 级元数据 + 小预览；`remember`、`resolve`、`preview`、`cache`、archive/restore；`sent` 上限 128，entries 上限 256 | **直接复用**；`resolve` 的 clientID fallback 是 Chat 页不丢附件的关键 |
| `ChatMessageAttachment` | `ChatAttachmentStore.swift:4-12` | `id`、`content`、`previewData`、`previewPixelSize`、`previewVersion` | **直接复用** |
| `ChatImageThumbnail` | `ios/.../Models/Chat/ChatImageThumbnail.swift:5-89` | maxWidth 240、maxHeight 320、aspect 0.6–1.8、grid cell 118、`maximumPixelSize`、EXIF 修正的 `imageSize`/`make` | **直接复用**（高度公式与图片解码） |
| `SessionChatModel.thumbnail` | `ios/.../Models/Chat/SessionChatModel.swift:683-700` | 先查 `attachmentPreviews`，再按 `fileId`/device path 下载并缓存预览；`file.isImage` 且 `size <= 25MB` | **直接复用**，作为 Code row 的 `loadThumbnail` |
| `AttachmentImageLoader` / `AttachmentImageCache` | `ios/.../Models/Chat/AttachmentImageLoader.swift:39-90`；`ios/.../Models/Chat/AttachmentImageCache.swift:19-239` | 原图 viewer 的磁盘缓存 + 单飞下载；**必须 `file.openUrl`**（`AttachmentImageLoader.swift:69-71`） | viewer 复用；注意 wire 附件没有 `openUrl` |
| `AttachmentImageViewerSheet` | `ios/.../Views/Chat/AttachmentImageViewerSheet.swift:15-80` | 全屏图片 viewer，初始缩略图 + 原图加载/重试/分享 | **直接复用**（经 `SessionChatView.openAttachment`） |
| `ChatMessageImage` 的可见性门 | `ChatMessageAttachments.swift:177,225-238` | `onScrollVisibilityChange(threshold: 0.01)` 置 `visible`；远端图只有 visible 才 `loadThumbnail` | Code 页是 `UIHostingConfiguration` 宿主，**是否触发未验证**（§7 高风险） |

**Chat 页的 resolve 模式（Code 应对齐）**：

```swift
// SessionTimelineRow.swift:28
let files = chat.session.attachmentPreviews.resolve(
    message.attachments,
    clientID: row.value.source["clientMessageId"]?.stringValue)
```

`resolve` 在 `contents.isEmpty` 时返回 `sent[clientID]`（`ChatAttachmentStore.swift:51-53`），所以 echo 暂时没有 wire attachments 也能画。Code 页需要把同样的 `clientID` 和 store fallback 带进去。

---

## 3. Code 页现状与丢弃点

### 3.1 模型层：builder 只产出 text

| 位置 | 现状 | 后果 |
|---|---|---|
| `CodeMessageRow.Block` | 只有 `.reasoning / .text / .toolCalls / .other`（`CodeMessageTimeline.swift:18-30`） | 没有附件 block 可表达 |
| `messageRow` 的 `bodies` | `items.filter { !isReasoning($0) && $0.type == .message }`（`CodeMessageTimeline.swift:111`） | 只取 message item |
| `bodies.map { .text(id:text:) }` | `CodeMessageTimeline.swift:140-142` | **attachments 在此被丢弃**；`V2MessageContent.attachments` 从未读 |
| `guard !blocks.isEmpty` | `CodeMessageTimeline.swift:147` | 纯附件消息仍有 `.text("")`，所以 builder 不丢；但视图会把它过滤掉（§3.2） |
| `isStackable` | 只收 reasoning/message/tool/file_change（`CodeMessageTimeline.swift:206-208`） | `type == .attachment` 的独立行不会进 message group（且当前无 producer） |

### 3.2 视图层：userRow / blockView 没有附件

| 位置 | 现状 | 后果 |
|---|---|---|
| `CodeMessageRowView.userRow` | `.text` 合并成一个 `CodeUserBubble`；其它 block 进 `others` 后走 `blockView`（`CodeMessageRowView.swift:150-172`） | 附件没有进入 `others`（builder 没产出），所以不画 |
| `CodeUserBubble(text:)` 调用 | `CodeMessageRowView.swift:166` | 没有传 attachments |
| `blockView` | 只有 reasoning/text/toolCalls/other（`CodeMessageRowView.swift:177-207`） | 没有附件渲染分支 |
| `renderRows` 过滤 | 空 text 被丢弃，`.toolCalls/.other` 保留（`CodeMessageRowView.swift:252-269`） | 纯附件消息即使 builder 有 `.attachments` 也会被过滤（需要加 case） |
| `CodeUserBubble.attachments` | 声明了 `[ChatMessageAttachment] = []`，注释说"预留，Code 页还没有官方附件气泡"；body 完全没用（`CodeUserBubble.swift:16-18,28-65`） | 空槽位；**且官方附件不在气泡内**（§8） |

### 3.3 Adapter：Code row 不拿 onAttachment / thumbnail / store

| 位置 | 现状 | 后果 |
|---|---|---|
| `onAttachment` 属性 | 存在且已接到 Chat renderer/pending（`TimelineChatContentAdapter.swift:22,152-156,1047,1061`） | Code row 构造时没传（`:1029-1048`） |
| `CodeMessageRowView(...)` 构造 | 只传 group/profile/cwd/streaming/typography/actionBar/tool/thinking 回调（`TimelineChatContentAdapter.swift:1029-1048`） | 附件点击/缩略图没有入口 |
| Code group signature | `attachments: []` 写死，注释说"none of them reach CodeMessageRowView"（`TimelineChatContentAdapter.swift:1687-1747`） | 附件预览到达不会触发 reconfigure / 重测 |
| 通用 signature 分支 | 会 `attachments(of: row.value)` + `attachmentSignatures(..., clientID:)`（`TimelineChatContentAdapter.swift:1773-1782`） | 这是 Code 应对齐的现成实现 |
| `attachments(of:)` | message → `content.attachments`，attachment → 单条（`TimelineChatContentAdapter.swift:1972-1978`） | 可直接复用 |
| `attachmentSignatures` | `resolve(contents, clientID:)` + `previewPixelSize ?? serverPixelSize`（`TimelineChatContentAdapter.swift:1980-1990`） | 可直接复用 |
| `hasVisibleBlock` | 只认非空 text / toolCalls / other（`TimelineChatContentAdapter.swift:1401-1419`） | **纯附件消息的 group 会被整个丢掉**（不只是附件消失） |
| `preparedBlocks` | `CodeMessageRowView` 有该属性/初始化参数（`CodeMessageRowView.swift:49,68-77`），但 adapter 构造时没传；`blockView` 的 `CodeMarkdownTextLeaf` 自己解析（`CodeMessageRowView.swift:194-195`；`CodeMarkdownTextLeaf.swift:66-80`） | 首帧预解析没有生效；附件 block 加入后，首帧高度更依赖 measurer，建议一并核对（§9.4） |
| `model.session.attachmentPreviews` | 只在 `attachmentSignatures` 里用到（`TimelineChatContentAdapter.swift:1980-1990`）；Code row 本身不拿 store | 附件预览/元数据无法进入 Code 视图 |
| `rowView(.group)` | `explicitID != nil` → `CodeMessageRowView`（`TimelineChatContentAdapter.swift:1029-1048`） | Code 页消息的唯一 renderer；Chat 旧列表不走这里 |

**适用范围 / 复现条件（重要）**：`TimelineChatContentAdapter` 只在 `SessionChatView.usesCollectionTimeline` 开启时构建（`ios/.../Views/Chat/SessionChatView.swift:66,156`，`aa.timeline.collectionView` 默认 false）。关闭时走旧 `ChatTimelineView` → `SessionTimelineRow`，附件会显示；所以本 bug 的复现需要 collection timeline（Code profile）开启。这也是"同一条消息在 Chat 旧列表有附件、Code 新列表没有"的原因。

### 3.4 高度层：没有附件高度

| 位置 | 现状 | 后果 |
|---|---|---|
| `CodeRowHeightPlan.Block` | `.text(height:) / .tools / .thinking / .other`（`CodeRowHeightPlan.swift:19-29`） | 没有附件高度 case |
| `height(rows:metrics:hasActionBar:)` | 只累加上述 case（`CodeRowHeightPlan.swift:58-88`） | 附件高度无法进入计划 |
| `CodeMessageHeightMeasurer.planRows` | user 分支只合并 text；assistant 分支只处理 reasoning/text/toolCalls/other（`CodeMessageHeightMeasurer.swift:61-122`） | 附件不测 |
| `codeEstimateKind` / `measuredCodeGroupHeight` | 用 `CodeMessageHeightMeasurer`（`TimelineChatContentAdapter.swift:331-356,487-520`） | 一旦视图开始画附件，测量值会小于实际 → 行自纠正 |
| `codeHeightDigest` | 只 hash reasoning/text/toolCalls/other（`TimelineChatContentAdapter.swift:574-604`） | 附件/预览尺寸变化不会失效 exact height 缓存 |
| `officialEstimateHeight` | 只算 text/tool/other 行数（`TimelineChatContentAdapter.swift:375-415`） | 首帧 seed 不含附件高度 |

### 3.5 Pending 行：附件可见但用的是 Chat 气泡

- `PendingMessageRow` 条件：`if bubbleStyle == .code, pending.attachments.isEmpty` → `CodeUserBubble`；否则 `UserMessageBubble`（`ios/.../Views/Chat/SessionTimelineRow.swift:126-138`）。
- 因此发送前附件可见（Chat accent 气泡、附件在文本上方），echo 后 Code 行只画文本 → 观感上"附件在发送后消失"。
- 纯附件 pending（text 为空）时，`UserMessageBubble` 仍渲染附件（`SessionTimelineRow.swift:80-93`）；但 echo 后 Code group 被 `hasVisibleBlock` 丢掉（§3.3），整条消息消失。

### 3.6 官方结构对照

| 官方事实 | 证据 | 对 AA 的含义 |
|---|---|---|
| `DisplayMessage.Block` 有 `attachments([ImageData])`、`sendUserMessageBubble(markdown:attachments:)`、`fileAttachments([SendUserMessageAttachment])` | `/home/ubuntu/aa-test/claude-ios-re/CANONICAL/02-transcript-model.md:183,188,191` | 附件是 block 级事实，不是 row 级；Code 的 `Block` 应扩 case |
| 乐观发送用 `optimisticAttachmentBlocks: [DisplayMessage.Block]` 把本地附件块挂到消息上 | `CANONICAL/02-transcript-model.md:280-311` | pending 与 settled 应共用同一 block 模型；支持"用 block 增附件"的方案 |
| Code 用户行 `UserMessageCell` 的 VStack 依次是 `UserTextBubble` → `AttachmentTiles`（`.attachments`）→ `SendUserMessageAttachmentRow`（`.fileAttachments`） | `/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round19/bubble-layout.md:66`；`round18/user-row-and-action-bar.md:160-177` | **文本气泡在前，附件在后；附件不在气泡背景内** |
| 图片 `AttachmentTiles` 每组最多 4 个，溢出折叠成第 4 格 "+N"（结构 [E] / 语义 [I]）；`edge` 决定 leading/trailing | `round19/bubble-layout.md:67`；`round18/user-row-and-action-bar.md:305-310` | AA 的 Chat 2 列、无 4 格上限是视觉差异 |
| 文件 `SendUserMessageAttachmentRow` = `VStack{ ArtifactPreviewCard..., AttachmentTiles<UploadedAttachment>? }` | `round19/bubble-layout.md:69`；`round18/user-row-and-action-bar.md:298-301` | AA 的 Chat 文件卡是简化版；官方 card 尺寸/字体未取到 |
| 点击附件 → `showAttachmentPreview`（官方预览 sheet） | `round19/bubble-layout.md:70`；`round18/...:294,315` | AA 用 `SessionChatView.openAttachment` 路由（QuickLook / 图片 viewer） |
| Code 与 Chat 共用 `AttachmentTiles` / `UserMessageBubble`，只是外层 cell 不同 | `round19/bubble-layout.md:109`；`round18/...:200-201` | AA 可复用 Chat 组件，但官方 tile 布局仍需补 |

---

## 4. 根因证据链（逐行）

1. **wire 内容存在**：`V2MessageContent.attachments` 从 `content.attachments` 解码（`ios/.../Domain/Session/V2TimelineItem.swift:213-225`）。
2. **connector 发出**：`message_item` 把 `attachments` 写进 `metadata`（`connector/.../timeline/messages.py:273-275`），`MarkdownMessageContent.to_mapping` 平铺到 content（`connector/.../runtime_protocol/timeline.py:157-163`）；lifecycle 在 early/replay/fallback 三条路径都传（`connector/.../turns/lifecycle.py:2839,3940,4019`）。
3. **server 原样存/发**：`TimelineItemIn.content: Any`（`server/agent_server/core/models.py:1067`）；`_upsert` 直接 `model_validate` 后写 store（`server/agent_server/services/connector_notifications.py:907-949`）。
4. **Chat 页消费**：`SessionTimelineRow` 对 user message 解析 `message.attachments` 并画 `UserMessageBubble(attachments:)`（`ios/.../Views/Chat/SessionTimelineRow.swift:27-31`）。
5. **Code builder 丢弃**：`CodeMessageBuilder.messageRow` 的 `bodies` 只 `map { .text(...) }`（`CodeMessageTimeline.swift:111,140-142`），全函数没有读 `content.attachments`（`:108-149`）。
6. **Code view 不画**：`userRow` 只画 text bubble（`CodeMessageRowView.swift:150-172`），`blockView` 无附件分支（`:177-207`），`CodeUserBubble` 的 attachments 槽位未使用（`CodeUserBubble.swift:16-18,28-65`）。
7. **Code adapter 不传入口**：`CodeMessageRowView` 构造不带 `onAttachment`/`loadThumbnail`/store（`TimelineChatContentAdapter.swift:1029-1048`）。
8. **pending 删除**：`confirmEcho` 在 echo 到达时删除 pending，不再看附件（`V2SessionModel.swift:559-566`）。
9. **结论**：只要一条 user message 走 Code renderer（`group.explicitID != nil`，`TimelineChatContentAdapter.swift:1029`），附件就必丢；是否"发送前可见"取决于 pending 是否还活着，所以用户看到的是"发送后消失"。

**对照实验（建议实施时做）**：
- 同一会话切到旧 Chat 列表（`aa.timeline.collectionView` 关）：附件应在 echo 后仍在（`SessionTimelineRow.swift:27-31`）。
- 同一会话开 collection timeline（Code renderer）：附件在 echo 后消失。
- 用 `TimelineProbe`/日志确认 echo item 的 `content.attachments` 非空（`V2SessionProjection` 解码后打印 raw）。

---

## 5. 建议接入方案

### 5.1 模型：选 `Block.attachments`，不选 row 级字段

**推荐**：在 `CodeMessageRow.Block` 增加

```swift
case attachments(id: String, files: [V2AttachmentContent], clientMessageID: String?)
```

理由：

1. 官方 `DisplayMessage.Block` 本身就是 block 级附件（`CANONICAL/02-transcript-model.md:183,191`），且 `optimisticAttachmentBlocks` 也按 block 挂（`:280-311`）。
2. block 能保留"属于哪条 body / 哪条附件在文本之后"的顺序；row 级 `attachments: [V2AttachmentContent]` 会把多条 body 的附件合并，丢失关联。
3. `V2AttachmentContent` 是 `Hashable`，`Block` 仍可 `Hashable`；`ChatMessageAttachment`（含 preview bytes）不应进模型层。
4. `clientMessageID` 是 AA 特有的 store fallback 需要；若不想污染模型，可改为 adapter 侧按 block id 提供 resolved list，但实现更绕。

**Builder 改动（`CodeMessageTimeline.swift:108-149`）**：

- 把 `blocks.append(contentsOf: bodies.map { .text(...) })` 改为按 body 循环：先 `.text(id:text:)`，若 `body.attachments` 非空则追加 `.attachments(id: body.id, files: body.attachments, clientMessageID: body.source["clientMessageId"])`。
- `guard !blocks.isEmpty` 保持；纯附件消息会因 `.attachments` 非空而保留。
- 可选：按官方拆成 `.attachments`（图片）与 `.fileAttachments`（非图片）两个 case；最小实现用一个 case，在视图内按 `isImage` 分流即可。
- 若未来有 runtime 发 `type == .attachment`，可把 `isStackable` 加上该类型并在 `messageRow` 里转成 `.attachments`；当前无 producer，不必为它改 `TimelineGrouping`。

**注意**：不要只在 `CodeMessageRow` 加 `attachments` 字段而跳过 block——那样 `CodeRowHeightPlan`、签名、digest 都得再加一套 row 级逻辑，且官方结构不是这个形状。

### 5.2 视图：`CodeMessageRowView` 渲染附件（气泡外、文本后）

**建议结构**（对应官方 `UserMessageCell`）：

```
userRow:
  VStack(alignment: .leading, spacing: CodePageTheme.blockGap) {
    if !texts.isEmpty { CodeUserBubble(text: joined) }   // 只包文本
    ForEach(others) { blockView($0) }                    // .attachments 在这里
  }
```

具体改动：

- `CodeMessageRowView` 新增：
  - `var onAttachment: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }`
  - `var loadThumbnail: (V2AttachmentContent) async throws -> Data? = { _ in nil }`
  - `var attachmentResolver: ([V2AttachmentContent], String?) -> [ChatMessageAttachment] = { contents, _ in contents.map { ... } }`（或直接传 `ChatAttachmentStore` + clientID）
- `blockView` 增加 `.attachments` case：
  - 用 `attachmentResolver(files, clientMessageID)` 得到 `[ChatMessageAttachment]`；
  - 用户行：`HStack { Spacer(minLength: CodePageTheme.userBubbleLeadingGutter); ChatMessageAttachments(files: ..., onOpen: onAttachment, loadThumbnail: loadThumbnail, alignment: .trailing, isOutgoing: true) }`
  - 助手行（当前无 producer，但保持通用）：leading 对齐、`isOutgoing: false`。
- `renderRows` 的过滤 switch 加 `.attachments: return true`（`CodeMessageRowView.swift:255-264`）。
- `userRow` 的 `default: others.append(block)` 会把 `.attachments` 放进 `others`，顺序在 text 之后，符合官方。
- `CodeUserBubble.attachments`：**不要**把附件渲染在 `CodeUserBubbleText` 的背景/padding 里面；要么删掉该空槽位，要么在 `CodeUserBubble` 的内层 VStack 中、`CodeUserBubbleText` 之后渲染（此时背景只包文本，等价于兄弟块）。推荐把附件留给 `CodeMessageRowView`，`CodeUserBubble` 保持纯文本。
- 纯附件消息：`texts` 为空 → 不画气泡，只画附件；pending 指示器不能依赖 `CodeUserBubble`（见 §5.4）。

### 5.3 Adapter：传入口 + 纳入签名/digest

| 位置 | 改动 |
|---|---|
| `rowView(.group)`（`TimelineChatContentAdapter.swift:1029-1048`） | 给 `CodeMessageRowView` 传 `onAttachment: onAttachment`、`loadThumbnail: model.thumbnail`、`attachmentResolver`（用 `model.session.attachmentPreviews.resolve(contents, clientID:)`） |
| Code group signature（`:1687-1747`） | 把 `attachments: []` 换成与通用分支（`:1773-1782`）相同的逻辑：对每个 row 取 `attachments(of:)`（**并且**考虑 clientID fallback），`attachmentSignatures(..., clientID:)`。这样预览尺寸到达/变化会改变 `contentRevision`，触发 reconfigure + 重测 |
| `codeHeightDigest`（`:574-604`） | 加 `.attachments` case：hash block id + 每个文件的 `fileId`/`cacheKey` + 用于布局的 pixel size（或直接 hash 该 block 的 `TimelineAttachmentPreviewSignature`）。否则签名变了但 exact height 缓存不会失效 |
| `officialEstimateHeight`（`:375-415`） | 加附件高度贡献；纯附件消息 `hasContent = true` |
| `probeDescribe` / `probeBreakdown`（`:1240-1320`） | 加附件计数，便于 gate/日志诊断 |
| `hasVisibleBlock`（`:1401-1419`） | 加 `.attachments: return true`；否则纯附件 group 被整条丢弃 |
| `measuredCodeGroupHeight` / `codeEstimateKind`（`:331-356,487-520`） | 把附件像素尺寸/`ChatMessageAttachment` 传给 measurer（见 §5.5） |

**clientID fallback（与 Chat 对齐，强烈建议）**：

- 在 `refresh()` 构建 `codeRowsByGroupID` 之前，对每个 user row：
  - `let cid = row.value.source["clientMessageId"]?.stringValue`
  - `let fallback = model.session.attachmentPreviews.resolve([], clientID: cid).map(\.content)`
  - 若 `row.value.content` 的 `attachments` 为空且 fallback 非空，把这个 fallback 作为该 message 的附件列表传给 builder（可给 `CodeMessageBuilder.rows` 加一个 `attachmentFallback: (V2TimelineItem) -> [V2AttachmentContent]` 参数，或 builder 后处理插入 block）。
- 这样"echo 暂时没有 wire attachments"时，Code 页也能像 Chat 页一样显示附件（`ChatAttachmentStore.swift:51-53`）。
- 签名/digest 也要用**同一份 resolved 列表**（wire 或 fallback），否则签的是空、画的是有，预览变化不重配。

### 5.4 Pending 行：统一 Code 用户行，不再回退 Chat 气泡

- `PendingMessageRow`（`SessionTimelineRow.swift:126-138`）：一旦 Code 能画附件，把 `.code` 分支改为始终使用 Code 用户行（文本气泡 + 附件块），不要再因 `pending.attachments` 非空而走 `UserMessageBubble`。
- 建议抽一个共享 `CodeUserMessageRow`（或 `CodeUserMessageContent`）：
  - 输入：`text`、`[ChatMessageAttachment]`、`isPending`、`onDeliveryIssue`、`onAttachment`、`loadThumbnail`；
  - 布局：`CodeUserBubble`（文本）+ 附件块（文本后、气泡外）+ 行级 pending/失败指示器；
  - 由 `PendingMessageRow`（`.code`）和 `CodeMessageRowView.userRow` 共用。
- 这样 pending→echo 的气泡样式、附件位置、附件可见性都不变；避免 Chat accent → Code neutral 的闪变。
- pending 指示器：`CodeUserBubble` 的 overlay 在 text 为空时不出现，纯附件 pending 需要行级指示器（放在共享 row 的 overlay，而不是 bubble 内）。

### 5.5 高度：新增附件高度，并接入现有 digest/seed

**`CodeRowHeightPlan`**（`CodeRowHeightPlan.swift:19-29,58-88`）：

- 加 `case attachments(height: CGFloat)`；在 `height` 里按 `blockSpacing` 规则累加。
- 图片/文件的具体高度由 `CodeMessageHeightMeasurer` 计算，plan 只负责"加一个已知高度"。

**`CodeMessageHeightMeasurer`**（`CodeMessageHeightMeasurer.swift:61-122`）：

- `planRows` 的 user/assistant 两个分支都加 `.attachments`：
  - 取 `files` 和解析后的 pixel sizes；
  - 图片：单图用 `ChatImageThumbnail.bubbleSize(for: previewPixelSize ?? serverPixelSize)`，无尺寸用 240×320 fallback（与 `ChatMessageImage.frameSize` 一致，`ChatMessageAttachments.swift:140-150`）；多图用 2 列 `gridCellSize() = 118`、spacing 4、rows = ceil(n/2)（`:100-112`）。
  - 文件：按 `ChatMessageFileAttachment` 的实际布局测：`HStack(spacing:12)` + icon 30 + `VStack(spacing:3)`（subheadline 1–2 行 + caption）+ padding 12×2；名称可用 `UIFontMetrics(.subheadline)` + `NSString.size` 在可用宽度内算 1/2 行。可用宽度 = `max(1, width - CodePageTheme.userBubbleLeadingGutter)`（用户行）再减 padding/icon/spacing。
  - 建议把这段抽成 `CodeAttachmentLayout`（纯函数），供 measurer 和 gate 共用。
- 新增可选参数：`attachmentSizes: [String: [CGSize?]] = [:]`（block id → 每个文件的显示像素尺寸）。缺省时用 `file.serverPixelSize`；adapter 传 store 的 `previewPixelSize ?? serverPixelSize`，保证 view 与 measurer 用同一尺寸。
- `CodeRowHeightPlan.Block.attachments(height:)` 的 height 在 `measured: false` 时也用同一公式（附件尺寸来自 wire 元数据，不依赖文本测量）。

**`codeHeightDigest` / `officialEstimateHeight` / `codeEstimateKind`**：见 §5.3。

**高度风险点**：见 §7，尤其是文件卡换行和"未知尺寸图片加载后改尺寸"。

### 5.6 点击 / 预览路由

现有 `SessionChatView.openAttachment`（`ios/.../Views/Chat/SessionChatView.swift:432-466`）已经覆盖：

1. `readsFromDevice` + `devicePath` → 工作区文件预览；
2. `localImageRoute`（`local:` fileId 且本地有原图）→ `AttachmentImageViewerSheet(localData:)`；
3. `file.isImage && file.openUrl != nil` → `AttachmentImageViewerSheet`（缩略图开局，原图用 `AttachmentImageLoader`）；
4. 其它（非图片、或图片但没有 `openUrl`）→ `model.download(fileID)` 写临时文件 → QuickLook（`:455-466`；`.quickLookPreview` 在 `:342`）。

**Code 页接法**：把 adapter 的 `onAttachment` 传给 `CodeMessageRowView` 即可，不需要新建路由。注意：

- connector 的 user attachment **没有 `openUrl`**（§1.2），所以跨设备/历史消息里的图片点击会走 QuickLook，而不是 `AttachmentImageViewerSheet`；这是现有 Chat 页同样的行为，不是 Code 新问题。
- 同一设备近期发送时，`resolve(contents, clientID:)` 可能从本地 `sent` 补出 `openUrl`（`ChatAttachmentStore.swift:51-66,146-159`），此时图片走 instant viewer；所以 Code 页 resolve 时**要带 clientID**，与 Chat 一致。
- 文件附件点击已有目标（QuickLook）；如果希望官方 `showAttachmentPreview` 的体验，需要另一张任务单，不在本次根因修复范围。

### 5.7 建议的最小改动顺序

1. 模型 + builder：加 `.attachments` block，单测覆盖 text+附件、纯附件、多 body 顺序。
2. 视图：`blockView` 渲染 `ChatMessageAttachments`；`renderRows` 保留；`hasVisibleBlock` 保留。
3. Adapter：传 `onAttachment`/`thumbnail`/resolver；Code signature 纳入附件；digest 纳入附件。
4. 高度：`CodeRowHeightPlan` + measurer + adapter 传尺寸；gate 加附件 fixture。
5. Pending：`.code` 统一 Code 行，去掉 Chat 气泡回退。
6. 可选：clientID fallback；官方 `AttachmentTiles` 4 格 +N / `SendUserMessageAttachmentRow` 视觉复刻。

---

## 6. 高度 / 签名 / digest 影响清单

| 位置 | 现在 | 需要加什么 | 不加的后果 |
|---|---|---|---|
| `TimelineGroupContentSignature.attachments` | Code group 恒 `[]`（`TimelineChatContentAdapter.swift:1747`） | 该 group 内 user row 的 `attachmentSignatures`（wire 或 fallback） | 预览到达/尺寸变化不 reconfigure；行高过期 |
| `TimelineAttachmentPreviewSignature` | `id + pixelWidth + pixelHeight`（`TimelineContentSignature.swift:23-27`） | 复用；如需区分"有无预览 bytes"，可加 `hasPreview: Bool`（当前 `previewVersion` 不在签名里） | 预览 eviction/到达在 server 尺寸已知时不影响高度，通常可接受；但 Code 的 fallback-only 列表需要 id/size 进签名 |
| `codeHeightDigest` | 只 hash text/tool/other（`:574-604`） | `.attachments` 的 id/文件身份/显示尺寸 | exact height 缓存不失效 → 视图与存储高度不一致 |
| `codeEstimateKind` | 用 measurer（`:331-356`） | measurer 带附件尺寸 | 流式/首帧估算漏附件高度 |
| `officialEstimateHeight` | 行数估算（`:375-415`） | 附件固定高度 + `hasContent` | 首帧 seed 偏小，cell 首次 fit 变高 |
| `measuredCodeGroupHeight` | 用 measurer（`:487-520`） | 附件尺寸 | settled 行首帧高度偏小，随后自纠正 |
| `CodeRowHeightPlan` | 无附件 case（`:19-29,58-88`） | `.attachments(height:)` | 编译期无法表达；手工加高度会重复/漏算 |
| `CodeMessageHeightMeasurer.planRows` | 无附件（`:61-122`） | 图片格/文件卡高度 | 同上 |
| pending `.pending` signature | 已含附件签名（`TimelineContentSignature.swift:156,181-189`；adapter `:1665-1668`） | 若 pending 改 Code 行，仍保留 | pending 高度估算与 settled 不一致的风险 |
| `TimelineHeightEstimate` | 每个附件 +180（`TimelineHeightEstimate.swift:54`） | 可选：改用 Code 附件高度公式 | pending 高度可能偏大/偏小，echo 瞬间跳一下 |

**高度公式建议**（与现有 `ChatMessageAttachments` 对齐）：

- 单图：`ChatImageThumbnail.bubbleSize(for: size)`；无 size → 240×320。
- 多图（`isOutgoing: true`）：`rows = ceil(count/2)`；`height = rows * 118 + (rows - 1) * 4`；maxWidth 240。
- 文件卡：`padding 12*2 + max(30, nameLines*subheadlineLine + 3 + captionLine)`；名称按可用宽度算 1–2 行（`lineLimit(2)`）。
- 多个附件块之间：`ChatMessageAttachments` 内部 `VStack(spacing: 8)`；`CodeMessageRowView.userRow` 的 `blockGap` 也是 8（`CodePageTheme.swift:192`），与官方 SwiftUI 默认 `interBlockSpacing` 一致（`EVIDENCE/round19/bubble-layout.md:94`；官方为 nil → 默认）。

---

## 7. 风险与测试 / 门禁建议

### 7.1 风险（按严重度）

**P1 / 高**

1. **宿主 cell 里的图片可见性门可能永不触发**：`ChatMessageImage` 只在 `onScrollVisibilityChange` 置 `visible` 后才远端加载（`ChatMessageAttachments.swift:177,225-238`）。Code 页是 `UIHostingConfiguration` inside `UICollectionViewCell`（`TimelineHostingCell.swift:64-105`），不是 SwiftUI `ScrollView`；该 modifier 是否收到可见性回调**未验证**。若收不到，远端图片会一直停在 `ProgressView`（本地 `previewData` 的图片不受影响，因为 `:229-233` 直接用）。建议：
   - 给 `ChatMessageAttachments`/`ChatMessageImage` 加 `loadsImmediately: Bool = false`（Code 传 true），或在 Code 专用附件 view 中直接加载；
   - 真机/模拟器验证滚动进出、首次进入、历史加载三种情况。
2. **未知尺寸图片加载后高度会变**：`ChatMessageImage.frameSize` 的 fallback 是 240×320，加载完成后若 `previewPixelSize`/`serverPixelSize` 都为空，会改用 `imagePixelSize`（`ChatMessageAttachments.swift:135-150`），导致行高在 decode 后变化；而 Code 的 exact height 只按布局前的尺寸算。Codex 的 history/typed-event 附件没有 `width/height`（`connector/.../codex/timeline/typed_events.py:477-506`），pending 路径是否带取决于 server 的 `timelineAttachments`（`server/.../session_run.py:1148-1161` 在客户端给了尺寸时会带）；风险真实但需 wire 验证。建议 Code 页在尺寸未知时固定 fallback（不采用 `imagePixelSize`），或把 decode 后的尺寸写回 store 并触发重测。
3. **文件卡高度测量**：`ChatMessageFileAttachment` 的名称 `lineLimit(2)` + Dynamic Type + 宽 320 上限，使高度依赖于名称换行；measurer 若只按固定高度会偏差。建议抽 `CodeAttachmentLayout` 用与视图相同的字体/宽度算行数，并加 gate fixture；或先给 Code 文件卡固定高度 + `lineLimit(1)`（视觉与官方 `ArtifactPreviewCard` 有差异，但高度稳定）。

**P2 / 中**

4. **pending→echo 高度跳变**：pending 用 `TimelineHeightEstimate`（每附件 +180，`TimelineHeightEstimate.swift:54`），settled 用 exact Code 高度；两者可能差很多。建议 pending 也走 Code 附件高度公式，或接受一次轻微的滚动锚定变化。
5. **纯附件消息**：必须同时改 `renderRows`、`hasVisibleBlock`、`CodeRowHeightPlan`；任何一处漏掉，整条消息仍然消失（不只是附件）。
6. **clientID fallback 缺失**：如果 echo 的 wire attachments 为空，Code 页即便加了 block 也画不出来；Chat 页有 `resolve([], clientID:)` fallback（`ChatAttachmentStore.swift:51-53`）。建议按 §5.3 注入 fallback，并纳入签名。
7. **history rebuild 覆盖**（§1.4）：binding 丢失时 server 侧的 attachment 会被同 id 的无附件 item 覆盖；这会影响所有客户端，不只是 Code。需要单独的 wire/DB 排查与修复任务，不在本次 renderer 修复范围。
8. **attachments 重复/顺序**：多条 body 的附件要按 fileId 去重（revision/重复 item）；`ChatMessageAttachment.id` 在 fileId 缺失时用 index+cacheKey，ForEach 冲突会少画。建议 builder 层按 `fileId ?? cacheKey` 去重。

**Q / 低**

9. **`size` 字段错位**：connector 发 `byteSize`，iOS 读 `size`（`turns/attachments.py:27` vs `V2AttachmentModels.swift:46`），文件卡不显示大小。建议 `V2AttachmentContent.init` 同时读 `byteSize`（或 connector 改发 `size`；按"改契约先加后删"，客户端先兼容两者更稳）。
10. **`openUrl` 缺失**：connector 的 wire 附件没有 `openUrl/downloadUrl`（`turns/attachments.py:21-33`），跨设备图片点击走 QuickLook；本地同设备近期发送可能因 `sent` merge 补出 `openUrl`。这是现有行为，不是本次 bug。
11. **大字号 / 暗色 / RTL**：`ChatMessageAttachments` 用系统字体 + `.quaternary`/`.secondary`，暗色和大字号基本可用；但官方 Code 页的附件是 `AttachmentTiles`/`SendUserMessageAttachmentRow`，AA 用的是 Chat 组件，视觉不一致（tile 字体/尺寸/圆角未取证）。RTL 下 36 pt gutter/Spacer 的方向需真机确认。
12. **性能**：每个 Code group 每次 refresh 都 `resolve` 附件；建议按 group/contentRevision 缓存 resolved list + signatures，避免长会话滚动时重复字典查找。

### 7.2 测试与门禁建议

**单测（ClientCoreTests）**

- `CodeProfileModelTests`：
  - text+附件 → `["text:u1", "attachments:u1"]`；
  - 纯附件（text 空）→ `["text:u1", "attachments:u1"]`（builder 层），并断言 `CodeMessageRowView` 的可见性过滤保留附件（如可测）；
  - 多 body 各自带附件 → 顺序为 `text1, attachments1, text2, attachments2`；
  - `fileId` 去重。
- `CodeRowHeightPlanTests`：`.attachments(height: 100)` + text 的 8 pt blockSpacing + 10 pt margins 的精确和。
- `TimelineCollectionModelsTests`：Code group signature 在附件列表/像素尺寸变化时 `contentRevision` 变化（复用 `:364-371` 的测试模式）。
- `ChatSessionPolishTests` / `LocalRestorationTests`：保留现有 pending 附件测试；新增 echo item 带 attachments 时 `confirmEcho` 删除 pending、group 仍有附件。

**Code profile gate（`CodeProfileAutoRun`）**

- `rowHeightFixtures` 加 `bubble-attachment`：user message + 1 张有 `width/height` 的图片 + 1 个文件；宽 361/320、large/accessibility3；`CodeMessageRowView` 与 `CodeMessageHeightMeasurer` 的 delta 按 `.bubble` 阈值 2 pt 断言（`CodeProfileAutoRun.swift:620-760`）。
- 加 `messageRow` 截图 fixture（user text + 图片 + 文件），确认附件在文本下方、右对齐、不在气泡背景内。
- `blockDescriptors` 的 switch 加 `attachments:<id>`（`CodeProfileAutoRun.swift:170-177`；测试 `CodeProfileModelTests.swift:63-72` 同步）。
- 若加 pending fixture：捕获 pending 与 settled 两态，确认样式/位置一致（gate 目前没有 pending 场景，需要新增 stage 或走 `TimelineAutoRun`）。
- 注意：gate 的 `verifyRowHeights` 构造 `CodeMessageRowView` 时也要传附件 resolver/loadThumbnail（`CodeProfileAutoRun.swift:780-800` 一带）。

**手工真机清单（自动化做不到的部分）**

1. 发送 text+1 图、text+多图、text+文件、纯图、纯文件：发送前/echo 后都可见，位置在文本下方。
2. 滚动离开附件行再回来：图片能从 ProgressView 变成图（验证 §7.1-1）。
3. 断网/弱网：图片失败显示"轻点重试预览"，点击能重试；文件点击有失败提示。
4. 大字号 accessibility3、暗色、RTL：附件卡不裁切、不重叠。
5. 点图片：同设备近期发送应打开 `AttachmentImageViewerSheet`（若有 openUrl/本地原图）；跨设备/历史消息可能 QuickLook——记录实际行为。
6. 历史重载/重连后：附件仍在（同时验证 §1.4 是否发生）。

---

## 8. 需要官方证据补的未知项

| # | 未知项 | 现状 | 建议补证 |
|---|---|---|---|
| 1 | `AttachmentTiles` 的 tile 边长/圆角 | 官方 `AttachmentTileButton{pixelSize, cornerRadius}` 是运行时参数，常量 [U]（`round19/bubble-layout.md:68,189`；`round18/...:310`） | 反编译 `AttachmentTile` body `0x10187b4cc`/布局函数 `0x10187a1ec` 的上游常量；或真机 View Debugger 量单张/两张/四张 |
| 2 | 官方图片网格最大宽度/edge/RTL | `edge` 决定 leading/trailing，`frame(maxWidth:.infinity)`；具体可用宽度 [U] | 真机量 attachment 区与气泡右缘/左缘的关系 |
| 3 | 文件 `ArtifactPreviewCard` 的高度/字体/内边距 | 结构 [E]，数值 [U]（`round18/...:298-301`） | 反编译 `ArtifactPreviewCard` body 或真机量 |
| 4 | 官方 3 张图片的 `.wide + 2 square` 布局 | [I]（`round18/...:305-310`） | 截图/反编译确认 1/2/3/4/5 张的实际排布 |
| 5 | Code 页 pending 用户行的官方结构 | `Role.user(isPending:)` + `optimisticAttachmentBlocks`（`CANONICAL/02-transcript-model.md:280-311`），具体 pending 附件块顺序 [I] | 真机录屏/截图发送瞬间 |
| 6 | 多 block 消息里 attachments/fileAttachments 的块顺序 | `UserMessageCell` VStack 顺序 [E]；`DisplayMessage.blocks` 任意顺序时的重排规则 [I] | 反编译 `UserRowContent` 构造或真机样本 |
| 7 | DSH 插件 user message 的 `content.attachments` 形状 | connector 只透传插件 content（`connector/.../dsh/bridge/models.py:198-245`），无 attachment 映射 | 用 DSH 插件实发一条带图消息，抓 `timeline.itemUpsert` |
| 8 | Codex 图片附件的 `width/height` | history/typed-event 的 `user_input_attachments` 只写 `fileId/path/name/mediaType`，LocalImage 无宽高（`connector/.../codex/timeline/typed_events.py:477-565`）；pending 路径可能由 server `timelineAttachments` 带入宽高（`server/.../session_run.py:1148-1161`） | 实发 Codex 图片消息，抓 wire；决定 Code 页未知尺寸 fallback |
| 9 | `onScrollVisibilityChange` 在 `UIHostingConfiguration` 宿主里的行为 | 代码推断"可能不触发"（§7.1-1） | 真机/模拟器 + 日志/断点；这是实现前必须验证的 P1 |
| 10 | 历史 rebuild 是否在 pp 环境发生过"覆盖附件" | 代码路径存在（§1.4），无 DB/wire 证据 | 抓一次长会话/重连的 `timeline.sync`，对比同 id item 的 content.attachments |
| 11 | 官方 `showAttachmentPreview` 的呈现方式 | 官方点击走 `showAttachmentPreview`（`round18/...:294`），具体 sheet 视觉 [U] | 反编译/真机；决定 AA 是否继续用 QuickLook |

---

## 9. 顺带发现（范围外，不修）

1. **`V2AttachmentContent.size` 与 connector `byteSize` 不一致**：`ios/.../V2AttachmentModels.swift:46` 只读 `size`；`connector/.../turns/attachments.py:27` 发 `byteSize`。影响文件卡大小显示、图片 25MB 门槛（`SessionChatModel.swift:685` 用 `size ?? 0`，nil 时放行）。建议客户端兼容两者或契约统一。严重度 P2（展示/门槛），置信度：已验证（静态）。
2. **Chat 页 group signature 对"wire 为空、store fallback 有"的附件不签名**：`TimelineChatContentAdapter.swift:1773-1782` 只在 `attachments(of:)` 非空时加签名，而 `SessionTimelineRow` 会用 `resolve([], clientID:)` 画 fallback；预览尺寸变化可能不触发重配。Code 页接入时应避免复制这个缺口。严重度 P2，置信度：代码推断。
3. **`CodeUserBubble.attachments` 是一个误导性空槽位**：注释说"预留官方附件气泡"，但官方证据明确附件不在气泡内（`round19/bubble-layout.md:17,66,180`）。建议删除该属性，或改名/注释说明它只承载"文本后、气泡外"的兄弟块，避免后续把附件塞进气泡背景。严重度 Q，置信度：已验证（静态 + 官方证据）。
4. **`CodeMessageRowView.preparedBlocks` 属性未被使用**：`CodeMessageRowView.swift:49,68-77` 声明/接收，但 `blockView` 的 `CodeMarkdownTextLeaf` 没有传；`TimelineHostingCell.swift:131-135` 的注释仍说"adapter builds preparedBlocks, CodeMessageRowView hands them to ChatMarkdownView(initialBlocks:)"。这是本次附件任务之外的既有不一致，建议单独核对，避免误以为首帧已预解析。严重度 P2/Q，置信度：已验证（静态代码），实际影响未验证。
5. **`AttachmentImageLoader` 需要 `openUrl`，但 wire 附件没有**：`AttachmentImageLoader.swift:69-71` 在无 `openUrl` 时抛 `missingURL`；`SessionChatView.openAttachment` 因此对无 URL 的图片走 QuickLook（`SessionChatView.swift:447-466`）。若产品希望 Code/Chat 图片都走 instant viewer，需要 server 在 timeline attachment 里补 `openUrl`，或让 viewer 支持 fileId 下载。严重度 P2（体验），置信度：已验证（静态）。

---

## 10. 最终判断

- **根因成立范围**：仅就本次静态审计成立；未在真机/真 wire 上验证。只要 Code renderer 生效（collection timeline + `group.explicitID != nil`），带附件的 user message 必丢附件；这是模型/视图层的确定性缺口，不依赖网络或 server 版本。
- **最小改法**：`Block.attachments` + `CodeMessageRowView` 复用 `ChatMessageAttachments` + adapter 传 `onAttachment`/`thumbnail`/resolver + 高度/签名/digest 补附件；pending 统一 Code 行。
- **最大风险**：宿主 cell 的 `onScrollVisibilityChange` 可能不触发导致远端图不加载；其次是未知尺寸图片 decode 后高度变化和文件卡高度测量。两者都需要 gate + 真机验证。
- **视觉复刻**：复用 Chat 组件能修"消失"，但不是官方 `AttachmentTiles`（4 格 +N）和 `SendUserMessageAttachmentRow`；官方 tile 尺寸/圆角/文件卡数值仍 [U]，需要单独补证。
