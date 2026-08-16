// swift-tools-version: 6.0
import PackageDescription
import Foundation

// V0 风险验证用的临时工程，代码可丢弃。
// 用 SPM 而非 Xcode 工程，是为了能直接在命令行 build / run 做自动化验证。
// V1 建正式 Xcode 工程时，Sources 里的东西直接搬过去即可。

/// 探测 Homebrew 前缀，不写死路径（Apple Silicon 是 /opt/homebrew，Intel 是 /usr/local）。
///
/// 没有走 SPM 的 `pkgConfig:`，因为那需要额外安装 pkg-config / pkgconf。
/// 这里只用 FileManager 探测，构建依赖就只剩 brew 和 mpv 本身。
func brewPrefix() -> String {
    if let override = ProcessInfo.processInfo.environment["CLIPFLOW_BREW_PREFIX"] {
        return override
    }
    let candidates = ["/opt/homebrew", "/usr/local"]
    for path in candidates
    where FileManager.default.fileExists(atPath: "\(path)/include/mpv/client.h") {
        return path
    }
    // 都没找到就返回默认值，让编译期报缺头文件的错，比在这里 fatalError 信息更有用
    return candidates[0]
}

let prefix = brewPrefix()

let package = Package(
    name: "ClipFlowSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(
            name: "CMPV",
            path: "Sources/CMPV",
            providers: [.brew(["mpv"])]
        ),
        .executableTarget(
            name: "ClipFlowSpike",
            dependencies: ["CMPV"],
            path: "Sources/ClipFlowSpike",
            swiftSettings: [
                // spike 是一次性代码，不为 Swift 6 严格并发检查买单
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-I\(prefix)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(prefix)/lib"]),
            ]
        ),
    ]
)
