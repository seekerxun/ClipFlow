import AppKit
import XCTest
@testable import ClipFlow

@MainActor
final class BrowserSelectionTests: XCTestCase {
    func testCommandAndShiftSelectionFollowDisplayedOrder() {
        let env = makeEnvironment()
        let items = makeItems(count: 5)
        env.items = items

        env.select(items[0])
        env.selectFromBrowser(items[2], modifiers: .command)
        XCTAssertEqual(env.selectedIDs, [items[0].id, items[2].id])

        let displayed = env.displayedItems
        let anchorIndex = displayed.firstIndex(of: items[0])!
        let targetIndex = displayed.firstIndex(of: items[3])!
        let expectedRange = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        env.selectFromBrowser(items[3], modifiers: .shift)
        XCTAssertEqual(env.selectedIDs, Set(expectedRange.map { displayed[$0].id }))
        XCTAssertEqual(env.selectedID, items[3].id)
    }

    func testContextMenuUsesGroupOnlyWhenPointerItemIsSelected() {
        let env = makeEnvironment()
        let items = makeItems(count: 3)
        env.items = items
        env.select(items[0])
        env.selectFromBrowser(items[1], modifiers: .command)

        XCTAssertEqual(env.contextActionIDs(for: items[0]), [items[0].id, items[1].id])
        XCTAssertEqual(env.contextActionIDs(for: items[2]), [items[2].id])
    }

    func testRemovingMultipleSelectionMovesPlaybackToNextRemainingItem() {
        let env = makeEnvironment()
        let items = makeItems(count: 4)
        env.items = items
        env.select(items[1])
        env.selectFromBrowser(items[2], modifiers: .command)
        let targets = env.selectedIDs
        let displayed = env.displayedItems
        let currentIndex = displayed.firstIndex(of: items[2])!
        let expectedNext = displayed.suffix(from: displayed.index(after: currentIndex))
            .first { !targets.contains($0.id) }
            ?? displayed[..<currentIndex].reversed().first { !targets.contains($0.id) }

        env.removeSelectedItemsFromList()

        XCTAssertEqual(env.items.map(\.id), [items[0].id, items[3].id])
        XCTAssertEqual(env.selectedIDs, [expectedNext!.id])
        XCTAssertEqual(env.selectedID, expectedNext!.id)
    }

    private func makeEnvironment() -> AppEnvironment {
        let env = AppEnvironment()
        env.thumbnails.enableProcessing = false
        return env
    }

    private func makeItems(count: Int) -> [MediaItem] {
        (0..<count).map { index in
            MediaItem(
                url: URL(fileURLWithPath: "/tmp/clipflow-selection-\(index).mp4"),
                size: Int64(index + 1),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }
    }
}
