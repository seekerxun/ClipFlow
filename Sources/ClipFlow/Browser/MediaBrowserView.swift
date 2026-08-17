import SwiftUI

/// 素材浏览区容器：列表 / 网格切换。布局会记住。
struct MediaBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var env = env
        VStack(spacing: 0) {
            header
            if env.isSearchVisible {
                searchBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            sortBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider()
                .opacity(0.45)
            if env.showsGrid {
                MediaGridView()
            } else {
                MediaListView()
            }
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.85)
        }
        .overlay(alignment: env.browserOnRight ? .leading : .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 0.5)
        }
        .animation(.easeOut(duration: 0.18), value: env.isSearchVisible)
        .onChange(of: env.searchFocusRequest) { _, _ in
            focusSearchField()
        }
        .onChange(of: env.isSearchVisible) { _, visible in
            if visible {
                focusSearchField()
            } else {
                isSearchFocused = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            countLabel
            Spacer(minLength: 0)
            Button {
                env.showSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(env.isSearchVisible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("搜索素材（⌘F）")
            .accessibilityLabel("搜索素材")
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
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var countLabel: some View {
        let query = env.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = query.isEmpty
            ? "\(env.items.count) 个视频"
            : "\(env.displayedItems.count) / \(env.items.count) 个视频"
        return Text(text)
            .font(.system(.callout, design: .rounded, weight: .medium))
            .foregroundStyle(.primary.opacity(0.82))
            .monospacedDigit()
    }

    private var searchBar: some View {
        @Bindable var env = env
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索素材", text: $env.searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityLabel("搜索素材")
            Button {
                env.hideSearch()
                isSearchFocused = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("关闭搜索")
            .accessibilityLabel("关闭搜索")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.10),
                    lineWidth: isSearchFocused ? 1 : 0.5
                )
        }
    }

    private var sortBar: some View {
        @Bindable var env = env
        return HStack(spacing: 8) {
            Picker("排序", selection: $env.sort) {
                ForEach(BrowserSort.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .controlSize(.small)
            .help("排序")
            .accessibilityLabel("排序")
            Button {
                env.sortAscending.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: env.sortAscending ? "arrow.up" : "arrow.down")
                    Text(env.sortAscending ? "正序" : "反序")
                }
                .frame(minWidth: 58)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .focusable(false)
            .help("切换正序 / 反序")
            .accessibilityLabel(env.sortAscending ? "正序" : "反序")
            .accessibilityHint("切换排序方向")
        }
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

    private func focusSearchField() {
        DispatchQueue.main.async {
            guard env.isSearchVisible else { return }
            isSearchFocused = true
        }
    }
}
