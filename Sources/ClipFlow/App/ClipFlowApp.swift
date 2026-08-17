import SwiftUI

@main
struct ClipFlowMain {
    static func main() {
        // 基准测试模式：不起界面，跑完直接退出
        if Bench.runIfRequested() {
            exit(0)
        }
        ClipFlowApp.main()
    }
}

struct ClipFlowApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("ClipFlow") {
            MainView()
                .environment(environment)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") {
                    environment.promptOpenFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(environment.isBrowserVisible ? "隐藏素材浏览区" : "显示素材浏览区") {
                    environment.isBrowserVisible.toggle()
                }
                Button("素材浏览区在左侧") {
                    environment.browserOnRight = false
                    environment.isBrowserVisible = true
                }
                Button("素材浏览区在右侧") {
                    environment.browserOnRight = true
                    environment.isBrowserVisible = true
                }
            }
        }
    }
}
