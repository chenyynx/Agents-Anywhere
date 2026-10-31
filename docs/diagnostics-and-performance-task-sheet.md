# AA 诊断台与性能线任务单（2026-10-31）

> 目的：把「找 bug」和「性能优化」做成一条可持续的量测闭环。诊断台只在 probe 构建（`AA_TIMELINE_PROBE`）生效，正式包零影响。
> 关联：`docs/handoff-code-timeline-20261031.md`、`docs/timeline-open-and-history-root-fixes-task-sheet.md`。
> 状态：设计稿，待 pp 拍板后开工。

## 0. 现状与缺口

**已有**
- 布局层报告已经很细：VISIBLE / HEIGHT CHANGES / APPLIES / HISTORY / ISSUES / TOUCHES / SLOW FRAME STACK（`TimelineProbe.swift:875`）。
- 入口是两个左边缘悬浮胶囊：「探针」+「锚点日志」（`TimelineChatTimelineView.swift:249-262`）。
- 帧率只在拖动/减速时统计（`TimelineProbe.swift:258-285`），有慢帧栈。
- 抽屉已有过渡态环境值 `sidebarDrawerIsTransitioning`（`SidebarDrawer.swift:58`），布局诊断可观测过渡期尺寸变化（`ChatLayoutDiagnostics.swift:24-40`）。

**缺口**
1. 入口难找、胶囊挡内容。
2. 报告缺上下文：会话 id、turn id、窗口状态、pending、socket/实时事件、runtime 状态。
3. 没有「打点」和同拍截图：报告里「刚刚」只能猜 t 段。
4. 「清空」把清空前事件压成 `t=0.00`，误导（b782 15:15 报告开头一堆 0.00）。
5. 没有性能仪表：帧时间线、场景记录、测量/apply 分布。
6. 导出只有剪贴板（复制→粘贴→长消息转文件）。

## 1. 诊断台 v2（Developer Diagnostics）

### 1.1 入口与可见性
- 主入口：会话页右上角「···」→「诊断浮窗」，开一个可拖动的半透明 HUD（位置持久化）。
- 次入口：设置 → 开发者 → 诊断（完整面板）。
- 全部包在 `#if AA_TIMELINE_PROBE`，正式包不编译（同现状）；CI 用 `probe` 输入出包（`.github/workflows/ios-build.yml:56`）。

### 1.2 视觉与结构（Claude 设计语言，不复用 AA 视觉）
- 配色：暖纸底 #FAF9F5 / 深色 #1F1E1D，表面 #FFFFFF / #262624，象牙 #F0EEE6，墨色 #1F1E1D / #F5F4EF，次级 #6F6C64 / #A9A69E，发丝线 #E8E4D8 / #3A3936，**唯一强调色赤陶 #D97757**；成功/警告/危险只用低饱和语义色。
- 字体：标题用衬线（New York），正文用系统无衬线，数字用等宽数字；8pt 网格；圆角 14–26；细边框 + 轻阴影；不用 AA 的绿色强调与材质胶囊。
- **HUD（实时盯）**：可拖动半透明卡片，常驻聊天上方；显示 fps、卡顿次数、整页重排峰值、严重度圆点；右侧一键「打点 + 截图」（图标变勾反馈）。点卡片展开完整面板。
- **完整面板**：单页滚动，不再用 tab：
  1. 实时：四块指标（流畅度/卡顿/整页重排/行高测量）+ 帧间隔面积图 + pending/窗口状态点。
  2. 发现：FINDINGS 按严重度排序，中文规则名 + 一句话证据。
  3. 现场：最近 3 次打点缩略图与时间。
  4. 原始日志：时间线报告 / 锚点日志切换，默认折叠。
- 底部操作：**打点 + 截图**（主按钮）、导出（txt+png）、更多（复制报告 / 清空采样 / 隐藏浮窗）。
- 信号色语义：红=可见断点，黄=性能警告，灰=信息；不用第三方图表库（sparkline 用 Canvas 自绘）。

### 1.3 数据补全（P0，先做）
- 会话：`session.id`、title、connectorId、runtime 名与状态。
- 窗口：latest/history、items 总数、`hasOlderItems`/`hasNewerItems`、`localOlderAvailable`、`isLoadingHistory`、`windowAnchor` 行 id。
- pending：id、delivery 状态、年龄、clientMessageId、队列条数。
- 连接：socket 连接状态、重连次数、最近 N 条实时事件（type/seq/到达时间）。
- turn：turn id、`suppressLatest`、活跃项、footer host 行 id。
- 时间：所有事件同时给绝对时间（CST）和相对时间；「清空」只重置计数并留一行 `CLEARED <绝对时间>`，不再把旧事件压成 `t=0.00`。
- 报告头：一段 `KEY=VALUE` 机器可读块，下面保持现有 VISIBLE/HEIGHT/APPLIES/HISTORY/ISSUES 格式。

### 1.4 打点 + 截图
- 点「打点」：往时间轴插一行 `MARK <绝对时间>`，并对当前时间线页截图（`drawHierarchy(afterScreenUpdates:)`）。
- 截图与报告一起导出；面板里显示最近 3 张缩略图。
- 目的：解决「pp 说刚刚，我不知道是哪个 t」和「视觉类 bug 日志看不出来」。

### 1.5 导出
- 首选：`ShareLink` 导出 `diagnostics-<build>-<yyyyMMdd-HHmmss>.txt` + `mark-*.png`。
- 进阶（后续）：一键把报告 + 截图作为附件发到当前会话（复用现有附件上传），省掉复制粘贴。

### 1.6 性能仪表
- 帧采样改为 probe 构建常开（不再只在拖动时），240 帧环，按上下文打标签：idle / browsing / streaming / drawer。
- hitch 阈值 33ms（超过记一次，含主线程栈）；同时保留 20ms 慢帧统计。
- 场景记录：开始/结束，输出 p50/p95/p99/max、hitch 数、apply/measure 分布、Mark 时间点。
- 关键路径加 `os_signpost`：apply、layout prepare、height measure、markdown 解析、抽屉 motion。
- 注意：探针自身有开销，性能结论需用 Release/probe 双跑对照。

### 1.7 诊断台验收
- 「···」两步内打开；面板打开过程无卡顿。
- 打点后 5 秒内可导出；导出包含 build、session id、MARK、至少一张截图。
- 报告同时含上下文头与现有布局段。

## 2. 性能线 A：聊天上下看历史掉帧

### 2.1 已有证据（b782 15:15 报告，`app 2.1.1(782)`）
- `frameSamples=2719`、`slowFrames=227`、`frameRateHitches=50`、`maxFrameMs=117`。
- `applyCount=1765`、`applyMsMax=994`、`applyMsTotal=23189`。
- `measureCount=1766`、`measureMsMax=61`、`measureMsTotal=2348`。
- `heightChanges=339`、`heightChangesOffscreen=45`、`offsetJumps=516`。
- 结论：卡顿是真实存在的；最可疑的是 apply 尖峰与滚动期间的高度测量/修正。

### 2.2 假设（待数据证实，不按假设直接改）
- **H1 离屏测量**：滚动时仍在测量视口外行，`measureMsMax=61` 单次就能掉一帧。修法：测量范围限定视口 + 预取预算，滚动中取消低优先级测量。
- **H2 apply 全量 diff**：某次 apply 994ms，疑似窗口替换/大快照的 diffable 全量计算。修法：增量 apply、无动画 apply、按块插入。
- **H3 大行渲染**：893pt 级别的 markdown 行配置/解析成本高。修法：解析缓存（按 revision+width）、离屏不配置、TextKit2 复用。
- **H4 高度修正驱动锚点补偿**：滚动中每次高度修正都写 offset，形成抖动。修法：单一 offset 写入者、同帧合并、拖动期间冻结离屏修正。
- **H5 流式更新频率**：回复流式期间每个 delta 触发整行重测/重排。修法：按显示刷新节流，帧边界统一提交。

### 2.3 场景与验收
- 场景 A1：300+ 行历史，连续上下滑 15s + 甩动。
- 场景 A2：顶部加载历史页 + 同时流式回复。
- 指标（同一设备、Release/probe 双跑）：
  - hitch（>33ms）率 < 0.5%；单次 max gap ≤ 50ms。
  - apply p99 < 50ms，max < 100ms。
  - 无视觉跳页/空白/错位。
- 回归：R6–R19 真机场景全部重跑一遍。

## 3. 性能线 B：侧滑抽屉掉帧

### 3.1 现状（代码已核对）
- 自定义 SwiftUI 抽屉：`SidebarDrawer.swift`。主卡片用 `GeometryEffect` + `ignoredByLayout` 只做位移（`:810-814`）；阴影恒定、只改 layer opacity（`:787-795`）；侧栏只做 `scaleEffect`（`:759-773`）。
- 已有过渡态环境值 `sidebarDrawerIsTransitioning`（`:58`），布局诊断只在过渡期记录尺寸变化（`ChatLayoutDiagnostics.swift:24-40`）。
- 侧栏是 ScrollView + LazyVStack（`ChatSidebarView.swift:38`）。

### 3.2 假设
- **D1 过渡期主内容仍在干活**：时间线 display link、流式更新、测量/apply 与抽屉动画抢主线程。
- **D2 侧栏首帧构建**：打开动画第一帧才 materialize LazyVStack 行、头像、渐变。
- **D3 尺寸变化**：过渡期某层发生尺寸变化触发 collection view 重排/换行（布局诊断就是为此加的）。
- **D4 材质/描边/圆角每帧重绘**：虽然阴影已分层，但 overlay/材质可能仍逐帧合成。
- **D5 数据源更新**：抽屉拖动期间 sessions/connectors 发布导致侧栏 body 重建。

### 3.3 优化方向（按测量结果取用）
- 过渡开始前预构建侧栏（预渲染或提前 materialize）。
- 过渡期间暂停时间线采样/测量/apply（用 `sidebarDrawerIsTransitioning` 判断），只保留必要绘制。
- 保证主内容零尺寸变化，只用 transform；若仍有尺寸变化，定位到具体层。
- 侧栏行内容缓存（头像、标题、时间），避免每帧重复格式化。
- 必要时对侧栏做一次性快照过渡（官方同款做法），动画结束换真视图。

### 3.4 场景与验收
- 场景 B1：有流式回复时开/关抽屉 20 次；场景 B2：慢速拖动开合 10 次。
- 指标：过渡期间无 >33ms 帧；20 次开合 hitch ≤ 2；无闪白/闪烁；手势手感与「官方抽屉手势参数」保持一致。

## 4. 分阶段交付

| 阶段 | 内容 | 产物 |
| --- | --- | --- |
| P1 | 诊断台骨架：入口（··· + 设置）、四个 tab 外壳、面板视觉 | probe 包 |
| P2 | 上下文头 + 打点/截图 + 导出 + 事件/性能 tab 数据 | probe 包 |
| P3 | 性能基线：A1/A2/B1/B2 四场景各一份报告 | 基线数据 |
| P4 | A 线逐假设修复（一假设一提交） | 每项 probe 包 + 验收 |
| P5 | B 线逐假设修复 | 每项 probe 包 + 验收 |

每阶段结束出 probe 包（带构建号），pp 真机验收后再进下一阶段；P4/P5 的每项修复都要带单测或探针红绿证据。

## 5. 实测基线（2026-10-31，b788）

真机首次抓到两条 A 线证据（报告 `long-message-20261031-155701.txt`，app 2.1.1(788)）：

1. **apply 1139ms（红）**：`t=194.07 apply-begin` → `t=195.21 apply-end`，中间 `apply-measure n=2 ms=0`。测量 0ms，1.14s 全在 diffable apply + 单元格重配。同一条 881pt 长消息 `g:msg_a428e10f` 在 8 秒内被 re-key 7 次（revision 每次变化），高度 29→180→363→410→387→443→592→625→881，每次高度修正都 reconfigure 整段 markdown 单元格。
2. **巨型气泡（产品）**：8KB/约 100 行的粘贴报告未达到 `LongMessageAttachmentPolicy` 的 12,000 字符 / 300 行阈值，被整段渲染成 7916pt 待发气泡；发送后内容替换造成 offset +7061pt、tail 错位 210pt、cell 重叠。42KB 的报告触发了转换（`long-message-*.txt`），未复现。
3. 同一报告 `frame_hitch 5 次，最大 63ms`（滚动掉帧，A 线）。

## 6. 边界与风险
- 诊断台只在 probe 构建；正式包不受影响。
- 不为了观测改变布局行为；探针本身的开销用 Release 对照排除。
- 不折叠正文、不自动转文件（既有底线）。
- 不引入第三方依赖（图表用 SwiftUI Path 自绘）。
- 性能结论至少一条用 Instruments/真机栈复核，避免被探针自身带偏。
