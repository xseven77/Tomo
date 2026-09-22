import XCTest
@testable import Tomo

@MainActor
final class StandalonePetWindowTests: XCTestCase {
    func testCollapsedSizeScalesPet() {
        let one = StandalonePetLayout.collapsedSize(scale: 1.0)
        let big = StandalonePetLayout.collapsedSize(scale: 1.25)
        XCTAssertGreaterThan(big.width, one.width)
        XCTAssertGreaterThan(big.height, one.height)
    }

    func testTaskPanelWidthIsFixed() {
        let size = StandalonePetLayout.taskPanelSize(taskCount: 2)
        XCTAssertEqual(size.width, StandalonePetLayout.taskPanelWidth)
    }

    func testTaskPanelHeightGrowsWithTaskCount() {
        let one = StandalonePetLayout.taskPanelSize(taskCount: 1)
        let four = StandalonePetLayout.taskPanelSize(taskCount: 4)
        let many = StandalonePetLayout.taskPanelSize(taskCount: 9)
        XCTAssertGreaterThan(four.height, one.height)
        XCTAssertEqual(many.height, four.height, "超过 4 条应保持 4 条高度，内部滚动")
    }

    func testStackHeightCapsAtFourRows() {
        let one = StandalonePetLayout.stackHeight(taskCount: 1)
        let four = StandalonePetLayout.stackHeight(taskCount: 4)
        let many = StandalonePetLayout.stackHeight(taskCount: 9)
        XCTAssertGreaterThan(four, one)
        XCTAssertEqual(many, four)
        XCTAssertEqual(StandalonePetLayout.stackHeight(taskCount: 0), 84)
    }

    func testToggleExpanded() {
        let model = StandalonePetViewModel()
        model.toggleExpanded()
        XCTAssertTrue(model.isExpanded)
        model.toggleExpanded()
        XCTAssertFalse(model.isExpanded)
    }

    func testTaskCountDidChange() {
        let model = StandalonePetViewModel()
        var received: Int?
        model.onTaskCountChanged = { received = $0 }
        model.taskCountDidChange(3)
        XCTAssertEqual(model.taskCount, 3)
        XCTAssertEqual(received, 3)
    }

    func testEdgeChangeNotifiesAndClearsFreeOrigin() {
        let model = StandalonePetViewModel()
        model.freeOrigin = NSPoint(x: 100, y: 200)
        var received: StandalonePetEdge?
        model.onEdgeChange = { received = $0 }
        model.setEdge(.right)
        XCTAssertEqual(model.edge, .right)
        XCTAssertEqual(received, .right)
        XCTAssertNil(model.freeOrigin)
    }

    func testEffectiveEdgeIsBottomWhenFreeFloating() {
        let model = StandalonePetViewModel()
        model.edge = .left
        XCTAssertEqual(model.effectiveEdge, .left)
        model.freeOrigin = NSPoint(x: 0, y: 0)
        XCTAssertEqual(model.effectiveEdge, .bottom)
    }

    func testCornerEdgesAreIncludedWithStableRawValues() {
        let cases = StandalonePetEdge.allCases
        XCTAssertEqual(cases.count, 8)
        XCTAssertEqual(StandalonePetEdge(rawValue: "topRight"), .topRight)
        XCTAssertEqual(StandalonePetEdge(rawValue: "bottomRight"), .bottomRight)
        XCTAssertEqual(StandalonePetEdge(rawValue: "topLeft"), .topLeft)
        XCTAssertEqual(StandalonePetEdge(rawValue: "bottomLeft"), .bottomLeft)
        XCTAssertEqual(StandalonePetEdge.topRight.title, "右上")
        XCTAssertEqual(StandalonePetEdge.bottomRight.title, "右下")
        XCTAssertEqual(StandalonePetEdge.topLeft.title, "左上")
        XCTAssertEqual(StandalonePetEdge.bottomLeft.title, "左下")
    }

    func testCornerEdgesRepositionPetIntoCorners() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 100, height: 120)
        let gap = StandalonePetLayout.edgeGap
        // 通过布局函数验证四角定位：窗口应贴住对应角并留 edgeGap。
        let topLeft = StandalonePetWindowController.edgeFrame(size: size, edge: .topLeft, in: visible)
        XCTAssertEqual(topLeft.minX, visible.minX + gap)
        XCTAssertEqual(topLeft.maxY, visible.maxY - gap)
        let topRight = StandalonePetWindowController.edgeFrame(size: size, edge: .topRight, in: visible)
        XCTAssertEqual(topRight.maxX, visible.maxX - gap)
        XCTAssertEqual(topRight.maxY, visible.maxY - gap)
        let bottomLeft = StandalonePetWindowController.edgeFrame(size: size, edge: .bottomLeft, in: visible)
        XCTAssertEqual(bottomLeft.minX, visible.minX + gap)
        XCTAssertEqual(bottomLeft.minY, visible.minY + gap)
        let bottomRight = StandalonePetWindowController.edgeFrame(size: size, edge: .bottomRight, in: visible)
        XCTAssertEqual(bottomRight.maxX, visible.maxX - gap)
        XCTAssertEqual(bottomRight.minY, visible.minY + gap)
    }

    func testShowRestoresPetPanelAfterItWasOrderedOut() {
        let suiteName = "StandalonePetWindowTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建隔离的 UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(
            defaults: defaults,
            codexPetSelectionSync: CodexPetSelectionSync(
                configURL: URL(fileURLWithPath: "/dev/null")
            )
        )
        let controller = StandalonePetWindowController(
            activityStore: CodexActivityStore(),
            frameStore: PetFrameStore(),
            settings: settings
        )

        controller.show()
        XCTAssertTrue(controller.isVisible)
        controller.hide()
        XCTAssertFalse(controller.isVisible)
        controller.show()
        XCTAssertTrue(controller.isVisible, "应用模式切换后再次 show 应恢复独立 Pet")
        controller.hide()
    }
}
