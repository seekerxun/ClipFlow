import SwiftUI

/// 素材浏览区容器：列表 / 网格切换。布局会记住。
struct MediaBrowserView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                TextField("搜索文件名", text: $env.searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Picker("排序", selection: $env.sort) {
                    ForEach(BrowserSort.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("排序")
                .accessibilityLabel("排序")
                Button {
                    env.sortAscending.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: env.sortAscending ? "arrow.up" : "arrow.down")
                        Text(env.sortAscending ? "正序" : "反序")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .focusable(false)
                .help("切换正序 / 反序")
                .accessibilityLabel(env.sortAscending ? "正序" : "反序")
                .accessibilityHint("切换排序方向")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()
            if env.showsGrid {
                MediaGridView()
            } else {
                MediaListView()
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            countLabel
            Spacer(minLength: 0)
            layoutPicker
            Button {
                env.browserOnRight.toggle()
            } label: {
                Image(systemName: env.browserOnRight
                      ? "sidebar.right"
                      : "sidebar.left")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(env.browserOnRight ? "移到左侧" : "移到右侧")
            Button {
                env.isBrowserVisible = false
            } label: {
                Image(systemName: env.browserOnRight ? "chevron.right" : "chevron.left")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("收起素材浏览区")
            .accessibilityLabel("收起素材浏览区")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var countLabel: some View {
        let query = env.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = query.isEmpty
            ? "\(env.items.count)"
            : "\(env.displayedItems.count)/\(env.items.count)"
        return Text(text)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var layoutPicker: some View {
        HStack(spacing: 0) {
            layoutButton(grid: false, symbol: "list.bullet", label: "列表")
            layoutButton(grid: true, symbol: "square.grid.2x2", label: "网格")
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("浏览方式")
    }

    private func layoutButton(grid: Bool, symbol: String, label: String) -> some View {
        let selected = env.showsGrid == grid
        return Button {
            env.showsGrid = grid
        } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 18)
                .background(
                    selected
                        ? Color.accentColor.opacity(0.22)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
