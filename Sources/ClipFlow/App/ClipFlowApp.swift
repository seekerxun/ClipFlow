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
    var body: some Scene {
        WindowGroup("ClipFlow") {
            MainView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
