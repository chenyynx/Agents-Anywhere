# C5 / M3.3 交接（2026-10-20）

> 分支：`feat/textkit2-assistant-body`
> 最新提交：`b7b52028`（per-block rows）；任务单 `cb015cc9`
> 约束：不合并、不发包、不碰 dev；M3 渲染只在设置「会话时间线（实验）」打开后生效。

## 0. 一句话

M3.3 已把助手消息从“一条消息一个 cell”改成官方粒度：**prose / code / table 各自成 segment 行**。
代码已推送，CI run `39392270705`（commit `b7b52028`）正在跑；先看这轮结果，再继续。

## 1. 已完成（含证据）

- M1 spike、M2 段落/标题、M3 列表/引用/代码/表格、M3.1 最终回复 text-only footer、M3.2 滚动 gate + 表格 label/chrome 优化。
- 最近一次全流程绿：run `39380175782`（commit `24f8d9f6`）
  - `stored 640 == measured 640`、`cellContent 639.67`
  - scroll：median 34.998 / p95 57.08 / max 72.60ms
  - cellBuild 平均 27.17ms；按类型：list 10.8 / text 5.4（2×2.7）/ code 3.3 / table 1.47
- 同 commit A/B：median 44.54 / 25.46，p95 64.36 / 54.95，max 64.42 / 71.24，cellBuild 30.19 / 23.10 → 方差大，chrome 自绘未判定为回归，保留。
- Hark 逆向报告（Code 页 `ClaudeMarkdownUI`）：
  - sbx：`/home/ubuntu/wiring/docs/part-aa-markdown-ui.md`
  - 本地副本：`/home/ubuntu/aa-test/part-aa-markdown-ui.md`

## 2. M3.3 改了什么

提交顺序：

1. `342f3865` `AssistantMarkdownDocument.segments`：连续 text/list/quote → `.prose`；`.code` / `.table` 各自成段。gate 报告 segment plan。
2. `639a54e6` `TimelineListItem.segment(group:row:index:)` + `itemID = sg:<row>:<index>`；`TimelineItemIdentity.build` 支持 `itemsForGroup` 展开；重复 itemID 去重。
3. `b7b52028` 适配器 refresh 时解析可接入文档并分段，生成 segment items；`assistantMarkdown(for:)` 返回段文档；footer 只挂最后一段；布局对同消息相邻 segment 用 12pt，其它仍 20pt；M3 gate 断言每段 stored==measured、段数 4、footer delta、段高之和 + 12×间距 = 原整条消息高度（容差 5pt，因每段整点取整）。

关键文件：

- `ios/Agents Anywhere/Agents Anywhere/Views/Chat/TextKit/AssistantMarkdownDocument.swift`
- `.../TextKit/AssistantMarkdownTextLayout.swift`
- `.../TextKit/AssistantMarkdownCell.swift`
- `.../TextKit/AssistantMarkdownBlockViews.swift`
- `.../TextKit/TextKitM3AutoRun.swift`
- `.../TimelineCollection/TimelineChatContentAdapter.swift`
- `.../TimelineCollection/TimelineCollectionController.swift`
- `.../TimelineCollection/TimelineListLayout.swift`
- `.../TimelineCollection/TimelineCollectionContentProviding.swift`
- `ios/Agents Anywhere/Agents Anywhere/Models/Chat/TimelineCollection/TimelineItemIdentity.swift`
- `.../TimelineCollection/TimelineListLayoutSupport.swift`

## 3. 当前要做的第一件事

看 CI run `39392270705`（commit `b7b52028`）的 M3 gate：

- 如果失败在编译：按 `sim-build.log` 的 `error:` 修；注意 `.segment` 的 switch 是否还有遗漏。
- 如果 M3 gate 失败：下载 artifact 的 `textkit-m3.json`，重点看
  `segmentItems`、`segmentHeights`、`segmentDelta`、`footerDelta`、`cellContent`、`failures`。
- 如果只有 `Assert gate results`（C3）失败：这是既有 flake，M3 独立绿即可；可 rerun failed jobs。
- 如果全绿：把结果写进 `docs/perf-6b-c5-m3.3-task-sheet.md` 的验证状态，更新记忆，然后进 M3.4（表格单 surface）。

CI 操作：

```bash
# 从 /home/ubuntu/aa-ring-work 的 origin 取 token，不要打印
TOKEN=$(git -C /home/ubuntu/aa-ring-work remote get-url origin | sed -E 's#.*x-access-token:([^@]+)@.*#\1#')
# 派发（工作流在 feature 分支不会自动触发，必须 workflow_dispatch）
curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" -H "User-Agent: cc" \
  "https://api.github.com/repos/chenyynx/Agents-Anywhere/actions/workflows/ios-build.yml/dispatches" \
  -d '{"ref":"feat/textkit2-assistant-body","inputs":{"timeline_autorun":"true"}}'
# 观察：/home/ubuntu/aa-test/ci-watch-aa-m3-step1.py（改 RUN_ID 后 run_in_background）
# artifact 下载到 ~/aa-test 后解压，看 textkit-m3.json / timeline-autorun.json
```

## 4. 已知 flake（与本改动无关）

- `ModelSwitchRecoveryTests.stopStaysReachableWhenADeadProjectionSaysItCannotInterrupt`
- C3 gate：`no cell for reasoning` / `longGroup cell 200 clips content 1471`
- 处理：rerun failed jobs；M3 gate 的结果独立看。

## 5. Hark 报告要点（决定后续方向）

- 官方 Code 页 `MarkdownTextCellContent.Body = prose(blocks) | code | table`：**一个块/一段连续 prose 一个 cell**；prose 可以包含多个 block，`MarkdownTextCellRow` 逐 part `sizeThatFits` 后 `heightDidChange` 上报。
- 官方表格是**单文本 surface + 自定义 layout**：一个 `MarkdownTableLayout`、每格一段、`tailIndent=列宽`、tile 按行列绘制；没有 UIView 单元格。`padH=12`、`padV=8`，行高=最高 cell+16，表宽=Σ(列宽+24)，超宽横向滚动 + edge fade，无竖线。
- 官方代码 cell 路径是 `ClaudeComponents.FramedCodeView`（header/divider/scroll/CodeTextView）；`MarkdownCodeTextSurface` 是 SwiftUI 路径。
- 官方流式：正文只失效“上一段起点到文末”；代码前缀相同只替换尾部；表格 tile 只重画 y0 以下。
- 未解出：`FramedCodeView` 内部常量、`TableOverflowPolicy` 完整分配、tokenizer/复制格式、图片异步尺寸、流式时序。

## 6. 待决定

- 视觉尺寸：官方 `padV=8` vs 我们 AA 产品 `10`；官方列宽 policy vs 我们的 max-content+260 封顶。M3.3 先保持 AA 现尺寸，官方像素对齐留到后续专项。
- 附件（图片/Git/math）仍建议 M4；M3.3 不做。
- 出包：未出；用户已明确先不出包。

## 7. 下一步顺序

1. 让 M3.3 gate 绿（编译/段高/footer/总高不变量）。
2. 记录验证状态 + 更新记忆。
3. M3.4：表格单 surface（按 Hark 公式；先决定是否改 padV/列宽 policy）。
4. M4：图片、选择/链接、DT/RTL、流式（Hark Q5–Q8 继续补）。
5. 真机验收、合并/出包另行确认。
