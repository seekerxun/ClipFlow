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
brew install mpv ffmpeg xcodegen
```

### 构建

工程文件由 [`project.yml`](project.yml) 生成，不入库。克隆后先生成一次：

```bash
xcodegen generate
```

之后正常用 Xcode 打开 `ClipFlow.xcodeproj` 即可。加减源文件不需要改工程，`Sources/ClipFlow` 下的文件会自动纳入；只有改构建设置时才需要动 `project.yml` 并重新生成。

Archive / Release 必须只编 **Apple Silicon**。Homebrew 的 `libmpv` 不是通用二进制；Xcode Archive 默认还会再编一套 Intel，链不上 mpv，所有符号都会报找不到。工程里已排除 x86_64。动态链接本机 Homebrew，打出来的包也只能在装了 mpv 的 Apple Silicon 机器上跑。生成工程后若 Xcode 把架构改回 Standard，再 Archive 仍会失败。

命令行构建与跑基准：

```bash
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Debug -derivedDataPath .build/dd build
CLIPFLOW_BENCH="/path/to/videos" .build/dd/Build/Products/Debug/ClipFlow.app/Contents/MacOS/ClipFlow
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

两个实测得到的注意事项：

- **不要用 SPM 的 `pkgConfig:`。** 它要求装 pkg-config / pkgconf，而 macOS 默认没有。直接用 `FileManager` 探测 `/opt/homebrew` 和 `/usr/local` 下的 `include/mpv/client.h` 即可，构建依赖就只剩 brew 和 mpv 本身。
- **Homebrew 的 bottle 按 macOS 版本构建。** 在 macOS 26 上装到的 `libmpv.2.dylib` 标记为 26.0，与声明的最低版本 15.0 不符时链接器会警告。源码分发不受影响（每台机器装自己的 bottle），但**不能把在新系统上构建出的二进制直接发给旧系统的人**。

### 跑 V0 spike

```bash
cd Spike && swift build && CLIPFLOW_SELFTEST=1 ./.build/debug/ClipFlowSpike
```

自测需要一个测试用 MKV（未入库，3 MB）：

```bash
ffmpeg -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -f lavfi -i "sine=frequency=440" -t 8 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest Spike/sample.mkv
```

`testsrc2` 会把时间码和帧号烧进画面，seek 精度可以直接从截图上读出来。

去掉 `CLIPFLOW_SELFTEST=1` 则进入交互模式：空格播放/暂停，左右方向键 ±5s，上下 ±30s。

---

## 3. 播放内核

使用 libmpv，由 mpv / FFmpeg 负责解码，**不自行实现视频解码**。

主要支持：MP4、MOV、MKV、AVI、WebM、FLV、MPG / MPEG、M4V、TS / M2TS、WMV、3GP，以及 libmpv / FFmpeg 可识别的其他格式。

> **原则：不根据扩展名限制播放能力，优先让 libmpv 尝试解析文件。**

### 渲染后端：render API（`--wid` 在 macOS 上不可用）

**`--wid` 不要用。** mpv 手册里 `--wid` 只写了 X11、win32、Android 三个平台，**没有 macOS**。V0 实测确认：mpv 会忽略这个选项，自己开一个独立窗口——带自己的圆角、不受父窗口裁剪、位置对不上，画面会糊到别的 app 上面去。

正确做法是 IINA 那条路：**`--vo=libmpv` + `mpv_render_context`**，由我们自己持有 GL 上下文，mpv 只往我们给的 FBO 里画。几何、裁剪、层级就全部归 AppKit 管，`NSViewRepresentable` 包一层塞进 SwiftUI 即可。

- 渲染 API 只有 **OpenGL** 和 **SW** 两种。SW 是 CPU 回读，太慢。所以 macOS 上只能用 OpenGL——虽然自 10.14 起标记废弃，但仍可用，IINA 也是这么做的。
- 宿主用 `NSOpenGLView`，在 `prepareOpenGL()` 里建 render context，`reshape()` 里重画。窗口缩放由 AppKit 正常处理，V0 已验证。
- SwiftUI 浮层压在上面表现正常，无闪烁、无 z-order 问题，且能被 `screencapture` 正常抓到（mpv 自己的窗口抓不到）。

**必须把渲染后端藏在一个 protocol 后面**，`PlaybackController` 只依赖抽象。将来 OpenGL 真被移除时，换成别的实现不会动到播放逻辑。

### 致命坑：命令必须用 `mpv_command_async`

用 render API 时，从主线程发同步的 `mpv_command` 会**死锁**：

```
主线程调 mpv_command 阻塞
  → mpv 核心等 VO(libmpv) 出帧
    → 出帧要靠主线程回调 mpv_render_context_render
      → 但主线程正卡在 mpv_command 里
```

V0 实测 `screenshot` 命令必挂。**一律用 `mpv_command_async`**，别留例外。

另外别开 `MPV_RENDER_PARAM_ADVANCED_CONTROL`：它要求调用方接管更多渲染时序，履行不到位反而更容易和 mpv 核心互等。基础模式够用。

> 附带发现：`--vo=libmpv` 下 mpv 自己的 `screenshot` 命令不产出文件。对本项目无影响——缩略图走 AVFoundation / ffmpeg，从不经过 mpv。

### 关键启动参数

```
--vo=libmpv           交给 render API，绝不能让 mpv 自己开窗
--idle=yes            空闲时保持实例存活
--keep-open=yes       播完不退出，由 end-file 事件驱动自动下一个
--hr-seek=yes         精确 seek，拖动进度条不跳关键帧
--cache=yes
--hwdec=auto-safe     macOS 上会走 videotoolbox
--osc=no              不要 mpv 自带控制条
--input-default-bindings=no / --input-vo-keyboard=no   键盘归 SwiftUI
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

- **启动时列表为空**，不自动打开上次的文件夹或文件。素材靠拖入或 `Cmd+O` 加入
- 打开文件夹（`Cmd+O`）：把该目录扫到的视频**加入当前列表**，不清空已有条目；可选多个文件夹
- 可拖入多个文件夹、多个视频，或二者混合；能作为视频的都加入列表（追加），同一路径已在列表中则不加第二次；非视频文件安静跳过
- 列表不显示单一目录名；数量、搜索、排序、列表/网格切换仍在
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
- 音量、静音；在**播放区**用鼠标滚轮调音量（上大下小），素材列表上的滚轮仍滚动列表
- 倍速
- 循环播放（单个循环 / 列表循环 / 关闭）
- 片段循环（A-B）：用当前播放位置设起点 / 终点，进度条画出 A/B 标记，两点之间高亮。两端都有且起点早于终点时，只在这段里循环；只设了一端则还不循环。若先设的终点比起点还早，对调成合法区间。有 A-B 时，播到 B 回到 A，不跳下一条；清掉 A-B 后，`L` 的单个 / 列表 / 关闭恢复原意
- 自动播放下一个
- 上一个 / 下一个
- 全屏
- 进度条 hover 显示该位置的缩略图预览（读精灵图，不解码）

---

## 6. 缩略图与精灵图流水线

这是本项目的核心资产。**在索引阶段一次性生成精灵图，同时供三个功能使用**：列表缩略图、网格悬停扫过、进度条 hover 预览。因此不需要第二个解码实例。

### 精灵图规格

| 项 | 精灵图 | 封面 |
|---|---|---|
| 帧数 | 24 帧，在 [3%, 97%] 时长范围内均匀取样 | 1 帧 |
| 尺寸 | 单帧长边 144px（等比缩放），6 × 4 排布 | 320 × 320，居中正方形裁切 |
| 质量 | JPEG 0.75 | JPEG 0.85 |
| 实测体积 | 平均 132 KB | 平均 45 KB |
| 存放位置 | `~/Library/Caches/ClipFlow/sprites/<摘要>.jpg` | `covers/<摘要>.jpg` |

封面单独存一份而不是从精灵图裁：精灵图那份只有 144px，做正方形裁切会糊。

1096 个真实视频实测共占 **189 MB**（封面 50 MB + 精灵图 143 MB），折合每个 177 KB。比预估偏大，主要是 24 帧各不相同时 JPEG 压不动。嫌大可以调低精灵图质量或单帧尺寸，属于可调项。

索引本身放 `~/Library/Application Support/ClipFlow/index.json`——图片是缓存，系统清掉能自动重建；索引重建成本高，不该被系统回收。因此存在「有索引但图没了」的情况，读取方必须能接受并触发重建。

### 生成路径

**主路径：`AVAssetImageGenerator`**（硬件加速，比走 mpv 快一个数量级）：

```swift
generator.maximumSize = CGSize(width: 144, height: 144)   // 解码时就降采样
generator.appliesPreferredTrackTransform = true           // 竖屏素材才不会横过来

// 时间偏差必须限定在取样间隔的一半以内，不能设成无限
let tolerance = CMTime(seconds: min(interval / 2, 0.5), preferredTimescale: 600)
generator.requestedTimeToleranceBefore = tolerance
generator.requestedTimeToleranceAfter  = tolerance
```

#### ⚠️「无限偏差取最近关键帧」是个陷阱

网上通行的抽帧提速做法是把 `requestedTimeTolerance` 设成 `.positiveInfinity`，让解码器就近取关键帧、不逐帧解。**这条建议在短视频素材上会造成严重后果**，1096 个真实文件的实测对比：

| | 无限偏差 | 限定偏差 |
|---|---|---|
| 24 个取样点实际拿到的不同画面 | 中位 **3** 个 | **24** 个 |
| 24 帧完全相同的视频 | **281 / 1096** | 0 |
| 单个视频耗时 | 10ms | 99ms |
| 封面兜底率 | **26%** | **0%** |

原因是这类素材关键帧极稀疏，很多片子整条只有开头一个，于是 24 个取样请求全部被吸附到同一帧。后果是悬停扫过只有一两张不同画面、进度条预览失效、封面候选全落在 0 秒因而大量触发兜底——**精灵图的全部价值都没了**。

代价是慢约十倍，但这个代价必须付。提速要靠下面的两阶段拆分，而不是牺牲时间分布。

> **同理，ffmpeg 的 `-skip_frame nokey` 也不能无条件用。** Jellyfin 报告的约 110 倍加速是真的，但他们的内容是电影剧集：关键帧密集、时长以小时计。换成十几秒、只有一个关键帧的短片，出来的就是一堆重复帧。回退路径要按素材的关键帧密度决定用不用。

**回退路径：ffmpeg**，用于 AVFoundation 打不开的格式（MKV / WebM / FLV / WMV / TS 等）。一个视频只起一个进程：

```bash
ffmpeg -i in.mkv -vf "fps=<每秒帧数>,scale=144:-1,tile=6x4" -frames:v 1 sprite.jpg
```

因为帧间隔不保证正好等于请求值，**索引中必须存下 24 帧各自的实际时间戳**，悬停位置到帧的映射才准确。这个字段做进度条预览也要用。

两条路径产出的精灵图格式完全一致，下游逻辑共用一套。

**不要用 libmpv 生成缩略图。** 500 个文件的目录首次扫描会慢到难以接受。

### 两阶段拆分

封面和精灵图的成本差一个数量级：封面通常只解一帧，精灵图要解 24 帧。全挤在一起做的话，用户得等整个目录的精灵图都生成完才能看到第一屏。所以拆成两段：

| 阶段 | 做什么 | 实测（1096 个真实文件） |
|---|---|---|
| **第一阶段** | 只出封面。按偏好顺序试候选位置，第一个不是近乎纯色的就用它，**多数视频只解一帧** | 折合 500 个 **11.9s** |
| **第二阶段** | 完整 24 帧精灵图，后台补，不阻塞浏览 | 折合 500 个 **49.4s** |

界面在第一阶段结束后就完全可用；悬停扫过等第二阶段补齐后自动生效。

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

- **`B` 键手动覆盖**：播放中按 `B`，把当前帧设为该视频封面。精确 seek 抽一帧、写索引、只重建这一张。
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
[                        将当前播放位置设为片段循环起点（A）
]                        将当前播放位置设为片段循环终点（B）
Shift+[                  取消起点
Shift+]                  取消终点
Z                        循环减速：0.75× → 0.5× → 0.25× → 1× → 0.75× …
X                        恢复 1×
C                        循环加速：1.25× → 1.5× → 2× → 1× → 1.25× …
B                        将当前帧设为该视频封面
Tab                      显示 / 隐藏素材浏览区
Cmd+O                    打开（加入）文件夹
播放区滚轮               调音量（上大下小；素材列表滚轮仍滚动列表）
```

左手区形成一个连贯的簇：`Q`/`E` 换视频，`A`/`D` 小幅 seek，`W`/`S` 大幅 seek，全部单手可达。

有 A-B 区间时，`L` 仍切单个 / 列表 / 关闭，但播到 B 回到 A，不跳下一条；清掉 A-B 后 `L` 恢复原意。

**明确不使用 `Cmd+W` / `Cmd+S`**——它们是"关闭窗口"和"保存"的系统级约定，占用会非常难受。

具体键位后续可调整。

---

## 9. 性能目标

比"尽量即时响应"这种描述有用得多的是可验证的数字。基准折算到 500 个文件。

用 `CLIPFLOW_BENCH=<目录> ClipFlow.app/Contents/MacOS/ClipFlow` 随时复测。

| 指标 | 目标 | 实测 |
|---|---|---|
| 目录扫描（1096 个文件） | — | **0.053s** |
| 目录打开 → 首屏出图 | < 1s | **0.54s** ✅ |
| 500 个文件封面全量 | < 30s | **11.9s** ✅ |
| 500 个文件精灵图全量（后台） | < 60s | **49.4s** ✅ |
| 切换视频 | < 150ms | 待测（界面未搭） |
| 列表滚动（2000 项） | 稳定 60fps | 待测 |
| 进度条 hover 预览响应 | < 16ms（读图，不解码） | 待测 |

实测环境：Apple Silicon 15 核，并发上限 4，素材为 1096 个 h264/hevc 的 mp4，中位时长 10.8 秒，约 40% 竖屏。**1096 个文件零失败。**

> 原先只有「精灵图全量 < 30s」一条。拆成两阶段后这条不再有意义：真正决定「多久能开始浏览」的是封面阶段，精灵图在后台补，慢一点不影响使用。所以指标也跟着拆开了。

---

## 10. 项目结构

```
ClipFlow/
├── App/
│   ├── ClipFlowApp.swift
│   └── AppEnvironment.swift
│
├── Player/
│   ├── MPVClient.swift              # libmpv C API 薄封装（命令一律 async）
│   ├── MPVRenderBackend.swift       # protocol：渲染后端抽象
│   ├── MPVGLBackend.swift           # 实现：vo=libmpv + mpv_render_context + OpenGL
│   ├── MPVVideoView.swift           # NSViewRepresentable
│   └── PlaybackController.swift     # 播放状态机（@Observable）
│
├── Media/
│   ├── MediaItem.swift
│   ├── MediaScanner.swift           # 目录扫描 + 过滤 + 递归
│   └── MediaProbe.swift             # 时长 / 分辨率 / 编码探测（带超时）
│
├── Thumbnail/
│   ├── SpriteGenerator.swift        # 两阶段抽帧：generateCover / generate
│   ├── FFmpegSpriteGenerator.swift  # ffmpeg 回退路径（尚未实现）
│   ├── CoverPicker.swift            # 封面帧选取（候选窗口 + 纯色剔除）
│   └── ThumbnailStore.swift         # 磁盘缓存读写
│
├── Index/
│   ├── MediaIndex.swift             # actor：索引读写 + 原子写
│   ├── IndexRecord.swift            # 落盘结构（Codable，带版本号）
│   └── IndexingPipeline.swift       # 两阶段流水线 + 并发上限
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
