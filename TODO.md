# ClipFlow TODO

设计细节见 [README.md](README.md)。本文件只管**做什么、什么顺序、做到什么程度算完**。

分期原则：**先消灭风险，再做流水线，最后做体验。** 每一期都有可验证的完成标准，达不到就不进入下一期。

---

## 当前进度

> 接手前请先读 [`AGENTS.md`](AGENTS.md) 与 [`README.md`](README.md)。
> 设计以 README 为准，**不要根据聊天记录推断当前设计**——README 里有几条结论是被实测推翻后改写过的。

| 阶段 | 状态 |
|---|---|
| **V0** 风险验证 | ✅ 完成。`--wid` 实测不可行，已改走 render API |
| **V1** 可用 | 🔵 进行中，第 1–6 块代码已齐；完成标准待真实目录手测 |
| └ 1. 扫描与索引 | ✅ 完成 |
| └ 2. 精灵图流水线 | ✅ 完成（ffmpeg 回退路径暂缓） |
| └ 3. 封面帧选取 | ✅ 完成（`C` 键已接；起始百分比默认 35%，尚无设置界面） |
| └ 4. 调度 | ✅ 完成（并发上限、两阶段拆分、可见优先级调度） |
| └ **5. 播放** | ✅ 完成（画面能嵌进 SwiftUI；F / Esc / 中键全屏已接） |
| └ **6. 界面与输入** | 🔵 **后半已接线**（快捷键 / 控制条 / C 键 / 循环 / 全屏）；完成标准未手测 |
| **V1.1 / V2 / 暂缓** | ⬜ 未开始 |

已跑通并可复现的部分：

```bash
brew install mpv ffmpeg xcodegen
xcodegen generate
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Debug -derivedDataPath .build/dd build
CLIPFLOW_BENCH="/path/to/videos" .build/dd/Build/Products/Debug/ClipFlow.app/Contents/MacOS/ClipFlow
```

V0 的验证代码在 [`Spike/`](Spike/)，是独立的轻量工程，**播放部分要从那里搬运**——渲染上下文的建立、更新回调、重绘都已经验证过。

### 下一步要做什么

第 6 块后半已接线：快捷键全集、播放控制条、`C` 键封面、循环 / 自动下一个、全屏。判据仍是「能用键盘从头到尾扫完一个真实目录」，见 V1 完成标准；未实测前不要勾。

起始百分比已接 `CoverPicker` 参数和 UserDefaults（默认 35%），设置界面还没有。网格模式、进度条 hover 预览仍是 V1.1。

---

## V0 — 风险验证（第一周）

整个项目押在 libmpv 上，而集成方式尚未验证。这一期**只做一件事**，代码写完可以全部丢掉。

- [x] `brew install mpv ffmpeg`，确认 `libmpv.dylib` 与 `mpv/client.h` 路径
- [x] 工程搭起来，写 module map 链接 libmpv
- [x] 构建配置探测 brew 前缀，不写死 `/opt/homebrew`
- [x] ~~用 `--wid` 把 mpv 渲染到 `NSView`~~ → **实测不可行，改走 render API**
- [x] `vo=libmpv` + `mpv_render_context` + `NSOpenGLView`，`NSViewRepresentable` 包一层塞进 SwiftUI
- [x] **放出一个 MKV 的画面**
- [x] 验证播放 / 暂停 / seek 三个基本操作
- [x] 验证 SwiftUI 浮层的 z-order / 闪烁 —— 正常
- [x] 验证窗口缩放时几何跟随 —— 正常
- [ ] 关闭 App Sandbox（spike 走 SPM 可执行文件，本就没沙盒；建正式 Xcode 工程时再落实）

**完成标准：** SwiftUI 窗口里能播 MKV，能暂停，能拖动 seek，浮层行为已知。✅

### V0 结论：`--wid` 不可行，render API 成立

代码在 [`Spike/`](Spike/)。`CLIPFLOW_SELFTEST=1 ./.build/debug/ClipFlowSpike` 跑自动验收。

**最重要的发现：`--wid` 在 macOS 上根本不受支持。** mpv 手册里 `--wid` 只写了 X11、win32、Android，没有 macOS。实测 mpv 会忽略它，自己开一个独立窗口——带自己的圆角、不受父窗口裁剪、位置对不上，画面糊到别的 app 上面。原计划的渲染方案作废。

换成 **`--vo=libmpv` + `mpv_render_context` + 自持 OpenGL 上下文**（IINA 的做法）后全部正常：

| 验证项 | 结果 |
|---|---|
| render context 建立 | 通过，`VO: [libmpv]`，mpv 0.41.0 |
| MKV 解析 | 通过，`mkv · H.264 · 1280×720 · 30fps` |
| 画面渲染在窗口内 | 通过，正确裁剪，无溢出 |
| 窗口缩放跟随 | 通过，缩到 760×520 后几何正确 |
| SwiftUI 浮层 z-order | 通过，无闪烁，且能被 `screencapture` 抓到 |
| 播放推进 | 通过 |
| 暂停冻结 | 通过，0.9s 间隔内 `time-pos` 纹丝不动 |
| 精确 seek（`hr-seek`） | 通过，seek 到 5.0s **落在第 150 帧 = 5.000s，帧级精确** |
| 从暂停恢复播放 | 通过，5.00 → 5.97 |

踩到的坑：

1. **同步 `mpv_command` 会死锁。** 主线程调命令阻塞 → mpv 核心等 VO 出帧 → 出帧要靠主线程回调 `mpv_render_context_render` → 主线程正卡在命令里。`screenshot` 必挂。**一律用 `mpv_command_async`。**
2. **别开 `MPV_RENDER_PARAM_ADVANCED_CONTROL`。** 它要求调用方接管更多渲染时序，履行不到位反而更容易和核心互等。
3. **`--vo=libmpv` 下 mpv 自己的 `screenshot` 不产出文件。** 对本项目无影响——缩略图走 AVFoundation / ffmpeg，从不经过 mpv。
4. **不需要 pkg-config。** SPM 的 `pkgConfig:` 要求装 pkg-config/pkgconf，macOS 默认没有。改成在 `Package.swift` 里用 `FileManager` 探测 `/opt/homebrew` 与 `/usr/local`。
5. **Homebrew bottle 按 macOS 版本构建。** macOS 26 上装的 `libmpv.2.dylib` 标记为 26.0，与声明的最低版本 15.0 不符时链接器会警告。源码分发不受影响，但**不能把新系统构建的二进制发给旧系统的人**。
6. **`swift run` 的 stdout 重定向时是块缓冲的**，挂起时一个字都看不到。自测入口需 `setvbuf(stdout, nil, _IONBF, 0)`。
7. **OpenGL 自 macOS 10.14 起废弃**，但 libmpv render API 在 macOS 上只有 OpenGL 和 SW 两种，SW 是 CPU 回读太慢。所以只能用 OpenGL，IINA 亦然。渲染后端要藏在 protocol 后面，为将来留退路。

---

## V1 — 可用（核心）

### 1. 扫描与索引

- [x] `MediaScanner`：目录扫描 + 扩展名白名单
- [x] 过滤隐藏文件、macOS 包（`.fcpbundle` / `.app`）、符号链接；递归深度上限 8
- [x] 排序使用 `localizedStandardCompare`（`10.mp4` 不能排在 `9.mp4` 前面）
- [x] `MediaProbe`：时长 / 显示尺寸探测，**带超时**；套旋转矩阵（竖屏素材才不会横过来）
- [x] `MediaIndex` actor：缓存键 = 路径 + 大小 + mtime（取整到秒）
- [x] Codable + 原子写，单文件，带版本号；攒 50 条落一次盘
- [x] **失败状态落库**，同一 (路径, 大小, mtime) 不重试
- [x] 打开文件夹 / 拖入文件夹的界面入口
- [x] 列表先用文件名立刻渲染，元数据异步填充

### 2. 精灵图流水线

- [x] `SpriteGenerator`：AVFoundation 主路径，24 帧 / 长边 144px / 6×4
- [x] `maximumSize` + `appliesPreferredTrackTransform`
- [x] ~~`requestedTimeTolerance = .positiveInfinity`~~ → **实测有害，改为限定在取样间隔的一半以内**
- [x] 用 `images(for:)` 一次提交 24 个时间点
- [x] **索引中存下 24 帧各自的实际时间戳**
- [x] `ThumbnailStore`：封面与精灵图分开存，图放缓存目录、索引放应用支持目录
- [ ] `FFmpegSpriteGenerator`：ffmpeg 回退路径（这批素材 100% 走主路径，暂缓）
- [ ] ~~`-skip_frame nokey`~~ → **同样有害**，只在关键帧密集的素材上才成立

### 3. 封面帧选取

- [x] 按偏好顺序试候选位置 [35%, 57.5%, 80%, 20%, 95%]，第一个不是近乎纯色的就用
- [x] 剔除近乎纯色的帧：平均亮度 < 16 或 > 240，或亮度标准差 < 12
- [x] 全灭则退回第一个能解出来的帧，并在索引中标记，不重复计算
- [x] 时长 < 4s 换一组候选位置，不做时间偏置
- [x] 懒抓：**多数视频只解一帧**，这是封面阶段能压到 11.9s/500 个的关键
- [x] **`C` 键手动覆盖封面**（当前播放时间 + AVFoundation 抽一帧，只重建这一张）
- [ ] 起始百分比做成偏好设置，默认 35%（流水线已接参数与 UserDefaults 默认值，尚无设置界面）

> 逃生口（`C` 键 + 可调百分比）比启发式本身更重要。实测这批 1096 个素材兜底率 0%，但那是因为它们没有片头 logo——真正要解决的场景没能在这批数据上得到验证。

### 4. 调度

- [x] 并发上限 `min(4, activeProcessorCount / 2)`
- [x] **两阶段拆分**：封面阶段先跑完，精灵图后台补
- [x] `ThumbnailQueue`：可见优先级调度
- [x] `onAppear` 入队（可见行 + 前后各一屏），`onDisappear` 降级 / 取消
- [x] 空闲时低优先级补齐剩余项

### 5. 播放

- [x] `MPVRenderBackend` protocol + `MPVGLBackend` 实现（渲染后端必须可替换）
- [x] 从 spike 搬运：render context 建立、update callback、`reshape` 重绘
- [x] `PlaybackController`（`@Observable`），单实例 + `loadfile`
- [x] 启动参数：`--vo=libmpv --idle=yes --keep-open=yes --hr-seek=yes --cache=yes`
- [x] 所有 mpv 命令走 `mpv_command_async`（同步版本会死锁）
- [x] 监听 `end-file` 事件驱动自动播放下一个（不用 mpv 的 playlist）
- [x] 播放 / 暂停 / seek / 音量 / 静音 / 倍速
- [x] 循环模式：单个循环 / 列表循环 / 关闭
- [x] 全屏状态 + `toggleFullscreen()` 接到 `NSWindow.toggleFullScreen`（F / Esc / 中键已接）

### 6. 界面与输入

- [x] `MainView` 左右布局，左侧宽度可拖动
- [x] 素材浏览区显示 / 隐藏，左侧 / 右侧切换
- [x] **视频画面不得被播放列表覆盖**
- [x] `MediaListView` 列表模式，单击即播
- [x] **悬停扫过**：鼠标横向划过缩略图，按位置在精灵图 24 帧间切换（零解码）
- [x] `TransportBar` 播放控制条
- [x] `KeyBindings` 全套快捷键（见 README 第 8 节）
- [x] 选中即播模型：`Q`/`E` 移动选中项即切换视频
- [ ] 建正式 Xcode 工程，关闭 App Sandbox
- [ ] 应用图标：`swift Tools/make-icon.swift icon.png Tools/out` 生成 `.icns` 后放进 bundle

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
| 渲染方式 | `--vo=libmpv` + `mpv_render_context` + 自持 OpenGL 上下文。**`--wid` 在 macOS 上不受支持,已实测作废**。后端藏在 protocol 后面保证可替换 |
| mpv 命令调用 | **一律 `mpv_command_async`**。同步版本在 render API 下会死锁 |
| 应用图标 | 源 `icon.png` 无 alpha,圆角外是纯黑,必须先抠透。`Tools/make-icon.swift` 负责生成 `.icns` |
| 缩略图生成 | AVFoundation 主路径 + ffmpeg 回退，**不用 libmpv** |
| 精灵图抽帧 | 只解关键帧（`-skip_frame nokey` / `tolerance = .infinity`）；24 帧的实际时间戳存进索引 |
| 封面帧选取 | 时间窗口 [35%, 80%] + 纯色剔除，约 40 行。dHash、跨文件片头聚类、Sobel、色彩丰富度**全部作废** |
| 封面选不准怎么办 | `C` 键手动覆盖 + 起始百分比可调。**不再加码启发式** |
| 悬停扫过 | 从 V1.1 提前到 V1。它是封面选不准时的兜底，比把选帧做复杂更有效 |
| 进度条 hover 预览 | 读预生成精灵图，**不需要第二个解码实例**，因此留在 V1.1 而非砍掉 |
| 切换速度方案 | V1 单实例 `loadfile`，实测超标才上预载 |
| `Cmd+W` / `Cmd+S` | 不使用，改为 `Q` / `E` |
| 索引存储 | Codable + 原子写单文件，不上 Core Data |
| 正式工程形式 | XcodeGen 从 `project.yml` 生成，工程文件不入库手改 |
| 抽帧时间偏差 | **必须限定在取样间隔的一半以内**。设成无限会让 24 个取样点塌缩到同一帧（实测中位只剩 3 个不同画面），精灵图彻底失效 |
| ffmpeg `-skip_frame nokey` | 同上，**不能无条件用**。只在关键帧密集的长视频上成立 |
| 流水线阶段 | 拆两段：封面先出（界面立刻可用），精灵图后台补 |
| 缩略图格子 | 统一方形，画面居中裁切填满 |
| 封面存储 | 单独存一份 320×320，不从精灵图裁（那份只有 144px，裁完会糊） |
