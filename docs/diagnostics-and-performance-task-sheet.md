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
- 主入口：会话页右上角「···」→「诊断与日志」（`SessionChatView.swift:291-302` 现有菜单位置）。
- 次入口：设置 → 开发者 → 诊断（`AccountSettingsSheet` 新增分区）。
- 左边缘两个胶囊撤掉；如需一键抓取，加一个**默认关闭**的小浮钮（设置里开关），只做「打点」。
- 全部包在 `#if AA_TIMELINE_PROBE`，正式包不编译（同现状）；CI 用 `probe` 输入出包（`.github/workflows/ios-build.yml:56`）。

### 1.2 面板结构（视觉规范）
- 全屏 sheet + NavigationStack，标题「诊断」。深色/浅色自适应，正文 11pt 等宽。
- 顶部状态条：build（如 b787）、session id、runtime 状态、连接状态（绿/黄/红点）。
- 分段控件四个 tab：
  1. **时间线**：现有报告（格式不动），加实时 counters 摘要。
  2. **性能**：帧时间线 sparkline（最近 240 帧，按间隔着色）、p50/p95/p99/max、hitch 列表 + 栈、apply/measure 时间线、场景统计。
  3. **事件**：socket 实时事件（type/seq/时间）、pending 列表（id/状态/年龄）、turn 状态（suppressLatest/活跃项/footer host）。
  4. **锚点**：现有 C3 inset 日志。
- 底部操作条：**「打点 + 截图」**（主按钮）、清空、导出、复制。
- 视觉：卡片 + `.thinMaterial`、SF Symbols、语义色（正常灰 / 警告橙 / hitch 红 / 删除紫），不用第三方图表库。

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

## 5. 边界与风险
- 诊断台只在 probe 构建；正式包不受影响。
- 不为了观测改变布局行为；探针本身的开销用 Release 对照排除。
- 不折叠正文、不自动转文件（既有底线）。
- 不引入第三方依赖（图表用 SwiftUI Path 自绘）。
- 性能结论至少一条用 Instruments/真机栈复核，避免被探针自身带偏。
