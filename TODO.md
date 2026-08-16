# ClipFlow TODO

设计细节见 [README.md](README.md)。本文件只管**做什么、什么顺序、做到什么程度算完**。

分期原则：**先消灭风险，再做流水线，最后做体验。** 每一期都有可验证的完成标准，达不到就不进入下一期。

---

## V0 — 风险验证（第一周）

整个项目押在 libmpv 上，而集成方式尚未验证。这一期**只做一件事**，代码写完可以全部丢掉。

- [ ] `brew install mpv ffmpeg`，确认 `libmpv.dylib` 与 `mpv/client.h` 路径
- [ ] Xcode 工程搭起来，写 module map 链接 libmpv
- [ ] 构建配置用 `brew --prefix` 探测前缀，不写死 `/opt/homebrew`
- [ ] 关闭 App Sandbox
- [ ] 用 `--wid` 把 mpv 渲染到 `NSView`，`NSViewRepresentable` 包一层塞进 SwiftUI 窗口
- [ ] **放出一个 MKV 的画面**
- [ ] 验证播放 / 暂停 / seek 三个基本操作
- [ ] 验证 SwiftUI 浮层画在 mpv 图层之上是否有 z-order / 闪烁问题

**完成标准：** SwiftUI 窗口里能播 MKV，能暂停，能拖动 seek，浮层行为已知。

> 这一期若卡住超过一周，说明 `--wid` 路线不通，需要提前评估 render API + `CAMetalLayer` 方案，而不是硬撑。

---

## V1 — 可用（核心）

### 1. 扫描与索引

- [ ] `MediaScanner`：打开文件夹 / 拖入文件夹
- [ ] 过滤 `.DS_Store`、隐藏文件、macOS 包（`.fcpbundle` / `.app`）、符号链接环
- [ ] 排序使用 `localizedStandardCompare`（`10.mp4` 不能排在 `9.mp4` 前面）
- [ ] `MediaProbe`：时长 / 分辨率探测，**带超时**（NAS 老素材会挂）
- [ ] `MediaIndex` actor：缓存键 = 路径 + 大小 + mtime
- [ ] `IndexStore`：Codable + 原子写，单文件
- [ ] **失败状态落库**，同一 (路径, 大小, mtime) 不重试
- [ ] 列表先用文件名立刻渲染，元数据异步填充

### 2. 精灵图流水线

- [ ] `SpriteGenerator`：AVFoundation 主路径，24 帧 / 160px / 6×4
- [ ] 四个关键参数一个不漏：`maximumSize`、`requestedTimeToleranceBefore/After = .positiveInfinity`、`appliesPreferredTrackTransform`
- [ ] 用 `images(for:)` 一次提交 24 个时间点，不要循环单帧请求
- [ ] `FFmpegSpriteGenerator`：ffmpeg 回退路径，一个视频一个进程
- [ ] **`-skip_frame nokey`**（只解关键帧，Jellyfin 实测约 110 倍加速）
- [ ] **索引中存下 24 帧各自的实际时间戳**（两条路径的帧间隔都不均匀，hover 映射要靠它）
- [ ] 两条路径产出格式对齐，下游共用
- [ ] `ThumbnailStore`：`~/Library/Caches/ClipFlow/sprites/<hash>.jpg`

### 3. 封面帧选取（约 40 行，别再加码）

- [ ] 候选范围取 [35%, 80%]（24 帧中的第 9–19 帧）
- [ ] 剔除近乎纯色的帧：平均亮度 < 16 或 > 240，或亮度标准差 < 12
- [ ] 取第一个存活的帧
- [ ] 全灭则放宽到 [20%, 95%] 重试；再全灭取中间帧并在索引中标记，不重复计算
- [ ] 时长 < 4s 跳过时间偏置，直接对全部 24 帧做纯色剔除
- [ ] **`C` 键手动覆盖封面**（精确 seek 抽帧 → 写索引 → 只重建这一张）
- [ ] 起始百分比做成偏好设置，默认 35%

> 逃生口（`C` 键 + 可调百分比）比启发式本身更重要。ffmpegthumbnailer 选"最典型帧"、ffmpeg 选"最独特帧"，两个成熟实现方向相反——说明这个问题没有最优解，不值得继续投入。真要不够用，先调那个百分比。

### 4. 调度

- [ ] `ThumbnailQueue`：可见优先级调度
- [ ] `onAppear` 入队（可见行 + 前后各一屏），`onDisappear` 降级 / 取消
- [ ] 并发上限 `min(4, activeProcessorCount / 2)`
- [ ] 空闲时低优先级补齐剩余项

### 5. 播放

- [ ] `MPVRenderBackend` protocol + `MPVWidBackend` 实现（渲染后端必须可替换）
- [ ] `PlaybackController`（`@Observable`），单实例 + `loadfile`
- [ ] 启动参数：`--idle=yes --keep-open=yes --hr-seek=yes --cache=yes`
- [ ] 监听 `end-file` 事件驱动自动播放下一个（不用 mpv 的 playlist）
- [ ] 播放 / 暂停 / seek / 音量 / 静音 / 倍速
- [ ] 循环模式：单个循环 / 列表循环 / 关闭
- [ ] 全屏 / 退出全屏

### 6. 界面与输入

- [ ] `MainView` 左右布局，左侧宽度可拖动
- [ ] 素材浏览区显示 / 隐藏，左侧 / 右侧切换
- [ ] **视频画面不得被播放列表覆盖**
- [ ] `MediaListView` 列表模式，单击即播
- [ ] **悬停扫过**：鼠标横向划过缩略图，按位置在精灵图 24 帧间切换（零解码）
- [ ] `TransportBar` 播放控制条
- [ ] `KeyBindings` 全套快捷键（见 README 第 8 节）
- [ ] 选中即播模型：`Q`/`E` 移动选中项即切换视频

### V1 完成标准

在一个 **500 个文件的真实素材目录**上实测：

- [ ] 打开目录 → 首屏出图 **< 1s**
- [ ] 精灵图全量生成 **< 30s**
- [ ] 切换视频 **< 150ms**
- [ ] 缩略图墙**没有成片的黑帧和 logo 卡**；少数选不准的，悬停扫过一秒内能看清内容
- [ ] 能用键盘从头到尾扫完整个目录，手不离开左手区

> 切换视频若稳定超过 150ms，才考虑 V2 的预载方案。不要提前优化。

---

## V1.1 — 高效浏览

- [ ] `MediaGridView` 网格模式，一屏 40–60 个缩略图（复用 V1 已做好的悬停扫过）
- [ ] `SeekPreview`：进度条 hover 缩略图预览，读精灵图（零解码，不需要第二个解码实例）
- [ ] 列表 / 网格模式切换
- [ ] **拖出**：从列表或网格拖文件到 Premiere / FCP / Finder（`NSItemProvider` 包 file URL，成本极低）

### V1.1 完成标准

- [ ] 网格模式下不点击任何一个视频，仅靠悬停扫过就能判断一批素材的内容
- [ ] 进度条 hover 预览响应 < 16ms

---

## V2 — 打磨

- [ ] 递归扫描子目录（**深度上限**，防符号链接成环）
- [ ] FSEvents 监听，目录内新增 / 删除文件自动更新
- [ ] 简单排序 / 搜索（按名称、时长、分辨率、日期）
- [ ] 记住上次打开的目录与窗口布局
- [ ] **仅当 V1 实测切换 > 150ms**：A/B 双实例预载
- [ ] 用于分发的构建脚本（编译 libmpv、`install_name_tool` 改 `@rpath`、重签名）—— 仅当真的有人反馈装不上

---

## 暂缓

以下功能已经讨论过，但**先不做**，等工作流想清楚了再回来。

- **标记 / 打分**（✓ ✗ 或 1–5 星）
- **筛选**（只看已标记 / 未看过 / 按时长·分辨率·日期筛）
- **导出动作**（在 Finder 中显示 / 拷贝到文件夹 / 移到废纸篓）
- **审片模式**（每个片子只播前 N 秒然后自动跳下一个）

> 这几项技术上都不难，难的是想清楚工作流。索引层已经预留了写入自定义字段的位置，加的时候不需要改结构。

---

## 已决定，不再讨论

避免反复纠结，把已经拍板的决定记在这里：

| 议题 | 结论 |
|---|---|
| 最低系统版本 | macOS 15 (Sequoia) |
| App Sandbox | 不启用 |
| libmpv 来源 | V1 动态链接 Homebrew 的 `libmpv`，README 写明前置依赖 |
| GPL / 分发处理 | 推迟，不阻塞 V1 |
| 渲染方式 | V1 用 `--wid`，但藏在 protocol 后面保证可替换 |
| 缩略图生成 | AVFoundation 主路径 + ffmpeg 回退，**不用 libmpv** |
| 精灵图抽帧 | 只解关键帧（`-skip_frame nokey` / `tolerance = .infinity`）；24 帧的实际时间戳存进索引 |
| 封面帧选取 | 时间窗口 [35%, 80%] + 纯色剔除，约 40 行。dHash、跨文件片头聚类、Sobel、色彩丰富度**全部作废** |
| 封面选不准怎么办 | `C` 键手动覆盖 + 起始百分比可调。**不再加码启发式** |
| 悬停扫过 | 从 V1.1 提前到 V1。它是封面选不准时的兜底，比把选帧做复杂更有效 |
| 进度条 hover 预览 | 读预生成精灵图，**不需要第二个解码实例**，因此留在 V1.1 而非砍掉 |
| 切换速度方案 | V1 单实例 `loadfile`，实测超标才上预载 |
| `Cmd+W` / `Cmd+S` | 不使用，改为 `Q` / `E` |
| 索引存储 | Codable + 原子写单文件，不上 Core Data |
