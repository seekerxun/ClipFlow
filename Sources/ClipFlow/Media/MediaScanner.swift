import Foundation

/// 目录扫描。只负责找出视频文件，不碰任何解码。
enum MediaScanner {

    /// 扫描阶段的扩展名白名单。
    ///
    /// 注意这与「播放不按扩展名设限」并不矛盾：
    /// 扫描要在成千上万个文件里挑出候选，不能对每个 txt / png 都去试探解码；
    /// 而用户手动打开单个文件时，仍然直接交给 libmpv 尝试解析。
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv", "asf",
        "mpg", "mpeg", "m2v", "ts", "m2ts", "mts", "3gp", "3g2", "ogv",
        "rm", "rmvb", "vob", "divx", "f4v", "mxf", "y4m", "amv",
    ]

    struct Options: Sendable {
        var recursive = true
        /// 递归深度上限。防止符号链接成环，也防止误选一个巨大的根目录时卡死。
        var maxDepth = 8

        init(recursive: Bool = true, maxDepth: Int = 8) {
            self.recursive = recursive
            self.maxDepth = maxDepth
        }
    }

    struct Result: Sendable {
        var items: [MediaItem] = []
        /// 跳过的非视频文件数，用于在界面上说明「这个目录里还有别的东西」。
        var skippedCount = 0
    }

    static func scan(root: URL, options: Options = .init()) -> Result {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey,
            .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]

        // skipsPackageDescendants 让 .fcpbundle / .app 这类「其实是目录的文件」
        // 不会被当成普通目录钻进去。
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles, .skipsPackageDescendants,
        ]
        if !options.recursive {
            enumeratorOptions.insert(.skipsSubdirectoryDescendants)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: enumeratorOptions
        ) else {
            return Result()
        }

        var result = Result()

        while let url = enumerator.nextObject() as? URL {
            if options.recursive, enumerator.level > options.maxDepth {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true || values.isPackage == true { continue }
            // 符号链接一律跳过：解引用会引入成环和重复计入的风险，收益却很小
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }

            guard videoExtensions.contains(url.pathExtension.lowercased()) else {
                result.skippedCount += 1
                continue
            }

            result.items.append(MediaItem(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }

        // 自然序：否则 10.mp4 会排在 9.mp4 前面，一眼就能看出来不对
        result.items.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return result
    }
}
