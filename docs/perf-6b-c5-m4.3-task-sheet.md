# C5 / M4.3 任务单：特殊块与异步尺寸（2026-10-21）

> 分支：`feat/textkit2-assistant-body`（**dev 绝对不碰、不合；测试包只从本分支出；未明确说“合 dev”前绝不合并**）
> 级别：**L**（块模型、TextKit 内联附件、准入规则、钱路测量与视觉 gate）
> 前置：M4.2 已完成、C3/M4 gate 连续 3 轮全绿（`docs/perf-6b-c5-m4.2-handoff.md`）；真机验收未回。
> 约束：**只换引擎、不改视觉**（pp 2026-10-20 定）；`ChatMetrics` / `ChatPalette` 的视觉常数不改；任何视觉常数改动单独问 pp。
> 先方案后代码：本单先审，通过后再实现；不自动出包、不合 dev。

## 0. 一句话

把当前会让整条回复回退 hosting 的四类内容——**内联图片、Git badge、公式、带文件变更摘要的 footer**——做成 TextKit 引擎正式承载的块/内联附件，并给出**同步可测、异步加载不塌**的尺寸规则；同时并入 M4.2 遗留的“揭示中不切引擎、收口后再交接”补丁，准入与 gate 同步更新。

## 1. 现状（代码证据）

### 1.1 四类内容现在都会整条回退 hosting

| 内容 | 解析产物 | 现在的处理 | 证据 |
|---|---|---|---|
| Markdown 图片 | run 上的 `imageURL`（Textual 在视图层才解析成附件） | 内联转换遇 `run.imageURL` 直接返回 nil → 整条文档 nil | `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TextKit/AssistantMarkdownDocument.swift:638` |
| Git badge | `run.textual.attachment`（`ChatGitBadgeAttachment`） | 同上，任何 attachment run 都拒绝 | 同上 `:638`；badge 生成 `:269-274` |
| 公式（行内/块） | `run.textual.attachment`（Textual `MathAttachment`） | 同上；块级 `default` 分支明确列为 hosting-only | 同上 `:374-379`、`:638` |
| 文件变更 footer | `TimelineTurnAction.changes` → `SessionTurnReviewFooter` | `isTextOnlyTurnAction` 为 false → 静态/流式准入都不通过 | `Views/Chat/TimelineCollection/TimelineChatContentAdapter.swift:483-494`、`:260-263`、`:407` |

- 流式侧还有一个放大效应：任一块转换返回 nil → `AssistantStreamingDocumentBuilder.isRejected` → adapter 把该行记入 `streamingFallbacks`，**整个回合都不再回 TextKit**（`AssistantMarkdownDocument.swift:847-864`、`TimelineChatContentAdapter.swift:316-323`）。
- 静态/流式的准入规则各自复制了一份事实判断（`TimelineStreamingEligibility.swift:10-30` + adapter `:398-423`）。

### 1.2 现有测量与“塌”的位置

- 静态文档在 apply 前同步测量，只把 `validatorHeight` 通过的数写缓存（`TimelineCollectionController.swift:646-694`）；footer 只认定高 `AssistantTurnFooter.height`（`:680-690`）。
- TextKit 文档行**不参与**可见 cell 的 fit 校正（`:849-851`），所以“防塌”必须在文档测量本身做到，不能靠事后校正。
- 已有的下限/单调保护：非文字游标 `<8pt` 不报（`AssistantMarkdownCell.swift:480-490`）；流式行高单调（`:609-620`）；控制器丢 `<8pt` 帧。M4.3 新增块必须沿用同一口径。
- 旧 Textual 路径的保留尺寸（M4.3 必须 1:1 复刻）：
  - 图片：`width = min(420, proposal.width)`，`height = width * 0.75`；session 文件引用走 68pt 芯片（`Views/Chat/Markdown/ChatMarkdownImage.swift:22-25`）。
  - Git badge：`size = 0.8 × 当前字体`，`height = size × 1.8`，`width = CTLine 宽度 + size × 2.8`，baseline `-0.22 × 字体`（`Views/Chat/Markdown/ChatGitBadge.swift:15-25`）。
  - 公式：Textual `MathAttachment`，字体比例 **1.2**，块级居中（`ios/Packages/Textual/Sources/Textual/Internal/Attachment/MathAttachment.swift:39-56`、`MathProperties.swift:28-36`）。
  - 文件变更摘要行：`minHeight 44`，组内 `VStack(spacing: 4)`（`Views/Chat/SessionTurnReviewSheet.swift:36-63`、`Views/Chat/SessionTimelineEventView.swift:24-35`）。

### 1.3 M4.2 遗留（本单并入）

- 行在揭示中因 notice / 文件变更 footer 变得不合格时，会**立即**切 hosting；此时 renderer-owned 模式已把原文全量发布，剩余文字一次性出现（`docs/perf-6b-c5-m4.2-handoff.md` §5）。
- 助手消息的 message-level 附件实际从不出现（connector 只给用户消息挂 `attachments`），`ChatMessageAttachments` 在助手侧是死代码；本单**不动**该分支。

## 2. 范围

**做**

1. 块模型新增：图片块、块公式块；文本块支持**内联附件**（Git badge、行内公式）。
2. Git badge / 行内公式 / 图片的尺寸全部在**文档构建期同步算好**；图片加载只在固定框内换内容，不参与测量。
3. 文件变更 footer 进 TextKit cell：定高行 + 定高常量，摘要是否出现由纯函数 `TimelineTurnReview.build` 同步决定；保留点击打开 review sheet。
4. 准入：静态与流式都允许带文件变更 footer 的助手行；新增“揭示中持住引擎”规则。
5. Gate：内联附件可行性的 spike；M4.3 静态块/尺寸/footer 断言；M4 gate（gateVersion 7）补流式与交接断言；视觉 parity 夹具扩到新块。
6. Textual 桥：只新增一个 public 文件（公式分类/尺寸/宿主视图），照 `Public/SyntaxHighlighting.swift` 的既有做法。

**不做**（明确留后）

- 选择 / 链接 / 复制（M4.4）；Dynamic Type / RTL / 无障碍全量（M4.5）。
- 工具调用平铺、per-block cell、官方完整滚动状态机。
- 助手 message-level 附件条（死代码，保持现状）。
- 用户消息气泡内的附件/图片（不走 TextKit）。
- 主题分隔线（`thematicBreak`）、块级 HTML 等仍保持 hosting 回退。

## 3. 设计

### 3.1 块模型扩展

```swift
enum AssistantMarkdownBlock {
    case text(AssistantTextBlock)
    case list(AssistantListBlock)
    case quote(AssistantQuoteBlock)
    case code(AssistantCodeBlock)
    case table(AssistantTableBlock)
    case image(AssistantImageBlock)   // 新增
    case math(AssistantMathBlock)     // 新增（仅块级公式）
}

struct AssistantImageBlock {
    let url: URL
    let description: String
    let isFileReference: Bool          // SessionFileReference.path(from:) != nil
    func reservedSize(columnWidth: CGFloat) -> CGSize   // 与旧路径同公式
}

struct AssistantMathBlock {
    let latex: String
    let fontSize: CGFloat              // typography.body
    func size(columnWidth: CGFloat) -> CGSize           // Textual 桥同步返回
}
```

- `height(of:width:)` 增加两个 case；`AssistantMarkdownBlockViewFactory.make` 增加两个视图。
- `characterCount`：图片块 = **1**；块公式 = **1**；文本块内的内联附件按 `NSAttributedString(attachment:)` 的 1 个 UTF-16 单元计。理由：引擎渲染的真实单位是 1 个 attachment；旧 Textual 的 label/alt 字符只影响揭示配速，不影响可见结果（写入已知差异）。
- `kindName` / `blockCounts` 增加 `image`、`math`，gate 用它做结构普查。

### 3.2 内联附件（Git badge / 行内公式）

**转换**：`inlineAttributedString` 不再因为 attachment 返回 nil，而是为每个 attachment run 生成：

1. 一个 `NSTextAttachment` 子类（`AssistantInlineAttachment`），携带：
   - 类型化 payload：`.gitBadge([GitDirective])` / `.math(latex: String)`；
   - 同步算好的 `bounds = CGRect(x: 0, y: baselineOffset, width:, height:)`；
   - accessibility label（badge = `ChatGitBadgeAttachment.description`；公式 = `$latex$`）。
2. `NSAttributedString(attachment:)` 追加进输出；文本块其余字符照旧。

**尺寸（构建期同步，宽度无关）**：

- badge：`size = 0.8 × 该文本块基础字号`；`height = 1.8 × size`；`width = CTLineGetTypographicBounds(标签 CTLine) + 2.8 × size`；上限取 `TimelineListMetrics.maximumColumnWidth (760)`（正常徽章远小于列宽；超过列宽时横向溢出，列入残余）。baseline `-0.22 × 基础字号`。
- 行内公式：Textual 桥 `TextualMath.metrics(latex:style:.inline,fontSize:)` 返回 `size` 与 baseline offset（字体比例 1.2）。
- **宽度无关**是刻意的：`AssistantMarkdownDocument` 的缓存键不含列宽（`TimelineChatContentAdapter.swift:275-291`），列宽变化只会重建视图、不会重建文档；把列宽塞进 bounds 会让旋转后附件尺寸失真。图片是唯一宽度相关的类型，因此走块级（3.3），按列宽现算。

**渲染**：`NSTextAttachmentViewProvider` 子类，`loadView()` 返回一个 `UIHostingController` 的 view：

- badge → 直接宿主 `ChatGitBadgeAttachment.body`（`Views/Chat/Markdown/ChatGitBadge.swift:10-13`），环境注入 `dynamicTypeSize` 与 `colorScheme`，并 `.foregroundStyle(.primary)`；
- 公式 → 宿主 Textual 桥的 `TextualMathView`（内部已把 `font` / `mathProperties` 注入 `TextEnvironmentValues`）。
- provider 持有 hosting controller 的强引用（TextKit 不负责生命周期）。

**交互（spike 决定，见 §6 S0）**：
- 主方案：provider 视图直接接收触摸（badge 的 Link/Menu）。为此含附件的文本块需要 `isUserInteractionEnabled = true`（当前 `AssistantMarkdownBlockTextView` 为 false，`AssistantMarkdownTextLayout.swift:225`）；保持 `isSelectable = false`、`isScrollEnabled = false`，gate 里用 `hitTest` 证明命中，滚动回归靠 M3/M4 的滚动 gate。
- 回退方案（spike 证明不可行时）：badge 用 UIKit 直接绘制胶囊 + `.link` 属性，由 `UITextViewDelegate` 的 primary action 打开 URL；多 URL 的 Menu 退化为打开第一个 URL（作为已知差异上报，不静默降级）。
- 公式无交互，回退为 `ImageRenderer` 快照不影响行为。

### 3.3 图片块

- 仅当**一个段落的内容只有一张图片**（除空白外的 run 全是 `imageURL`）时，`makeBlock` 产出 `.image`；段内图文混排仍返回 nil（整条回退 hosting，视觉与旧路径一致）。
- 视图：`AssistantImageBlockView`（UIView）宿主 `ChatMarkdownImageAttachment.body`（即现有 `ChatMarkdownImage`，`Views/Chat/Markdown/ChatMarkdownImage.swift:17-20`），固定 frame = `reservedSize(width)`；加载中/失败/重试都在这块框里发生。
- `reservedSize`：`width = min(420, columnWidth)`，`height = width × 0.75`；`isFileReference == true` 时 `height = 68`（宽度仍为 `min(420, columnWidth)`），与旧路径 `sizeThatFits` 完全一致。
- 点击行为由宿主视图自身提供（文件引用 → 打开；远程图片 → 预览），不新增手势逻辑。

### 3.4 块公式

- 段落内容只有一个 block-style 数学附件 → `.math`（通过 Textual 桥分类，见 3.8）。
- 视图：宿主 `TextualMathView`，水平居中（旧 Textual `MathBlock` 的 `textAlignment = .center`），宽度 = 列宽，高度 = `metrics.size.height`。
- 块级公式不是“非文字游标块”的特例：沿用现有 code/table/list 的块入场 + 块底 clamp（`AssistantMarkdownCell.swift:470-493`）。

### 3.5 文件变更 footer

- 新协议方法（默认 nil，gates 不受影响）：

```swift
struct AssistantFooterHost {
    let height: CGFloat        // 常量，不来自 fitting
    let view: AnyView
}
func assistantFooter(for item: TimelineListItem) -> AssistantFooterHost?
```

- adapter 构建：`TimelineTurnReview.build(...)`（`Models/Chat/TimelineTurnReview.swift`）按与 `SessionTurnReviewFooter.ReviewMemo` 相同的键（ids + revision + updatedSeq + root）记忆化；`review.files.isEmpty` 时不出现摘要行。
- 视图：`SessionTurnReviewFooter(action:root:hasOlderItems:onFile:)` 原样宿主（保留 sheet 行为），再有回复时追加 `SessionTurnActionsRow`；整体放一个 `VStack(spacing: 4)`。
- 高度（常量）：
  - 有摘要行：`4 + 44`；再加大盘动作行：`+ 4 + SessionTurnActionsRow.rowHeight`。
  - 仅动作行：`4 + SessionTurnActionsRow.rowHeight`（与现有 `AssistantTurnFooter.height` 相同）。
- 防塌：`44` 来自旧视图的 `minHeight`；若当前 trait 下 `UIFont.preferredFont(forTextStyle: .footnote).lineHeight > 44`（极端 Dynamic Type），adapter 返回 nil，该行继续走 hosting（宁缺勿假，M4.5 再收）。
- 测量：`TimelineCollectionController` 的 footerHeight 改用 `assistantFooter(for:)?.height`（替换 `:680-690` 的旧字段）。
- 单元格：`AssistantMarkdownCell` 增加一条“定高宿主 footer”路径，约束到 `height`；与现有 actions-only 路径合并。

### 3.6 异步尺寸防塌（硬规则）

1. **块高必须是 `(块数据, 列宽, displayScale)` 的纯函数**；不得读取图片加载结果、SwiftUI fitting、非确定状态。
2. 图片：`reservedSize` 先定框；加载/成功/失败/重试一律不改变块高；失败只能画在框内。
3. 内联附件：bounds 在文档构建期算好，测量和渲染共用同一份 `NSAttributedString`；`ChatMarkdownImageAttachment` / badge 的 `sizeThatFits` 只作为“旧路径真值”的对照，不再参与 TextKit 测量。
4. footer：只由常量与 `TimelineTurnReview.build` 的结果决定；**禁止**对 footer 做 `systemLayoutSizeFitting`。
5. 控制器：TextKit 文档行继续排除在可见 cell fit 之外；新增块不得依赖 `documentHeights` 的二次校正。
6. 下限：块高/行高 `<8pt` 一律视为未就绪（沿用 `AssistantMarkdownCell:480-490`、controller `:342-344`）。
7. 单调：流式行继续 `max(新, 旧)`；静态行允许在内容 revision 变化时重测（这是内容变化，不是塌）。

### 3.7 准入与“揭示中不切引擎”

**准入（静态 + 流式统一）**

- `TimelineStreamingEligibility` 的 `isTextOnlyAction` 改名为 `footerSupported`；M4.3 后 adapter 对文件变更 footer 返回 true（仅 §3.5 的极端 DT 例外）。
- 静态 `assistantMarkdown` 去掉 `isTextOnlyTurnAction` 守卫，改为 `footerSupported`。
- message-level `hasAttachments` 守卫保留（死代码路径，不动）。

**持住规则（并入 M4.2 遗留）**

`TimelineStreamingEligibility.admits` 增加：

```swift
holdsEngineThroughDisqualifiers: Bool   // adapter: isRevealEnabled && rendererRevealOwnership.isActive(row.id)
```

规则：

```
guard isSingleRowGroup, isAssistantMessage, !textIsEmpty, !isFallback else { return false }
if !holdsEngineThroughDisqualifiers {
    guard !hasInlineNotice, !hasAttachments, footerSupported else { return false }
}
return isStreamingText || isRevealing || isRevealPending
```

- `isFallback`（文档无法构建、不支持的块）**不**被持住规则豁免：没有可渲染的文档就不能硬撑 TextKit。
- 持住窗口 = ownership 存活期（揭示追平 + 最多 1.5s 兜底，`TimelineChatContentAdapter.swift:445-467`）。期间 notice / footer 不显示；owner 清除后第一次 apply 立即切 hosting 或带 footer 的静态 TextKit。
- 目的：不再出现“原文已全量发布 → 立刻切 hosting → 剩余文字一次性蹦出”。

**单测（ClientCore）**

- notice 到达 + 持住 → 仍准入；无持住 → 拒绝。
- attachments 同上。
- footerSupported=false + 持住 → 准入；解除持住 → 拒绝。
- `isFallback=true` 时持住也拒绝。
- 空文本/非助手/多行组：持住也不准入。

### 3.8 Textual 桥（唯一的三方包改动）

新增 `ios/Packages/Textual/Sources/Textual/Public/MathRendering.swift`（照 `Public/SyntaxHighlighting.swift` 的桥接模式）：

```swift
public enum TextualMath {
    public struct Descriptor { public let latex: String; public let isBlock: Bool }
    public struct Metrics { public let size: CGSize; public let baselineOffset: CGFloat }

    public static func descriptor(for attachment: AnyAttachment) -> Descriptor?
    public static func metrics(latex: String, isBlock: Bool,
                               fontSize: CGFloat, proposalWidth: CGFloat?) -> Metrics
}

public struct TextualMathView: View {
    public init(latex: String, isBlock: Bool, fontSize: CGFloat)
}
```

- `descriptor` 内部 `attachment.base as? MathAttachment`（`AnyAttachment.base` 为 internal，桥在包内可用）。
- `metrics` 用 `MathAttachment(...).sizeThatFits(...)` / `baselineOffset(in:)`，环境字体 = `.system(size: fontSize)`，`mathProperties` 用默认值（与旧路径未设置 `.mathProperties` 一致）。
- `TextualMathView` 把同一个 `TextEnvironmentValues` 注入 `MathAttachment.body`，保证“测得多少、画出来多少”。
- 不改 Textual 的现有渲染代码；包版本与产品不变。

### 3.9 旧路径

- `ChatMarkdownView`、`SessionTimelineRow`、`SessionTurnReviewFooter` 的行为与视觉**逐字节不变**。
- 新块只是 TextKit 侧新增；不支持的混排仍回退到旧路径。
- M3 gate 里的 `imageRejected` 断言（`TextKitM3AutoRun.swift:318-324, 364`）必须翻转成“图片被接受且成为 image 块”；这是预期改动，不是放宽。

## 4. 参数（全部沿用旧路径，无新视觉常数）

| 项 | 值 | 来源 |
|---|---|---|
| 图片宽 | `min(420, columnWidth)` | `ChatMarkdownImage.swift:22-25` |
| 图片高 | `width × 0.75`；session 文件引用 = 68 | 同上 |
| badge 字号 | `0.8 × 块基础字号` | `ChatGitBadge.swift:19-25` |
| badge 高 | `1.8 × size` | 同上 |
| badge 宽 | `CTLine + 2.8 × size` | 同上 |
| badge baseline | `-0.22 × 基础字号` | 同上 |
| 公式字号 | `1.2 × 块基础字号` | `MathProperties.swift:28-36` |
| 块公式对齐 | 居中 | 旧 `MathBlock` |
| 摘要行高 | `44`（极端 DT 时回退 hosting） | `SessionTurnReviewSheet.swift:36-63` |
| 组内 footer 间距 | `4` | `SessionTimelineEventView.swift:24-35` |
| 动作行高 | `SessionTurnActionsRow.rowHeight` | `SessionTurnActions.swift:42` |

## 5. Gate

### 5.1 S0：内联附件 spike（先做，决定主/回退方案）

在现有 `TextKitMaskSpikeAutoRun`（`aa-textkit-mask-spike`，workflow 已有步骤）增加 `attachments` 段，断言并写入 `textkit-mask-spike.json`：

1. `textView.textLayoutManager != nil`（确认 TextKit 2）。
2. 内联附件 provider 挂载成功（文本视图子树里能找到宿主视图）。
3. `AssistantMarkdownTextLayout.height` 与 `attachment.bounds.height` 一致（±0.5）。
4. `hitTest` 命中宿主视图（不需要合成触摸，证明交互接线）。
5. `layer.mask` 安装后附件视图仍在 mask 子树内（揭示可遮）。
6. 同一夹具在旧 Textual 路径的高度 ≥ 新路径，差值记录（供 parity 判读）。

spike 不过 → **停，按 §3.2 回退方案改设计并汇报**，不硬推。

### 5.2 M4.3 静态块 gate

夹具（新增，独立于 M3 fixture）：

```
一段行内公式 $a^2+b^2=c^2$ 与 badge ::git-commit{branch="main"} 混排的段落。
一张图片 ![alt](https://example.invalid/x.png)（离线必然失败，验证失败态不塌）。
$$ \int_0^1 x^2 dx = 1/3 $$（块公式）。
一张 session 文件引用图片（68pt 芯片）。
带文件变更 footer 的完成回合（actions + review）。
```

断言：

- `AssistantMarkdownDocumentParser.make` 非 nil；`blockCounts` 含 `image` / `math`；混排图文段仍回退（记录预期回退）。
- cell 是 `AssistantMarkdownCell`；`stored == measured`（±0.5）；每个块视图的高度约束 == `height(of:width:)`（±0.5）。
- 图片块高度 == `reservedSize(width)`；等待 2s（加载失败/重试）后再测，高度不变。
- footer：`stored == content + footer.height`；宿主视图 frame 高 == 常量；摘要行出现/不出现与 `review.files.isEmpty` 一致。
- 列宽变化：在同一 fixture 上按 `width1=393`、`width2=760` 各测一次，块高/行高都与纯函数一致（证明宽度相关块不是缓存死的）。
- 没有 `<8pt` 的块高/行高。
- 截图：`m43-static.png`。

### 5.3 M4 gate（gateVersion 7）

在 `TextKitM4AutoRun` 上扩展（不新增 job）：

- 夹具尾部加入 badge / 行内公式 / 图片块；断言流式文档不被拒绝、非文字游标能跨过它们、`stored == measured`、无塌陷。
- 完成帧：turn action 带 changes → 行在收口后进入**带 footer 的静态 TextKit cell**（不是 hosting），高度包含 footer。
- 穿插断言：揭示中新增 notice/footer 事实时，cell 实例保持不变直到收口（持住规则的产品侧接线由单测覆盖；gate 侧只验证渲染不跳）。

### 5.4 视觉 parity

`TextKitVisualParityAutoRun` 夹具扩充 badge / 行内公式 / 块公式 / 图片（离线失败态与文件引用芯片），旧/新双渲染截图对比；差值只允许来自既有 1.67pt 级别的取整漂移，新的结构性差异判红。

### 5.5 单测（ClientCore）

- `TimelineStreamingEligibility` 持住规则全矩阵（§3.7）。
- `AssistantFooterMetrics`（常量求和：摘要行/动作行/两者/极端 DT）纯函数测试。
- `AssistantImageBlock.reservedSize(width:)` 纯函数测试（420 上限、0.75、68）。
- 文档/块转换、TextKit 测量、adapter 接线仍不在 SwiftPM 测试目标（Views 不进 ClientCore）——靠 gate + 代码审查，与 M4.2 同口径。

## 6. 交付顺序

1. **S0 spike**（TextKit 2 附件 provider/交互/mask/测量）；不过就停下汇报。
2. **持住补丁**：`TimelineStreamingEligibility` + 单测 + adapter 接线（小、可独立验证）。
3. **Textual 桥**：`MathRendering.swift` + M3/M4 gate 能编译通过。
4. **块模型 + 转换**：image/math 块、内联附件转换；更新 M3 `imageRejected` 断言。
5. **视图与测量**：`AssistantMarkdownBlockViews` / `AssistantMarkdownTextLayout` / cell 内联附件视图提供者。
6. **footer**：adapter `assistantFooter`、cell 定高宿主、controller 测量接入。
7. **准入**：静态/流式支持 footer，去掉 `isTextOnlyAction` 守卫。
8. **Gate/parity/CI**：静态 gate、M4 gate v7、parity 夹具；dispatch `timeline_autorun=true` 连续两轮全绿。
9. 交接文档 `docs/perf-6b-c5-m4.3-handoff.md`（含恢复提示词）。

## 7. 风险与回退

- **TextKit 2 附件 view provider**：若 `isUserInteractionEnabled` 与滚动冲突、或 provider 不渲染，按 §3.2 回退；图片可独立改为块级（§3.3）不受影响。
- **宽度相关缓存**：图片/块公式按列宽现算；内联附件刻意宽度无关。若 gate 抓到旋转后高度不一致，优先改成“文档带宽度 revision”而不是放宽断言。
- **Textual 桥**：只增 public API，不改现有代码；包版本不动。桥若与内部 `MathAttachment` 签名漂移，CI 编译即红。
- **footer 极端 DT**：按 §3.5 回退 hosting，M4.5 统一处理；不为此改视觉常数。
- **性能**：每个内联附件一个 hosting controller。夹具按真实回复规模（个位数附件）验收；若 gate 的构建耗时明显高于 M4.2，再评估 `ImageRenderer` 快照（不改变尺寸与行为）。

## 8. 已知不覆盖 / 顺带发现

- 段内图文混排仍回退 hosting；多图同段同样回退。
- 内联附件超过列宽时横向溢出（badge 上限 760、行内公式按 intrinsic）；旧路径会按 proposal 收缩。属边缘，记残余。
- 揭示配速按 attachment = 1 字符计，与旧 Textual 的 label/alt 字符数不同（只影响揭示节奏，不影响结果）。
- 助手 message-level 附件条是死代码（`docs/perf-6b-c5-m4.2-handoff.md` §5），保持 hosting 守卫。
- 主题分隔线 / 块级 HTML 仍 hosting。
- 真机手势、震动、滚动仍只能真机验收（simctl 不能合成触摸）。

## 9. 验收

- S0 spike 通过（或按回退方案重新评审）。
- M4.3 静态 gate、M4 gate v7、视觉 parity 全绿；CI `test` + `timeline_autorun` 连续两轮绿。
- 旧 SwiftUI 路径截图与改动前一致（除既有 1.67pt 级漂移）。
- 未覆盖项按 §8 明示。
- **不碰 dev、不合并、不出包**；测试包只从 `feat/textkit2-assistant-body` 出。
