# Composer 官方 Chat 视觉对齐 · 任务单

> 日期：2026-11-03 CST　级别：**L**（跨组件、涉及权限/相机/新 sheet、影响 Chat 与 Code 两 profile）
> 依据：`/home/ubuntu/aa-test/claude-ios-re/EVIDENCE/round30-composer-visuals/SUMMARY.md`（官方 1.261023.20 反编译 + 截图实测）
> 版本说明：App Store 最新为 1.261030.19，手头解密包为 1.261023.20；截图来自更新的 App。数值以 1023 证据为准，截图实测作交叉校验。

## 0. 目标

功能不变，把 AA 输入区（composer）与两个弹层（添加到会话 / 选择模型）的视觉对齐官方 Chat 页：
附件卡、底行控件、模型 pill、「添加到会话」sheet、「选择模型」sheet。消息渲染与消息附件 tiles **不动**。

## 1. 已定产品决策

1. 文件 chip：只显示 **类型 badge + 文件名**，不显示文件大小。
2. 连接器行：**占位、不可点**（AA 无 MCP connectors）。
3. 相机：**做入口**（系统相机拍照 → 附件）。
4. 模型 pill：**常驻底行**，点击打开选择模型 sheet。
5. 最近照片条：**复刻**（PhotoKit 最近照片）。
6. 权限：官方视觉 + **AA 全部权限档位**，不丢功能。
7. 添加到项目：**整行隐藏**（不做该功能）。
8. 接管会话：放「添加到会话」**底部**。
9. Chat/Code 共用同一份 composer（现状已共用，见 §2）。

## 2. 现状盘点（改前必读）

| 组件 | 位置 | 现状 |
|---|---|---|
| Composer 度量 | `ios/Agents Anywhere/Agents Anywhere/Models/Chat/ComposerMetricsProfile.swift` | 已有 `chat` / `code` 两套。**Code 已按官方**：18/52、9/95、36 chrome + 44 hit、r24/26、spring 0.22/0.77；**Chat 仍是旧 AA 设计**：32/12、48+ 高、bare 加号、smooth 0.24 |
| Composer 本体 | `.../Views/Chat/Composer/ChatComposer.swift` | GlassEffectContainer + 自定义 Layout；底行 = 加号/输入/发送（可选指挥）；`attachmentTray` = HStack spacing 8 |
| 附件卡 | `.../Views/Chat/ChatMessageAttachments.swift`（`ChatComposerAttachment`，:85） | 图片 72×72 r12；文件 72 高 r12 + 名称/大小；X = `xmark.circle.fill` 19pt，offset(9,-9) |
| 选项 sheet | `.../Views/Chat/Composer/ComposerOptionsSheet.swift` | `NavigationStack` + 照片/文件 tile + 模型/权限二级页 + 接管开关 |
| 项目选择 | `.../Views/Chat/ProjectSelectionSheet.swift` | 存在，但本任务**不接**（项目行隐藏） |
| 会话页 | `.../Views/Chat/SessionChatView.swift` | `composerProfile` 按 Chat/Code 选择度量；两页共用 `ChatComposerDock` |
| Info.plist | `ios/Agents Anywhere/Info.plist` | **无** `NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription`（需新增） |

## 3. 目标视觉规格（来自 round30，E 级）

### 3.1 Composer 度量（Chat profile → 官方）

沿用 `ComposerMetricsProfile.code` 的官方数值作为 Chat 新基线（若与 round30 证据冲突以表内为准）：

| 项 | 值 |
|---|---|
| collapsed 横向 inset | 18 |
| collapsed 高度 | 52 |
| expanded 横向 inset | 9 |
| expanded 高度 | 95（`textInset 11 + editor + 10 + touch 44 + bottom 8`） |
| 控件 chrome | 36×36（regular），hit slot 44 |
| 发送钮直径 | 36 |
| 圆角 | collapsed 26 / expanded 24 |
| 动画 | spring(response 0.22, dampingFraction 0.77) |

*注：`ComposerMetricsProfile` 是纯数据，Unit test 可直接钉住。*

### 3.2 输入框附件条（截图③）

| 项 | 值 |
|---|---|
| 容器 | 横向 ScrollView、单行、无背景 |
| item 间距 | **4** |
| tile | 高度上限 **96**（实际由内容定），square 缩略图 96×96 |
| 圆角 | **16**（compact 10） |
| 底色 | `bg000` = light #FFFFFF / dark #20201F |
| 描边 | `border20` @30% |
| 文件内容 | 类型 badge（扩展名大写，如 CONF）+ 文件名；**无大小**；中间截断 |
| 照片 | AsyncImage 填充 + 加载态 |
| X | overlay topTrailing：**24×24 圆**、`padding 8`、`black@15% shadow radius 2`、前景 bg000 / 背景深色 |

### 3.3 底行控件

| 项 | 值 |
|---|---|
| 行 spacing | **8** |
| 控件 frame | **36×36**，padding v4/h4 |
| 模型 pill | Capsule，高 36；水平 padding `4 + 12×share`（4…16） |
| 按下 | opacity **0.7** |
| “+” 底 | light **#F0EFEC** / dark #FFFFFF@8%；图标 text100 #131313 |
| 麦克风 | 36；图标 text300 #383835 / #C3C2B7 |
| 发送 | 36；底 **#C6613F**；箭头白；长按 10s + 触感 |

### 3.4 「添加到会话」sheet

- 结构：`List` 多卡片；相机 tile + 最近照片条 + 添加文件 + 权限 + 连接器（占位）+ 接管会话（底部）。
- 文案/图标（官方 asset 名，AA 用 SF Symbols 映射）：
  - 相机 `anthropicon.camera`；照片 `anthropicon.image`；添加文件 `anthropicon.files`
  - 权限：自动 `anthropicon.fastforward` / 手动 `anthropicon.hand`（AA 其余档位用现有图标）
- 行：右侧值 + chevron；行高/卡片圆角/分隔线按截图 [I]：行 ≈51pt、卡片内缩 25pt、卡间距 15pt、分隔线 1pt。
- 关闭 X：白色圆底 + 细黑 X（截图 ≈57pt）。
- detents：{.medium, .large}。

### 3.5 「选择模型」sheet

- 行 = `IconLabelRow`：HStack spacing **8**；标题 + 副标题 + 右侧勾。
- badge：padding h8/v4、默认 Capsule（显式圆角 16）、前景 `accentMain100` + 同色 10% 背景。
- 选中勾：SF Symbol `checkmark` + semibold，颜色 `accentSecondary000`。
- 思考强度：独立行 + 二级选择页；动画 `.easeOut(0.18)`。
- 说明文字 + 链接；行 ≈64.5pt、卡片内缩 15pt（截图 [I]）。

### 3.6 颜色 token

| token | light | dark |
|---|---|---|
| text000/text100 | #131313 | #F9F9F7 |
| text300 | #383835 | #C3C2B7 |
| 发送底 | #C6613F | #C6613F |
| “+” 底 | #F0EFEC | 白@8% |
| bg000 | #FFFFFF | #20201F |

## 4. 实现方案（分阶段，逐阶段可编译）

**P1 度量与底行**
1. `ComposerMetricsProfile.chat` 改用官方数值（与 `code` 对齐；若两页视觉应完全一致，直接复用同一 profile）。
2. `ChatComposer` 底行：加号改 circle（36）、发送 36、间距 8、按下 0.7。
3. 新增模型 pill（Capsule，标题 + 思考强度；点击 → 选择模型 sheet）。

**P2 附件条**
1. `ChatComposerAttachment` 重做：tile ≈80–96（上限 96）、r16、badge+文件名、无大小。
2. X 改 24pt 黑圆 + 白 X + 8pt 内缩 + 阴影。
3. tray spacing 8→4、padding 对齐截图（8/8）。

**P3 添加到会话 sheet**
1. 用新 `AddToChatSheet` 替换 `ComposerOptionsSheet` 的入口（保留旧文件直到 Code 页回归通过，或直接重构）。
2. 相机 tile（入口）+ 最近照片条 + 添加文件 + 权限 + 连接器占位 + 接管开关（底部）。
3. 移除项目行（隐藏）。
4. 保留 loading/error/重试 状态。

**P4 选择模型 sheet**
1. 新 `ModelPickerSheet`：模型行（名称/badge/副标题/勾）+ 说明文字 + 思考强度行。
2. 复用现有 catalog（模型/推理档位），badge/副标题缺失时留空。

**P5 权限与采集**
1. Info.plist 增加 `NSCameraUsageDescription`、`NSPhotoLibraryUsageDescription`（及本地化）。
2. 相机：`UIImagePickerController` 包装 → 附件。
3. 最近照片：PhotoKit（`PHPhotoLibrary` 授权；limited/denied 要有空态与设置入口）。

**P6 测试与验收**
- Unit：metrics profile、附件标题/截断、badge 文案（U+202F）、权限档位映射、最近照片数量上限。
- CI：看 **build job**（iOS CI test job 不编译 app target，见记忆 `aa-ios-ci-app-build-gap`）。
- 真机：三张截图逐项对照；深色模式；大字号；相册 denied/limited；相机不可用（模拟器）。

## 5. 数据/契约影响

- 无服务端契约变更。
- 新增客户端权限：相机、相册读取。
- 新增本地化文案：相机、最近照片、权限提示、空态。
- `ComposerMetricsProfile` 是纯数据，改值会影响 Chat 页所有使用处；Code 页如共用需同步回归。

## 6. UI 状态清单

| 区域 | 状态 |
|---|---|
| 附件条 | 空 / 单张 / 多张横向滚动 / 图片加载中 / 失败 |
| 相机 | 可用 / 不可用（模拟器）/ 权限拒绝 |
| 最近照片 | 加载中 / 有数据 / 空 / 权限 denied / limited |
| 添加到会话 | loading / 正常 / 加载失败 + 重试 / 附件超限 |
| 选择模型 | loading / 正常 / 空目录 / 加载失败 |
| 全局 | 深色模式 / 大字号 / 离线（沿用现有网络状态） |

## 7. 风险与注意

1. **版本差异**：1023 → 1030 可能改过尺寸；真机对照时若不符，以真机为准并回填 round30。
2. **Code profile**：Chat 改度量后，Code 页应保持既有官方数值；若两页统一 profile，要跑 Code 页真机回归。
3. **相册权限**：limited 模式下列表可能为空，需要引导「管理照片」。
4. **动态字体**：官方字号走 Typography 运行时；AA 用系统字体，需保证放大后不溢出（尤其 badge 与 pill）。
5. **键盘/底部手势**：`ComposerKeyboardGesture` 与 dock 行为不能回归。
6. **不要动**：消息附件 tiles（`CodeAttachmentTiles` 等）、消息渲染。

## 8. 验收标准

- 三张截图对应界面：尺寸/间距/圆角/颜色与 round30 表一致（允许 ≤1pt/色差）。
- 功能无丢失：照片、文件、相机、权限全档位、模型/思考强度、接管开关、连接器占位。
- 深色模式、动态字体、权限 denied/limited 路径可用。
- 现有 composer 相关测试全绿；CI build job 通过。

## 9. 不做

- 消息里的附件 tiles / 消息气泡样式。
- 「添加到项目」行为（整行隐藏）。
- 连接器的真实功能（仅占位）。
- Code 页消息渲染。
