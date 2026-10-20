# C5 / M4 交接：静态正文收口与流式起点（2026-10-20）

> 分支：`feat/textkit2-assistant-body`
> 最新代码提交：`1d6af112`（代码卡图标改 AppSymbol 资源）
> 最新文档提交：本文件
> 约束：**不合并 dev、不发包、不动部署**；视觉冻结；先验证再动手。

## 0. 一句话

静态助手正文已经完成“只换引擎、不改视觉”的收口：一条消息一个 cell、TextKit 2 测量、表格单 surface、代码高亮与 AA 视觉一致。下一步是 **M4 流式**，然后是附件与选择/链接。

## 1. 当前状态（已验证 / 待验证）

### 1.1 已验证

- **行粒度**：Code 页一个 `DisplayMessage` 一行，块在行内堆叠；流式正文是独立 `.streamingText` 行。证据：Hark `part-ab-code-page-granularity.md`（EVIDENCE）。
- **M3 gate**（回退 padV 后，CI `39418489821` 双绿）：
  - `stored 640 == measured 640`、`cellContent 639.67`
  - 表格 surface：6 个无障碍元素 / 0 子视图 / 0 label
  - 滚动：median 22.88ms / p95 27.00ms / max 28.18ms
- **视觉 parity**（CI `39448039339` 的 artifact，`textkit-parity.json`）：
  - 旧 Textual：`608.33pt`
  - 新 TextKit 2：`610.00pt`
  - 差 `1.67pt`，逐块取整级别；代码高亮颜色、列表 pitch、表格/代码卡尺寸已对齐
  - 像素差异约 4.56%，主要是 1.67pt 累计位移，不是结构性差异
  - 图片：`/home/ubuntu/aa-test/art-39448039339/parity-legacy.png`、`parity-textkit.png`
- **代码高亮**：Textual 的 Prism tokenizer 通过新增公开桥接复用（`ios/Packages/Textual/Sources/Textual/Public/SyntaxHighlighting.swift`），AA 侧用 `ChatPalette` 同一套 token 颜色。
- **列表 pitch**：Textual 在列表内用“行距 + 2pt”的条目 pitch（`ChatMetrics.listItemSpacing`），已同步到测量/渲染。

### 1.2 待验证

- **图标修复 CI `39451773950`**（`1d6af112`）：代码卡复制/放大按钮改为 `AppSymbolAssets` 的 `aa-Copy` / `aa-Maximize2`，尺寸按 body 缩放。跑完需：
  1. 下载 artifact 的 `parity-legacy.png` / `parity-textkit.png`
  2. 看两张图的代码卡 header 图标是否一致
  3. 重新生成并排图/像素 diff
- 真机未验：模拟器只证明静态排版；滚动、手势、字体渲染需真机。

## 2. 本轮提交（按时间）

| 提交 | 内容 |
|---|---|
| `a55c1d25` | 表格单 surface（M3.4 结构） |
| `02c727bd` | revert M3.3 分段行，恢复一条消息一个 cell |
| `f617fb07` | DEBUG 视觉 parity gate（旧/新双渲染） |
| `bda18589` | TextKit 块间距按 Textual 边距折叠 |
| `c656efdd` | parity 采集忽略安全区 |
| `9ef3bdbc` | 顶层快照 12pt 间距 |
| `228963da` | parity 报表每块高度/间距 |
| `f36492b0` | parity 裁剪空白边 |
| `8fc03f95` | 裁剪用不透明背景 + ink 诊断 |
| `3501f375` | 裁剪按画面自身背景色 |
| `2158c6c4` | Textual 公开 Prism tokenizer 桥 |
| `3bc16a2a` | TextKit 代码卡接语法高亮 |
| `c5086a1a` | parity 截图等待高亮 settle |
| `70ee0530` | 列表条目 pitch 对齐 Textual |
| `1d6af112` | 代码卡图标改 AppSymbol 资源 |

## 3. 已确认的决策/约束

1. **视觉冻结**：pp 2026-10-20 定「逆向只学架构不动视觉」。`ChatMetrics` / `ChatPalette` 的视觉值不再动；任何视觉常数改动必须单独问 pp。
2. **行粒度**：一条助手消息一个 cell，内部块堆叠；不回到 M3.3 的每段一行。
3. **tool call 形态**：保持 AA 现有 A 形态（工具胶囊聚合）；官方 B 形态（消息内平铺）以后再说，见 `docs/perf-6b-c5-code-page-parity-task.md` §4。
4. **不合并/不出包**：`origin/dev` 不动；真机验收/合并/出包都要 pp 明确点头。
5. **验证纪律**：第三方逆向报告的 `INFERENCE` 不等于验证；任何官方行为先有地址级 EVIDENCE，再写实现任务单，再改代码。

## 4. M4 顺序（建议）

### 4.1 流式（下一步，先写任务单）

官方证据（Hark `part-ab` §1、§8；Muse `part-ac` M5）：

- 流式正文是**独立 `.streamingText` 行**（固定 ID），完成后转 `.message(id)` 行（换行，不是原行原地切换）。
- 数据每 0.1s 发布整段 `StreamingAssistantText`（`blocks: [Block{index,text,markdown}]` + `isComplete`）。
- 视图按 block id 逐块 `EquatableView` diff；未变化的块不重算 body。
- 正文 leaf：`MarkdownTextView` 引擎只失效“上一段起点到文末”；`MarkdownUITextView` 引擎整段替换。
- 代码：前缀相同时只追加尾部 + 增量高亮；表格原地更新、整表重排、tile 从 y0 往下失效。
- 流式期 tool call 不在 `.streamingText` 行（`SessionLiveStreamAssembler` 无 tool 字段）。

AA 现状：

- `TimelineChatContentAdapter.swift:239` 明确排除 `isStreamingText` / `isRevealing`，流式走旧 SwiftUI/Textual 路径。
- 所以流式期间**没有**用 TextKit 2；这是当前最大的体感/性能缺口。

流式任务单至少覆盖：

1. 独立 streaming 行模型与固定 ID；完成后换 `.message` 行的时序/锚点。
2. 0.1s 块集合的解析/测量；逐块 diff 的身份。
3. 正文尾部增量失效（至少做到不整段重建）；代码块增量高亮；表格复用。
4. gate：流式高度单调、stored == measured、无重叠/跳动；滚动 gate；视觉 parity（流式结束后与静态一致）。
5. 不改变现有视觉。

### 4.2 附件与特殊块

- 图片、Git badge、公式、带文件变更摘要的 footer。
- 现状：解析器遇到未支持结构整条回退 hosting（`imageRejected` gate）。
- 要把它们做成正式 block（图片块/chip/公式视图），接入测量；图片异步尺寸要防“先塌后长”。

### 4.3 选择 / 链接 / 复制

- 正文 `isSelectable=false`，表格不参与字符级选择，链接不可点。
- 官方：系统选择/自实现 `UITextInput`、链接菜单、HTML/纯文本复制、按行无障碍元素。

### 4.4 Dynamic Type / RTL / 无障碍

- 全字号档、RTL、VoiceOver 链接/代码行元素验证。

### 4.5 真机验收 + 出包 + 合并

- 真机滚动/手势/字体；出包；合并 dev（需 pp 点头）。

## 5. 关键文件与路径

- 行模型/解析：`ios/Agents Anywhere/Agents Anywhere/Views/Chat/TextKit/AssistantMarkdownDocument.swift`
- 测量/间距：`.../TextKit/AssistantMarkdownTextLayout.swift`
- Cell/块视图：`.../TextKit/AssistantMarkdownCell.swift`、`AssistantMarkdownBlockViews.swift`
- Gate：`.../TextKit/TextKitM3AutoRun.swift`、`TextKitVisualParityAutoRun.swift`
- 适配器/流式准入：`.../TimelineCollection/TimelineChatContentAdapter.swift`（`:239`）
- 工作流：`.github/workflows/ios-build.yml`
- 视觉 parity 结果：`/home/ubuntu/aa-test/art-39448039339/textkit-parity.json`
- 图片服务（临时，tailnet）：`/home/ubuntu/parity-share/`，端口 8898，进程为后台 `python3 -m http.server`。URL 形如 `http://ser621270764721.tail02735d.ts.net:8898/parity-side-by-side.png`；重启即失效。
- 本地报告：
  - `/home/ubuntu/aa-test/part-aa-markdown-ui.md`（Code/Chat 页 Markdown 渲染）
  - `/home/ubuntu/aa-test/part-ab-code-page-granularity.md`（行粒度）
  - `/home/ubuntu/aa-test/part-ac-code-page-parity.md`（M1–M5 补挖）
  - `docs/perf-6b-c5-code-page-parity-task.md`
  - `docs/perf-6b-c5-muse-audit.md`
  - `docs/perf-6b-c5-code-page-verification-task.md`
  - `docs/perf-6b-c5-m3.4-task-sheet.md`

## 6. CI / 验证命令

```bash
# 派发（feature 分支不会自动触发）
TOKEN=$(git -C /home/ubuntu/aa-ring-work remote get-url origin | sed -E 's#.*x-access-token:([^@]+)@.*#\1#')
curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" -H "User-Agent: cc" \
  "https://api.github.com/repos/chenyynx/Agents-Anywhere/actions/workflows/ios-build.yml/dispatches" \
  -d '{"ref":"feat/textkit2-assistant-body","inputs":{"timeline_autorun":"true"}}'
# watcher：/home/ubuntu/aa-test/ci-watch-aa-m3-step1.py（改 RUN_ID，run_in_background；结束会走 Bark）
```

已知 flake（与本改动无关）：

- `ModelSwitchRecoveryTests.stopStaysReachableWhenADeadProjectionSaysItCannotInterrupt`
- C3 gate：`measurement: no cell for reasoning` / `measurement longGroup: cell 200.0 clips content 1471.0`
- 处理：M3/parity 独立看；必要时 rerun failed jobs。

## 7. 通知

- AA 客户端通知做好前，所有通知走 `/home/ubuntu/bin/aa-notify "标题" "正文" "AA"`。
- URL 在 `/home/ubuntu/.config/bark/aa.url`（0600），不进仓库/记忆正文。

## 8. 新会话开场提示

```text
读 /home/ubuntu/aa-ring-work/docs/perf-6b-c5-m4-handoff.md，按里面的约束继续 C5 M4。
先确认图标修复 CI 39451773950 和最终 parity 图，再写流式任务单；
不要动视觉、不要合并 dev、不要出包；先验证再动手。
```
