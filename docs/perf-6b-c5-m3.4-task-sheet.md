# C5 / M3.4 任务单：表格单 surface（2026-10-20）

> 分支：`feat/textkit2-assistant-body`（不合并、不发包）
> 依据：Hark 第二轮报告（本地 `/home/ubuntu/aa-test/part-aa-markdown-ui.md`，sbx `/home/ubuntu/wiring/docs/part-aa-markdown-ui.md`）
> 前置：M3.3 per-block 行 CI `39392270705` 全绿

## 0. 一句话

把表格从「每格一个 UILabel + 卡片子视图」改成官方的单 surface 形状：**一个表格 surface 视图画完整张表**（表头填充、行分隔线、外框、所有单元格文字），单元格不再各自持有 UIView。表格作为助手正文里的一个 block，随 Code 页的“一条消息一行”一起渲染。

## 1. 依据与边界

Hark 报告确认：

- 官方**Code 页**是一条助手正文一个 hosting 行，内部由 `RichMarkdownView` 按块渲染；**聊天页**才是 `prose | code | table` 每段一个 cell。按 pp 定稿，助手正文采用 Code 页的一条消息一行，M3.3 的分段行已回退（见 `docs/perf-6b-c5-m3.3-task-sheet.md` §10）。
- 官方表格是单文本 surface + 自定义 layout：一张表一个 `MarkdownTableLayout`，单元格是段落，绘制按 `(column,row)` 分 tile；没有单元格 UIView。单元格只以无障碍元素形式存在。
- 几何：`padH = 12`、`padV = 8`；行高 = 本行最高单元格 + `2×padV`；表宽 = `Σ(列宽 + 2×padH)`；溢出时横向滚动 + 边缘渐隐；表头填充第 0 行、行分隔线、外框；未找到竖线。
- 列宽由 `TableOverflowPolicy` 分配（`lines 8`、`comfortCap 10×body`、`proseCap 16×body`、`tokenCap 12×body`、`squeezeBand 0.15`、`columnInset 40`、`comfortFraction 0.7`）；字段与常量的对应关系仍是 INFERENCE，先不照搬。

本单只做**渲染形状与几何中已确证的部分**：

1. 单 surface 绘制表格，删除每格 UILabel。
2. `padV` 从 AA 的 10 对齐到官方的 8；`padH` 已是 12。
3. 保留 AA 现有列宽策略（max-content，`ChatMetrics.tableContentWidthCap = 260` 封顶）；官方 `TableOverflowPolicy` 待其分配算法确认后再单独对齐。
4. 表格的无障碍从「每个 UILabel 自动成为元素」改为 surface 自己提供单元格元素（label + frame + row/column 信息）。
5. 边缘渐隐、单元格图片、整表结构化复制不在本单。

## 2. 实现

### 2.1 `AssistantTableBlockView`

- 保留横向 `UIScrollView`、`contentSize = 表格尺寸`、`bounces = false`。
- 子视图从 `card + labels` 改为单个 `AssistantTableSurfaceView`，frame = `table.totalWidth × table.totalHeight`。
- 删除 `AssistantTableCardView`、`AssistantTableLabel`。
- 圆角由 surface 自己裁剪/描边，不再依赖 card 的 layer。

### 2.2 `AssistantTableSurfaceView`

- `isOpaque = false`、`contentMode = .redraw`、`backgroundColor = .clear`。
- `draw(_:)`（只处理与 `rect` 相交的单元格）：
  1. 用圆角路径 `addClip()`；
  2. 表头填充 `rowHeights[0]`；
  3. 行分隔线：`y = rowTop[i] − line`，宽 = `bounds.width`，高 = `line`；
  4. 每个单元格：`UIRectClip` 到单元格矩形后，用 `NSAttributedString.draw(with:options:[.usesLineFragmentOrigin, .usesFontLeading])` 在 `(x + padH, y + padV, colW − 2padH, rowH − 2padV)` 内绘制；
  5. 恢复裁剪，描外框（`line = 1/displayScale`）。
- 颜色沿用 `ChatTextUIColors.tableHeaderFill` / `tableLine`；`traitCollectionDidChange` 配色变化时 `setNeedsDisplay()`。
- 文字绘制与测量仍分离：高度仍由 `AssistantMarkdownTextLayout.tableMetrics`（TextKit 2）给出，绘制使用同一份 attributed string 与同一列宽；`2×padV` 的余量吸收引擎间行高差。

### 2.3 无障碍

- surface 不是单个 accessibility element。
- 每个非空单元格生成一个 `AssistantTableCellAccessibilityElement: UIAccessibilityElement`：
  - `accessibilityLabel` = 单元格纯文本；
  - `accessibilityFrameInContainerSpace` = 单元格矩形（不含 padding 或含？用单元格矩形，含 padding 更易点中）；
  - `accessibilityTraits = .staticText`；
  - 记录 `row` / `column`，作为自定义属性（官方同名属性；VoiceOver 不直接消费，但便于调试）。
- `accessibilityElements` 在布局/内容变化时重建并缓存。

## 3. Gate

沿用 `aa-textkit-m3`，增加：

1. 表格 block view 只有一个表格 surface 子视图（scrollView 内），没有逐格 label。可通过 DEBUG 计数或在 gate 里遍历视图树断言。
2. 表格 surface 的 accessibilityElements 数量 = 非空单元格数。
3. 现有断言全部保持：每 segment `stored == measured`、总高不变量、footer、滚动 gate。
4. 报告新增 `tableSurfaceCells` 与 `tableSurfaceSubviews`。

`padV` 改为 8 后，表格与整条 fixture 的高度会下降（每行 −4pt），gate 的期望值都是相对断言，不写死绝对高度。

## 4. 风险

- **绘制引擎差**：TextKit 2 测量、UIKit 绘制；若行高不足会裁字。验收用 CI 截图 + 真机目测；必要时改为 TextKit 2 fragment 绘制。
- **无障碍回归**：删除 UILabel 会丢掉自动元素，必须补齐 surface 元素；gate 断言数量。
- **滚动性能**：单 surface 的文字绘制可能比 label 合成慢；以 M3.2 滚动 gate 为准（当前 median 29.09 / p95 58.95ms），若 p95 明显回退则回滚单 surface、保留 padV 对齐。
- **附件**：表格单元格里的 Git badge/图片仍不会渲染（与当前 UILabel 行为一致），记为遗留。

## 5. 交付顺序

1. `AssistantTableSurfaceView` + 无障碍元素
2. `AssistantTableBlockView` 切换、删除旧 label/card
3. `padV = 8`
4. gate 增加 surface/无障碍断言
5. CI 全绿后记录结果

## 6. 验收

- CI `test` + `timeline-autorun` 双绿；M3 gate `passed: true`
- 每段 stored == measured；总高不变量；footer 不变
- 表格 surface 无逐格子视图；无障碍元素数正确
- 未覆盖：真机视觉/滚动、边缘渐隐、官方列宽 policy、表格内附件
