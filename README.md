# ClipFlow / 片巡

一个仅用于 macOS 的本地视频素材浏览器，解决**大量短视频快速浏览和切换**的问题。

仓库：https://github.com/seekerxun/ClipFlow.git

---

## 1. 项目目标

典型场景：

- 一个目录包含几十到几百个视频
- 单个视频时长约几秒到几十秒，偶尔十几分钟
- 格式比较杂，包含多年以前收集的旧素材，但大部分是 mp4
- 播放列表始终独立显示，不遮挡视频画面
- 点击素材即可立即播放

**项目重点不是替代 IINA / VLC，而是提高批量浏览视频素材的效率。**

定位约束：

- 仅供个人及小范围熟人使用
- 在 GitHub 开源
- 不上架任何 Store

这三条约束直接决定了下面若干技术选择（不启用沙盒、依赖 Homebrew、不处理 GPL 分发问题）。

---

## 2. 环境与依赖

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | **macOS 15 (Sequoia) 及以上** | 见下方说明 |
| 语言 | Swift 6 | |
| UI | SwiftUI 为主，必要时 AppKit | |
| 播放内核 | libmpv | `brew install mpv` |
| 抽帧回退 | ffmpeg | `brew install ffmpeg` |
| 沙盒 | **不启用** | |

```bash
brew install mpv ffmpeg
```

### 为什么是 macOS 15

技术栈里真正卡版本的是 SwiftUI：`@Observable`（14+）、`.onKeyPress`（14+）、`AVAssetImageGenerator` 的 async API（14+）、`onScrollGeometryChange`（15+）。取 15 可以把这些全部拿到手，且不需要写任何版本兼容分支。

再往上（macOS 26）对本项目没有额外收益，只会无谓地排除掉还没升级的机器，所以停在 15。libmpv / ffmpeg 走 Homebrew，不构成版本约束。

### 为什么不启用沙盒

不上架 Store，因此没有必须沙盒化的理由。关掉沙盒可以省掉一整套 security-scoped bookmark 逻辑：重启后恢复目录访问权限、书签失效重建、递归子目录逐级授权等等。这是一个能省掉数百行状态管理代码的决定。

### 关于 libmpv 的集成与分发

**V1 直接动态链接 Homebrew 安装的 libmpv**，README 中把 `brew install mpv` 写为前置依赖。`brew install mpv` 自带 `libmpv.dylib` 和 `mpv/client.h`，Swift 侧写一个 module map 即可使用。

构建配置**不要写死路径**：Apple Silicon 是 `/opt/homebrew`，Intel 是 `/usr/local`，用 `brew --prefix` 探测。

以下工作**全部推迟**，等真的有人反馈装不上再做：

- 自行编译 libmpv 静态库打进 app bundle
- `install_name_tool` 改 `@rpath` + 重签名
- GPL / LGPL 许可处理（mpv 默认 GPLv2+，`--enable-lgpl` 可构建 LGPL 版本但会砍功能）

动态链接 + 用户自备 mpv 的模式下，GPL 的传染性问题基本不需要碰。

---

## 3. 播放内核

使用 libmpv，由 mpv / FFmpeg 负责解码，**不自行实现视频解码**。

主要支持：MP4、MOV、MKV、AVI、WebM、FLV、MPG / MPEG、M4V、TS / M2TS、WMV、3GP，以及 libmpv / FFmpeg 可识别的其他格式。

> **原则：不根据扩展名限制播放能力，优先让 libmpv 尝试解析文件。**

### 渲染后端

V1 走 `--wid`：把 mpv 渲染到一个 `NSView`，外面用 `NSViewRepresentable` 包一层。实现简单，风险低。

但**必须把渲染后端藏在一个 protocol（`MPVRenderBackend`）后面**，`PlaybackController` 只依赖抽象。将来若要换成 libmpv render API + `CAMetalLayer`（IINA 的做法，支持多实例和更精细的控制），不会动到播放逻辑。

已知坑：`--wid` 模式下 mpv 在 NSView 里挂自己的 CALayer，SwiftUI 画在其上的浮层（控制条、hover 预览）偶尔会有 z-order 或闪烁问题。因此浮层设计要克制——这也是把进度条预览做成"读预生成精灵图"而非"实时解码"的动机之一。

### 关键启动参数

```
--idle=yes            空闲时保持实例存活
--keep-open=yes       播完不退出，由 end-file 事件驱动自动下一个
--hr-seek=yes         精确 seek，拖动进度条不跳关键帧
--cache=yes
```

`keep-open` 是必须的，否则播放结束会直接销毁窗口。自动播放下一个通过监听 `end-file` 事件自行控制，不交给 mpv 的 playlist。

### 切换速度

**V1 用单实例 + `loadfile`**。本地文件通常本来就在 100ms 内完成，先测量再优化。

不要一上来就做 A/B 双实例交替预载。只有当 V1 实测切换延迟稳定超过 150ms 时，才考虑引入预载方案——它的代价是内存翻倍和显著的复杂度上升。

---

## 4. 界面

### 列表模式（默认）

```
┌────────────────────┬──────────────────────────────┐
│ 素材浏览区          │                              │
│                    │                              │
│ [缩略图] 001.mp4   │                              │
│ [缩略图] 002.mov   │          视频播放区          │
│ [缩略图] 003.avi   │                              │
│ [缩略图] 004.mkv   │                              │
│ ...                │                              │
│                    │                              │
└────────────────────┴──────────────────────────────┘
```

- 左侧宽度可拖动调整
- 素材浏览区支持显示 / 隐藏，支持切换到左侧 / 右侧
- **视频画面不得被播放列表覆盖**

### 网格模式

一屏铺 40–60 个缩略图，用于快速扫过整批素材。这是批量浏览效率的主要来源——列表模式适合精看，网格模式适合筛。

**悬停扫过（hover scrub）**：鼠标横向划过某个缩略图时，按横向位置在该视频的精灵图 24 帧之间切换，等于不点击就能预览整个片子的内容走向。因为精灵图在索引阶段已经生成，这个功能是零解码成本的。

---

## 5. 核心功能

### 文件夹浏览

- 打开文件夹（`Cmd+O`）
- 拖入文件夹
- 自动扫描目录中的视频，支持递归扫描子目录（**需设深度上限**，防止符号链接成环）
- 显示文件名、时长、分辨率
- 自动生成缩略图

扫描时需过滤：`.DS_Store`、隐藏文件、macOS 包（`.fcpbundle` / `.app` 等）、符号链接环。

**排序必须使用 `localizedStandardCompare`**，否则 `10.mp4` 会排在 `9.mp4` 前面。这个细节一眼就能被看出来。

**时长与分辨率异步填充**：列表先用文件名立刻渲染出来，元数据后到。不要为了等元数据卡住首屏。元数据探测要设超时——NAS 上的老素材可能让 `AVAsset` 挂很久。

### 视频播放

- 单击素材立即播放
- 播放 / 暂停
- 拖动进度
- 音量、静音
- 倍速
- 循环播放（单个循环 / 列表循环 / 关闭）
- 自动播放下一个
- 上一个 / 下一个
- 全屏
- 进度条 hover 显示该位置的缩略图预览（读精灵图，不解码）

---

## 6. 缩略图与精灵图流水线

这是本项目的核心资产。**在索引阶段一次性生成精灵图，同时供三个功能使用**：列表缩略图、网格悬停扫过、进度条 hover 预览。因此不需要第二个解码实例。

### 精灵图规格

| 项 | 值 |
|---|---|
| 帧数 | 24 帧，在 [3%, 97%] 时长范围内均匀取样 |
| 单帧宽度 | 160px（等比缩放） |
| 排布 | 6 × 4 网格 |
| 格式 | JPEG，质量 0.8 |
| 单文件体积 | 约 40–60 KB |
| 存放位置 | `~/Library/Caches/ClipFlow/sprites/<hash>.jpg` |

500 个视频约 20–30 MB，完全可接受。

### 生成路径

**主路径：`AVAssetImageGenerator`**（硬件加速，比走 mpv 快一个数量级）。关键参数一个都不能漏：

```swift
generator.maximumSize = CGSize(width: 160, height: 160)     // 解码时就降采样
generator.requestedTimeToleranceBefore = .positiveInfinity  // 允许就近关键帧
generator.requestedTimeToleranceAfter  = .positiveInfinity  // 不做精确帧解码
generator.appliesPreferredTrackTransform = true             // 尊重旋转元数据
```

不加 tolerance 的话每帧都要从关键帧解码到目标帧，慢十倍以上。用 `images(for:)` 一次提交全部 24 个时间点，比循环单帧请求便宜。

**回退路径：ffmpeg**，用于 AVFoundation 打不开的格式（MKV / WebM / FLV / WMV / TS 等）。一个视频只起一个进程：

```bash
ffmpeg -skip_frame nokey -i in.mkv -vf "scale=160:-1,tile=6x4" -frames:v 1 -fps_mode passthrough sprite.jpg
```

**`-skip_frame nokey` 是这里最重要的一个参数**：只解关键帧。Jellyfin 实测这一项带来约 **110 倍**加速（244 fps vs 2.2 fps），因为不需要解码整条视频。代价是帧的时间点不再均匀。

这与 AVFoundation 路径上 `requestedTimeTolerance = .positiveInfinity` 是同一个思路——两条路径都放弃精确时间点、换取只碰关键帧。

因为两条路径的帧间隔都不保证均匀，**索引中必须存下 24 帧各自的实际时间戳**，hover 位置到帧的映射才准确。这个字段本来做进度条预览也要用。

两条路径产出的精灵图格式完全一致，下游逻辑共用一套。

**不要用 libmpv 生成缩略图。** 500 个文件的目录首次扫描会慢到难以接受。

### 封面帧选取

这是老素材最容易翻车的地方：开头几秒常常是黑屏、淡入，或者**网站 / 个人 logo 开场动画**。素材来源很杂，这些片头各不相同，但共同点是都出现在视频开头。一屏全是黑帧和 logo 卡的缩略图墙会让工具直接失去价值。

#### 先看实际项目怎么做

| 项目 | 做法 |
|---|---|
| **ffmpegthumbnailer**（Nautilus / Dolphin / Thunar 的缩略图后端） | 默认 seek 到 **10%**。可选 smart 模式：在该点取 25 帧连续帧各算直方图，选与平均直方图 **RMSE 最小**的一帧（最"典型"） |
| **ffmpeg 内置 `thumbnail` 滤镜** | 按 100 帧一批各算 RGB 直方图，选与平均直方图**差异最大**的一帧（最"独特"） |
| **Jellyfin** | 固定百分比抽帧，无智能选择 |
| **Kodi** | 历史上取 1/3 处 |

两点值得注意：

1. **ffmpegthumbnailer 和 ffmpeg 的启发式方向正好相反**——一个选最典型的，一个选最独特的，两个都是被广泛使用的成熟实现。这说明"帧评分"这个问题本身没有公认最优解，继续加码的投入产出比很低。
2. **没有任何一个项目在处理片头 logo。** 因为它们面对的是电影和剧集，10% 早就过了片头。ClipFlow 面对的是几秒到几十秒的短片，10% 可能还在 logo 里——**这是我们和它们唯一实质性的差别。**

所以真正的杠杆只有一个：**候选时间窗口**。不是更聪明的评分函数。

#### 实际方案

精灵图已有 24 帧，封面选取就是"从这 24 帧里挑一帧"，逻辑到此为止：

1. **候选范围取 [35%, 80%]**（24 帧中的第 9–19 帧）。取 35% 而非业界常见的 10%，正是针对"短片 + 片头"这个场景调的。
2. **剔除近乎纯色的帧**：平均亮度 < 16 或 > 240，或亮度标准差 < 12。这一步过滤黑场、淡入、白底 logo 卡。
3. **取第一个存活的帧**。
4. 全被剔除则放宽到 [20%, 95%] 再来一遍；仍然全灭就取中间帧，并在索引中标记，避免每次扫描重算。
5. 时长 < 4 秒的片子跳过第 1 步的时间偏置，直接对全部 24 帧走第 2 步。

大约 40 行代码，**零额外解码成本**（全部跑在已生成的精灵图上）。

> 早期版本设计过 dHash 跨文件片头指纹 + 场景切变检测 + Sobel 边缘密度 + 色彩丰富度加权评分的三层方案，**已全部作废**。其中跨文件指纹那层的前提是"同一批素材共用同一个片头"，而实际素材来源很杂、片头并不重复，前提本身就不成立。

#### 两个逃生口比启发式更重要

任何启发式都会失手。与其把评分做复杂，不如保证失手时的代价足够低：

- **`C` 键手动覆盖**：播放中按 `C`，把当前帧设为该视频封面。精确 seek 抽一帧、写索引、只重建这一张。
- **起始百分比做成偏好设置**（默认 35%）。你比任何启发式都更清楚自己的素材，一个滑块顶得上一堆代码。

#### 最好的答案是不依赖封面

如果在网格模式下鼠标划过缩略图就能扫完 24 帧，那封面选得准不准就没那么要紧了——**一秒之内就能看到整个片子的内容走向。**

所以与其在选帧上加码，不如把**悬停扫过从 V1.1 提前到 V1**。这是把"猜哪一帧有代表性"这个问题绕过去，而不是去解决它。

### 调度策略

**这是"首屏 < 1s"的唯一解法。** 打开目录时绝不能把 500 个文件一次性排进队列。

- 只为**当前可见行 + 前后各一屏**的项目排队。`LazyVStack` / `LazyVGrid` 的 `onAppear` 入队，`onDisappear` 降级或取消。
- 并发上限 `min(4, activeProcessorCount / 2)`。视频解码是内存大户，开 500 个 Task 会直接爆内存。
- 剩余项目在空闲时以低优先级慢慢补齐。

有了可见优先级调度，"首屏出图 < 1s" 与目录里有 500 个还是 5000 个文件无关。

---

## 7. 索引与缓存

这是实际最容易失控的地方，规格必须先定死。

| 项 | 方案 |
|---|---|
| 缓存键 | `路径 + 文件大小 + mtime`，任一变化则失效重建 |
| 精灵图 | 存磁盘，索引只存路径引用，**不要把图存进数据库** |
| 存储形式 | V1 用 Codable + 原子写的单文件索引 |
| 失败记录 | **必须落库** |

**失败状态必须持久化。** 老素材里必然混着坏文件、无视频流的文件、零时长文件。如果不记录失败，每次扫描都会重试同一批坏文件，直接卡死在那里。记录失败原因和时间，同一 `(路径, 大小, mtime)` 下不再重试。

**存储选型**：几千条以内，一个 Codable + 原子写的索引文件完全够用。不要一上来就上 Core Data。真到几万条再换 GRDB。

索引访问统一走一个 `actor`，避免并发写。

---

## 8. 快捷键

采用**选中即播**模型：移动选中项就等于切换视频，不存在独立的"上一个视频"概念。

```
Space                    播放 / 暂停
Q / PageUp / Cmd+↑       上一个视频
E / PageDown / Cmd+↓     下一个视频
A / ←                    后退 5s
D / →                    快进 5s
W / ↑                    大幅后退 30s
S / ↓                    大幅快进 30s
F / 鼠标中键              全屏 / 退出全屏
Esc                      退出全屏
L                        循环模式切换（单个 / 列表 / 关闭）
M                        静音
[ / ]                    降低 / 提高倍速
C                        将当前帧设为该视频封面
Tab                      显示 / 隐藏素材浏览区
Cmd+O                    打开文件夹
```

左手区形成一个连贯的簇：`Q`/`E` 换视频，`A`/`D` 小幅 seek，`W`/`S` 大幅 seek，全部单手可达。

**明确不使用 `Cmd+W` / `Cmd+S`**——它们是"关闭窗口"和"保存"的系统级约定，占用会非常难受。

具体键位后续可调整。

---

## 9. 性能目标

比"尽量即时响应"这种描述有用得多的是可验证的数字。基准：500 个文件的本地目录。

| 指标 | 目标 |
|---|---|
| 目录打开 → 首屏出图 | < 1s |
| 500 个文件精灵图全量生成 | < 30s |
| 切换视频 | < 150ms |
| 列表滚动（2000 项） | 稳定 60fps |
| 进度条 hover 预览响应 | < 16ms（读图，不解码） |

---

## 10. 项目结构

```
ClipFlow/
├── App/
│   ├── ClipFlowApp.swift
│   └── AppEnvironment.swift
│
├── Player/
│   ├── MPVClient.swift              # libmpv C API 薄封装
│   ├── MPVRenderBackend.swift       # protocol：渲染后端抽象
│   ├── MPVWidBackend.swift          # V1 实现：--wid + NSView
│   ├── MPVVideoView.swift           # NSViewRepresentable
│   └── PlaybackController.swift     # 播放状态机（@Observable）
│
├── Media/
│   ├── MediaItem.swift
│   ├── MediaScanner.swift           # 目录扫描 + 过滤 + 递归
│   └── MediaProbe.swift             # 时长 / 分辨率 / 编码探测（带超时）
│
├── Thumbnail/
│   ├── SpriteGenerator.swift        # AVFoundation 主路径
│   ├── FFmpegSpriteGenerator.swift  # ffmpeg 回退路径（-skip_frame nokey）
│   ├── CoverPicker.swift            # 封面帧选取（时间窗口 + 纯色剔除，约 40 行）
│   └── ThumbnailStore.swift         # 磁盘缓存读写
│
├── Index/
│   ├── MediaIndex.swift             # actor：索引读写
│   ├── IndexRecord.swift            # 落盘结构（Codable）
│   └── IndexStore.swift             # 原子写 / 版本迁移
│
├── Browser/
│   ├── MediaBrowserView.swift       # 容器：列表 / 网格模式切换
│   ├── MediaListView.swift
│   ├── MediaGridView.swift
│   ├── MediaItemView.swift          # 含悬停扫过
│   └── ThumbnailQueue.swift         # 可见优先级调度
│
├── Playback/
│   ├── PlayerView.swift
│   ├── TransportBar.swift
│   └── SeekPreview.swift            # 进度条 hover 预览（读精灵图）
│
├── Input/
│   └── KeyBindings.swift
│
└── Main/
    └── MainView.swift
```

不使用 MVVM 套路，直接用 `@Observable`。

---

## 11. 核心原则

> **优先做好"大量短视频快速浏览"，不要把项目做成另一个 IINA。**

任何功能在加入之前先问一句：它是否让"扫过 500 个素材"这件事更快？如果不是，它就属于 [TODO.md](TODO.md) 里的暂缓区。

---

## 12. 参考

缩略图与抽帧方案的调研来源：

- [ffmpegthumbnailer](https://github.com/dirkvdb/ffmpegthumbnailer) —— Nautilus / Dolphin / Thunar 的缩略图后端。默认 10% seek；smart 模式取 25 帧算直方图，选 RMSE 最小（最典型）的一帧
- [ffmpeg `thumbnail` 滤镜文档](https://ayosec.github.io/ffmpeg-filters-docs/8.0/Filters/Video/thumbnail.html) —— 按批算 RGB 直方图，选与均值差异最大（最独特）的一帧
- [Jellyfin #11336：用关键帧生成 trickplay，约 110 倍加速](https://github.com/jellyfin/jellyfin/issues/11336) —— 244 fps vs 2.2 fps 的实测对比，`-skip_frame nokey` 的依据
