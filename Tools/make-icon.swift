#!/usr/bin/env swift

// 从 icon.png 生成 macOS 标准 AppIcon.icns。
//
// 源图是不带 alpha 的方形 PNG，squircle 圆角外面是纯黑填充。
// 直接拿去当图标，Dock / Finder 里会显示成一个黑方块。
// 这里从四边做洪泛填充，只把「与画布边缘连通的近黑像素」抠成透明，
// 这样图标内部本身的黑色区域（缩略图暗部、播放键阴影）不会被误伤。
//
// 用法：swift Tools/make-icon.swift icon.png Tools/out

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: swift Tools/make-icon.swift <输入.png> <输出目录>")
    exit(2)
}
let inputPath = args[1]
let outDir = args[2]

/// 判定为背景的阈值：三个通道都不超过这个值才算「近黑」。
let blackThreshold: UInt8 = 18
let masterSize = 1024

// MARK: - 载入并重绘到 1024×1024 RGBA

guard let source = NSImage(contentsOfFile: inputPath),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    print("读不到图片: \(inputPath)")
    exit(1)
}
print("源图: \(sourceCG.width)×\(sourceCG.height), alpha = \(sourceCG.alphaInfo.rawValue)")

guard let ctx = CGContext(
    data: nil,
    width: masterSize,
    height: masterSize,
    bitsPerComponent: 8,
    bytesPerRow: masterSize * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("建 CGContext 失败")
    exit(1)
}
ctx.interpolationQuality = .high
ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: masterSize, height: masterSize))

guard let raw = ctx.data else {
    print("拿不到位图数据")
    exit(1)
}
let px = raw.bindMemory(to: UInt8.self, capacity: masterSize * masterSize * 4)

func isNearBlack(_ index: Int) -> Bool {
    let o = index * 4
    return px[o] <= blackThreshold && px[o + 1] <= blackThreshold && px[o + 2] <= blackThreshold
}

let corner = (r: px[0], g: px[1], b: px[2])
print("左下角像素: rgb(\(corner.r), \(corner.g), \(corner.b))")

// MARK: - 从四边洪泛，抠掉与边缘连通的黑色

var visited = [Bool](repeating: false, count: masterSize * masterSize)
var stack: [Int] = []

func seed(_ index: Int) {
    guard !visited[index], isNearBlack(index) else { return }
    visited[index] = true
    stack.append(index)
}

for x in 0..<masterSize {
    seed(x)                                    // 底边
    seed((masterSize - 1) * masterSize + x)    // 顶边
}
for y in 0..<masterSize {
    seed(y * masterSize)                       // 左边
    seed(y * masterSize + masterSize - 1)      // 右边
}

var cleared = 0
while let index = stack.popLast() {
    let o = index * 4
    px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = 0
    cleared += 1

    let x = index % masterSize
    let y = index / masterSize
    if x > 0 { seed(index - 1) }
    if x < masterSize - 1 { seed(index + 1) }
    if y > 0 { seed(index - masterSize) }
    if y < masterSize - 1 { seed(index + masterSize) }
}

let total = masterSize * masterSize
print("抠掉 \(cleared) 像素（占 \(String(format: "%.1f", Double(cleared) * 100 / Double(total)))%）")

if cleared == 0 {
    print("警告：一个像素都没抠掉，源图边缘可能不是纯黑，请检查。")
} else if cleared > total / 2 {
    print("警告：抠掉超过一半，阈值可能过高，请检查输出。")
}

// MARK: - 写出主图

guard let masterCG = ctx.makeImage() else {
    print("makeImage 失败")
    exit(1)
}
try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true
)
let masterPath = "\(outDir)/icon-1024.png"
let rep = NSBitmapImageRep(cgImage: masterCG)
rep.size = NSSize(width: masterSize, height: masterSize)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    print("PNG 编码失败")
    exit(1)
}
try! pngData.write(to: URL(fileURLWithPath: masterPath))
print("已写出 \(masterPath)")

// MARK: - 生成 iconset 并转 icns

let iconsetDir = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(
    atPath: iconsetDir, withIntermediateDirectories: true
)

/// macOS 要求的全套尺寸：(边长, 文件名)
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

for (size, name) in variants {
    _ = run("/usr/bin/sips", [
        "-z", String(size), String(size), masterPath,
        "--out", "\(iconsetDir)/\(name)",
    ])
}

let icnsPath = "\(outDir)/AppIcon.icns"
let status = run("/usr/bin/iconutil", ["-c", "icns", iconsetDir, "-o", icnsPath])
if status == 0 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: icnsPath)
    let size = (attrs?[.size] as? Int) ?? 0
    print("已写出 \(icnsPath)（\(size / 1024) KB）")
} else {
    print("iconutil 失败，状态码 \(status)")
    exit(1)
}
